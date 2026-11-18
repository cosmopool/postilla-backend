//! postilla-server: the feed, the lists, `POST /stories` and `DELETE /stories/<id>`
//! (specification.md, Endpoints). Every connection runs as its own concurrent task on
//! `std.Io.Threaded`, so one OS thread per connection, with its own SQLite connection.

const std = @import("std");
const Io = std.Io;
const c = @import("c");
pub const db = @import("db.zig");

const log = std.log.scoped(.server);

pub const Config = struct {
    port: u16 = 8080,
    bind: []const u8 = "127.0.0.1",
    db_path: [:0]const u8 = "./postilla.db",
    author_token: []const u8 = "",
    /// A connection that sends no request for this long is closed.
    idle_timeout_ms: i64 = 30_000,
};

const gpa = std.heap.smp_allocator;

/// specification.md, Database. The temp table's CHECK refuses a schema newer than 1.
const schema =
    \\CREATE TEMP TABLE version_check (user_version CHECK (user_version <= 1));
    \\INSERT INTO version_check SELECT user_version FROM pragma_user_version;
    \\CREATE TABLE IF NOT EXISTS story (id BLOB NOT NULL, lang TEXT NOT NULL REFERENCES language(id),
    \\  sha256 BLOB NOT NULL, change INTEGER NOT NULL, cursor INTEGER NOT NULL UNIQUE, PRIMARY KEY (id, lang)) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS genre (id TEXT PRIMARY KEY, it TEXT NOT NULL, pt_br TEXT NOT NULL, en TEXT NOT NULL) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS tag (id TEXT PRIMARY KEY, it TEXT NOT NULL, pt_br TEXT NOT NULL, en TEXT NOT NULL) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS author (id TEXT PRIMARY KEY, name TEXT NOT NULL) WITHOUT ROWID;
    \\CREATE TRIGGER IF NOT EXISTS author_keep BEFORE DELETE ON author BEGIN SELECT RAISE(ABORT, 'author ids are permanent'); END;
    \\CREATE TRIGGER IF NOT EXISTS author_id_fixed BEFORE UPDATE OF id ON author BEGIN SELECT RAISE(ABORT, 'author ids are permanent'); END;
    \\CREATE TABLE IF NOT EXISTS language (id TEXT PRIMARY KEY CHECK (length(id) <= 8), name TEXT NOT NULL,
    \\  target INTEGER NOT NULL, translate INTEGER NOT NULL) WITHOUT ROWID;
    \\CREATE TRIGGER IF NOT EXISTS language_keep BEFORE DELETE ON language BEGIN SELECT RAISE(ABORT, 'language ids are permanent'); END;
    \\CREATE TRIGGER IF NOT EXISTS language_id_fixed BEFORE UPDATE OF id ON language BEGIN SELECT RAISE(ABORT, 'language ids are permanent'); END;
    \\INSERT OR IGNORE INTO language VALUES
    \\  ('it', 'Italiano', 1, 0), ('pt-BR', 'Português brasileiro', 0, 1), ('en', 'English', 0, 0);
    \\INSERT OR IGNORE INTO genre VALUES ('quotidiano', 'Quotidiano', 'Cotidiano', 'Everyday'), ('famiglia', 'Famiglia', 'Família', 'Family'),
    \\  ('viaggio', 'Viaggio', 'Viagem', 'Travel'), ('mistero', 'Mistero', 'Mistério', 'Mystery'), ('lettere', 'Lettere', 'Cartas', 'Letters'),
    \\  ('racconto', 'Racconto', 'Conto', 'Short story'), ('classici', 'Classici', 'Clássicos', 'Classics');
    \\INSERT OR IGNORE INTO author VALUES ('collodi', 'Carlo Collodi');
    \\PRAGMA user_version = 1;
;

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

