const std = @import("std");
const Io = std.Io;
const harness = @import("harness");
const Harness = harness.Harness;
const Response = harness.Response;

const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

const auth = "\r\nauthorization: Bearer " ++ harness.token;

/// `n` copies of `ch`.
inline fn rep(comptime ch: u8, comptime n: usize) *const [n]u8 {
    return comptime &@as([n]u8, @splat(ch));
}

/// The written form of a story id whose 16 bytes are all `b`.
inline fn uuid(comptime b: u8) []const u8 {
    return comptime blk: {
        const x = std.fmt.comptimePrint("{x:0>2}", .{b});
        const four = x ++ x;
        break :blk four ++ four ++ "-" ++ four ++ "-" ++ four ++ "-" ++ four ++ "-" ++ four ++ four ++ four;
    };
}

/// One 40-byte STRY translation: `lang` as given, zero-padded to 8, and a sha256 that is
/// `sha` repeated.
inline fn tr(comptime lang: []const u8, comptime sha: u8) *const [40]u8 {
    return comptime blk: {
        var t: [40]u8 = @splat(0);
        @memcpy(t[0..lang.len], lang);
        @memset(t[8..], sha);
        const final = t;
        break :blk &final;
    };
}

/// A STRY body for the story whose id is `id` repeated, with `lang_count` set to the
/// number of translations.
inline fn stry(comptime id: u8, comptime translations: []const *const [40]u8) []const u8 {
    return comptime blk: {
        var out: []const u8 = "STRY\x01" ++ rep(id, 16) ++ [_]u8{translations.len};
        for (translations) |t| out = out ++ t;
        break :blk out;
    };
}

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

/// `x000` … `x999`: language ids a test adds to reach 255 translations.
inline fn extraLang(comptime i: usize) []const u8 {
    return comptime &[_]u8{ 'x', '0' + i / 100, '0' + i / 10 % 10, '0' + i % 10 };
}

const empty_feed = "FEED\x01\x00\x00\x00\x00";

/// Sends `head` with `body` and expects 200 with no body.
fn expectDone(h: *const Harness, head: []const u8, body: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const r = try h.send(head, body, &buf);
    try expectEqual(200, r.status);
    try expectEqualStrings("0", r.header("content-length"));
    try expectEqualStrings("", r.body);
}

fn publish(h: *const Harness, body: []const u8) !void {
    try expectDone(h, "POST /stories HTTP/1.1" ++ auth, body);
}

fn remove(h: *const Harness, comptime id: []const u8) !void {
    try expectDone(h, "DELETE /stories/" ++ id ++ " HTTP/1.1" ++ auth, "");
}

fn expectReason(h: *const Harness, head: []const u8, body: []const u8, status: u16, reason: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const r = try h.send(head, body, &buf);
    try expectEqual(status, r.status);
    try expectEqualStrings("text/plain", r.header("content-type"));
    try expectEqualStrings(reason, r.body);
}

/// The feed body for `query`, after checking it is a 200 binary body.
fn getFeed(h: *const Harness, comptime query: []const u8, buf: []u8) ![]const u8 {
    const r = try h.send("GET /stories?" ++ query ++ " HTTP/1.1", "", buf);
    try expectEqual(200, r.status);
    try expectEqualStrings("application/octet-stream", r.header("content-type"));
    return r.body;
}

fn expectFeed(h: *const Harness, comptime query: []const u8, want: []const u8) !void {
    var buf: [4096]u8 = undefined;
    try expectEqualSlices(u8, want, try getFeed(h, query, &buf));
}

/// The feed for `query` is one of `a` or `b`: two records written in one transaction
/// take consecutive cursors in either order.
fn expectFeedEither(h: *const Harness, comptime query: []const u8, a: []const u8, b: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const got = try getFeed(h, query, &buf);
    if (!std.mem.eql(u8, got, a)) try expectEqualSlices(u8, b, got);
}

