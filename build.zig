const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_file = b.option([]const u8, "test-file", "Run only this test file (test/<name>.zig)");
    const coverage = b.option(bool, "coverage", "Run the tests under kcov, into coverage/kcov") orelse false;

    // SQLite, vendored as the amalgamation. Multi-thread mode (2): every thread opens its
    // own connection, and no connection is shared between threads.
    const sqlite_dir = b.dependency("sqlite", .{}).path("");
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
    const test_step = b.step("test", "Run the integration tests");
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
