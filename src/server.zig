//! postilla-server: the feed, the lists, `POST /stories` and `DELETE /stories/<id>`
//! (specification.md, Endpoints). Every connection runs as its own concurrent task on
//! `std.Io.Threaded`, so one OS thread per connection, with its own SQLite connection.

const std = @import("std");
const Io = std.Io;
const c = @import("c");
pub const db = @import("db.zig");
const wire = @import("wire.zig");

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
        route(&request, d, config.author_token) catch |err| switch (err) {
            error.Sqlite => request.respond("", .{ .status = .internal_server_error }) catch return,
            else => return,
        };
        if (!request.head.keep_alive) return;
    }
}

fn route(request: *std.http.Server.Request, d: db.Db, token: []const u8) !void {
    const target = request.head.target;
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..q];
    var params = std.mem.splitScalar(u8, target[@min(q + 1, target.len)..], '&');
    if (request.head.method == .GET) {
        if (std.mem.eql(u8, path, "/stories")) return feed(request, d, &params);
        if (std.mem.eql(u8, path, "/genres")) return list(request, d, "GNRS", "SELECT id, it, pt_br, en, count(*) OVER (), 7 + sum(16 + octet_length(id) + octet_length(it) + octet_length(pt_br) + octet_length(en)) OVER () FROM genre ORDER BY id");
        if (std.mem.eql(u8, path, "/tags")) return list(request, d, "TAGS", "SELECT id, it, pt_br, en, count(*) OVER (), 7 + sum(16 + octet_length(id) + octet_length(it) + octet_length(pt_br) + octet_length(en)) OVER () FROM tag ORDER BY id");
        if (std.mem.eql(u8, path, "/authors")) return list(request, d, "AUTH", "SELECT id, name, count(*) OVER (), 7 + sum(8 + octet_length(id) + octet_length(name)) OVER () FROM author ORDER BY id");
        if (std.mem.eql(u8, path, "/languages")) return list(request, d, "LANG", "SELECT id, name, target, translate, count(*) OVER (), 7 + sum(10 + octet_length(id) + octet_length(name)) OVER () FROM language ORDER BY id");
    }
    const post = request.head.method == .POST and std.mem.eql(u8, path, "/stories");
    if (post or request.head.method == .DELETE and std.mem.startsWith(u8, path, "/stories/") and std.mem.indexOfScalar(u8, path[9..], '/') == null) {
        // A write's connection closes after its answer, so a refused body is never read.
        request.head.keep_alive = false;
        var given: []const u8 = "";
        var headers = request.iterateHeaders();
        while (headers.next()) |h| given = if (std.ascii.eqlIgnoreCase(h.name, "authorization")) h.value else given;
        // Digests compare in constant time whatever the lengths; the token is never empty.
        var digests: [2][32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(if (std.ascii.startsWithIgnoreCase(given, "bearer ")) given[7..] else "", &digests[0], .{});
        std.crypto.hash.sha2.Sha256.hash(token, &digests[1], .{});
        if (!std.crypto.timing_safe.eql([32]u8, digests[0], digests[1])) return request.respond("", .{ .status = .unauthorized });
        return if (post) publish(request, d) else remove(request, d, path[9..]);
    }
    return reason(request, .not_found, "not found\n");
}

