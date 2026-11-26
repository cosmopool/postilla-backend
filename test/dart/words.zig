//! The generated Dart normalization against the Zig one. It needs the Dart SDK, so it runs
//! in `zig build test-dart`, not `zig build test` (CI runs it in its own job).

const std = @import("std");
const words = @import("words");

const io = std.testing.io;
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

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

test "AC-10, AC-6, AC-7, AC-8: the generated Dart normalize and lookupKeys give the Zig results" {
    const build = try runOk(&.{ "zig", "build", "dart" }, .inherit);
    gpa.free(build.stdout);
    gpa.free(build.stderr);
    try std.Io.Dir.cwd().access(io, "zig-out/dart/words_norm.dart", .{});

    // words_check.dart checks the AC-6, AC-7 and AC-8 expectations itself, then prints
    // one line per input: the input, its normalization and its lookup keys, tab-separated.
    const check = try runOk(&.{ "dart", "run", "test/dart/words_check.dart" }, .inherit);
    defer gpa.free(check.stdout);
    defer gpa.free(check.stderr);

    var letters: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, check.stdout, "\n"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const input = fields.next().?;
        if (try std.unicode.utf8CountCodepoints(input) == 1) letters += 1;

        var norm_buf: [64]u8 = undefined;
        try expectEqualStrings(words.normalize(input, &norm_buf), fields.next() orelse "");

        var key_buf: [64]u8 = undefined;
        var keys: [4][]const u8 = undefined;
        for (words.lookupKeys(input, &key_buf, &keys)) |key| try expectEqualStrings(key, fields.next() orelse "");
        try expect(fields.next() == null);
    }
    // One line per letter of the table: U+00C0–U+024F without × and ÷.
    try expectEqual(0x24F - 0xC0 + 1 - 2, letters);

    // The Dart table has one `0x<code>: '<replacement>',` entry per letter of the
    // committed table (`"<replacement>", // U+XXXX`), with the same replacement.
    const table = try std.Io.Dir.cwd().readFileAlloc(io, "src/words_table.zig", gpa, .limited(1 << 20));
    defer gpa.free(table);
    var committed: [0x24F - 0xC0 + 1]?[]const u8 = @splat(null);
    var table_lines = std.mem.splitScalar(u8, table, '\n');
    while (table_lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "\", // U+") orelse continue;
        const want = std.mem.trimStart(u8, line[0..at], " \"");
        if (want.len > 0) committed[try std.fmt.parseInt(u21, line[at + 8 ..][0..4], 16) - 0xC0] = want;
    }
    const dart = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/dart/words_norm.dart", gpa, .limited(1 << 20));
    defer gpa.free(dart);
    var seen: [0x24F - 0xC0 + 1]bool = @splat(false);
    var dart_entries: usize = 0;
    var dart_lines = std.mem.splitScalar(u8, dart, '\n');
    while (dart_lines.next()) |line| {
        const entry = std.mem.trim(u8, line, " ");
        if (!std.mem.startsWith(u8, entry, "0x")) continue;
        const colon = std.mem.indexOf(u8, entry, ": '") orelse return error.BadDartEntry;
        const code = try std.fmt.parseInt(u21, entry[2..colon], 16);
        try expect(code >= 0xC0 and code <= 0x24F);
        try expect(!seen[code - 0xC0]);
        seen[code - 0xC0] = true;
        dart_entries += 1;
        try expectEqualStrings(committed[code - 0xC0] orelse "(no entry)", std.mem.trimEnd(u8, entry[colon + 3 ..], "',"));
    }
    var committed_entries: usize = 0;
    for (committed) |c| committed_entries += @intFromBool(c != null);
    try expectEqual(committed_entries, dart_entries);
}
