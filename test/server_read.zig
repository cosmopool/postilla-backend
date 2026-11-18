const std = @import("std");
const Io = std.Io;
const server = @import("server");
const harness = @import("harness");
const Harness = harness.Harness;
const Response = harness.Response;

const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

/// A `str` on the wire: u32 big-endian length, then the bytes.
inline fn str(comptime s: []const u8) *const [4 + s.len]u8 {
    return comptime &(std.mem.toBytes(std.mem.nativeToBig(u32, s.len)) ++ s[0..s.len].*);
}

inline fn named(comptime id: []const u8, comptime it: []const u8, comptime pt_br: []const u8, comptime en: []const u8) []const u8 {
    return comptime str(id) ++ str(it) ++ str(pt_br) ++ str(en);
}

const languages = "LANG\x01\x00\x03" ++
    str("en") ++ str("English") ++ "\x00\x00" ++
    str("it") ++ str("Italiano") ++ "\x01\x00" ++
    str("pt-BR") ++ str("Português brasileiro") ++ "\x00\x01";

const genres = "GNRS\x01\x00\x07" ++
    named("classici", "Classici", "Clássicos", "Classics") ++
    named("famiglia", "Famiglia", "Família", "Family") ++
    named("lettere", "Lettere", "Cartas", "Letters") ++
    named("mistero", "Mistero", "Mistério", "Mystery") ++
    named("quotidiano", "Quotidiano", "Cotidiano", "Everyday") ++
    named("racconto", "Racconto", "Conto", "Short story") ++
    named("viaggio", "Viaggio", "Viagem", "Travel");

const authors = "AUTH\x01\x00\x01" ++ str("collodi") ++ str("Carlo Collodi");

/// One 61-byte FEED record: the story id and the sha256 are a byte repeated.
inline fn record(comptime id: u8, comptime lang: []const u8, comptime change: u8, comptime sha: u8, comptime cursor: u32) [61]u8 {
    return comptime blk: {
        var r: [61]u8 = @splat(0);
        @memset(r[0..16], id);
        @memcpy(r[16..][0..lang.len], lang);
        r[24] = change;
        @memset(r[25..57], sha);
        std.mem.writeInt(u32, r[57..61], cursor, .big);
        break :blk r;
    };
}

inline fn feed(comptime records: []const [61]u8) []const u8 {
    return comptime blk: {
        var out: [9 + 61 * records.len]u8 = undefined;
        @memcpy(out[0..5], "FEED\x01");
        std.mem.writeInt(u32, out[5..9], records.len, .big);
        for (records, 0..) |r, i| @memcpy(out[9 + 61 * i ..][0..61], &r);
        const final = out;
        break :blk &final;
    };
}

/// `n` copies of `ch`, for hex blob literals and padding.
inline fn rep(comptime ch: u8, comptime n: usize) *const [n]u8 {
    return comptime &@as([n]u8, @splat(ch));
}

/// A STRY body for the story whose id is `id` repeated: each translation is a `lang`
/// and a byte its sha256 repeats.
inline fn stry(comptime id: u8, comptime translations: []const struct { []const u8, u8 }) []const u8 {
    return comptime blk: {
        var out: []const u8 = "STRY\x01" ++ rep(id, 16) ++ [_]u8{translations.len};
        for (translations) |t| {
            var one: [40]u8 = @splat(0);
            @memcpy(one[0..t[0].len], t[0]);
            @memset(one[8..], t[1]);
            out = out ++ one;
        }
        break :blk out;
    };
}

const auth = "\r\nauthorization: Bearer " ++ harness.token;

fn write(h: *const Harness, head: []const u8, body: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const r = try h.send(head, body, &buf);
    try expectEqual(200, r.status);
}

/// Four translations of three stories, published through the endpoints so that story
/// ids sort opposite to cursors. Story 0x11 was removed after its publish.
fn publishStories(h: *const Harness) !void {
    try write(h, "POST /stories HTTP/1.1" ++ auth, stry(0x33, &.{.{ "it", 0xaa }}));
    try write(h, "POST /stories HTTP/1.1" ++ auth, stry(0x22, &.{.{ "it", 0xbb }}));
    try write(h, "POST /stories HTTP/1.1" ++ auth, stry(0x22, &.{ .{ "it", 0xbb }, .{ "pt-BR", 0xcc } }));
    try write(h, "POST /stories HTTP/1.1" ++ auth, stry(0x11, &.{.{ "it", 0xdd }}));
    try write(h, "DELETE /stories/11111111-1111-1111-1111-111111111111 HTTP/1.1" ++ auth, "");
}

