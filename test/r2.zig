//! The R2 client against a fake R2: a plain-HTTP server on a free port that checks every
//! request's SigV4 signature against a fixed secret, keeps the objects it is given, and can
//! be scripted to answer its first requests with an error status, a Retry-After, or
//! nothing at all. Waits and timeouts are shortened through the client's retry schedule.

const std = @import("std");
const Io = std.Io;
const r2 = @import("r2");

const io = std.testing.io;
const gpa = std.testing.allocator;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const bucket = "postilla";
const key_id = "test-key-id";
const secret = "test-secret-access-key";
const story = "stories/d0159518-99cc-46f0-bef2-b5b6f6f9a76d";
const sha = "9f2c1e0d4b7a65839c0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e";

/// One scripted answer: a status, with a Retry-After when `retry_after` isn't empty, or
/// no answer at all when `stall` is set (the connection stays open for 3 s).
const Answer = struct {
    status: std.http.Status = .ok,
    retry_after: []const u8 = "",
    stall: bool = false,
    body: []const u8 = "",
};

/// What the fake saw of one request.
const Seen = struct {
    method: std.http.Method,
    target: []const u8,
    content_type: []const u8 = "",
    cache_control: []const u8 = "",
    content_encoding: []const u8 = "",
    signed: bool = false,
    body: []u8 = "",
    at: Io.Timestamp,
};

const FakeR2 = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    endpoint: []const u8,
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    /// The answers to the first requests, in order; later ones are served from `objects`.
    script: []const Answer,
    objects: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    seen: std.ArrayList(Seen) = .empty,

    /// In place, since the running fake keeps a pointer to `f`.
    fn start(f: *FakeR2, script: []const Answer) !void {
        f.* = .{ .listener = undefined, .task = undefined, .endpoint = "", .arena = .init(gpa), .script = script };
        errdefer f.arena.deinit();
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        f.listener = try address.listen(io, .{ .reuse_address = true });
        errdefer f.listener.deinit(io);
        f.endpoint = try std.fmt.allocPrint(f.arena.allocator(), "http://127.0.0.1:{d}", .{f.listener.socket.address.getPort()});
        f.task = try io.concurrent(serve, .{f});
    }

    fn stop(f: *FakeR2) void {
        f.task.cancel(io) catch {};
        f.listener.deinit(io);
        f.arena.deinit();
    }

    /// A client of this fake with `retry` as its schedule.
    fn client(f: *const FakeR2, retry: @FieldType(r2.Client, "retry")) r2.Client {
        return .{
            .endpoint = f.endpoint,
            .bucket = bucket,
            .access_key_id = key_id,
            .secret_access_key = secret,
            .retry = retry,
        };
    }

    /// Stores `body` under `key`, as if it had been uploaded before.
    fn object(f: *FakeR2, key: []const u8, body: []const u8) !void {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        try f.objects.put(a, try std.fmt.allocPrint(a, "/" ++ bucket ++ "/{s}", .{key}), try a.dupe(u8, body));
    }

    /// The requests seen for `key` so far.
    fn count(f: *FakeR2, key: []const u8) usize {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        var n: usize = 0;
        for (f.seen.items) |s| {
            if (std.mem.startsWith(u8, s.target, "/" ++ bucket ++ "/") and std.mem.eql(u8, s.target[bucket.len + 2 ..], key)) n += 1;
        }
        return n;
    }

    /// Milliseconds between request `i` and the next one.
    fn gapMs(f: *const FakeR2, i: usize) i64 {
        return f.seen.items[i].at.durationTo(f.seen.items[i + 1].at).toMilliseconds();
    }

    fn serve(f: *FakeR2) Io.Cancelable!void {
        var group: Io.Group = .init;
        defer group.cancel(io);
        while (true) {
            const stream = f.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            group.concurrent(io, connection, .{ f, stream }) catch stream.close(io);
        }
    }

    fn connection(f: *FakeR2, stream: Io.net.Stream) Io.Cancelable!void {
        defer stream.close(io);
        var in_buf: [16384]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var in = stream.reader(io, &in_buf);
        var out = stream.writer(io, &out_buf);
        var http: std.http.Server = .init(&in.interface, &out.interface);
        while (true) {
            var request = http.receiveHead() catch return;
            const keep_alive = request.head.keep_alive;
            const answer = f.receive(&request) catch return;
            if (answer.stall) return io.sleep(.fromSeconds(3), .awake);
            const retry_after = [_]std.http.Header{.{ .name = "retry-after", .value = answer.retry_after }};
            request.respond(answer.body, .{
                .status = answer.status,
                .keep_alive = keep_alive,
                .extra_headers = retry_after[0..@intFromBool(answer.retry_after.len > 0)],
            }) catch return;
            if (!keep_alive) return;
        }
    }

    /// Records the request, body included, and picks its answer: the script's while it
    /// lasts, then 403 for a bad signature, else the stored object for a GET (404 when
    /// missing) and storage for a PUT.
    fn receive(f: *FakeR2, request: *std.http.Server.Request) !Answer {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        var s: Seen = .{ .method = request.head.method, .target = try a.dupe(u8, request.head.target), .at = Io.Clock.awake.now(io) };
        var host: []const u8 = "";
        var date: []const u8 = "";
        var hash: []const u8 = "";
        var authorization: []const u8 = "";
        var headers = request.iterateHeaders();
        while (headers.next()) |h| {
            const v = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "host")) host = v;
            if (std.ascii.eqlIgnoreCase(h.name, "x-amz-date")) date = v;
            if (std.ascii.eqlIgnoreCase(h.name, "x-amz-content-sha256")) hash = v;
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) authorization = v;
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) s.content_type = v;
            if (std.ascii.eqlIgnoreCase(h.name, "cache-control")) s.cache_control = v;
            if (std.ascii.eqlIgnoreCase(h.name, "content-encoding")) s.content_encoding = v;
        }
        const len = request.head.content_length orelse 0;
        s.body = try a.alloc(u8, len);
        if (len > 0) try (try request.readerExpectContinue(&.{})).readSliceAll(s.body);
        s.signed = try signedBy(a, s.method, s.target, host, date, hash, authorization, s.body);
        try f.seen.append(a, s);

        if (f.seen.items.len <= f.script.len) return f.script[f.seen.items.len - 1];
        if (!s.signed) return .{ .status = .forbidden };
        switch (s.method) {
            .PUT => {
                try f.objects.put(a, s.target, s.body);
                return .{};
            },
            .GET => return if (f.objects.get(s.target)) |body| .{ .body = body } else .{ .status = .not_found },
            else => return .{ .status = .method_not_allowed },
        }
    }
};