/// Creates the schema and the seed rows, refusing a newer schema, then binds. Port 0
/// picks a free port; the bound one is `listener.socket.address`.
pub fn listen(io: Io, config: *const Config) !Io.net.Server {
    var d = try db.open(config.db_path);
    defer d.close();
    try d.exec(schema);
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
    defer stream.close(io);
    var d = db.open(config.db_path) catch return;
    defer d.close();
    var in_buf: [8192]u8 = undefined;
    var out_buf: [16384]u8 = undefined;
    var in = stream.reader(io, &in_buf);
    var out = stream.writer(io, &out_buf);
    var http: std.http.Server = .init(&in.interface, &out.interface);
    while (true) {
        if (in.interface.bufferedLen() == 0) {
            // Waits for the next request's first byte, without taking it.
            var byte: [1]u8 = undefined;
            var message: Io.net.IncomingMessage = .init;
            const idle = io.operateTimeout(.{ .net_receive = .{
                .socket_handle = stream.socket.handle,
                .message_buffer = (&message)[0..1],
                .data_buffer = &byte,
                .flags = .{ .peek = true },
            } }, .{ .duration = .{ .raw = .fromMilliseconds(config.idle_timeout_ms), .clock = .awake } }) catch return;
            if (idle.net_receive[0] != null) return;
        }
        var request = http.receiveHead() catch |err| switch (err) {
            error.HttpHeadersInvalid, error.HttpHeadersOversize => {
                out.interface.writeAll("HTTP/1.1 400 Bad Request\r\nconnection: close\r\n" ++
                    "content-type: text/plain\r\ncontent-length: 17\r\n\r\nbad request head\n") catch {};
                out.interface.flush() catch {};
                return;
            },
            else => return,
        };
        route(&request, d) catch |err| switch (err) {
            error.Sqlite => request.respond("", .{ .status = .internal_server_error }) catch return,
            else => return,
        };
        if (!request.head.keep_alive) return;
    }
}

fn route(request: *std.http.Server.Request, d: db.Db) !void {
    const target = request.head.target;
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..q];
    var params = std.mem.splitScalar(u8, target[@min(q + 1, target.len)..], '&');
    if (request.head.method == .GET) {
        if (std.mem.eql(u8, path, "/stories")) return feed(request, d, &params);
        if (std.mem.eql(u8, path, "/genres")) return list(request, d, "GNRS", "SELECT id, it, pt_br, en FROM genre ORDER BY id");
        if (std.mem.eql(u8, path, "/tags")) return list(request, d, "TAGS", "SELECT id, it, pt_br, en FROM tag ORDER BY id");
        if (std.mem.eql(u8, path, "/authors")) return list(request, d, "AUTH", "SELECT id, name FROM author ORDER BY id");
        if (std.mem.eql(u8, path, "/languages")) return list(request, d, "LANG", "SELECT id, name, target, translate FROM language ORDER BY id");
    }
    return reason(request, .not_found, "not found\n");
}

