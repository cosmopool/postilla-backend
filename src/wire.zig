//! The binary encoding every body shares (specification.md, Encoding): big-endian,
//! no padding, `str` as a u32 length then UTF-8, `lang` as 8 zero-padded ASCII bytes,
//! `uuid` as 16 bytes, and a 4-byte magic plus a u8 version at the start of every body.

const std = @import("std");

pub const version: u8 = 1;

/// A story id: the UUID's 16 bytes in written order.
pub const StoryId = struct {
    bytes: [16]u8 = @splat(0),

    /// Parses the written form, `d0159518-99cc-46f0-bef2-b5b6f6f9a76d`, lowercase or
    /// uppercase hex.
    pub fn parse(written: []const u8) error{BadUuid}!StoryId {
        if (written.len != 36) return error.BadUuid;
        var id: StoryId = .{};
        var hex: [32]u8 = undefined;
        var n: usize = 0;
        for (written, 0..) |ch, i| {
            const dash = i == 8 or i == 13 or i == 18 or i == 23;
            if (dash != (ch == '-')) return error.BadUuid;
            if (dash) continue;
            hex[n] = ch;
            n += 1;
        }
        _ = std.fmt.hexToBytes(&id.bytes, &hex) catch return error.BadUuid;
        return id;
    }

    /// The written form, lowercase.
    pub fn text(id: StoryId) [36]u8 {
        const hex = std.fmt.bytesToHex(id.bytes, .lower);
        return (hex[0..8] ++ "-" ++ hex[8..12] ++ "-" ++ hex[12..16] ++ "-" ++
            hex[16..20] ++ "-" ++ hex[20..32]).*;
    }
};

/// A language id (BCP 47 tag of at most 8 ASCII bytes), zero-padded.
pub const Lang = struct {
    bytes: [8]u8 = @splat(0),

    /// From a tag such as `pt-BR`: 1 to 8 printable ASCII bytes.
    pub fn fromText(tag: []const u8) error{BadLang}!Lang {
        if (tag.len == 0 or tag.len > 8) return error.BadLang;
        var l: Lang = .{};
        for (tag, 0..) |ch, i| {
            if (ch <= ' ' or ch > '~') return error.BadLang;
            l.bytes[i] = ch;
        }
        return l;
    }

    /// The tag without its zero padding.
    pub fn text(l: *const Lang) []const u8 {
        return std.mem.sliceTo(&l.bytes, 0);
    }
};

/// Bytes a `str` takes on the wire.
pub fn strSize(s: []const u8) usize {
    return 4 + s.len;
}

/// Writes into a buffer sized up front by the caller; writing past its end is a bug.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn header(w: *Writer, magic: *const [4]u8) void {
        w.bytes(magic);
        w.int(u8, version);
    }

    pub fn int(w: *Writer, comptime T: type, v: T) void {
        std.mem.writeInt(T, w.buf[w.len..][0..@sizeOf(T)], v, .big);
        w.len += @sizeOf(T);
    }

    pub fn bytes(w: *Writer, b: []const u8) void {
        @memcpy(w.buf[w.len..][0..b.len], b);
        w.len += b.len;
    }

    pub fn str(w: *Writer, s: []const u8) void {
        w.int(u32, @intCast(s.len));
        w.bytes(s);
    }

    pub fn written(w: *const Writer) []u8 {
        return w.buf[0..w.len];
    }
};

/// Reads a request body. The only code that may fail on bad input: every error here is
/// a 400 at the boundary.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub const Error = error{ Short, BadMagic, BadVersion, BadUtf8, BadLang, Trailing };

    pub fn header(r: *Reader, magic: *const [4]u8) Error!void {
        if (!std.mem.eql(u8, try r.bytes(4), magic)) return error.BadMagic;
        if (try r.int(u8) != version) return error.BadVersion;
    }

    pub fn int(r: *Reader, comptime T: type) Error!T {
        const b = try r.bytes(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .big);
    }

    pub fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (r.buf.len - r.pos < n) return error.Short;
        defer r.pos += n;
        return r.buf[r.pos..][0..n];
    }

    pub fn str(r: *Reader) Error![]const u8 {
        const s = try r.bytes(try r.int(u32));
        if (!std.unicode.utf8ValidateSlice(s)) return error.BadUtf8;
        return s;
    }

    /// A `lang`: non-empty printable ASCII, followed only by zero bytes.
    pub fn lang(r: *Reader) Error!Lang {
        const l: Lang = .{ .bytes = (try r.bytes(8))[0..8].* };
        const tag = l.text();
        for (l.bytes[tag.len..]) |b| if (b != 0) return error.BadLang;
        return Lang.fromText(tag) catch error.BadLang;
    }

    pub fn storyId(r: *Reader) Error!StoryId {
        return .{ .bytes = (try r.bytes(16))[0..16].* };
    }

    /// No bytes may be left after the last field.
    pub fn end(r: *const Reader) Error!void {
        if (r.pos != r.buf.len) return error.Trailing;
    }
};