/// Whether `authorization` is the SigV4 signature, with `secret`, of a request whose
/// signed headers are host, x-amz-content-sha256 and x-amz-date, region `auto`, service
/// `s3`, and whose x-amz-content-sha256 is the body's.
fn signedBy(
    a: Allocator,
    method: std.http.Method,
    target: []const u8,
    host: []const u8,
    date: []const u8,
    hash: []const u8,
    authorization: []const u8,
    body: []const u8,
) !bool {
    var digest: [32]u8 = undefined;
    Sha256.hash(body, &digest, .{});
    if (!std.mem.eql(u8, hash, &std.fmt.bytesToHex(digest, .lower)) or date.len != 16) return false;
    const scope = try std.fmt.allocPrint(a, "{s}/auto/s3/aws4_request", .{date[0..8]});
    const canonical = try std.fmt.allocPrint(
        a,
        "{t}\n{s}\n\nhost:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n\nhost;x-amz-content-sha256;x-amz-date\n{s}",
        .{ method, target, host, hash, date, hash },
    );
    Sha256.hash(canonical, &digest, .{});
    const to_sign = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ date, scope, &std.fmt.bytesToHex(digest, .lower) });
    var k_date: [32]u8 = undefined;
    var k_region: [32]u8 = undefined;
    var k_service: [32]u8 = undefined;
    var k_signing: [32]u8 = undefined;
    var signature: [32]u8 = undefined;
    HmacSha256.create(&k_date, date[0..8], "AWS4" ++ secret);
    HmacSha256.create(&k_region, "auto", &k_date);
    HmacSha256.create(&k_service, "s3", &k_region);
    HmacSha256.create(&k_signing, "aws4_request", &k_service);
    HmacSha256.create(&signature, to_sign, &k_signing);
    const expected = try std.fmt.allocPrint(
        a,
        "AWS4-HMAC-SHA256 Credential=" ++ key_id ++ "/{s}, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={s}",
        .{ scope, &std.fmt.bytesToHex(signature, .lower) },
    );
    // AWS accepts the comma-separated parts with or without a space after each comma.
    const given = try std.mem.replaceOwned(u8, a, authorization, ", ", ",");
    return std.mem.eql(u8, given, try std.mem.replaceOwned(u8, a, expected, ", ", ","));
}