const c1 = record(0x33, "it", 1, 0xaa, 1);
const c2 = record(0x22, "it", 1, 0xbb, 2);
const c3 = record(0x22, "pt-BR", 1, 0xcc, 3);
const c4_removed = record(0x11, "it", 2, 0x00, 5);

fn expectBody(h: *const Harness, head: []const u8, want: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const r = try h.send(head, "", &buf);
    try expectEqual(200, r.status);
    try expectEqualStrings("application/octet-stream", r.header("content-type"));
    try expectEqual(r.body.len, try std.fmt.parseInt(usize, r.header("content-length"), 10));
    try expectEqualSlices(u8, want, r.body);
}

fn expectReason(h: *const Harness, head: []const u8, status: u16, reason: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const r = try h.send(head, "", &buf);
    try expectEqual(status, r.status);
    try expectEqualStrings("text/plain", r.header("content-type"));
    try expectEqualStrings(reason, r.body);
}

/// Opens its own connection, waits `idle_ms`, writes `bytes` as is, and returns all
/// that arrives until the server closes. A write or read failure after the server
/// closed counts as the end of the response.
fn raw(h: *const Harness, bytes: []const u8, idle_ms: i64, buf: []u8) ![]const u8 {
    const address = try Io.net.IpAddress.parse("127.0.0.1", h.port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try io.sleep(.fromMilliseconds(idle_ms), .awake);
    var out_buf: [4096]u8 = undefined;
    var out = stream.writer(io, &out_buf);
    out.interface.writeAll(bytes) catch {};
    out.interface.flush() catch {};
    var in = stream.reader(io, buf);
    while (true) in.interface.fillMore() catch break;
    return in.interface.buffered();
}

test "AC-1, AC-2, AC-3, AC-4, AC-11: a fresh database serves the seed rows of the four lists" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try expectBody(&h, "GET /languages HTTP/1.1", languages);
    try expectBody(&h, "GET /genres HTTP/1.1", genres);
    try expectBody(&h, "GET /tags HTTP/1.1", "TAGS\x01\x00\x00");
    try expectBody(&h, "GET /authors HTTP/1.1", authors);
}

test "AC-11: startup creates the schema and triggers and stamps user_version 1" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    // Each INSERT fails its CHECK when the condition is false.
    try h.sql(
        \\CREATE TEMP TABLE ok (v CHECK (v));
        \\INSERT INTO ok SELECT user_version = 1 FROM pragma_user_version;
        \\INSERT INTO ok SELECT count(*) = 5 FROM sqlite_schema WHERE type = 'table'
        \\  AND name IN ('story', 'genre', 'tag', 'author', 'language');
        \\INSERT INTO ok SELECT count(*) = 4 FROM sqlite_schema WHERE type = 'trigger'
        \\  AND name IN ('author_keep', 'author_id_fixed', 'language_keep', 'language_id_fixed');
        \\INSERT INTO ok SELECT count(*) = 3 FROM language;
        \\INSERT INTO ok SELECT count(*) = 7 FROM genre;
        \\INSERT INTO ok SELECT count(*) = 1 FROM author;
        \\INSERT INTO ok SELECT count(*) = 0 FROM tag;
        \\INSERT INTO ok SELECT count(*) = 0 FROM story;
    );
}

test "AC-3, AC-11: rows added or renamed by hand show up in the lists and survive a restart" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try h.sql(
        \\INSERT INTO tag VALUES ('cibo', 'Cibo', 'Comida', 'Food');
        \\UPDATE genre SET it = 'Classici rinominati' WHERE id = 'classici';
    );
    const tags = "TAGS\x01\x00\x01" ++ named("cibo", "Cibo", "Comida", "Food");
    try expectBody(&h, "GET /tags HTTP/1.1", tags);

    // A second startup on the same file runs the schema and seed again.
    var again = try server.listen(io, &h.config);
    again.deinit(io);

    try expectBody(&h, "GET /tags HTTP/1.1", tags);
    var buf: [4096]u8 = undefined;
    const r = try h.send("GET /genres HTTP/1.1", "", &buf);
    try expectEqual(200, r.status);
    try expectEqualSlices(u8, "GNRS\x01\x00\x07", r.body[0..7]);
    try expect(std.mem.indexOf(u8, r.body, str("Classici rinominati")) != null);
    try expect(std.mem.indexOf(u8, r.body, str("Classici")) == null);
    try expectEqual(genres.len + "Classici rinominati".len - "Classici".len, r.body.len);
}

