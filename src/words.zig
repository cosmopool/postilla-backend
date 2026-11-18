//! The word rule, the normalization and the lookup keys of tilla.md (Words). Pure: no
//! allocation and no I/O; callers size the buffers.

const std = @import("std");
const table = @import("words_table.zig").table;

/// A word: its byte range in the sentence text, the `.tilla` word.
pub const Span = struct { start: u16 = 0, end: u16 = 0 };

const final_apostrophe = [_][]const u8{ "po", "va", "fa", "da", "di", "sta", "to", "mo", "be", "ca", "pie", "vo", "te" };
const leading_apostrophe = [_][]const u8{ "sto", "sta", "sti", "ste", "na", "ndrangheta" };

/// Splits a sentence into its words. `out.len >= text.len` is always enough. A word that
/// would end past byte 65 535 isn't returned.
pub fn split(text: []const u8, out: []Span) []Span {
    var n: usize = 0;
    var i: usize = 0;
    var lead: usize = 0; // where an apostrophe right before i starts, when lead < i
    var after_word = false; // the character before i is part of a word
    while (i < text.len) {
        const c, const len = char(text[i..]);
        if (!isAlnum(c)) {
            lead = if (std.mem.eql(u8, c, "'") and !after_word) i else i + len;
            after_word = false;
            i += len;
            continue;
        }
        var end = i;
        var letter = false; // the last character taken is a letter, with its accents
        while (end < text.len) {
            const d, const l = char(text[end..]);
            // An accent after a letter, or an apostrophe or hyphen between two letters.
            const joins = letter and (d.len == 0 or
                ((std.mem.eql(u8, d, "'") or std.mem.eql(u8, d, "-")) and isLetter(at(text, end + l))));
            if (isAlnum(d)) letter = isLetter(d) else if (!joins) break;
            end += l;
        }
        const start = if (lead < i and inList(&leading_apostrophe, text[i..end])) lead else i;
        after_word = true;
        if (std.mem.eql(u8, at(text, end), "'") and !isAlnum(at(text, end + char(text[end..])[1])) and
            inList(&final_apostrophe, text[i..end]))
        {
            end += char(text[end..])[1];
            after_word = false;
        }
        if (end > std.math.maxInt(u16)) break;
        out[n] = .{ .start = @intCast(start), .end = @intCast(end) };
        n += 1;
        i = end;
    }
    return out[0..n];
}

/// Normalizes `text` into `out`: letters to their lowercase base, combining accents
/// dropped, apostrophes to `'`, hyphens to `-`, the rest unchanged. `out.len >= text.len`
/// is always enough.
pub fn normalize(text: []const u8, out: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c, const len = char(text[i..]);
        @memcpy(out[n..][0..c.len], c);
        n += c.len;
        i += len;
    }
    return out[0..n];
}

/// The keys to look `word` up by, in order: as written, normalized, then the same two for
/// the part after the last apostrophe between two letters, skipping a key equal to the one
/// before it. `buf.len >= 2 * word.len` is always enough.
pub fn lookupKeys(word: []const u8, buf: []u8, keys: *[4][]const u8) []const []const u8 {
    var tail: usize = 0;
    var prev: []const u8 = "";
    var i: usize = 0;
    while (i < word.len) {
        const c, const len = char(word[i..]);
        if (std.mem.eql(u8, c, "'") and isLetter(prev) and isLetter(at(word, i + len))) tail = i + len;
        if (c.len > 0) prev = c;
        i += len;
    }
    const norm = normalize(word, buf);
    const all = [4][]const u8{ word, norm, word[tail..], normalize(word[tail..], buf[norm.len..]) };
    var n: usize = 0;
    for (all[0..if (tail > 0) 4 else 2]) |key| {
        if (n > 0 and std.mem.eql(u8, key, keys[n - 1])) continue;
        keys[n] = key;
        n += 1;
    }
    return keys[0..n];
}

/// The first character of `text`: its normalization and its length in bytes. A byte that
/// doesn't start valid UTF-8 is a character of its own and stays as it is. The
/// normalization tells the class: a letter starts with `a`–`z`, a digit is itself, an
/// apostrophe is `'`, a hyphen `-`, and a combining accent is empty.
fn char(text: []const u8) struct { []const u8, usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return .{ text[0..1], 1 };
    if (len > text.len) return .{ text[0..1], 1 };
    const cp = std.unicode.utf8Decode(text[0..len]) catch return .{ text[0..1], 1 };
    return .{ switch (cp) {
        'A'...'Z' => "abcdefghijklmnopqrstuvwxyz"[cp - 'A' ..][0..1],
        0xC0...0x24F => if (table[cp - 0xC0].len > 0) table[cp - 0xC0] else text[0..len],
        0x300...0x36F => "",
        '\'', 0x2019, 0x2BC => "'",
        '-', 0x2010, 0x2011 => "-",
        else => text[0..len],
    }, len };
}

/// The normalized character at `text[i]`; empty past the end.
fn at(text: []const u8, i: usize) []const u8 {
    return if (i < text.len) char(text[i..])[0] else "";
}

fn isLetter(c: []const u8) bool {
    return c.len > 0 and std.ascii.isLower(c[0]);
}

fn isAlnum(c: []const u8) bool {
    return c.len > 0 and std.ascii.isAlphanumeric(c[0]);
}

/// Whether `word`, normalized, is in `list`.
fn inList(list: []const []const u8, word: []const u8) bool {
    var buf: [32]u8 = undefined;
    if (word.len > buf.len) return false;
    const norm = normalize(word, &buf);
    for (list) |w| if (std.mem.eql(u8, w, norm)) return true;
    return false;
}