/// `data` gzipped.
fn gzip(a: Allocator, data: []const u8) ![]u8 {
    var gz: std.Io.Writer.Allocating = try .initCapacity(a, 64);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var z: std.compress.flate.Compress = try .init(&gz.writer, &window, .gzip, .default);
    try z.writer.writeAll(data);
    try z.finish();
    return gz.written();
}

/// The lowercase hex sha256 of `data`.
fn sha256(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Puts `db` gzipped into the fake as `dict/<sha256>.db.gz` and points `dict/latest` at
/// it. Returns the sha256.
fn publishDict(f: *FakeR2, a: Allocator, db: []const u8) ![64]u8 {
    const gz = try gzip(a, db);
    const hex = sha256(gz);
    try f.object(try std.fmt.allocPrint(a, "dict/{s}.db.gz", .{hex}), gz);
    try f.object("dict/latest", try std.fmt.allocPrint(a, "{s} {d}\n", .{ hex, gz.len }));
    return hex;
}

/// The names in `tmp`'s `dict` directory, sorted and joined by spaces.
fn listing(a: Allocator, tmp: std.testing.TmpDir) ![]const u8 {
    var dir = try tmp.dir.openDir(io, "dict", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| try names.append(a, try a.dupe(u8, entry.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return std.mem.join(a, " ", names.items);
}

/// A `dict` directory inside `tmp`, as a path from the working directory.
fn dictDir(a: Allocator, tmp: std.testing.TmpDir) ![]const u8 {
    try tmp.dir.createDirPath(io, "dict");
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/dict", .{tmp.sub_path});
}

const db_v1 = "SQLite format 3\x00" ++ "the first dictionary build, with its entries and forms";
const db_v2 = "SQLite format 3\x00" ++ "the second dictionary build, with more entries and forms";

test "AC-1, AC-2: an upload is one signed PUT to /<bucket>/<key> with the exact body, the type by extension, the immutable Cache-Control and no Content-Encoding" {
    var f: FakeR2 = undefined;
    try f.start(&.{});
    defer f.stop();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = f.client(.{});

    const tilla_gz = try gzip(a, "TILL\x01\x00 a .tilla file, gzipped \xff\x00\x01");
    const cases = [_]struct { key: []const u8, body: []const u8, content_type: []const u8 }{
        .{ .key = story ++ "/it/" ++ sha ++ ".tilla.gz", .body = tilla_gz, .content_type = "application/gzip" },
        .{ .key = story ++ "/it/" ++ sha ++ ".opus", .body = "OggS\x00\x02 opus pages \xff", .content_type = "audio/ogg" },
        .{ .key = story ++ "/it/" ++ sha ++ ".flac", .body = "fLaC\x00\x00\x00\x22 flac frames \xff", .content_type = "audio/flac" },
    };
    for (cases, 0..) |case, i| {
        const res = try c.put(io, a, case.key, case.body);
        try expectEqual(.ok, res.status);
        try expectEqual(i + 1, f.seen.items.len);
        const s = f.seen.items[i];
        try expectEqual(.PUT, s.method);
        try expectEqualStrings(try std.fmt.allocPrint(a, "/" ++ bucket ++ "/{s}", .{case.key}), s.target);
        try expectEqualStrings(case.body, s.body);
        try expectEqualStrings(case.content_type, s.content_type);
        try expectEqualStrings("public, max-age=31536000, immutable", s.cache_control);
        try expectEqualStrings("", s.content_encoding);
        try expect(s.signed);
    }
}

test "AC-3: a download is a signed GET that brings the object's body back byte for byte" {
    var f: FakeR2 = undefined;
    try f.start(&.{});
    defer f.stop();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try gzip(a, "every byte of this object, \x00\xff\x7f, comes back");
    try f.object(story ++ "/it/" ++ sha ++ ".tilla.gz", body);

    const res = try f.client(.{}).get(io, a, story ++ "/it/" ++ sha ++ ".tilla.gz");
    try expectEqual(.ok, res.status);
    try expectEqualStrings(body, res.body);
    try expectEqual(1, f.seen.items.len);
    try expectEqual(.GET, f.seen.items[0].method);
    try expectEqualStrings("/" ++ bucket ++ "/" ++ story ++ "/it/" ++ sha ++ ".tilla.gz", f.seen.items[0].target);
    try expect(f.seen.items[0].signed);
}

test "AC-4: two 500s then a 200 succeed on the third try, after the first and the second scheduled waits" {
    var f: FakeR2 = undefined;
    try f.start(&.{ .{ .status = .internal_server_error }, .{ .status = .internal_server_error } });
    defer f.stop();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try f.object("dict/latest", sha ++ " 1234\n");

    const res = try f.client(.{ .waits_ms = .{ 100, 400, 60_000 } }).get(io, a, "dict/latest");
    try expectEqual(.ok, res.status);
    try expectEqualStrings(sha ++ " 1234\n", res.body);
    try expectEqual(3, f.seen.items.len);
    for (f.seen.items) |s| try expect(s.signed);
    try expect(f.gapMs(0) >= 100 and f.gapMs(0) < 400);
    try expect(f.gapMs(1) >= 400 and f.gapMs(1) < 1400);
}

test "AC-5: a Retry-After on a 429 or a 503 replaces the scheduled wait, capped at the longest wait allowed" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var f: FakeR2 = undefined;
        try f.start(&.{.{ .status = .too_many_requests, .retry_after = "1" }});
        defer f.stop();
        try f.object("dict/latest", sha ++ " 1234\n");
        const res = try f.client(.{ .waits_ms = .{ 50, 50, 50 } }).get(io, a, "dict/latest");
        try expectEqual(.ok, res.status);
        try expectEqual(2, f.seen.items.len);
        try expect(f.gapMs(0) >= 1000 and f.gapMs(0) < 1900);
    }
    {
        var f: FakeR2 = undefined;
        try f.start(&.{.{ .status = .service_unavailable, .retry_after = "3600" }});
        defer f.stop();
        try f.object("dict/latest", sha ++ " 1234\n");
        const res = try f.client(.{ .waits_ms = .{ 50, 50, 50 }, .max_wait_ms = 300 }).get(io, a, "dict/latest");
        try expectEqual(.ok, res.status);
        try expectEqual(2, f.seen.items.len);
        try expect(f.gapMs(0) >= 300 and f.gapMs(0) < 1500);
    }
}

test "AC-6: a 403, a 400 or a 404 fails after one try with that status" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var f: FakeR2 = undefined;
        try f.start(&.{.{ .status = .forbidden }});
        defer f.stop();
        const res = try f.client(.{ .waits_ms = .{ 50, 50, 50 } }).put(io, a, story ++ "/it/" ++ sha ++ ".opus", "OggS");
        try expectEqual(.forbidden, res.status);
        try expectEqual(1, f.seen.items.len);
    }
    {
        var f: FakeR2 = undefined;
        try f.start(&.{.{ .status = .bad_request }});
        defer f.stop();
        try f.object("dict/latest", sha ++ " 1234\n");
        const res = try f.client(.{ .waits_ms = .{ 50, 50, 50 } }).get(io, a, "dict/latest");
        try expectEqual(.bad_request, res.status);
        try expectEqual(1, f.seen.items.len);
    }
    {
        var f: FakeR2 = undefined;
        try f.start(&.{});
        defer f.stop();
        const res = try f.client(.{ .waits_ms = .{ 50, 50, 50 } }).get(io, a, "dict/" ++ sha ++ ".db.gz");
        try expectEqual(.not_found, res.status);
        try expectEqual(1, f.seen.items.len);
    }
}

