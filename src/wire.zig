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

/// A `POST /stories` body (specification.md): the story id and every translation's language
/// and sha256, in body order.
pub const Story = struct {
    id: StoryId = .{},
    n: u8 = 0,
    langs: [255]Lang = @splat(.{}),
    hashes: [255][32]u8 = @splat(@splat(0)),

    /// The translations read so far.
    pub fn translations(s: *const Story) struct { []const Lang, []const [32]u8 } {
        return .{ s.langs[0..s.n], s.hashes[0..s.n] };
    }
};

pub const StoryError = error{ BadMagic, BadVersion, WrongLength, BadLang, RepeatedLang, NoOriginal };

/// The largest body: the header, then 255 translations of 40 bytes.
pub const story_max = 22 + 40 * 255;

/// Parses a `STRY` body into `s`, checking in this order (specification.md): magic and version;
/// at least one translation and exactly `22 + 40 × lang_count` bytes; every `lang`; no `lang`
/// twice; one `lang` is `it`. On `RepeatedLang`, `s.langs[s.n]` is the language that repeated.
pub fn parseStory(body: []const u8, s: *Story) StoryError!void {
    s.* = .{};
    var r: Reader = .{ .buf = body };
    r.header("STRY") catch |err| return switch (err) {
        error.BadMagic, error.BadVersion => |e| e,
        else => error.WrongLength,
    };
    s.id = r.storyId() catch return error.WrongLength;
    const n = r.int(u8) catch 0;
    if (n == 0 or body.len != 22 + 40 * @as(usize, n)) return error.WrongLength;
    var original = false;
    for (0..n) |i| {
        s.langs[i] = r.lang() catch return error.BadLang;
        // The length was checked above, so the hash is there.
        s.hashes[i] = (r.bytes(32) catch unreachable)[0..32].*;
        s.n = @intCast(i);
        for (s.langs[0..i]) |p| if (std.mem.eql(u8, &p.bytes, &s.langs[i].bytes)) return error.RepeatedLang;
        original = original or std.mem.eql(u8, s.langs[i].text(), "it");
    }
    s.n = n;
    if (!original) return error.NoOriginal;
    std.debug.assert(r.pos == body.len);
}

/// Writes a `STRY` body for `s` into `buf` (at least `22 + 40 × s.n` bytes): what the CLI sends,
/// and the inverse of `parseStory`.
pub fn writeStory(s: *const Story, buf: []u8) []u8 {
    std.debug.assert(buf.len >= 22 + 40 * @as(usize, s.n));
    var w: Writer = .{ .buf = buf };
    w.header("STRY");
    w.bytes(&s.id.bytes);
    w.int(u8, s.n);
    const langs, const hashes = s.translations();
    for (langs, hashes) |l, h| {
        w.bytes(&l.bytes);
        w.bytes(&h);
    }
    return w.written();
}
