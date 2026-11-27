//! The shared `words` module: the word rule, the normalization and the lookup keys of
//! tilla.md (Words), the package export another build imports, and the Dart file
//! `zig build dart` generates from the same source.

const std = @import("std");
const words = @import("words");

const io = std.testing.io;
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

/// Splits `text` and checks the words, as the text the spans cover.
fn expectWords(text: []const u8, expected: []const []const u8) !void {
    var buf: [64]words.Span = undefined;
    const spans = words.split(text, &buf);
    try expectEqual(expected.len, spans.len);
    for (expected, spans) |want, span| try expectEqualStrings(want, text[span.start..span.end]);
}

fn expectNormalized(text: []const u8, expected: []const u8) !void {
    var buf: [64]u8 = undefined;
    try expectEqualStrings(expected, words.normalize(text, &buf));
}

fn expectKeys(word: []const u8, expected: []const []const u8) !void {
    var buf: [64]u8 = undefined;
    var keys: [4][]const u8 = undefined;
    const got = words.lookupKeys(word, &buf, &keys);
    try expectEqual(expected.len, got.len);
    for (expected, got) |want, key| try expectEqualStrings(want, key);
}

/// Runs `argv` and fails with its stderr unless it exits 0. The caller frees the result.
fn runOk(argv: []const []const u8, cwd: std.process.Child.Cwd) !std.process.RunResult {
    const r = try std.process.run(gpa, io, .{ .argv = argv, .cwd = cwd });
    errdefer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!r.term.success()) try expectEqualStrings("(exit 0)", r.stderr);
    return r;
}

test "AC-1: a sentence splits into its words, as byte ranges of the text" {
    const text = "C'era una volta un re.";
    var buf: [64]words.Span = undefined;
    const spans = words.split(text, &buf);
    const expected = [_]words.Span{
        .{ .start = 0, .end = 5 },
        .{ .start = 6, .end = 9 },
        .{ .start = 10, .end = 15 },
        .{ .start = 16, .end = 18 },
        .{ .start = 19, .end = 21 },
    };
    try std.testing.expectEqualSlices(words.Span, &expected, spans);
    try expectWords(text, &.{ "C'era", "una", "volta", "un", "re" });
}

test "AC-2: an apostrophe or hyphen between letters joins, between digits it separates" {
    try expectWords("l'aria", &.{"l'aria"});
    try expectWords("dell\u{2019}anno", &.{"dell\u{2019}anno"});
    try expectWords("porta-finestra", &.{"porta-finestra"});
    try expectWords("porta\u{2010}finestra", &.{"porta\u{2010}finestra"});
    try expectWords("c\u{2011}\u{e8} sempre", &.{ "c\u{2011}\u{e8}", "sempre" });
    try expectWords("3,5", &.{ "3", "5" });
    try expectWords("3-5", &.{ "3", "5" });
    try expectWords("anni '80", &.{ "anni", "80" });
}

test "AC-3: edge apostrophes belong only to the words in the two closed lists" {
    try expectWords("un po' di pane", &.{ "un", "po'", "di", "pane" });
    try expectWords("Va\u{2019} via", &.{ "Va\u{2019}", "via" });
    try expectWords("di'", &.{"di'"});
    try expectWords("un po'", &.{ "un", "po'" });
    try expectWords("Va\u{2019}", &.{"Va\u{2019}"});
    try expectWords("di' tu", &.{ "di'", "tu" });
    try expectWords("dammi 'sto libro", &.{ "dammi", "'sto", "libro" });
    try expectWords("\u{e8} 'Na storia", &.{ "\u{e8}", "'Na", "storia" });
    try expectWords("la 'casa' bella", &.{ "la", "casa", "bella" });
    try expectWords("'casa'", &.{"casa"});
}

test "AC-4: letters and digits form one run, × and ÷ separate" {
    try expectWords("nel 1860", &.{ "nel", "1860" });
    try expectWords("A1 B2", &.{ "A1", "B2" });
    try expectWords("a\u{d7}b", &.{ "a", "b" });
    try expectWords("a\u{f7}b", &.{ "a", "b" });
}