test "AC-7: four failing tries end the call with the last status, and no fifth try is made" {
    var f: FakeR2 = undefined;
    try f.start(&.{
        .{ .status = .internal_server_error },
        .{ .status = .bad_gateway },
        .{ .status = .internal_server_error },
        .{ .status = .service_unavailable },
    });
    defer f.stop();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const key = story ++ "/it/" ++ sha ++ ".flac";

    const res = try f.client(.{ .waits_ms = .{ 20, 20, 20 } }).put(io, a, key, "fLaC");
    try expectEqual(.service_unavailable, res.status);
    try expectEqual(4, f.seen.items.len);
    try expectEqual(4, f.count(key));
}

test "AC-F1: a connection that answers nothing fails the try after the idle timeout, and the retry succeeds" {
    var f: FakeR2 = undefined;
    try f.start(&.{.{ .stall = true }});
    defer f.stop();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try f.object("dict/latest", sha ++ " 1234\n");

    const started = Io.Clock.awake.now(io);
    const res = try f.client(.{ .waits_ms = .{ 10, 10, 10 }, .idle_timeout_ms = 200 }).get(io, a, "dict/latest");
    const took = started.untilNow(io, .awake).toMilliseconds();
    try expectEqual(.ok, res.status);
    try expectEqualStrings(sha ++ " 1234\n", res.body);
    try expectEqual(2, f.seen.items.len);
    try expect(f.gapMs(0) >= 200);
    try expect(took < 2000);
}