test "AC-12: triggers refuse deleting a language or author row or changing its id" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try std.testing.expectError(error.Sqlite, h.sql("DELETE FROM language WHERE id = 'en';"));
    try std.testing.expectError(error.Sqlite, h.sql("UPDATE language SET id = 'eng' WHERE id = 'en';"));
    try std.testing.expectError(error.Sqlite, h.sql("DELETE FROM author WHERE id = 'collodi';"));
    try std.testing.expectError(error.Sqlite, h.sql("UPDATE author SET id = 'carlo' WHERE id = 'collodi';"));
    try expectBody(&h, "GET /languages HTTP/1.1", languages);
    try expectBody(&h, "GET /authors HTTP/1.1", authors);

    // Only the id is fixed: a name can still be corrected.
    try h.sql("UPDATE author SET name = 'C. Collodi' WHERE id = 'collodi';");
    try expectBody(&h, "GET /authors HTTP/1.1", "AUTH\x01\x00\x01" ++ str("collodi") ++ str("C. Collodi"));
}

test "AC-5, AC-6, AC-7: the feed returns the listed languages' rows above since, ascending by cursor" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try expectBody(&h, "GET /stories?lang=it HTTP/1.1", feed(&.{}));

    try publishStories(&h);

    const above_1 = feed(&.{ c2, c3, c4_removed });
    try expectEqual(9 + 61 * 3, above_1.len);
    try expectBody(&h, "GET /stories?since=1&lang=it,pt-BR HTTP/1.1", above_1);
    try expectBody(&h, "GET /stories?lang=pt-BR,it&since=1 HTTP/1.1", above_1);

    try expectBody(&h, "GET /stories?since=1&lang=it HTTP/1.1", feed(&.{ c2, c4_removed }));
    try expectBody(&h, "GET /stories?since=0&lang=pt-BR HTTP/1.1", feed(&.{c3}));
    try expectBody(&h, "GET /stories?lang=en HTTP/1.1", feed(&.{}));

    const all = feed(&.{ c1, c2, c3, c4_removed });
    try expectBody(&h, "GET /stories?lang=it,pt-BR HTTP/1.1", all);
    try expectBody(&h, "GET /stories?since=0&lang=it,pt-BR HTTP/1.1", all);
    try expectBody(&h, "GET /stories?since=0000000000&x=1&lang=it,pt-BR HTTP/1.1", all);

    try expectBody(&h, "GET /stories?since=4&lang=it,pt-BR HTTP/1.1", feed(&.{c4_removed}));
    const empty = "FEED\x01\x00\x00\x00\x00";
    try expectBody(&h, "GET /stories?since=5&lang=it,pt-BR HTTP/1.1", empty);
    try expectBody(&h, "GET /stories?since=0000000005&lang=it,pt-BR HTTP/1.1", empty);
    try expectBody(&h, "GET /stories?since=4294967295&lang=it,pt-BR HTTP/1.1", empty);
}

test "AC-8: a bad since gets 400 with the matching reason" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const not_u32 = "since: not a u32\n";
    for ([_][]const u8{
        "GET /stories?since=&lang=it HTTP/1.1",
        "GET /stories?since=-1&lang=it HTTP/1.1",
        "GET /stories?since=+1&lang=it HTTP/1.1",
        "GET /stories?since=abc&lang=it HTTP/1.1",
        "GET /stories?since=1a&lang=it HTTP/1.1",
        "GET /stories?since=0x10&lang=it HTTP/1.1",
        "GET /stories?since=1.0&lang=it HTTP/1.1",
        "GET /stories?since=%201&lang=it HTTP/1.1",
        "GET /stories?since=00000000001&lang=it HTTP/1.1",
        "GET /stories?since=99999999999&lang=it HTTP/1.1",
        "GET /stories?since=4294967296&lang=it HTTP/1.1",
    }) |head| try expectReason(&h, head, 400, not_u32);

    try expectReason(&h, "GET /stories?since=1&since=2&lang=it HTTP/1.1", 400, "since: repeated\n");
    try expectReason(&h, "GET /stories?since=1&lang=it&since=1 HTTP/1.1", 400, "since: repeated\n");
}

