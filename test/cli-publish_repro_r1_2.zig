//! A fresh setup has no dict cache directory: `POSTILLA_DICT_DIR` defaults to `./dict`, and
//! git can't track an empty directory, so nothing creates it. docs/specification.md, The
//! CLI, says the CLI "downloads that build into `POSTILLA_DICT_DIR` if it doesn't have it",
//! so the first publish must download the build and succeed, not stop on the missing
//! directory.
//!
//! The story here passes every check against the real server. R2 is a local fake that
//! serves `dict/latest` and the fixture build and keeps what is uploaded; the dict cache
//! directory `<tmp>/dict` does not exist.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli");
const server = @import("server");
const harness = @import("harness");

const io = std.testing.io;
const gpa = std.testing.allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// The Italian as narrated: its sentences joined by one space, its paragraphs by one newline.
const it_text = "Il gatto entra in casa. Apre la porta.\nFuori tira aria di festa.";

const story_template =
    \\{
    \\  "id": "d0159518-99cc-46f0-bef2-b5b6f6f9a76d",
    \\  "level": 2,
    \\  "genre": "classici",
    \\  "tags": ["legno"],
    \\  "work": "Pinocchio",
    \\  "part": 1,
    \\  "author": "collodi",
    \\  "adapted": 1,
    \\  "license": "public-domain",
    \\  "translations": {
    \\    "it": {"title": "Il gatto e la porta", "subtitle": "Una storia di casa", "paragraphs": [["Il gatto entra in casa.", "Apre la porta."], ["Fuori tira aria di festa."]],
    \\           "audio": {"audio_ms": 5000, "text_sha256": "TEXT_SHA256", "times": [[[0, 1500], [1600, 2900]], [[3000, 4800]]]}},
    \\    "pt-BR": {"title": "O gato e a porta", "subtitle": "Uma história de casa", "paragraphs": [["O gato entra em casa.", "Abre a porta."], ["Lá fora há ar de festa."]]}
    \\  }
    \\}
    \\
;

/// CONTRACT.md's `dict.db` schema, as a rollback-journal database like the content build ships.
const dict_sql =
    \\CREATE TABLE meta  (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\CREATE TABLE entry (id INTEGER PRIMARY KEY, word TEXT NOT NULL, word_norm TEXT NOT NULL,
    \\                    pos TEXT NOT NULL, band INTEGER NOT NULL, data TEXT NOT NULL);
    \\CREATE TABLE form  (form TEXT NOT NULL, form_norm TEXT NOT NULL, entry_id INTEGER NOT NULL);
    \\CREATE INDEX form_form ON form(form);
    \\CREATE INDEX form_form_norm ON form(form_norm);
    \\INSERT INTO entry VALUES (1, 'casa', 'casa', 'sostantivo', 1, '{}');
    \\INSERT INTO form VALUES ('casa', 'casa', 1);
    \\PRAGMA journal_mode = DELETE;
;

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn gzip(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var gz: Io.Writer.Allocating = try .initCapacity(a, 64);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var z: std.compress.flate.Compress = try .init(&gz.writer, &window, .gzip, .default);
    try z.writer.writeAll(data);
    try z.finish();
    return gz.written();
}

/// A bare R2: GET serves a stored object (404 when missing), PUT stores one. Targets are
/// `/<bucket>/<key>`.
const FakeR2 = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    endpoint: []const u8,
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    objects: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn start(f: *FakeR2) !void {
        f.* = .{ .listener = undefined, .task = undefined, .endpoint = "", .arena = .init(gpa) };
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

    fn object(f: *FakeR2, target: []const u8, body: []const u8) !void {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        try f.objects.put(a, try a.dupe(u8, target), try a.dupe(u8, body));
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
            const a = f.arena.allocator();
            f.mutex.lockUncancelable(io);
            const target = a.dupe(u8, request.head.target) catch {
                f.mutex.unlock(io);
                return;
            };
            const body = a.alloc(u8, request.head.content_length orelse 0) catch {
                f.mutex.unlock(io);
                return;
            };
            f.mutex.unlock(io);
            if (body.len > 0) {
                const r = request.readerExpectContinue(&.{}) catch return;
                r.readSliceAll(body) catch return;
            }
            var status: std.http.Status = .ok;
            var answer: []const u8 = "";
            switch (request.head.method) {
                .PUT => f.object(target, body) catch return,
                .GET => {
                    f.mutex.lockUncancelable(io);
                    defer f.mutex.unlock(io);
                    if (f.objects.get(target)) |b| answer = b else status = .not_found;
                },
                else => status = .method_not_allowed,
            }
            request.respond(answer, .{ .status = status, .keep_alive = keep_alive }) catch return;
            if (!keep_alive) return;
        }
    }
};