/// Opens its own connection, writes `bytes` as is, ends its side of the connection, and
/// returns all that arrives until the server closes. A failure after the server closed
/// counts as the end of the response.
fn raw(h: *const Harness, bytes: []const u8, buf: []u8) ![]const u8 {
    const address = try Io.net.IpAddress.parse("127.0.0.1", h.port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out_buf: [4096]u8 = undefined;
    var out = stream.writer(io, &out_buf);
    out.interface.writeAll(bytes) catch {};
    out.interface.flush() catch {};
    stream.shutdown(io, .send) catch {};
    var in = stream.reader(io, buf);
    while (true) in.interface.fillMore() catch break;
    return in.interface.buffered();
}

const follow = "GET /languages HTTP/1.1\r\nhost: test\r\nconnection: close\r\n\r\n";

test "AC-1, AC-12: a new story's translations get consecutive new cursors and the feed lists them byte for byte" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try publish(&h, stry(0x11, &.{ tr("it", 0xaa), tr("pt-BR", 0xbb) }));

    try expectFeedEither(
        &h,
        "lang=it,pt-BR",
        feed(&.{ record(0x11, "it", 1, 0xaa, 1), record(0x11, "pt-BR", 1, 0xbb, 2) }),
        feed(&.{ record(0x11, "pt-BR", 1, 0xbb, 1), record(0x11, "it", 1, 0xaa, 2) }),
    );
    try expectFeedEither(
        &h,
        "lang=it",
        feed(&.{record(0x11, "it", 1, 0xaa, 1)}),
        feed(&.{record(0x11, "it", 1, 0xaa, 2)}),
    );
    try expectFeed(&h, "lang=en", empty_feed);
}

test "AC-2, AC-3, AC-12: a republish moves only the new or changed translations, and an identical one moves nothing" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try publish(&h, stry(0x11, &.{tr("it", 0xaa)}));
    try expectFeed(&h, "lang=it,pt-BR", feed(&.{record(0x11, "it", 1, 0xaa, 1)}));

    // A new translation is a new row: it takes the next cursor, `it` keeps its own.
    try publish(&h, stry(0x11, &.{ tr("it", 0xaa), tr("pt-BR", 0xbb) }));
    try expectFeed(&h, "lang=it,pt-BR", feed(&.{ record(0x11, "it", 1, 0xaa, 1), record(0x11, "pt-BR", 1, 0xbb, 2) }));

    // `pt-BR` changed, `it` didn't. Body order doesn't matter.
    try publish(&h, stry(0x11, &.{ tr("pt-BR", 0xcc), tr("it", 0xaa) }));
    try expectFeed(&h, "since=2&lang=it,pt-BR", feed(&.{record(0x11, "pt-BR", 1, 0xcc, 3)}));
    const after_change = feed(&.{ record(0x11, "it", 1, 0xaa, 1), record(0x11, "pt-BR", 1, 0xcc, 3) });
    try expectFeed(&h, "lang=it,pt-BR", after_change);

    // Nothing changed: 200 and no cursor moves.
    try publish(&h, stry(0x11, &.{ tr("it", 0xaa), tr("pt-BR", 0xcc) }));
    try expectFeed(&h, "lang=it,pt-BR", after_change);
    try expectFeed(&h, "since=3&lang=it,pt-BR", empty_feed);

    // One cursor sequence for every story.
    try publish(&h, stry(0x22, &.{tr("it", 0xdd)}));
    try publish(&h, stry(0x11, &.{ tr("it", 0xee), tr("pt-BR", 0xcc) }));
    try expectFeed(&h, "lang=it,pt-BR", feed(&.{
        record(0x11, "pt-BR", 1, 0xcc, 3),
        record(0x22, "it", 1, 0xdd, 4),
        record(0x11, "it", 1, 0xee, 5),
    }));
}

