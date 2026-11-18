//! The `.tilla` writer: one translation of a story in, its `.tilla` bytes, their `.gz` and
//! the sha256 out (tilla.md). Every file built here is read back by `read`, which applies
//! tilla.md's reader rules 1–8 the way the app does, and `band_words` comes from a real
//! `dict.db` made with CONTRACT.md's schema.

const std = @import("std");
const server = @import("server");
const tilla = @import("tilla");
const words = @import("words");

const io = std.testing.io;
const gpa = std.testing.allocator;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const story_id = "d0159518-99cc-46f0-bef2-b5b6f6f9a76d";
const id_bytes = "\xd0\x15\x95\x18\x99\xcc\x46\xf0\xbe\xf2\xb5\xb6\xf6\xf9\xa7\x6d";

/// CONTRACT.md's `dict.db` schema, and the rows the tests look words up in: *porta* leads
/// to *portare* (1) and *porgere* (2), *casa* to band 1, *gatto* to band 2, *aria* to
/// band 3 (but *l'aria* is no form), *perché* to band 2 by its `form_norm` *perche*, and
/// *ciao* to a band 0 and a band 3 lemma.
const dict_sql =
    \\CREATE TABLE meta  (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\CREATE TABLE entry (id INTEGER PRIMARY KEY, word TEXT NOT NULL, word_norm TEXT NOT NULL,
    \\                    pos TEXT NOT NULL, band INTEGER NOT NULL, data TEXT NOT NULL);
    \\CREATE TABLE form  (form TEXT NOT NULL, form_norm TEXT NOT NULL, entry_id INTEGER NOT NULL);
    \\CREATE INDEX entry_word ON entry(word);
    \\CREATE INDEX entry_word_norm ON entry(word_norm);
    \\CREATE INDEX form_form ON form(form);
    \\CREATE INDEX form_form_norm ON form(form_norm);
    \\INSERT INTO entry VALUES
    \\  (1, 'portare', 'portare', 'verbo', 1, '{}'),
    \\  (2, 'porgere', 'porgere', 'verbo', 2, '{}'),
    \\  (3, 'casa', 'casa', 'sostantivo', 1, '{}'),
    \\  (4, 'gatto', 'gatto', 'sostantivo', 2, '{}'),
    \\  (5, 'aria', 'aria', 'sostantivo', 3, '{}'),
    \\  (6, 'perché', 'perche', 'avverbio', 2, '{}'),
    \\  (7, 'ciao', 'ciao', 'interiezione', 0, '{}'),
    \\  (8, 'ciao', 'ciao', 'sostantivo', 3, '{}');
    \\INSERT INTO form VALUES
    \\  ('porta', 'porta', 1), ('porta', 'porta', 2), ('casa', 'casa', 3), ('gatto', 'gatto', 4),
    \\  ('aria', 'aria', 5), ('perché', 'perche', 6), ('ciao', 'ciao', 7), ('ciao', 'ciao', 8);
;

/// `name` inside `tmp`, as a path from the working directory. The caller frees it.
fn tmpPath(tmp: std.testing.TmpDir, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name }, 0);
}

/// Writes the fixture `dict.db` into `tmp` and returns its path. The caller frees it.
fn dictDb(tmp: std.testing.TmpDir) ![:0]u8 {
    const path = try tmpPath(tmp, "dict.db");
    errdefer gpa.free(path);
    var d = try server.db.open(path);
    defer d.close();
    try d.exec(dict_sql);
    return path;
}

/// A translation into `lang` of a story written in Italian, part 2 of a work adapted from
/// an author, without narration.
fn translation(lang: []const u8, paragraphs: []const []const []const u8) !tilla.Input {
    return .{
        .id = try .parse(story_id),
        .lang = try .fromText(lang),
        .original = try .fromText("it"),
        .title = "Il gatto e la porta",
        .subtitle = "Una fiaba di casa",
        .level = 3,
        .genre = "fiaba",
        .tags = &.{ "animali", "casa" },
        .work = "Fiabe italiane",
        .part = 2,
        .author = "calvino",
        .adapted = true,
        .license = "CC-BY-SA-4.0",
        .paragraphs = paragraphs,
    };
}

