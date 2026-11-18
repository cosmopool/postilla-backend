const std = @import("std");
const words_zig = @import("src/words.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_file = b.option([]const u8, "test-file", "Run only this test file (test/<name>.zig)");
    const coverage = b.option(bool, "coverage", "Run the tests under kcov, into coverage/kcov") orelse false;

    const words = b.addModule("words", .{ .root_source_file = b.path("src/words.zig") });
    // A package that imports only `words` needs nothing below, so it never fetches SQLite.
    if (!b.isRoot()) return;

    // The app's normalization, from the same source: the letter table read through
    // `words.normalize`, then `normalize` and `lookupKeys` in Dart.
    var table: []const u8 = "";
    var cp: u21 = 0xC0;
    while (cp <= 0x24F) : (cp += 1) {
        var letter: [2]u8 = undefined;
        var norm: [2]u8 = undefined;
        const r = words_zig.normalize(letter[0 .. std.unicode.utf8Encode(cp, &letter) catch unreachable], &norm);
        if (std.ascii.isLower(r[0])) table = b.fmt("{s}  0x{x}: '{s}',\n", .{ table, cp, r });
    }
    const dart = b.addWriteFiles().add("words_norm.dart", b.fmt("{s}{s}{s}", .{ dart_head, table, dart_tail }));
    b.step("dart", "Write the app's normalization to zig-out/dart/words_norm.dart")
        .dependOn(&b.addInstallFileWithDir(dart, .prefix, "dart/words_norm.dart").step);

    // SQLite, vendored as the amalgamation. Multi-thread mode (2): every thread opens its
    // own connection, and no connection is shared between threads.
    const sqlite_dir = (b.lazyDependency("sqlite", .{}) orelse return).path("");
    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(sqlite_dir);
    const c_mod = c.createModule();

    const server_mod = module(b, "src/server.zig", target, optimize, c_mod, sqlite_dir);
    const cli_mod = module(b, "src/cli.zig", target, optimize, c_mod, sqlite_dir);

    const server_exe = b.addExecutable(.{ .name = "postilla-server", .root_module = server_mod });
    const cli_exe = b.addExecutable(.{ .name = "postilla", .root_module = cli_mod });
    b.installArtifact(server_exe);
    b.installArtifact(cli_exe);

    b.step("run", "Run postilla-server (config from env)").dependOn(&b.addRunArtifact(server_exe).step);

    // Every test/*.zig except the harness is a test root. Tests start the real server
    // through the `server` module and talk HTTP to it.
    const harness = b.createModule(.{
        .root_source_file = b.path("test/harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "server", .module = server_mod }},
    });
    // `tilla` reaches SQLite and the wire types through `server.db` and `server.wire`.
    const tilla = b.createModule(.{ .root_source_file = b.path("src/tilla.zig"), .imports = &.{
        .{ .name = "c", .module = c_mod },
        .{ .name = "server", .module = server_mod },
        .{ .name = "words", .module = words },
    } });
    const r2 = b.createModule(.{ .root_source_file = b.path("src/r2.zig") });
    const test_step = b.step("test", "Run the integration tests");
    // The configure phase is cached: without this, a file added to test/ is ignored
    // until the cache is cleared.
    b.dependOnDirectoryContents(b.path("test"));
    const io = b.graph.io;
    var dir = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, "test" }), .{ .iterate = true }) catch
        @panic("cannot open test/");
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch @panic("cannot list test/")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "harness.zig")) continue;
        const path = b.fmt("test/{s}", .{entry.name});
        if (test_file) |only| if (!std.mem.eql(u8, std.fs.path.basename(only), entry.name)) continue;
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "server", .module = server_mod },
                .{ .name = "harness", .module = harness },
                .{ .name = "words", .module = words },
                .{ .name = "tilla", .module = tilla },
                .{ .name = "r2", .module = r2 },
            },
        }) });
        if (coverage) {
            const run = b.addSystemCommand(&.{ "kcov", "--include-pattern=/src/" });
            run.addArg("coverage/kcov");
            run.addArtifactArg(t);
            test_step.dependOn(&run.step);
        } else {
            test_step.dependOn(&b.addRunArtifact(t).step);
        }
    }
}

fn module(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_mod: *std.Build.Module,
    sqlite_dir: std.Build.LazyPath,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_mod }},
    });
    m.addIncludePath(sqlite_dir);
    m.addCSourceFile(.{
        .file = sqlite_dir.path(b, "sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=2",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
        },
    });
    return m;
}

const dart_head =
    \\// Generated by `zig build dart` from postilla-backend's src/words.zig (tilla.md,
    \\// Words). Do not edit.
    \\
    \\/// The normalization of every letter in U+00C0–U+024F.
    \\const table = <int, String>{
    \\
;

const dart_tail =
    \\};
    \\
    \\/// Letters to their lowercase base, combining accents dropped, apostrophes to `'`,
    \\/// hyphens to `-`, the rest unchanged.
    \\String normalize(String text) {
    \\  final out = StringBuffer();
    \\  for (final c in text.runes) {
    \\    if (c >= 0x41 && c <= 0x5a) {
    \\      out.writeCharCode(c + 0x20);
    \\    } else if (c == 0x27 || c == 0x2019 || c == 0x2bc) {
    \\      out.write("'");
    \\    } else if (c == 0x2d || c == 0x2010 || c == 0x2011) {
    \\      out.write('-');
    \\    } else if (c < 0x300 || c > 0x36f) {
    \\      out.write(table[c] ?? String.fromCharCode(c));
    \\    }
    \\  }
    \\  return out.toString();
    \\}
    \\
    \\bool _isLetter(int c) => RegExp('^[a-z]').hasMatch(normalize(String.fromCharCode(c)));
    \\
    \\/// The keys to look `word` up by, in order: as written, normalized, then the same two
    \\/// for the part after the last apostrophe between two letters, skipping a key equal
    \\/// to the one before it.
    \\List<String> lookupKeys(String word) {
    \\  final r = word.runes.toList();
    \\  var tail = 0;
    \\  var prev = 0x20;
    \\  for (var i = 0; i + 1 < r.length; i++) {
    \\    if (normalize(String.fromCharCode(r[i])) == "'" && _isLetter(prev) && _isLetter(r[i + 1])) tail = i + 1;
    \\    if (r[i] < 0x300 || r[i] > 0x36f) prev = r[i];
    \\  }
    \\  final rest = String.fromCharCodes(r.sublist(tail));
    \\  final all = [word, normalize(word), if (tail > 0) ...[rest, normalize(rest)]];
    \\  return [for (var i = 0; i < all.length; i++) if (i == 0 || all[i] != all[i - 1]) all[i]];
    \\}
    \\
;