test "AC-4, AC-5: a republish missing a published translation, or of a removed story, gets 409 and changes nothing" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try publish(&h, stry(0x11, &.{ tr("it", 0xaa), tr("pt-BR", 0xbb) }));
    try publish(&h, stry(0x22, &.{tr("it", 0xaa)}));
    try remove(&h, uuid(0x22));
    var before_buf: [4096]u8 = undefined;
    const before = try getFeed(&h, "lang=it,pt-BR,en", &before_buf);
    try expectEqual(9 + 61 * 3, before.len);

    const post = "POST /stories HTTP/1.1" ++ auth;
    const missing = "pt-BR: published, missing from body\n";
    try expectReason(&h, post, stry(0x11, &.{tr("it", 0xcc)}), 409, missing);
    try expectReason(&h, post, stry(0x11, &.{ tr("it", 0xcc), tr("en", 0xdd) }), 409, missing);

    try expectReason(&h, post, stry(0x22, &.{tr("it", 0xaa)}), 409, "story removed\n");
    try expectReason(&h, post, stry(0x22, &.{ tr("it", 0xcc), tr("pt-BR", 0xdd) }), 409, "story removed\n");

    try expectFeed(&h, "lang=it,pt-BR,en", before);
}

test "AC-6, AC-7: a STRY that fails the parse or names an unknown language gets 400 with its reason and changes nothing" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try publish(&h, stry(0x11, &.{ tr("it", 0xaa), tr("pt-BR", 0xbb) }));
    var before_buf: [4096]u8 = undefined;
    const before = try getFeed(&h, "lang=it,pt-BR,en", &before_buf);

    // Every body below would be a valid republish of story 0x11 but for one rule.
    const valid = stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xcc) });
    const head = "STRY\x01" ++ rep(0x11, 16);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "STRZ" ++ valid[4..], "body: bad magic\n" },
        .{ "stry" ++ valid[4..], "body: bad magic\n" },
        .{ "STRY\x00" ++ valid[5..], "body: bad version\n" },
        .{ "STRY\x02" ++ valid[5..], "body: bad version\n" },
        .{ head ++ "\x02" ++ tr("it", 0xcc), "body: wrong length\n" },
        .{ head ++ "\x01" ++ tr("it", 0xcc) ++ tr("pt-BR", 0xcc), "body: wrong length\n" },
        .{ valid ++ "\x00", "body: wrong length\n" },
        .{ valid[0 .. valid.len - 1], "body: wrong length\n" },
        .{ "STRY\x01" ++ rep(0x11, 10), "body: wrong length\n" },
        .{ stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xcc), tr("", 0xcc) }), "lang: empty or not ASCII\n" },
        .{ stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xcc), tr("pt\xc3\xa9", 0xcc) }), "lang: empty or not ASCII\n" },
        .{ stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xcc), tr("en\x00x", 0xcc) }), "lang: empty or not ASCII\n" },
        .{ stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xcc), tr("it", 0xdd) }), "lang: repeated id 'it'\n" },
        .{ stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xcc), tr("pt-BR", 0xdd) }), "lang: repeated id 'pt-BR'\n" },
        .{ stry(0x22, &.{ tr("pt-BR", 0xcc), tr("en", 0xcc) }), "lang: no 'it'\n" },
        .{ stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xcc), tr("fr", 0xcc) }), "lang: unknown id 'fr'\n" },
        .{ stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xcc), tr("IT", 0xcc) }), "lang: unknown id 'IT'\n" },
    };
    for (cases) |case| try expectReason(&h, "POST /stories HTTP/1.1" ++ auth, case[0], 400, case[1]);

    // `lang_count` 0 in a 22-byte body breaks rule 2 and, with no translation, rule 4:
    // either reason names a broken rule.
    var buf: [4096]u8 = undefined;
    const r = try h.send("POST /stories HTTP/1.1" ++ auth, head ++ "\x00", &buf);
    try expectEqual(400, r.status);
    try expectEqualStrings("text/plain", r.header("content-type"));
    try expect(std.mem.eql(u8, r.body, "body: wrong length\n") or std.mem.eql(u8, r.body, "lang: no 'it'\n"));

    try expectFeed(&h, "lang=it,pt-BR,en", before);
}