const it_paragraphs: []const []const []const u8 = &.{
    &.{ "C'era una volta un gatto.", "Viveva in una casa sul mare, perch\u{e9} amava l'aria." },
    &.{"Un po' di pane, e la porta-finestra aperta."},
};

const opus = "OggS fake narration bytes";

/// The sha256 of `bytes`.
fn sha256(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

/// `it_paragraphs` with a narration of 6.2 s, one time pair per sentence.
fn narrated() !tilla.Input {
    var in = try translation("it", it_paragraphs);
    in.narration = .{
        .audio_ms = 6200,
        .opus_sha256 = sha256(opus),
        .opus_size = opus.len,
        .times = &.{
            .{ .start_ms = 0, .end_ms = 1800 },
            .{ .start_ms = 1800, .end_ms = 4100 },
            .{ .start_ms = 4300, .end_ms = 6200 },
        },
    };
    return in;
}

const Sentence = struct {
    text: []const u8,
    words: []const words.Span,
    start_ms: u32,
    end_ms: u32,
};

/// A `.tilla` as a reader sees it.
const Tilla = struct {
    id: [16]u8,
    lang: []const u8,
    original: []const u8,
    title: []const u8,
    subtitle: []const u8,
    level: u8,
    genre: []const u8,
    tags: []const []const u8,
    work: []const u8,
    part: u16,
    author: []const u8,
    adapted: u8,
    license: []const u8,
    words: u16,
    band_words: [4]u16,
    audio_ms: u32,
    opus_sha256: [32]u8,
    opus_size: u32,
    paragraphs: []const []const Sentence,
};

/// Reads `.tilla` bytes in tilla.md's order; running out of bytes breaks reader rule 2.
const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    fn bytes(c: *Cursor, n: usize) ![]const u8 {
        if (c.buf.len - c.pos < n) return error.Short;
        defer c.pos += n;
        return c.buf[c.pos..][0..n];
    }

    fn int(c: *Cursor, comptime T: type) !T {
        return std.mem.readInt(T, (try c.bytes(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    /// Rule 3: a `str` is valid UTF-8.
    fn str(c: *Cursor) ![]const u8 {
        const s = try c.bytes(try c.int(u32));
        try expect(std.unicode.utf8ValidateSlice(s));
        return s;
    }

    /// Rule 3: a `lang` is non-empty ASCII followed only by zero bytes.
    fn lang(c: *Cursor) ![]const u8 {
        const b = try c.bytes(8);
        const tag = std.mem.sliceTo(b, 0);
        try expect(tag.len > 0);
        for (tag) |ch| try expect(ch > ' ' and ch <= '~');
        for (b[tag.len..]) |ch| try expectEqual(0, ch);
        return tag;
    }
};

/// Whether `i` is on a UTF-8 character boundary of `text`.
fn boundary(text: []const u8, i: usize) bool {
    return i == text.len or text[i] & 0xC0 != 0x80;
}

/// Reads `file` the way the app does, failing on any break of tilla.md's reader rules 1–8.
fn read(arena: Allocator, file: []const u8) !Tilla {
    var c: Cursor = .{ .buf = file };
    try expectEqualSlices(u8, "TILLA\x01", try c.bytes(6)); // rule 1
    var t: Tilla = undefined;
    t.id = (try c.bytes(16))[0..16].*;
    t.lang = try c.lang();
    t.original = try c.lang();
    t.title = try c.str();
    t.subtitle = try c.str();
    t.level = try c.int(u8);
    t.genre = try c.str();
    const tags = try arena.alloc([]const u8, try c.int(u16));
    for (tags) |*tag| tag.* = try c.str();
    t.tags = tags;
    t.work = try c.str();
    t.part = try c.int(u16);
    t.author = try c.str();
    t.adapted = try c.int(u8);
    t.license = try c.str();
    t.words = try c.int(u16);
    for (&t.band_words) |*b| b.* = try c.int(u16);
    t.audio_ms = try c.int(u32);
    t.opus_sha256 = (try c.bytes(32))[0..32].*;
    t.opus_size = try c.int(u32);

    const paragraphs = try arena.alloc([]const Sentence, try c.int(u16));
    try expect(paragraphs.len >= 1); // rule 5
    var word_total: usize = 0;
    for (paragraphs) |*p| {
        const sentences = try arena.alloc(Sentence, try c.int(u16));
        try expect(sentences.len >= 1); // rule 5
        for (sentences) |*s| {
            s.text = try c.str();
            try expect(s.text.len > 0); // rule 5
            const spans = try arena.alloc(words.Span, try c.int(u16));
            var prev_end: usize = 0;
            for (spans) |*w| {
                w.* = .{ .start = try c.int(u16), .end = try c.int(u16) };
                // Rule 6.
                try expect(w.start < w.end and w.end <= s.text.len and w.start >= prev_end);
                try expect(boundary(s.text, w.start) and boundary(s.text, w.end));
                prev_end = w.end;
            }
            s.words = spans;
            word_total += spans.len;
            s.start_ms = try c.int(u32);
            s.end_ms = try c.int(u32);
        }
        p.* = sentences;
    }
    t.paragraphs = paragraphs;
    try expectEqual(file.len, c.pos); // rule 2

    // Rule 4.
    try expect(t.level >= 1 and t.level <= 6);
    try expect(t.adapted <= 1);
    try expectEqual(t.work.len == 0, t.part == 0);

    // Rule 7.
    try expectEqual(word_total, t.words);
    if (std.mem.eql(u8, t.lang, "it")) {
        var bands: usize = 0;
        for (t.band_words) |b| bands += b;
        try expectEqual(t.words, bands);
    } else {
        try expectEqual([4]u16{ 0, 0, 0, 0 }, t.band_words);
    }

    // Rule 8.
    const silent = t.audio_ms == 0 and t.opus_size == 0 and std.mem.allEqual(u8, &t.opus_sha256, 0);
    var untimed = true;
    var prev_start: u32 = 0;
    for (t.paragraphs) |p| for (p) |s| {
        if (s.start_ms != 0 or s.end_ms != 0) untimed = false;
        if (!silent) {
            try expect(s.start_ms <= s.end_ms and s.end_ms <= t.audio_ms and s.start_ms >= prev_start);
            prev_start = s.start_ms;
        }
    };
    try expectEqual(silent, untimed);
    return t;
}

/// Builds `input` and reads the `.tilla` back.
fn buildRead(arena: Allocator, input: tilla.Input, dict: [:0]const u8) !Tilla {
    return read(arena, (try tilla.build(arena, input, dict)).tilla);
}

/// `build` refuses `input` with an input error, not a dictionary one.
fn expectRefused(input: tilla.Input, dict: [:0]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    if (tilla.build(arena.allocator(), input, dict)) |_| {
        return error.TestExpectedError;
    } else |err| {
        try expect(@as(anyerror, err) != error.Sqlite);
    }
}

/// The `.gz` decompressed.
fn gunzip(arena: Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = try d.reader.streamRemaining(&out.writer);
    return out.written();
}

test "AC-1, AC-2: an Italian translation without narration reads back field by field, with the spans words.split gives" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dict = try dictDb(tmp);
    defer gpa.free(dict);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const t = try buildRead(arena.allocator(), try translation("it", it_paragraphs), dict);

    try expectEqualSlices(u8, id_bytes, &t.id);
    try expectEqualStrings("it", t.lang);
    try expectEqualStrings("it", t.original);
    try expectEqualStrings("Il gatto e la porta", t.title);
    try expectEqualStrings("Una fiaba di casa", t.subtitle);
    try expectEqual(3, t.level);
    try expectEqualStrings("fiaba", t.genre);
    try expectEqual(2, t.tags.len);
    try expectEqualStrings("animali", t.tags[0]);
    try expectEqualStrings("casa", t.tags[1]);
    try expectEqualStrings("Fiabe italiane", t.work);
    try expectEqual(2, t.part);
    try expectEqualStrings("calvino", t.author);
    try expectEqual(1, t.adapted);
    try expectEqualStrings("CC-BY-SA-4.0", t.license);
    try expectEqual(0, t.audio_ms);
    try expectEqual(@as([32]u8, @splat(0)), t.opus_sha256);
    try expectEqual(0, t.opus_size);

    try expectEqual(2, t.paragraphs.len);
    var total: usize = 0;
    for (it_paragraphs, t.paragraphs) |want, got| {
        try expectEqual(want.len, got.len);
        for (want, got) |text, s| {
            try expectEqualStrings(text, s.text);
            var buf: [128]words.Span = undefined;
            const spans = words.split(text, &buf);
            try expectEqualSlices(words.Span, spans, s.words);
            total += spans.len;
            try expectEqual(0, s.start_ms);
            try expectEqual(0, s.end_ms);
        }
    }
    try expectEqual(total, t.words);
}

test "AC-3, AC-4: band_words counts each word in the best band of its lemmas, by form, then form_norm, then after the apostrophe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dict = try dictDb(tmp);
    defer gpa.free(dict);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // band_words is bands 0, 1, 2, 3.
    const five = try buildRead(a, try translation("it", &.{&.{"porta casa gatto xyz l'aria"}}), dict);
    try expectEqual(5, five.words);
    try expectEqual([4]u16{ 1, 2, 1, 1 }, five.band_words);

    const perche = try buildRead(a, try translation("it", &.{&.{"Perch\u{e9}?"}}), dict);
    try expectEqual([4]u16{ 0, 0, 1, 0 }, perche.band_words);

    // A band 0 lemma ranks after every other band.
    const ciao = try buildRead(a, try translation("it", &.{&.{"Ciao!"}}), dict);
    try expectEqual([4]u16{ 0, 0, 0, 1 }, ciao.band_words);
}

test "AC-5: a pt-BR translation lists its words, carries four zero band_words and never opens the dict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try tmpPath(tmp, "missing/dict.db");
    defer gpa.free(missing);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const paragraphs: []const []const []const u8 = &.{
        &.{ "Era uma vez um gato.", "Morava numa casa \u{e0} beira-mar." },
        &.{"A porta estava aberta."},
    };
    const t = try buildRead(arena.allocator(), try translation("pt-BR", paragraphs), missing);

    try expectEqualStrings("pt-BR", t.lang);
    try expectEqualStrings("it", t.original);
    try expectEqual([4]u16{ 0, 0, 0, 0 }, t.band_words);
    var total: usize = 0;
    for (paragraphs, t.paragraphs) |want, got| for (want, got) |text, s| {
        var buf: [128]words.Span = undefined;
        const spans = words.split(text, &buf);
        try expectEqualSlices(words.Span, spans, s.words);
        total += spans.len;
    };
    try expectEqual(total, t.words);
    try expect(total > 0);
}

test "AC-6, AC-7: a narrated translation carries its audio and sentence times, and builds to the same bytes, sha256 and gunzipped .tilla every time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dict = try dictDb(tmp);
    defer gpa.free(dict);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try tilla.build(a, try narrated(), dict);
    const t = try read(a, first.tilla);
    try expectEqual(6200, t.audio_ms);
    try expectEqual(sha256(opus), t.opus_sha256);
    try expectEqual(opus.len, t.opus_size);
    const times = [_][2]u32{ .{ 0, 1800 }, .{ 1800, 4100 }, .{ 4300, 6200 } };
    var i: usize = 0;
    for (t.paragraphs) |p| for (p) |s| {
        try expectEqual(times[i], [2]u32{ s.start_ms, s.end_ms });
        i += 1;
    };
    try expectEqual(times.len, i);

    var again_arena: std.heap.ArenaAllocator = .init(gpa);
    defer again_arena.deinit();
    const again = try tilla.build(again_arena.allocator(), try narrated(), dict);
    try expectEqualSlices(u8, first.tilla, again.tilla);
    try expectEqual(first.sha256, again.sha256);
    try expectEqual(sha256(first.tilla), first.sha256);
    try expectEqualSlices(u8, first.tilla, try gunzip(a, first.gz));
    try expectEqualSlices(u8, again.tilla, try gunzip(a, again.gz));
}