test "AC-9: with no dict cache directory at all, the first publish downloads the dictionary and publishes" {
    var h: harness.Harness = undefined;
    try h.start();
    defer h.stop();
    try h.sql("INSERT INTO tag VALUES ('legno', 'Legno', 'Madeira', 'Wood');");
    var f: FakeR2 = undefined;
    try f.start();
    defer f.stop();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    // The content build's dict.db, as R2 serves it.
    const fixture = try std.fmt.allocPrintSentinel(a, "{s}/fixture.db", .{root}, 0);
    {
        var d = try server.db.open(fixture);
        defer d.close();
        try d.exec(dict_sql);
    }
    const gz = try gzip(a, try tmp.dir.readFileAlloc(io, "fixture.db", a, .limited(1 << 20)));
    const hex = sha256Hex(gz);
    try f.object(try std.fmt.allocPrint(a, "/postilla/dict/{s}.db.gz", .{&hex}), gz);
    try f.object("/postilla/dict/latest", try std.fmt.allocPrint(a, "{s} {d}\n", .{ &hex, gz.len }));

    try tmp.dir.createDirPath(io, "story");
    try tmp.dir.writeFile(io, .{ .sub_path = "story/story.json", .data = try std.mem.replaceOwned(u8, a, story_template, "TEXT_SHA256", &sha256Hex(it_text)) });
    try tmp.dir.writeFile(io, .{ .sub_path = "story/it.opus", .data = "OggS\x00\x02 the narration for the app \xff\x00" });
    try tmp.dir.writeFile(io, .{ .sub_path = "story/it.flac", .data = "fLaC\x00\x00\x00\x22 the narration master \xff\x00" });

    var env: std.process.Environ.Map = .init(a);
    try env.put("POSTILLA_SERVER_URL", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{h.port}));
    try env.put("POSTILLA_AUTHOR_TOKEN", harness.token);
    try env.put("POSTILLA_OPENCODE_KEY", "test-opencode-key");
    try env.put("POSTILLA_SPEECHIFY_KEY", "test-speechify-key");
    try env.put("POSTILLA_R2_ACCOUNT_ID", "test-account");
    try env.put("POSTILLA_R2_ENDPOINT", f.endpoint);
    try env.put("POSTILLA_R2_ACCESS_KEY_ID", "test-key-id");
    try env.put("POSTILLA_R2_SECRET_ACCESS_KEY", "test-secret-access-key");
    try env.put("POSTILLA_R2_BUCKET", "postilla");
    // A fresh setup: the cache directory has never been made.
    try env.put("POSTILLA_DICT_DIR", try std.fmt.allocPrint(a, "{s}/dict", .{root}));

    // Run `postilla publish <folder>`, with what it prints captured.
    const path = try std.fmt.allocPrintSentinel(a, "{s}/story", .{root}, 0);
    const out_file = try tmp.dir.createFile(io, "output.txt", .{ .read = true });
    const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
    _ = std.c.dup2(out_file.handle, 1);
    _ = std.c.dup2(out_file.handle, 2);
    const code = cli.run(io, a, &env, tmp.dir, &.{ "postilla", "publish", path });
    _ = std.c.dup2(saved[0], 1);
    _ = std.c.dup2(saved[1], 2);
    for (saved) |fd| _ = std.c.close(fd);
    out_file.close(io);
    const out = try tmp.dir.readFileAlloc(io, "output.txt", a, .limited(1 << 20));

    try expectEqualStrings("", if (std.mem.find(u8, out, "dict:")) |i| out[i..] else "");
    try expectEqual(0, code);
    // The build was downloaded into the cache, and the story is in the feed.
    try tmp.dir.access(io, try std.fmt.allocPrint(a, "dict/{s}.db", .{&hex}), .{});
    var buf: [4096]u8 = undefined;
    const feed = try h.send("GET /stories?lang=it,pt-BR HTTP/1.1", "", &buf);
    try expectEqual(200, feed.status);
    try expect(feed.body.len > 9);
}