test "AC-8, AC-12: a removal tombstones every translation of the story with new cursors, once" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try publish(&h, stry(0xab, &.{tr("it", 0xaa)}));
    try publish(&h, stry(0xab, &.{ tr("it", 0xaa), tr("pt-BR", 0xbb) }));
    try publish(&h, stry(0xcd, &.{tr("it", 0xcc)}));

    try remove(&h, uuid(0xab));
    const removed_a = feed(&.{
        record(0xcd, "it", 1, 0xcc, 3),
        record(0xab, "it", 2, 0x00, 4),
        record(0xab, "pt-BR", 2, 0x00, 5),
    });
    const removed_b = feed(&.{
        record(0xcd, "it", 1, 0xcc, 3),
        record(0xab, "pt-BR", 2, 0x00, 4),
        record(0xab, "it", 2, 0x00, 5),
    });
    try expectFeedEither(&h, "lang=it,pt-BR", removed_a, removed_b);

    // Already removed: 200, and no cursor moves.
    var before_buf: [4096]u8 = undefined;
    const before = try getFeed(&h, "lang=it,pt-BR", &before_buf);
    try remove(&h, uuid(0xab));
    try expectFeed(&h, "lang=it,pt-BR", before);
    try expectFeed(&h, "since=5&lang=it,pt-BR", empty_feed);

    // The path id may be written in uppercase hex, and a DELETE body is ignored.
    try expectDone(&h, "DELETE /stories/CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD HTTP/1.1" ++ auth, "ignored");
    try expectFeed(&h, "since=5&lang=it,pt-BR", feed(&.{record(0xcd, "it", 2, 0x00, 6)}));
}

test "AC-9: removing an id never published gets 404, and a path id that isn't a UUID gets 400" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try expectReason(&h, "DELETE /stories/" ++ uuid(0x11) ++ " HTTP/1.1" ++ auth, "", 404, "not found\n");

    try publish(&h, stry(0x22, &.{tr("it", 0xaa)}));
    try expectReason(&h, "DELETE /stories/" ++ uuid(0x11) ++ " HTTP/1.1" ++ auth, "", 404, "not found\n");

    for ([_][]const u8{
        "DELETE /stories/nope HTTP/1.1" ++ auth,
        "DELETE /stories/" ++ rep('2', 32) ++ " HTTP/1.1" ++ auth,
        "DELETE /stories/" ++ uuid(0x22)[0..35] ++ " HTTP/1.1" ++ auth,
        "DELETE /stories/" ++ uuid(0x22) ++ "2 HTTP/1.1" ++ auth,
        "DELETE /stories/2222222-22222-2222-2222-222222222222 HTTP/1.1" ++ auth,
        "DELETE /stories/g2222222-2222-2222-2222-222222222222 HTTP/1.1" ++ auth,
    }) |head| try expectReason(&h, head, "", 400, "id: not a UUID\n");

    try expectFeed(&h, "lang=it", feed(&.{record(0x22, "it", 1, 0xaa, 1)}));
}

