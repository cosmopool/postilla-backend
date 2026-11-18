//! The `.tilla` writer (tilla.md): one translation of a story in, its `.tilla` bytes, their
//! gzip and the sha256 of the `.tilla` out. `postilla publish` calls it per translation.

const std = @import("std");
const c = @import("c");
const db = @import("server").db;
const wire = @import("wire");
const words = @import("words");

/// One translation of a story: the story-level fields, the translation and its narration.
pub const Input = struct {
    id: wire.StoryId = .{},
    lang: wire.Lang = .{},
    original: wire.Lang = .{},
    title: []const u8 = "",
    subtitle: []const u8 = "",
    level: u8 = 0,
    genre: []const u8 = "",
    tags: []const []const u8 = &.{},
    work: []const u8 = "",
    part: u16 = 0,
    author: []const u8 = "",
    adapted: bool = false,
    license: []const u8 = "",
    paragraphs: []const []const []const u8 = &.{},
    /// All zero without narration; with it, one time pair per sentence in reading order.
    narration: struct {
        audio_ms: u32 = 0,
        opus_sha256: [32]u8 = @splat(0),
        opus_size: u32 = 0,
        times: []const struct { start_ms: u32 = 0, end_ms: u32 = 0 } = &.{},
    } = .{},
};

/// Builds `in`'s `.tilla`, looking `band_words` up in the `dict.db` at `dict` only for the
/// Italian original. An input that would break a reader rule is refused before writing.
pub fn build(arena: std.mem.Allocator, in: Input, dict: [:0]const u8) !struct { tilla: []u8, gz: []u8, sha256: [32]u8 } {
    const n = in.narration;
    if (in.title.len == 0 or in.subtitle.len == 0 or in.paragraphs.len == 0) return error.Empty;
    const spans = try arena.alloc(words.Span, 1 << 16);
    const key_buf = try arena.alloc(u8, 2 << 16);

    const italian = std.mem.eql(u8, in.lang.text(), "it") and std.mem.eql(u8, in.original.text(), "it");
    var dict_db: db.Db = .{};
    defer dict_db.close();
    var lookup: db.Stmt = .{ .db = dict_db };
    defer _ = c.sqlite3_finalize(lookup.handle);
    if (italian) {
        dict_db = try db.open(dict);
        // The key's lowest band among the lemmas it leads to by `form`, else by `form_norm`,
        // with band 0 ranked last; NULL when it leads to none.
        lookup = try dict_db.prepare(
            \\SELECT coalesce(
            \\  (SELECT min(CASE band WHEN 0 THEN 4 ELSE band END) FROM form JOIN entry ON id = entry_id WHERE form = ?1),
            \\  (SELECT min(CASE band WHEN 0 THEN 4 ELSE band END) FROM form JOIN entry ON id = entry_id WHERE form_norm = ?1)) % 4
        );
    }

    // First pass: check every sentence and the narration, count the words and size the file
    // (96 bytes of fixed-size header fields, then the strs and paragraphs).
    var size: usize = 96 + wire.strSize(in.title) + wire.strSize(in.subtitle) + wire.strSize(in.genre) +
        wire.strSize(in.work) + wire.strSize(in.author) + wire.strSize(in.license);
    for (in.tags) |tag| size += wire.strSize(tag);
    var total: usize = 0;
    var band_words: [4]u16 = @splat(0);
    var sentences: usize = 0;
    var prev_start: u32 = 0;
    var untimed = true;
    for (in.paragraphs) |p| {
        if (p.len == 0) return error.Empty;
        size += 2;
        for (p) |text| {
            if (text.len == 0 or text.len > 65535) return error.BadSentence;
            const ws = words.split(text, spans);
            total += ws.len;
            if (total > 65535) return error.TooManyWords;
            size += wire.strSize(text) + 2 + 4 * ws.len + 8;
            if (italian) for (ws) |w| {
                var keys: [4][]const u8 = undefined;
                var band: usize = 0;
                for (words.lookupKeys(text[w.start..w.end], key_buf, &keys)) |key| {
                    _ = c.sqlite3_reset(lookup.handle);
                    _ = c.sqlite3_bind_text(lookup.handle, 1, key.ptr, @intCast(key.len), null);
                    _ = try lookup.step();
                    if (c.sqlite3_column_type(lookup.handle, 0) == c.SQLITE_NULL) continue;
                    band = @intCast(c.sqlite3_column_int(lookup.handle, 0));
                    break;
                }
                band_words[band] += 1;
            };
            if (sentences < n.times.len) {
                const t = n.times[sentences];
                if (t.start_ms > t.end_ms or t.end_ms > n.audio_ms or t.start_ms < prev_start) return error.BadNarration;
                prev_start = t.start_ms;
                if (t.end_ms != 0) untimed = false;
            }
            sentences += 1;
        }
    }
    const silent = n.audio_ms == 0 and n.opus_size == 0 and std.mem.allEqual(u8, &n.opus_sha256, 0);
    if ((n.times.len != 0 and n.times.len != sentences) or silent != untimed) return error.BadNarration;

    const file = try arena.alloc(u8, size);
    var w: wire.Writer = .{ .buf = file };
    w.bytes("TILLA\x01");
    w.bytes(&in.id.bytes);
    w.bytes(&in.lang.bytes);
    w.bytes(&in.original.bytes);
    w.str(in.title);
    w.str(in.subtitle);
    w.int(u8, in.level);
    w.str(in.genre);
    w.int(u16, @intCast(in.tags.len));
    for (in.tags) |tag| w.str(tag);
    w.str(in.work);
    w.int(u16, in.part);
    w.str(in.author);
    w.int(u8, @intFromBool(in.adapted));
    w.str(in.license);
    w.int(u16, @intCast(total));
    for (band_words) |b| w.int(u16, b);
    w.int(u32, n.audio_ms);
    w.bytes(&n.opus_sha256);
    w.int(u32, n.opus_size);
    w.int(u16, @intCast(in.paragraphs.len));
    sentences = 0;
    for (in.paragraphs) |p| {
        w.int(u16, @intCast(p.len));
        for (p) |text| {
            w.str(text);
            const ws = words.split(text, spans);
            w.int(u16, @intCast(ws.len));
            for (ws) |s| {
                w.int(u16, s.start);
                w.int(u16, s.end);
            }
            if (n.times.len == 0) w.int(u64, 0) else {
                w.int(u32, n.times[sentences].start_ms);
                w.int(u32, n.times[sentences].end_ms);
            }
            sentences += 1;
        }
    }

    var sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file, &sha256, .{});
    var gz: std.Io.Writer.Allocating = try .initCapacity(arena, 64);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var z: std.compress.flate.Compress = try .init(&gz.writer, &window, .gzip, .default);
    try z.writer.writeAll(file);
    try z.finish();
    return .{ .tilla = file, .gz = gz.written(), .sha256 = sha256 };
}