test "AC-5, AC-6: a combining accent belongs to the letter before it, and normalizes away" {
    try expectWords("perche\u{301} no", &.{ "perche\u{301}", "no" });
    try expectWords("ca\u{300}sa", &.{"ca\u{300}sa"});
    try expectWords("a \u{301}b", &.{ "a", "b" });
    try expectWords("e\u{301}\u{302} \u{301}", &.{"e\u{301}\u{302}"});
    try expectNormalized("perche\u{301}", "perche");
}

test "AC-6: normalize lowercases to the base letter and unifies apostrophes and hyphens" {
    try expectNormalized("\u{c8} GI\u{c0} cos\u{ec}", "e gia cosi");
    try expectNormalized("perch\u{e9}", "perche");
    try expectNormalized("Stra\u{df}e", "strasse");
    try expectNormalized("\u{152}uvre", "oeuvre");
    try expectNormalized("\u{c6}r\u{f8}", "aero");
    try expectNormalized("\u{141}\u{f3}d\u{17a}", "lodz");
    try expectNormalized("\u{110}or\u{111}e", "dorde");
    try expectNormalized("\u{126}al", "hal");
    try expectNormalized("l\u{2019}aria", "l'aria");
    try expectNormalized("c\u{2011}\u{e8}", "c-e");
    try expectNormalized("1860, 3.5!? (x)", "1860, 3.5!? (x)");
}

test "AC-7: every letter in U+00C0–U+024F normalizes to lowercase ASCII letters, once and for all" {
    var cp: u21 = 0xC0;
    while (cp <= 0x24F) : (cp += 1) {
        if (cp == 0xD7 or cp == 0xF7) continue;
        var letter: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &letter);
        var once_buf: [8]u8 = undefined;
        const once = words.normalize(letter[0..len], &once_buf);
        try expect(once.len > 0);
        for (once) |b| try expect(b >= 'a' and b <= 'z');
        var twice_buf: [8]u8 = undefined;
        try expectEqualStrings(once, words.normalize(once, &twice_buf));
    }
    try expectNormalized("\u{c0}\u{e0}\u{e1}\u{e2}\u{c7}\u{d1}", "aaaacn");

    // The committed table: one `"<replacement>", // U+XXXX <letter>` line per code point.
    const table = try std.Io.Dir.cwd().readFileAlloc(io, "src/words_table.zig", gpa, .limited(1 << 20));
    defer gpa.free(table);
    var entries: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "\", // U+") orelse continue;
        const want = std.mem.trimStart(u8, line[0..at], " \"");
        const code = try std.fmt.parseInt(u21, line[at + 8 ..][0..4], 16);
        if (code == 0xD7 or code == 0xF7) continue;
        entries += 1;
        var letter: [4]u8 = undefined;
        var got_buf: [8]u8 = undefined;
        try expectEqualStrings(want, words.normalize(letter[0..try std.unicode.utf8Encode(code, &letter)], &got_buf));
    }
    try expectEqual(0x24F - 0xC0 + 1 - 2, entries);
}

test "AC-8: lookupKeys gives the keys to try in order, skipping one equal to the key before" {
    try expectKeys("l'aria", &.{ "l'aria", "aria" });
    try expectKeys("Dell\u{2019}Anno", &.{ "Dell\u{2019}Anno", "dell'anno", "Anno", "anno" });
    try expectKeys("casa", &.{"casa"});
    try expectKeys("po'", &.{"po'"});
}

test "AC-F1: bytes that aren't valid UTF-8 separate words and normalize unchanged" {
    try expectWords("ab\xffcd \xc3 ef\xe2\x80", &.{ "ab", "cd", "ef" });
    try expectWords("e\x81ra \xc0\xafx", &.{ "e", "ra", "x" });
    try expectWords("l'\xff", &.{"l"});
    try expectNormalized("AB\xffcd", "ab\xffcd");
    try expectNormalized("\xc3(\xc0\xaf\xe2\x80", "\xc3(\xc0\xaf\xe2\x80");

    // Truncated sequences at the end, and buffers exactly as long as the text.
    for ([_][]const u8{ "e\xcc", "po\xe2\x80", "\xc3", "a\xffb\xffc", "\xff\xfe\xf8\x80\xbf" }) |text| {
        var spans: [16]words.Span = undefined;
        for (words.split(text, spans[0..text.len])) |span| try expect(span.start < span.end and span.end <= text.len);
        var out: [16]u8 = undefined;
        try expectEqual(text.len, words.normalize(text, out[0..text.len]).len);
    }
    try expectWords("e\xcc", &.{"e"});
    try expectWords("po\xe2\x80", &.{"po"});
}