test "AC-10: a write without the right bearer token gets an empty 401 and its body goes unread; other routes get 404 with no token check" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const body = stry(0x11, &.{tr("it", 0xaa)});
    var buf: [4096]u8 = undefined;
    for ([_][]const u8{
        "",
        "\r\nauthorization: Bearer wrong",
        "\r\nauthorization: Bearer test-toke",
        "\r\nauthorization: Bearer test-token2",
        "\r\nauthorization: Bearer ",
        "\r\nauthorization: Basic test-token",
        "\r\nauthorization: Token test-token",
        "\r\nauthorization: test-token",
    }) |header| {
        for ([_][]const u8{
            "POST /stories HTTP/1.1",
            "DELETE /stories/" ++ uuid(0x11) ++ " HTTP/1.1",
            "DELETE /stories/nope HTTP/1.1",
        }) |line| {
            var head_buf: [256]u8 = undefined;
            const head = try std.fmt.bufPrint(&head_buf, "{s}{s}", .{ line, header });
            const r = try h.send(head, if (line[0] == 'P') body else "", &buf);
            try expectEqual(401, r.status);
            try expectEqualStrings("", r.body);
        }
    }
    try expectFeed(&h, "lang=it", empty_feed);

    // Whatever follows the head of a refused write goes unread: the server closes, so
    // neither the body nor the request after it is answered.
    for ([_][]const u8{
        "POST /stories HTTP/1.1\r\nhost: test\r\ncontent-length: 62\r\n\r\n" ++ body ++ follow,
        "POST /stories HTTP/1.1\r\nhost: test\r\nauthorization: Bearer wrong\r\ncontent-length: 62\r\n\r\n" ++ body ++ follow,
        "DELETE /stories/" ++ uuid(0x11) ++ " HTTP/1.1\r\nhost: test\r\ncontent-length: 4\r\n\r\nxxxx" ++ follow,
    }) |bytes| {
        const r = try Response.parse(try raw(&h, bytes, &buf));
        try expectEqual(401, r.status);
        try expectEqualStrings("", r.body);
    }
    try expectFeed(&h, "lang=it", empty_feed);

    // The scheme is matched case-insensitively.
    try expectDone(&h, "POST /stories HTTP/1.1\r\nauthorization: bearer " ++ harness.token, body);
    try expectDone(&h, "DELETE /stories/" ++ uuid(0x11) ++ " HTTP/1.1\r\nauthorization: BEARER " ++ harness.token, "");
    try expectFeed(&h, "lang=it", feed(&.{record(0x11, "it", 2, 0x00, 2)}));

    // An unknown path or method is 404 whether or not a token comes with it.
    for ([_][]const u8{
        "PUT /stories HTTP/1.1",
        "DELETE /stories HTTP/1.1",
        "PATCH /stories HTTP/1.1",
        "POST /storiesx HTTP/1.1",
        "POST /Stories HTTP/1.1",
        "GET /stories/" ++ uuid(0x11) ++ " HTTP/1.1",
        "POST /stories/" ++ uuid(0x11) ++ " HTTP/1.1",
        "PUT /stories/" ++ uuid(0x11) ++ " HTTP/1.1",
        "DELETE /stories/" ++ uuid(0x11) ++ "/ HTTP/1.1",
        "DELETE /stories/" ++ uuid(0x11) ++ "/x HTTP/1.1",
    }) |line| {
        try expectReason(&h, line, "", 404, "not found\n");
        var head_buf: [256]u8 = undefined;
        try expectReason(&h, try std.fmt.bufPrint(&head_buf, "{s}{s}", .{ line, auth }), "", 404, "not found\n");
    }
}

test "AC-11: a publish without a Content-Length, or with one above 10 222, gets 400 before its body is read" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const body = stry(0x11, &.{tr("it", 0xaa)});
    const post = "POST /stories HTTP/1.1\r\nhost: test\r\nauthorization: Bearer " ++ harness.token ++ "\r\nconnection: close\r\n";
    var buf: [4096]u8 = undefined;
    for ([_]struct { []const u8, []const u8 }{
        .{ post ++ "\r\n" ++ body, "body: length required\n" },
        .{ post ++ "transfer-encoding: chunked\r\n\r\n3e\r\n" ++ body ++ "\r\n0\r\n\r\n", "body: length required\n" },
        // No body follows: the answer comes from the head alone.
        .{ post ++ "content-length: 10223\r\n\r\n", "body: too large\n" },
        .{ post ++ "content-length: 4294967296\r\n\r\n", "body: too large\n" },
    }) |case| {
        const r = try Response.parse(try raw(&h, case[0], &buf));
        try expectEqual(400, r.status);
        try expectEqualStrings("text/plain", r.header("content-type"));
        try expectEqualStrings(case[1], r.body);
    }
    try expectFeed(&h, "lang=it", empty_feed);

    // 10 222 bytes is the largest valid STRY, 255 translations, and is taken.
    const extra = 252;
    try h.sql(comptime blk: {
        @setEvalBranchQuota(100_000);
        var sql: []const u8 = "INSERT INTO language VALUES ('x000', 'x', 0, 0)";
        for (1..extra) |i| sql = sql ++ ", ('" ++ extraLang(i) ++ "', 'x', 0, 0)";
        break :blk sql ++ ";";
    });
    const largest = comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "STRY\x01" ++ rep(0x22, 16) ++ "\xff" ++ tr("it", 0xaa) ++ tr("pt-BR", 0xaa) ++ tr("en", 0xaa);
        for (0..extra) |i| out = out ++ tr(extraLang(i), 0xaa);
        break :blk out;
    };
    try expectEqual(10_222, largest.len);
    try publish(&h, largest);
    var feed_buf: [4096]u8 = undefined;
    const last = try getFeed(&h, "lang=x251", &feed_buf);
    try expectEqualSlices(u8, "FEED\x01\x00\x00\x00\x01", last[0..9]);
    try expectEqual(9 + 61, last.len);
}