/// A list body (specification.md, Encoding): the rows of `sql`, each TEXT column as a
/// `str` and each INTEGER column as a `u8`, after a header whose `count` is set last.
fn list(request: *std.http.Server.Request, d: db.Db, comptime magic: []const u8, sql: [:0]const u8) !void {
    const st = try d.prepare(sql);
    const stmt = st.handle;
    defer _ = c.sqlite3_finalize(stmt);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.writeAll(magic ++ "\x01\x00\x00");
    var count: u16 = 0;
    while (try st.step()) : (count += 1) {
        var i: c_int = 0;
        while (i < c.sqlite3_column_count(stmt)) : (i += 1) {
            if (c.sqlite3_column_type(stmt, i) == c.SQLITE_INTEGER) {
                try body.writer.writeByte(@intCast(c.sqlite3_column_int(stmt, i)));
            } else {
                const t = st.bytes(i);
                try body.writer.writeInt(u32, @intCast(t.len), .big);
                try body.writer.writeAll(t);
            }
        }
    }
    std.mem.writeInt(u16, body.written()[5..7], count, .big);
    try request.respond(body.written(), .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/octet-stream" }} });
}

/// `GET /stories`: parses `since` and `lang`, then runs one query on the `cursor` index.
/// The first row carries the row count, so the body is sized once.
fn feed(request: *std.http.Server.Request, d: db.Db, params: *std.mem.SplitIterator(u8, .scalar)) !void {
    var since: ?[]const u8 = null;
    var lang: ?[]const u8 = null;
    while (params.next()) |p| {
        if (std.mem.startsWith(u8, p, "since=")) {
            if (since != null) return reason(request, .bad_request, "since: repeated\n");
            since = p[6..];
        } else if (std.mem.startsWith(u8, p, "lang=")) {
            if (lang != null) return reason(request, .bad_request, "lang: repeated\n");
            lang = p[5..];
        }
    }
    const s = since orelse "0";
    const parsed = if (s.len <= 10 and std.mem.indexOfNone(u8, s, "0123456789") == null) std.fmt.parseInt(u32, s, 10) else error.Overflow;
    const after = parsed catch return reason(request, .bad_request, "since: not a u32\n");

    // The reason names an id from the head, which is at most 8 KiB.
    var message: [8256]u8 = undefined;
    const known = try d.prepare("SELECT 1 FROM language WHERE id = ?1");
    defer _ = c.sqlite3_finalize(known.handle);
    var ids: [4][]const u8 = undefined;
    var n: usize = 0;
    var items = std.mem.splitScalar(u8, lang orelse return reason(request, .bad_request, "lang: missing\n"), ',');
    while (items.next()) |id| : (n += 1) {
        if (id.len == 0) return reason(request, .bad_request, "lang: empty id\n");
        if (n == 4) return reason(request, .bad_request, "lang: more than 4 ids\n");
        for (ids[0..n]) |prev| if (std.mem.eql(u8, id, prev))
            return reason(request, .bad_request, std.fmt.bufPrint(&message, "lang: duplicate id '{s}'\n", .{id}) catch unreachable);
        _ = c.sqlite3_reset(known.handle);
        _ = c.sqlite3_bind_text(known.handle, 1, id.ptr, @intCast(id.len), null);
        if (!try known.step())
            return reason(request, .bad_request, std.fmt.bufPrint(&message, "lang: unknown id '{s}'\n", .{id}) catch unreachable);
        ids[n] = id;
    }

    const st = try d.prepare("SELECT id, lang, change, sha256, cursor, count(*) OVER () FROM story " ++
        "WHERE cursor > ?1 AND lang IN (?2, ?3, ?4, ?5) ORDER BY cursor");
    const stmt = st.handle;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, after);
    for (ids[0..n], 2..) |id, i| _ = c.sqlite3_bind_text(stmt, @intCast(i), id.ptr, @intCast(id.len), null);
    var row = try st.step();
    const count: u32 = if (row) @intCast(c.sqlite3_column_int64(stmt, 5)) else 0;
    var body: std.Io.Writer.Allocating = try .initCapacity(gpa, 9 + 61 * @as(usize, count));
    defer body.deinit();
    const w = &body.writer;
    try w.writeAll("FEED\x01");
    try w.writeInt(u32, count, .big);
    while (row) : (row = try st.step()) {
        try w.writeAll(st.bytes(0));
        const l = st.bytes(1);
        try w.writeAll(l);
        try w.splatByteAll(0, 8 - l.len);
        const change = c.sqlite3_column_int(stmt, 2);
        try w.writeByte(@intCast(change));
        if (change == 2) try w.splatByteAll(0, 32) else try w.writeAll(st.bytes(3));
        try w.writeInt(u32, @intCast(c.sqlite3_column_int64(stmt, 4)), .big);
    }
    try request.respond(body.written(), .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/octet-stream" }} });
}

fn reason(request: *std.http.Server.Request, status: std.http.Status, line: []const u8) !void {
    try request.respond(line, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
}
