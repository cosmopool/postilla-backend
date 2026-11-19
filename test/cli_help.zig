//! `postilla --help` (docs/specification.md, The CLI): the full help on stdout with exit 0;
//! a usage error keeps the short usage on stderr with exit 2 and points to `--help`.

const std = @import("std");
const cli = @import("cli");

const io = std.testing.io;

const Run = struct { code: u8, out: []const u8, err: []const u8 };

/// Runs `cli.run` with `args` (program name first), stdout and stderr each captured.
fn run(a: std.mem.Allocator, tmp: *std.testing.TmpDir, args: []const [:0]const u8) !Run {
    var env: std.process.Environ.Map = .init(a);
    const files = [2]std.Io.File{ try tmp.dir.createFile(io, "out.txt", .{ .read = true }), try tmp.dir.createFile(io, "err.txt", .{ .read = true }) };
    defer for (files) |f| f.close(io);
    const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
    _ = std.c.dup2(files[0].handle, 1);
    _ = std.c.dup2(files[1].handle, 2);
    const code = cli.run(io, a, &env, tmp.dir, args);
    _ = std.c.dup2(saved[0], 1);
    _ = std.c.dup2(saved[1], 2);
    for (saved) |fd| _ = std.c.close(fd);
    return .{
        .code = code,
        .out = try tmp.dir.readFileAlloc(io, "out.txt", a, .limited(1 << 20)),
        .err = try tmp.dir.readFileAlloc(io, "err.txt", a, .limited(1 << 20)),
    };
}

test "--help, -h and help print the full help to stdout and exit 0" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][:0]const u8{ "--help", "-h", "help" }) |flag| {
        const r = try run(arena.allocator(), &tmp, &.{ "postilla", flag });
        try std.testing.expectEqual(0, r.code);
        try std.testing.expectEqualStrings("", r.err);
        for ([_][]const u8{ "translate <folder>", "--force", "--redo <lang>", "narrate <folder>", "publish <folder>", "story.json", "cli.env", "POSTILLA_SERVER_URL", "POSTILLA_R2_BUCKET", "POSTILLA_MODERATION_THRESHOLD", "Exit codes" }) |part|
            try std.testing.expect(std.mem.find(u8, r.out, part) != null);
    }
}

test "a usage error prints the short usage to stderr, points to --help, and exits 2" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const [:0]const u8{ &.{"postilla"}, &.{ "postilla", "frobnicate", "x" }, &.{ "postilla", "--help", "extra" } }) |args| {
        const r = try run(arena.allocator(), &tmp, args);
        try std.testing.expectEqual(2, r.code);
        try std.testing.expectEqualStrings("", r.out);
        try std.testing.expect(std.mem.startsWith(u8, r.err, "usage: postilla"));
        try std.testing.expect(std.mem.find(u8, r.err, "postilla --help") != null);
    }
}