test "AC-8: an input that breaks a rule is refused, and the limits themselves are accepted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dict = try dictDb(tmp);
    defer gpa.free(dict);

    var in = try translation("it", &.{&.{ "Ciao.", "" }});
    try expectRefused(in, dict);

    in = try translation("it", &.{ &.{"Ciao."}, &.{} });
    try expectRefused(in, dict);

    in = try translation("it", &.{});
    try expectRefused(in, dict);

    in = try translation("it", it_paragraphs);
    in.title = "";
    try expectRefused(in, dict);

    in = try translation("it", it_paragraphs);
    in.subtitle = "";
    try expectRefused(in, dict);

    // A sentence one byte over what a span can reach, and one exactly at it.
    const long = try gpa.alloc(u8, 65536);
    defer gpa.free(long);
    @memset(long, 'a');
    try expectRefused(try translation("it", &.{&.{long}}), dict);
    for (long[0..65535], 0..) |*ch, j| ch.* = if (j % 2 == 0) 'a' else ' ';
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const t = try buildRead(arena.allocator(), try translation("pt-BR", &.{&.{long[0..65535]}}), dict);
        try expectEqual(32768, t.words);
    }

    // 3 × 21846 words is over what `words` can count; 3 × 21845 is exactly at it.
    const third = try gpa.alloc(u8, 2 * 21846 - 1);
    defer gpa.free(third);
    for (third, 0..) |*ch, j| ch.* = if (j % 2 == 0) 'a' else ' ';
    try expectRefused(try translation("pt-BR", &.{&.{ third, third, third }}), dict);
    {
        const at = third[0 .. 2 * 21845 - 1];
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const t = try buildRead(arena.allocator(), try translation("pt-BR", &.{&.{ at, at, at }}), dict);
        try expectEqual(65535, t.words);
    }

    // Narrations: one time pair short, one too many, then times that break reader rule 8.
    in = try narrated();
    in.narration = .{ .audio_ms = 6200, .opus_sha256 = sha256(opus), .opus_size = opus.len, .times = &.{
        .{ .start_ms = 0, .end_ms = 1800 },
        .{ .start_ms = 1800, .end_ms = 4100 },
    } };
    try expectRefused(in, dict);
    in.narration = .{ .audio_ms = 6200, .opus_sha256 = sha256(opus), .opus_size = opus.len, .times = &.{
        .{ .start_ms = 0, .end_ms = 1800 },
        .{ .start_ms = 1800, .end_ms = 4100 },
        .{ .start_ms = 4300, .end_ms = 6000 },
        .{ .start_ms = 6000, .end_ms = 6200 },
    } };
    try expectRefused(in, dict);
    in.narration = .{ .audio_ms = 6200, .opus_sha256 = sha256(opus), .opus_size = opus.len, .times = &.{
        .{ .start_ms = 1000, .end_ms = 1800 },
        .{ .start_ms = 500, .end_ms = 4100 },
        .{ .start_ms = 4300, .end_ms = 6200 },
    } };
    try expectRefused(in, dict);
    in.narration = .{ .audio_ms = 6200, .opus_sha256 = sha256(opus), .opus_size = opus.len, .times = &.{
        .{ .start_ms = 0, .end_ms = 1800 },
        .{ .start_ms = 2500, .end_ms = 2000 },
        .{ .start_ms = 4300, .end_ms = 6200 },
    } };
    try expectRefused(in, dict);
    in.narration = .{ .audio_ms = 6200, .opus_sha256 = sha256(opus), .opus_size = opus.len, .times = &.{
        .{ .start_ms = 0, .end_ms = 1800 },
        .{ .start_ms = 1800, .end_ms = 4100 },
        .{ .start_ms = 4300, .end_ms = 7000 },
    } };
    try expectRefused(in, dict);
    in.narration = .{ .audio_ms = 6200, .opus_sha256 = sha256(opus), .opus_size = opus.len, .times = &.{
        .{ .start_ms = 0, .end_ms = 0 },
        .{ .start_ms = 0, .end_ms = 0 },
        .{ .start_ms = 0, .end_ms = 0 },
    } };
    try expectRefused(in, dict);
}

test "AC-F1: a dict.db that can't be opened, isn't a database or has no form table fails an Italian build with error.Sqlite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try translation("it", it_paragraphs);

    const missing = try tmpPath(tmp, "missing/dict.db");
    defer gpa.free(missing);
    try expectError(error.Sqlite, tilla.build(a, in, missing));

    try tmp.dir.writeFile(io, .{ .sub_path = "garbage.db", .data = "this is not an SQLite database, only text, long enough to fill the header of one" });
    const garbage = try tmpPath(tmp, "garbage.db");
    defer gpa.free(garbage);
    try expectError(error.Sqlite, tilla.build(a, in, garbage));

    const empty = try tmpPath(tmp, "empty.db");
    defer gpa.free(empty);
    {
        var d = try server.db.open(empty);
        defer d.close();
        try d.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);");
    }
    try expectError(error.Sqlite, tilla.build(a, in, empty));
}