test "AC-F2: an endpoint where nothing listens fails every try to connect, and the call fails after 4 tries" {
    // A port that was free a moment ago, now with nothing listening on it.
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    listener.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c: r2.Client = .{
        .endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port}),
        .bucket = bucket,
        .access_key_id = key_id,
        .secret_access_key = secret,
        .retry = .{ .waits_ms = .{ 100, 100, 100 } },
    };

    const started = Io.Clock.awake.now(io);
    if (c.get(io, a, "dict/latest")) |_| return error.TestExpectedError else |_| {}
    const took = started.untilNow(io, .awake).toMilliseconds();
    try expect(took >= 300 and took < 3000);
}

test "AC-8: an empty dict dir gets the build dict/latest names, checked and gunzipped into <sha>.db, and a second call downloads nothing" {
    var f: FakeR2 = undefined;
    try f.start(&.{});
    defer f.stop();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try dictDir(a, tmp);
    const hex = try publishDict(&f, a, db_v1);
    const gz_key = try std.fmt.allocPrint(a, "dict/{s}.db.gz", .{hex});
    const c = f.client(.{ .waits_ms = .{ 10, 10, 10 } });

    const path = try c.dict(io, a, dir);
    try expectEqualStrings(try std.fmt.allocPrint(a, "{s}/{s}.db", .{ dir, hex }), path);
    try expectEqualStrings(db_v1, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)));
    try expectEqualStrings(try std.fmt.allocPrint(a, "{s}.db", .{hex}), try listing(a, tmp));
    try expectEqual(1, f.count(gz_key));
    for (f.seen.items) |s| try expect(s.signed);

    try expectEqualStrings(path, try c.dict(io, a, dir));
    try expectEqual(1, f.count(gz_key));
    try expectEqualStrings(db_v1, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)));
    try expectEqualStrings(try std.fmt.allocPrint(a, "{s}.db", .{hex}), try listing(a, tmp));
}

test "AC-9: a new dict/latest replaces the cached build, and the older .db is deleted while other files stay" {
    var f: FakeR2 = undefined;
    try f.start(&.{});
    defer f.stop();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try dictDir(a, tmp);
    const c = f.client(.{ .waits_ms = .{ 10, 10, 10 } });

    const old = try publishDict(&f, a, db_v1);
    _ = try c.dict(io, a, dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "dict/notes.txt", .data = "not a build" });
    const new = try publishDict(&f, a, db_v2);
    try expect(!std.mem.eql(u8, &old, &new));

    const path = try c.dict(io, a, dir);
    try expectEqualStrings(try std.fmt.allocPrint(a, "{s}/{s}.db", .{ dir, new }), path);
    try expectEqualStrings(db_v2, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)));
    try expectEqualStrings(try std.fmt.allocPrint(a, "{s}.db notes.txt", .{new}), try listing(a, tmp));
}