test "AC-9: a package that imports only `words` builds and runs without fetching SQLite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // The consumer sits in .zig-cache/tmp/<dir>, three levels under this repository.
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data =
        \\.{
        \\    .name = .words_consumer,
        \\    .version = "0.0.1",
        \\    .fingerprint = 0xfa0acd8acc54374d,
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{ .postilla_backend = .{ .path = "../../.." } },
        \\    .paths = .{""},
        \\}
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const words = b.dependency("postilla_backend", .{}).module("words");
        \\    b.installArtifact(b.addExecutable(.{ .name = "words_consumer", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("main.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "words", .module = words }},
        \\    }) }));
        \\}
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data =
        \\const std = @import("std");
        \\const words = @import("words");
        \\pub fn main() u8 {
        \\    var buf: [16]u8 = undefined;
        \\    return if (std.mem.eql(u8, words.normalize("Perch\u{e9}", &buf), "perche")) 0 else 1;
        \\}
        \\
    });

    // A global cache that shares the compiled artifacts of the real one but not its
    // package store (p/), so any package the build needs has to be fetched again.
    const env = try runOk(&.{ "zig", "env" }, .inherit);
    defer gpa.free(env.stdout);
    defer gpa.free(env.stderr);
    const key = ".global_cache_dir = \"";
    const at = (std.mem.indexOf(u8, env.stdout, key) orelse return error.NoGlobalCache) + key.len;
    const reported = env.stdout[at..][0 .. std.mem.indexOfScalar(u8, env.stdout[at..], '"') orelse return error.NoGlobalCache];
    // zig env prints the cache relative to the cwd when it's inside it (CI's setup-zig puts both
    // caches in the workspace's .zig-cache); the symlinks need it absolute.
    const global = try std.Io.Dir.cwd().realPathFileAlloc(io, reported, gpa);
    defer gpa.free(global);
    try tmp.dir.createDirPath(io, "cache");
    var real = try std.Io.Dir.openDirAbsolute(io, global, .{ .iterate = true });
    defer real.close(io);
    var it = real.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "p")) continue;
        const target = try std.fs.path.join(gpa, &.{ global, entry.name });
        defer gpa.free(target);
        const link = try std.fs.path.join(gpa, &.{ "cache", entry.name });
        defer gpa.free(link);
        try tmp.dir.symLink(io, target, link, .{});
    }
    const cache = try tmp.dir.realPathFileAlloc(io, "cache", gpa);
    defer gpa.free(cache);
    const cache_env = try std.fmt.allocPrint(gpa, "ZIG_GLOBAL_CACHE_DIR={s}", .{cache});
    defer gpa.free(cache_env);

    const build = try runOk(&.{ "env", cache_env, "zig", "build" }, .{ .path = tmp_path });
    defer gpa.free(build.stdout);
    defer gpa.free(build.stderr);
    try expectError(error.FileNotFound, tmp.dir.access(io, "zig-pkg", .{}));
    try expectError(error.FileNotFound, tmp.dir.access(io, "cache/p", .{}));

    const exe = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin/words_consumer", .{tmp_path});
    defer gpa.free(exe);
    const ran = try runOk(&.{exe}, .inherit);
    gpa.free(ran.stdout);
    gpa.free(ran.stderr);
}

test "AC-F2: zig build dart fails with the filesystem error when its directory can't be created" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ok = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer gpa.free(ok);
    const built = try runOk(&.{ "zig", "build", "dart", "--prefix", ok }, .inherit);
    gpa.free(built.stdout);
    gpa.free(built.stderr);
    try tmp.dir.access(io, "out/dart/words_norm.dart", .{});

    // A file where the prefix directory should be: dart/ can't be created under it.
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "" });
    const blocked = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/blocked", .{tmp.sub_path});
    defer gpa.free(blocked);
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "zig", "build", "dart", "--prefix", blocked } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try expect(!r.term.success());
    try expect(std.mem.indexOf(u8, r.stderr, "NotDir") != null);
}