test "AC-9: a bad lang gets 400 with the matching reason" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try expectReason(&h, "GET /stories HTTP/1.1", 400, "lang: missing\n");
    try expectReason(&h, "GET /stories?since=0 HTTP/1.1", 400, "lang: missing\n");
    try expectReason(&h, "GET /stories?lang=it&lang=it HTTP/1.1", 400, "lang: repeated\n");
    try expectReason(&h, "GET /stories?lang=it,,pt-BR HTTP/1.1", 400, "lang: empty id\n");
    try expectReason(&h, "GET /stories?lang=,it HTTP/1.1", 400, "lang: empty id\n");
    try expectReason(&h, "GET /stories?lang=it, HTTP/1.1", 400, "lang: empty id\n");
    try expectReason(&h, "GET /stories?lang=it,pt-BR,it HTTP/1.1", 400, "lang: duplicate id 'it'\n");
    try expectReason(&h, "GET /stories?lang=it,fr HTTP/1.1", 400, "lang: unknown id 'fr'\n");
    try expectReason(&h, "GET /stories?lang=IT HTTP/1.1", 400, "lang: unknown id 'IT'\n");

    // `lang=` is both missing and an empty item: either reason names the rule.
    var buf: [4096]u8 = undefined;
    const r = try h.send("GET /stories?lang= HTTP/1.1", "", &buf);
    try expectEqual(400, r.status);
    try expectEqualStrings("text/plain", r.header("content-type"));
    try expect(std.mem.eql(u8, r.body, "lang: missing\n") or std.mem.eql(u8, r.body, "lang: empty id\n"));

    // Five ids, every one of them in `language`.
    try h.sql("INSERT INTO language VALUES ('de', 'Deutsch', 0, 0), ('es', 'Español', 0, 0);");
    try expectReason(&h, "GET /stories?lang=de,en,es,it,pt-BR HTTP/1.1", 400, "lang: more than 4 ids\n");
    try expectBody(&h, "GET /stories?lang=de,en,es,it HTTP/1.1", feed(&.{}));
}

test "AC-10: any other path, or a method other than GET, gets 404 not found" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    for ([_][]const u8{
        "GET / HTTP/1.1",
        "GET /nope HTTP/1.1",
        "GET /genres/classici HTTP/1.1",
        "GET /languagesx HTTP/1.1",
        "GET /Stories?lang=it HTTP/1.1",
        "GET /storiesx?lang=it HTTP/1.1",
        "POST /languages HTTP/1.1",
        "PUT /stories?lang=it HTTP/1.1",
        "DELETE /genres HTTP/1.1",
        "PATCH /authors HTTP/1.1",
        "OPTIONS /tags HTTP/1.1",
    }) |head| try expectReason(&h, head, 404, "not found\n");

    var buf: [4096]u8 = undefined;
    for ([_][]const u8{
        "HEAD /languages HTTP/1.1",
        "HEAD /stories?lang=it HTTP/1.1",
    }) |head| {
        const r = try h.send(head, "", &buf);
        try expectEqual(404, r.status);
        try expectEqualStrings("text/plain", r.header("content-type"));
    }
}

test "AC-F1: a malformed or oversized request head gets 400 bad request head and the connection closes" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    var buf: [4096]u8 = undefined;
    // A valid request follows the malformed head on the same connection: it must go
    // unanswered, because the server closes after the 400.
    const malformed = try Response.parse(try raw(
        &h,
        "garbage\r\n\r\nGET /languages HTTP/1.1\r\nhost: test\r\nconnection: close\r\n\r\n",
        0,
        &buf,
    ));
    try expectEqual(400, malformed.status);
    try expectEqualStrings("text/plain", malformed.header("content-type"));
    try expectEqualStrings("bad request head\n", malformed.body);

    const oversized = try Response.parse(try raw(
        &h,
        "GET /languages HTTP/1.1\r\nhost: test\r\nx-pad: " ++ rep('a', 9000) ++ "\r\n\r\n",
        0,
        &buf,
    ));
    try expectEqual(400, oversized.status);
    try expectEqualStrings("text/plain", oversized.header("content-type"));
    try expectEqualStrings("bad request head\n", oversized.body);

    // The server closes after the 400 instead of reading on: the valid request that
    // follows an oversized head goes unanswered.
    const oversized_then_valid = try Response.parse(try raw(
        &h,
        "GET /languages HTTP/1.1\r\nhost: test\r\nx-pad: " ++ rep('a', 9000) ++ "\r\n\r\n" ++
            "GET /languages HTTP/1.1\r\nhost: test\r\nconnection: close\r\n\r\n",
        0,
        &buf,
    ));
    try expectEqual(400, oversized_then_valid.status);
    try expectEqualStrings("bad request head\n", oversized_then_valid.body);

    // A head that never ends: the 400 comes once 8 KiB have arrived, not at the idle timeout.
    const endless = try Response.parse(try raw(&h, "GET /languages HTTP/1.1\r\nx-pad: " ++ rep('a', 9000), 0, &buf));
    try expectEqual(400, endless.status);
    try expectEqualStrings("text/plain", endless.header("content-type"));
    try expectEqualStrings("bad request head\n", endless.body);

    try expectBody(&h, "GET /languages HTTP/1.1", languages);
}

