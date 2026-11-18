//! postilla-server: the feed, the lists, `POST /stories` and `DELETE /stories/<id>`
//! (specification.md, Endpoints). Every connection runs as its own concurrent task on
//! `std.Io.Threaded`, so one OS thread per connection, with its own SQLite connection.

const std = @import("std");
const Io = std.Io;
const db = @import("db.zig");

const log = std.log.scoped(.server);

pub const Config = struct {
    port: u16 = 8080,
    bind: []const u8 = "127.0.0.1",
    db_path: [:0]const u8 = "./postilla.db",
    author_token: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    const config = readConfig(init.arena.allocator(), init.environ_map) catch std.process.exit(1);
    var listener = listen(init.io, &config) catch |err| {
        log.err("cannot listen on {s}:{d}: {t}", .{ config.bind, config.port, err });
        std.process.exit(1);
    };
    defer listener.deinit(init.io);
    log.info("listening on {s}:{d}", .{ config.bind, config.port });
    serve(init.io, &listener, &config) catch {};
}

/// Reads and checks every variable once (specification.md, Configuration). A missing or
/// bad value is logged and stops the server before it binds.
fn readConfig(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !Config {
    var config: Config = .{};
    var ok = true;
    if (env.get("POSTILLA_PORT")) |v| config.port = std.fmt.parseInt(u16, v, 10) catch blk: {
        log.err("POSTILLA_PORT: not a port: '{s}'", .{v});
        ok = false;
        break :blk 0;
    };
    if (env.get("POSTILLA_BIND")) |v| config.bind = v;
    if (env.get("POSTILLA_DB")) |v| config.db_path = try arena.dupeSentinel(u8, v, 0);
    config.author_token = env.get("POSTILLA_AUTHOR_TOKEN") orelse "";
    if (config.author_token.len == 0) {
        log.err("POSTILLA_AUTHOR_TOKEN: required", .{});
        ok = false;
    }
    if (!ok) return error.BadConfig;
    return config;
}

/// Opens the database once to check it (and, in slice 1, create the schema), then
/// binds. Port 0 picks a free port; the bound one is `listener.socket.address`.
pub fn listen(io: Io, config: *const Config) !Io.net.Server {
    var d = try db.open(config.db_path);
    d.close();
    const address = try Io.net.IpAddress.parse(config.bind, config.port);
    return address.listen(io, .{ .reuse_address = true });
}

/// Accepts connections until canceled.
pub fn serve(io: Io, listener: *Io.net.Server, config: *const Config) Io.Cancelable!void {
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.warn("accept: {t}", .{err});
                continue;
            },
        };
        group.concurrent(io, connection, .{ io, stream, config }) catch |err| {
            log.warn("no task for a connection: {t}", .{err});
            stream.close(io);
        };
    }
}

fn connection(io: Io, stream: Io.net.Stream, config: *const Config) Io.Cancelable!void {
    _ = config;
    defer stream.close(io);
    var in_buf: [8192]u8 = undefined;
    var out_buf: [16384]u8 = undefined;
    var in = stream.reader(io, &in_buf);
    var out = stream.writer(io, &out_buf);
    var http: std.http.Server = .init(&in.interface, &out.interface);
    while (true) {
        var request = http.receiveHead() catch return;
        const keep_alive = request.head.keep_alive;
        request.respond("not found\n", .{
            .status = .not_found,
            .keep_alive = keep_alive,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        }) catch return;
        if (!keep_alive) return;
    }
}