/// A list body (specification.md, Encoding): the rows of `sql`, each TEXT column as a
/// `str` and each INTEGER column as a `u8`, but for the last two: row count, body size.
fn list(request: *std.http.Server.Request, d: db.Db, magic: *const [4]u8, sql: [:0]const u8) !void {
    const st = try d.prepare(sql);
    const stmt = st.handle;
    defer _ = c.sqlite3_finalize(stmt);
    var row = try st.step();
    const columns = c.sqlite3_column_count(stmt) - 2;
    const body = try gpa.alloc(u8, if (row) @intCast(c.sqlite3_column_int64(stmt, columns + 1)) else 7);
    defer gpa.free(body);
    var w: wire.Writer = .{ .buf = body };
    w.header(magic);
    w.int(u16, if (row) @intCast(c.sqlite3_column_int(stmt, columns)) else 0);
    while (row) : (row = try st.step()) {
        var i: c_int = 0;
        while (i < columns) : (i += 1) {
            if (c.sqlite3_column_type(stmt, i) == c.SQLITE_INTEGER) w.int(u8, @intCast(c.sqlite3_column_int(stmt, i))) else w.str(st.bytes(i));
        }
    }
    try request.respond(w.written(), .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/octet-stream" }} });
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
            return reason(request, .bad_request, try std.fmt.bufPrint(&message, "lang: duplicate id '{s}'\n", .{id}));
        _ = c.sqlite3_reset(known.handle);
        _ = c.sqlite3_bind_text(known.handle, 1, id.ptr, @intCast(id.len), null);
        if (!try known.step())
            return reason(request, .bad_request, try std.fmt.bufPrint(&message, "lang: unknown id '{s}'\n", .{id}));
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
    const body = try gpa.alloc(u8, 9 + 61 * @as(usize, count));
    defer gpa.free(body);
    var w: wire.Writer = .{ .buf = body };
    w.header("FEED");
    w.int(u32, count);
    while (row) : (row = try st.step()) {
        w.bytes(st.bytes(0));
        w.bytes(&(try wire.Lang.fromText(st.bytes(1))).bytes);
        const change = c.sqlite3_column_int(stmt, 2);
        w.int(u8, @intCast(change));
        w.bytes(if (change == 2) &@as([32]u8, @splat(0)) else st.bytes(3));
        w.int(u32, @intCast(c.sqlite3_column_int64(stmt, 4)));
    }
    try request.respond(w.written(), .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/octet-stream" }} });
}

/// `POST /stories`: reads and parses the STRY body, then checks and upserts every
/// translation in one transaction (specification.md, `POST /stories`).
fn publish(request: *std.http.Server.Request, d: db.Db) !void {
    const len = request.head.content_length orelse return reason(request, .bad_request, "body: length required\n");
    var buf: [22 + 40 * 255]u8 = undefined;
    if (len > buf.len) return reason(request, .bad_request, "body: too large\n");
    const body = buf[0..@intCast(len)];
    try (try request.readerExpectContinue(&.{})).readSliceAll(body);
    var r: wire.Reader = .{ .buf = body };
    r.header("STRY") catch |err| return reason(request, .bad_request, if (err == error.BadMagic) "body: bad magic\n" else if (err == error.BadVersion) "body: bad version\n" else "body: wrong length\n");
    const id = r.storyId() catch return reason(request, .bad_request, "body: wrong length\n");
    const n = r.int(u8) catch 0;
    if (n == 0 or body.len != 22 + 40 * @as(usize, n)) return reason(request, .bad_request, "body: wrong length\n");
    var message: [128]u8 = undefined; // names a language id: at most 8 characters
    var original = false;
    var langs: [255]wire.Lang = undefined;
    var hashes: [255][]const u8 = undefined;
    for (langs[0..n], hashes[0..n], 0..) |*l, *h, i| {
        l.* = r.lang() catch return reason(request, .bad_request, "lang: empty or not ASCII\n");
        h.* = try r.bytes(32);
        for (langs[0..i]) |p| if (std.mem.eql(u8, &p.bytes, &l.bytes))
            return reason(request, .bad_request, try std.fmt.bufPrint(&message, "lang: repeated id '{s}'\n", .{l.text()}));
        original = original or std.mem.eql(u8, l.text(), "it");
    }
    if (!original) return reason(request, .bad_request, "lang: no 'it'\n");
    try d.exec("BEGIN IMMEDIATE");
    defer if (c.sqlite3_get_autocommit(d.handle) == 0) d.exec("ROLLBACK") catch {};
    const rows = try d.prepare("SELECT lang, change FROM story WHERE id = ?1");
    defer _ = c.sqlite3_finalize(rows.handle);
    _ = c.sqlite3_bind_blob(rows.handle, 1, &id.bytes, 16, null);
    while (try rows.step()) {
        if (c.sqlite3_column_int(rows.handle, 1) == 2) return reason(request, .conflict, "story removed\n");
        for (langs[0..n]) |*l| {
            if (std.mem.eql(u8, l.text(), rows.bytes(0))) break;
        } else return reason(request, .conflict, try std.fmt.bufPrint(&message, "{s}: published, missing from body\n", .{rows.bytes(0)}));
    }
    // An unknown id selects no `language` row, so it inserts and returns nothing.
    const upsert = try d.prepare(
        \\INSERT INTO story (id, lang, sha256, change, cursor)
        \\SELECT ?1, id, ?3, 1, (SELECT coalesce(max(cursor), 0) + 1 FROM story) FROM language WHERE id = ?2
        \\ON CONFLICT (id, lang) DO UPDATE SET sha256 = excluded.sha256,
        \\  cursor = iif(sha256 = excluded.sha256, cursor, excluded.cursor) RETURNING 1
    );
    defer _ = c.sqlite3_finalize(upsert.handle);
    _ = c.sqlite3_bind_blob(upsert.handle, 1, &id.bytes, 16, null);
    for (langs[0..n], hashes[0..n]) |*lang, hash| {
        const l = lang.text();
        _ = c.sqlite3_bind_text(upsert.handle, 2, l.ptr, @intCast(l.len), null);
        _ = c.sqlite3_bind_blob(upsert.handle, 3, hash.ptr, 32, null);
        if (!try upsert.step()) return reason(request, .bad_request, try std.fmt.bufPrint(&message, "lang: unknown id '{s}'\n", .{l}));
        _ = c.sqlite3_reset(upsert.handle);
    }
    try d.exec("COMMIT");
    try request.respond("", .{});
}

/// `DELETE /stories/<id>`: gives every translation of the story `change` 2 and a new
/// cursor, one row at a time, in one transaction. A removed story stays as it is.
fn remove(request: *std.http.Server.Request, d: db.Db, written: []const u8) !void {
    const id = wire.StoryId.parse(written) catch return reason(request, .bad_request, "id: not a UUID\n");
    try d.exec("BEGIN IMMEDIATE");
    defer if (c.sqlite3_get_autocommit(d.handle) == 0) d.exec("ROLLBACK") catch {};
    const found = try d.prepare("SELECT 1 FROM story WHERE id = ?1");
    defer _ = c.sqlite3_finalize(found.handle);
    _ = c.sqlite3_bind_blob(found.handle, 1, &id.bytes, 16, null);
    if (!try found.step()) return reason(request, .not_found, "not found\n");
    const st = try d.prepare(
        \\UPDATE story SET change = 2, cursor = (SELECT max(cursor) + 1 FROM story)
        \\WHERE id = ?1 AND lang = (SELECT lang FROM story WHERE id = ?1 AND change = 1) RETURNING 1
    );
    defer _ = c.sqlite3_finalize(st.handle);
    _ = c.sqlite3_bind_blob(st.handle, 1, &id.bytes, 16, null);
    while (try st.step()) _ = c.sqlite3_reset(st.handle);
    try d.exec("COMMIT");
    try request.respond("", .{});
}

fn reason(request: *std.http.Server.Request, status: std.http.Status, line: []const u8) !void {
    try request.respond(line, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
}