test "AC-F3: a .db.gz whose size or sha256 doesn't match dict/latest fails every try and writes no .db" {
    var f: FakeR2 = undefined;
    try f.start(&.{});
    defer f.stop();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try dictDir(a, tmp);
    const c = f.client(.{ .waits_ms = .{ 10, 10, 10 } });

    // The size dict/latest gives is one byte more than the .gz's.
    const gz = try gzip(a, db_v1);
    const hex = sha256(gz);
    const gz_key = try std.fmt.allocPrint(a, "dict/{s}.db.gz", .{hex});
    try f.object(gz_key, gz);
    try f.object("dict/latest", try std.fmt.allocPrint(a, "{s} {d}\n", .{ hex, gz.len + 1 }));
    if (c.dict(io, a, dir)) |_| return error.TestExpectedError else |_| {}
    try expectEqual(4, f.count(gz_key));
    try expectEqualStrings("", try listing(a, tmp));

    // The size matches, but the bytes under that sha256 are another build's.
    const other = try gzip(a, db_v2);
    try f.object(gz_key, other);
    try f.object("dict/latest", try std.fmt.allocPrint(a, "{s} {d}\n", .{ hex, other.len }));
    if (c.dict(io, a, dir)) |_| return error.TestExpectedError else |_| {}
    try expectEqual(8, f.count(gz_key));
    try expectEqualStrings("", try listing(a, tmp));
}

test "AC-F3: a dict/latest line that doesn't parse fails r2.dict at once, with nothing else downloaded" {
    var f: FakeR2 = undefined;
    try f.start(&.{});
    defer f.stop();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try dictDir(a, tmp);
    const c = f.client(.{ .waits_ms = .{ 10, 10, 10 } });
    const gz = try gzip(a, db_v1);
    const hex = sha256(gz);
    try f.object(try std.fmt.allocPrint(a, "dict/{s}.db.gz", .{hex}), gz);

    const lines = [_][]const u8{
        try std.fmt.allocPrint(a, "{s} {d}\n", .{ try std.ascii.allocUpperString(a, &hex), gz.len }),
        try std.fmt.allocPrint(a, "{s} {d}\n", .{ hex[1..], gz.len }),
        try std.fmt.allocPrint(a, "{s} ten\n", .{hex}),
        try std.fmt.allocPrint(a, "{s}\n", .{hex}),
    };
    for (lines, 1..) |line, n| {
        try f.object("dict/latest", line);
        if (c.dict(io, a, dir)) |_| return error.TestExpectedError else |_| {}
        try expectEqual(n, f.seen.items.len);
        try expectEqual(n, f.count("dict/latest"));
        try expectEqualStrings("", try listing(a, tmp));
    }
}

test "AC-F4: a dict dir that can't be written fails r2.dict with the filesystem error and leaves no temp file, nor does a build that breaks halfway through being written" {
    var f: FakeR2 = undefined;
    try f.start(&.{});
    defer f.stop();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try dictDir(a, tmp);
    const hex = try publishDict(&f, a, db_v1);
    const c = f.client(.{ .waits_ms = .{ 10, 10, 10 } });

    {
        var d = try tmp.dir.openDir(io, "dict", .{ .iterate = true });
        defer d.close(io);
        try d.setPermissions(io, .fromMode(0o555));
        defer d.setPermissions(io, .fromMode(0o755)) catch {};
        try expectError(error.AccessDenied, c.dict(io, a, dir));
    }
    try expectEqualStrings("", try listing(a, tmp));

    // Writable again, the same build lands and nothing from the failed call is left.
    const path = try c.dict(io, a, dir);
    try expectEqualStrings(db_v1, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)));
    try expectEqualStrings(try std.fmt.allocPrint(a, "{s}.db", .{hex}), try listing(a, tmp));

    // A new build whose size and sha256 match dict/latest but whose gzip trailer is cut
    // off: the content is written out before the gunzip fails. No temp file and no new
    // .db are left, and the current build is kept since nothing was switched to.
    const whole = try gzip(a, db_v2);
    const cut = whole[0 .. whole.len - 8];
    const cut_hex = sha256(cut);
    try f.object(try std.fmt.allocPrint(a, "dict/{s}.db.gz", .{cut_hex}), cut);
    try f.object("dict/latest", try std.fmt.allocPrint(a, "{s} {d}\n", .{ cut_hex, cut.len }));
    if (c.dict(io, a, dir)) |_| return error.TestExpectedError else |_| {}
    try expectEqualStrings(try std.fmt.allocPrint(a, "{s}.db", .{hex}), try listing(a, tmp));
    try expectEqualStrings(db_v1, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)));
}