test "AC-F2: a connection that sends nothing for idle_timeout_ms is closed" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();
    // The server reads its config through `&h.config` when it accepts a connection.
    h.config.idle_timeout_ms = 100;

    var buf: [4096]u8 = undefined;
    const late = try raw(&h, "GET /languages HTTP/1.1\r\nhost: test\r\nconnection: close\r\n\r\n", 600, &buf);
    try expectEqualStrings("", late);

    // A kept-alive connection that goes quiet after its first answer is closed too: the
    // request sent after the timeout goes unanswered.
    {
        const address = try Io.net.IpAddress.parse("127.0.0.1", h.port);
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var out_buf: [4096]u8 = undefined;
        var out = stream.writer(io, &out_buf);
        try out.interface.writeAll("GET /languages HTTP/1.1\r\nhost: test\r\n\r\n");
        try out.interface.flush();
        var in = stream.reader(io, &buf);
        while (std.mem.indexOf(u8, in.interface.buffered(), languages) == null) try in.interface.fillMore();
        try io.sleep(.fromMilliseconds(600), .awake);
        out.interface.writeAll("GET /languages HTTP/1.1\r\nhost: test\r\nconnection: close\r\n\r\n") catch {};
        out.interface.flush() catch {};
        while (true) in.interface.fillMore() catch break;
        const first = try Response.parse(in.interface.buffered());
        try expectEqual(200, first.status);
        try expectEqualSlices(u8, languages, first.body);
    }

    // A client that doesn't wait still gets its answer.
    try expectBody(&h, "GET /languages HTTP/1.1", languages);
}

test "AC-F3: a SQLite error answers 500 with no body and the connection keeps serving" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try h.sql("DROP TABLE story;");

    // Two requests on one connection: the feed (keep-alive), then a list.
    var buf: [4096]u8 = undefined;
    const r = try h.send("GET /stories?lang=it HTTP/1.1\r\nhost: test\r\n\r\nGET /languages HTTP/1.1", "", &buf);
    try expectEqual(500, r.status);
    try expectEqualStrings("0", r.header("content-length"));
    const next = try Response.parse(r.body);
    try expectEqual(200, next.status);
    try expectEqualStrings("application/octet-stream", next.header("content-type"));
    try expectEqualSlices(u8, languages, next.body);

    // A list whose table is gone fails the same way, and the connection keeps serving.
    try h.sql("DROP TABLE tag;");
    const list = try h.send("GET /tags HTTP/1.1\r\nhost: test\r\n\r\nGET /genres HTTP/1.1", "", &buf);
    try expectEqual(500, list.status);
    try expectEqualStrings("0", list.header("content-length"));
    const after = try Response.parse(list.body);
    try expectEqual(200, after.status);
    try expectEqualSlices(u8, genres, after.body);
}

test "AC-F4: startup fails on a newer schema or a database path in a missing directory" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try h.sql("PRAGMA user_version = 2;");
    if (server.listen(io, &h.config)) |l| {
        var listener = l;
        listener.deinit(io);
        return error.TestExpectedError;
    } else |_| {}
    // The refused startup left the newer database as it found it.
    try h.sql(
        \\CREATE TEMP TABLE ok (v CHECK (v));
        \\INSERT INTO ok SELECT user_version = 2 FROM pragma_user_version;
    );

    var path_buf: [256]u8 = undefined;
    var config = h.config;
    config.db_path = try std.mem.printSentinel(&path_buf, ".zig-cache/tmp/{s}/missing/postilla.db", .{h.tmp.sub_path}, 0);
    if (server.listen(io, &config)) |l| {
        var listener = l;
        listener.deinit(io);
        return error.TestExpectedError;
    } else |_| {}
}