test "AC-F1: a SQLite failure inside a publish or a removal answers 500 with no body and changes no row" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    try publish(&h, stry(0x11, &.{ tr("it", 0xaa), tr("pt-BR", 0xbb) }));
    try publish(&h, stry(0x22, &.{tr("it", 0xaa)}));
    var before_buf: [4096]u8 = undefined;
    const before = try getFeed(&h, "lang=it,pt-BR", &before_buf);

    // Every write to a `pt-BR` row fails, so a write that touches `it` too must roll it back.
    try h.sql(
        \\CREATE TRIGGER story_ro_insert BEFORE INSERT ON story WHEN NEW.lang = 'pt-BR'
        \\  BEGIN SELECT RAISE(ABORT, 'read-only'); END;
        \\CREATE TRIGGER story_ro_update BEFORE UPDATE ON story WHEN NEW.lang = 'pt-BR'
        \\  BEGIN SELECT RAISE(ABORT, 'read-only'); END;
        \\CREATE TRIGGER story_ro_delete BEFORE DELETE ON story WHEN OLD.lang = 'pt-BR'
        \\  BEGIN SELECT RAISE(ABORT, 'read-only'); END;
    );

    var buf: [4096]u8 = undefined;
    for ([_]struct { []const u8, []const u8 }{
        .{ "POST /stories HTTP/1.1" ++ auth, stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xdd) }) },
        .{ "POST /stories HTTP/1.1" ++ auth, stry(0x33, &.{ tr("it", 0xcc), tr("pt-BR", 0xdd) }) },
        .{ "DELETE /stories/" ++ uuid(0x11) ++ " HTTP/1.1" ++ auth, "" },
    }) |case| {
        const r = try h.send(case[0], case[1], &buf);
        try expectEqual(500, r.status);
        try expectEqualStrings("0", r.header("content-length"));
        try expectEqualStrings("", r.body);
    }
    try expectFeed(&h, "lang=it,pt-BR", before);

    try h.sql(
        \\DROP TRIGGER story_ro_insert;
        \\DROP TRIGGER story_ro_update;
        \\DROP TRIGGER story_ro_delete;
    );
    try publish(&h, stry(0x11, &.{ tr("it", 0xcc), tr("pt-BR", 0xdd) }));
    try expectFeedEither(
        &h,
        "since=3&lang=it,pt-BR",
        feed(&.{ record(0x11, "it", 1, 0xcc, 4), record(0x11, "pt-BR", 1, 0xdd, 5) }),
        feed(&.{ record(0x11, "pt-BR", 1, 0xdd, 4), record(0x11, "it", 1, 0xcc, 5) }),
    );
}

test "AC-F2: a publish whose client closes before the body is complete changes nothing, and the server keeps serving" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    const body = stry(0x11, &.{tr("it", 0xaa)});
    {
        const address = try Io.net.IpAddress.parse("127.0.0.1", h.port);
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var out_buf: [4096]u8 = undefined;
        var out = stream.writer(io, &out_buf);
        try out.interface.writeAll("POST /stories HTTP/1.1\r\nhost: test" ++ auth ++ "\r\ncontent-length: 62\r\n\r\n" ++ body[0..30]);
        try out.interface.flush();

        // Another connection is served while this body is still incomplete.
        try expectFeed(&h, "lang=it", empty_feed);
    }

    try publish(&h, stry(0x22, &.{tr("it", 0xbb)}));
    try expectFeed(&h, "lang=it", feed(&.{record(0x22, "it", 1, 0xbb, 1)}));
}
