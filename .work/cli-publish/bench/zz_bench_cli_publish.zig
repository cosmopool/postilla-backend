//! `postilla publish <folder>` end to end (docs/specification.md, The CLI): `cli.run` runs
//! in-process with a temp directory as its current directory, against the real server
//! (harness) and a fake R2 on free ports. `args` are the process's arguments, program name
//! first. What the command prints, on stdout or stderr, is read back by pointing both at a
//! file while it runs.
//!
//! The fake R2 checks every request's SigV4 signature against a fixed secret, keeps the
//! objects it is given, and serves `dict/latest` and the fixture `dict.db` build. It can fail
//! the requests for one key (the first gets no answer at all, the later ones a 503 with
//! `Retry-After: 0`, so the retries take seconds, not minutes), or cut the first upload of
//! a key mid-body.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("cli");
const r2 = @import("r2");
const server = @import("server");
const tilla = @import("tilla");
const harness = @import("harness");
const Harness = harness.Harness;

const io = std.testing.io;
const gpa = std.testing.allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

const bucket = "postilla";
const key_id = "test-key-id";
const secret = "test-secret-access-key";
const story_id = "d0159518-99cc-46f0-bef2-b5b6f6f9a76d";
/// Where the story's objects land in the fake: `/<bucket>/stories/<id>/`.
const prefix = "/" ++ bucket ++ "/stories/" ++ story_id ++ "/";

const opus = "OggS\x00\x02 the narration for the app \xff\x00";
const flac = "fLaC\x00\x00\x00\x22 the narration master \xff\x00";

/// The Italian as narrated: its sentences joined by one space, its paragraphs by one newline.
const it_text = "Il gatto entra in casa. Apre la porta.\nFuori tira aria di festa.";
const it_paragraphs: []const []const []const u8 = &.{
    &.{ "Il gatto entra in casa.", "Apre la porta." },
    &.{"Fuori tira aria di festa."},
};
const pt_paragraphs: []const []const []const u8 = &.{
    &.{ "O gato entra em casa.", "Abre a porta." },
    &.{"Lá fora há ar de festa."},
};

/// `translations.it.audio`; `TEXT_SHA256` becomes the sha256 of `it_text`.
const audio_member =
    \\"audio": {"audio_ms": 5000, "text_sha256": "TEXT_SHA256", "times": [[[0, 1500], [1600, 2900]], [[3000, 4800]]]}
;
const pt_member =
    \\"pt-BR": {"title": "O gato e a porta", "subtitle": "Uma história de casa", "paragraphs": [["O gato entra em casa.", "Abre a porta."], ["Lá fora há ar de festa."]]}
;
/// `pt_member` as a language the server doesn't list.
const scn_member =
    \\"scn": {"title": "O gato e a porta", "subtitle": "Uma história de casa", "paragraphs": [["O gato entra em casa.", "Abre a porta."], ["Lá fora há ar de festa."]]}
;
/// A story that passes every check: narrated in Italian, translated into pt-BR.
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
    \\  "moderation": {"none": 0.98, "homophobic": 0.0, "racist": 0.01, "sexist": 0.0, "religious": 0.0, "other_hate": 0.01, "forced": false},
    \\  "translations": {
    \\    "it": {"title": "Il gatto e la porta", "subtitle": "Una storia di casa", "paragraphs": [["Il gatto entra in casa.", "Apre la porta."], ["Fuori tira aria di festa."]],
++ " " ++ audio_member ++ "},\n    " ++ pt_member ++ "\n  }\n}\n";

/// `story_template` with each edit's first string, which must occur exactly once, replaced
/// by its second, then `TEXT_SHA256` by the sha256 of `it_text`.
fn story(a: Allocator, edits: []const [2][]const u8) ![]const u8 {
    var json: []const u8 = story_template;
    for (edits) |e| {
        try expectEqual(1, std.mem.count(u8, json, e[0]));
        json = try std.mem.replaceOwned(u8, a, json, e[0], e[1]);
    }
    return std.mem.replaceOwned(u8, a, json, "TEXT_SHA256", &sha256Hex(it_text));
}

/// What `tilla.build` must have been given for `lang`'s translation of `story_template`.
fn expected(lang: []const u8) !tilla.Input {
    const italian = std.mem.eql(u8, lang, "it");
    var in: tilla.Input = .{
        .id = try .parse(story_id),
        .lang = try .fromText(lang),
        .original = try .fromText("it"),
        .title = if (italian) "Il gatto e la porta" else "O gato e a porta",
        .subtitle = if (italian) "Una storia di casa" else "Uma história de casa",
        .level = 2,
        .genre = "classici",
        .tags = &.{"legno"},
        .work = "Pinocchio",
        .part = 1,
        .author = "collodi",
        .adapted = true,
        .license = "public-domain",
        .paragraphs = if (italian) it_paragraphs else pt_paragraphs,
    };
    if (italian) {
        var opus_sha: [32]u8 = undefined;
        Sha256.hash(opus, &opus_sha, .{});
        in.narration = .{
            .audio_ms = 5000,
            .opus_sha256 = opus_sha,
            .opus_size = opus.len,
            .times = &.{ .{ .start_ms = 0, .end_ms = 1500 }, .{ .start_ms = 1600, .end_ms = 2900 }, .{ .start_ms = 3000, .end_ms = 4800 } },
        };
    }
    return in;
}

/// CONTRACT.md's `dict.db` schema, as a rollback-journal database like the content build
/// ships. In `it_text`, *casa* and *porta* (via *portare* 1, *porgere* 2) are band 1,
/// *gatto* band 2, *aria* band 3, and the other 9 words have no lemma: band_words 9 2 1 1.
const dict_sql =
    \\CREATE TABLE meta  (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\CREATE TABLE entry (id INTEGER PRIMARY KEY, word TEXT NOT NULL, word_norm TEXT NOT NULL,
    \\                    pos TEXT NOT NULL, band INTEGER NOT NULL, data TEXT NOT NULL);
    \\CREATE TABLE form  (form TEXT NOT NULL, form_norm TEXT NOT NULL, entry_id INTEGER NOT NULL);
    \\CREATE INDEX form_form ON form(form);
    \\CREATE INDEX form_form_norm ON form(form_norm);
    \\INSERT INTO entry VALUES
    \\  (1, 'portare', 'portare', 'verbo', 1, '{}'),
    \\  (2, 'porgere', 'porgere', 'verbo', 2, '{}'),
    \\  (3, 'casa', 'casa', 'sostantivo', 1, '{}'),
    \\  (4, 'gatto', 'gatto', 'sostantivo', 2, '{}'),
    \\  (5, 'aria', 'aria', 'sostantivo', 3, '{}');
    \\INSERT INTO form VALUES
    \\  ('porta', 'porta', 1), ('porta', 'porta', 2), ('casa', 'casa', 3), ('gatto', 'gatto', 4), ('aria', 'aria', 5);
    \\PRAGMA journal_mode = DELETE;
;

/// What a run of the command gave: its exit code and everything it printed.
const Run = struct { code: u8, out: []const u8 };

/// The world a publish runs in: the real server (with the tag `legno` added), a fake R2
/// holding the fixture `dict.db` build, and a temp directory that is the command's current
/// directory, with the story folder at `story/` and an empty dict cache at `dict/`.
const World = struct {
    h: Harness,
    f: FakeR2,
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    /// The temp directory's absolute path.
    root: [:0]const u8,
    /// Every variable the CLI's configuration lists, pointing at the server, the fake and
    /// `<root>/dict`.
    env: std.process.Environ.Map,
    /// The fixture `dict.db` as R2 serves it (gunzipped), a copy of it for the tests' own
    /// builds, and the sha256 `dict/latest` names.
    dict: []const u8,
    dict_path: [:0]const u8,
    dict_hex: [64]u8,

    /// In place, since the running server and fake keep pointers into `w`.
    fn start(w: *World, options: FakeR2.Options) !void {
        try w.h.start();
        errdefer w.h.stop();
        try w.f.start(options);
        errdefer w.f.stop();
        w.tmp = std.testing.tmpDir(.{});
        errdefer w.tmp.cleanup();
        w.arena = .init(gpa);
        errdefer w.arena.deinit();
        const a = w.arena.allocator();
        w.root = try w.tmp.dir.realPathFileAlloc(io, ".", a);
        try w.h.sql("INSERT INTO tag VALUES ('legno', 'Legno', 'Madeira', 'Wood');");

        w.dict_path = try std.fmt.allocPrintSentinel(a, "{s}/fixture.db", .{w.root}, 0);
        {
            var d = try server.db.open(w.dict_path);
            defer d.close();
            try d.exec(dict_sql);
        }
        w.dict = try w.tmp.dir.readFileAlloc(io, "fixture.db", a, .limited(1 << 20));
        const gz = try gzip(a, w.dict);
        w.dict_hex = sha256Hex(gz);
        try w.f.object(try std.fmt.allocPrint(a, "dict/{s}.db.gz", .{&w.dict_hex}), gz);
        try w.f.object("dict/latest", try std.fmt.allocPrint(a, "{s} {d}\n", .{ &w.dict_hex, gz.len }));

        w.env = .init(a);
        try w.env.put("POSTILLA_SERVER_URL", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{w.h.port}));
        try w.env.put("POSTILLA_AUTHOR_TOKEN", harness.token);
        try w.env.put("POSTILLA_OPENCODE_KEY", "test-opencode-key");
        try w.env.put("POSTILLA_SPEECHIFY_KEY", "test-speechify-key");
        try w.env.put("POSTILLA_R2_ACCOUNT_ID", "test-account");
        try w.env.put("POSTILLA_R2_ENDPOINT", w.f.endpoint);
        try w.env.put("POSTILLA_R2_ACCESS_KEY_ID", key_id);
        try w.env.put("POSTILLA_R2_SECRET_ACCESS_KEY", secret);
        try w.env.put("POSTILLA_R2_BUCKET", bucket);
        try w.env.put("POSTILLA_DICT_DIR", try std.fmt.allocPrint(a, "{s}/dict", .{w.root}));
    }

    fn stop(w: *World) void {
        w.arena.deinit();
        w.tmp.cleanup();
        w.f.stop();
        w.h.stop();
    }

    /// Writes the story folder, `story.json` as `json` plus `it.opus` and `it.flac`, and
    /// returns its absolute path.
    fn folder(w: *World, json: []const u8) ![:0]const u8 {
        try w.tmp.dir.createDirPath(io, "story");
        try w.tmp.dir.writeFile(io, .{ .sub_path = "story/story.json", .data = json });
        try w.tmp.dir.writeFile(io, .{ .sub_path = "story/it.opus", .data = opus });
        try w.tmp.dir.writeFile(io, .{ .sub_path = "story/it.flac", .data = flac });
        return std.fmt.allocPrintSentinel(w.arena.allocator(), "{s}/story", .{w.root}, 0);
    }

    /// Runs `postilla publish <path>` with `w.env`, stdout and stderr captured.
    fn publish(w: *World, path: [:0]const u8) !Run {
        const a = w.arena.allocator();
        const file = try w.tmp.dir.createFile(io, "output.txt", .{ .read = true });
        defer file.close(io);
        const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
        _ = std.c.dup2(file.handle, 1);
        _ = std.c.dup2(file.handle, 2);
        const code: u8 = cli.run(io, a, &w.env, w.tmp.dir, &.{ "postilla", "publish", path });
        _ = std.c.dup2(saved[0], 1);
        _ = std.c.dup2(saved[1], 2);
        for (saved) |fd| _ = std.c.close(fd);
        return .{ .code = code, .out = try w.tmp.dir.readFileAlloc(io, "output.txt", a, .limited(1 << 20)) };
    }

    /// The feed body for `it,pt-BR` from `since` 0, after checking it is a 200.
    fn feed(w: *World) ![]const u8 {
        var buf: [4096]u8 = undefined;
        const r = try w.h.send("GET /stories?lang=it,pt-BR HTTP/1.1", "", &buf);
        try expectEqual(200, r.status);
        return w.arena.allocator().dupe(u8, r.body);
    }

    /// Nothing was uploaded and nothing was published.
    fn expectNothing(w: *World) !void {
        try expectEqual(0, w.f.requests(.PUT, "/"));
        try expectEqualSlices(u8, "FEED\x01\x00\x00\x00\x00", try w.feed());
    }

    /// The names in the dict cache, sorted and joined by spaces.
    fn cache(w: *World) ![]const u8 {
        const a = w.arena.allocator();
        var dir = try w.tmp.dir.openDir(io, "dict", .{ .iterate = true });
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
};

/// Fails unless `out` mentions `word`, in any case.
fn expectSays(out: []const u8, word: []const u8) !void {
    if (std.ascii.findIgnoreCase(out, word) == null) {
        std.debug.print("expected the output to mention '{s}', got:\n{s}\n", .{ word, out });
        return error.TestExpectedSays;
    }
}

/// Fails unless `out` has `n` as a number of its own, not part of a longer one.
fn expectNumber(out: []const u8, n: u32) !void {
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const start = i;
        while (i < out.len and std.ascii.isDigit(out[i])) i += 1;
        if (i > start and (std.fmt.parseInt(u32, out[start..i], 10) catch null) == n) return;
    }
    std.debug.print("expected the output to name {d}, got:\n{s}\n", .{ n, out });
    return error.TestExpectedNumber;
}

/// `n` times the two-byte letter `à`.
fn letters(a: Allocator, n: usize) ![]u8 {
    const out = try a.alloc(u8, 2 * n);
    for (0..n) |i| @memcpy(out[2 * i ..][0..2], "\u{e0}");
    return out;
}

/// The lowercase hex sha256 of `data`.
fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
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

/// The `.gz` decompressed.
fn gunzip(a: Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    var out: std.Io.Writer.Allocating = .init(a);
    _ = try d.reader.streamRemaining(&out.writer);
    return out.written();
}

/// A `.tilla`'s `band_words`, which follow `words` after the header's fields (tilla.md).
fn bandWords(file: []const u8) ![4]u16 {
    var r: server.wire.Reader = .{ .buf = file };
    _ = try r.bytes(6 + 16 + 8 + 8); // magic and version, id, lang, original
    _ = try r.str(); // title
    _ = try r.str(); // subtitle
    _ = try r.int(u8); // level
    _ = try r.str(); // genre
    for (0..try r.int(u16)) |_| _ = try r.str(); // tags
    _ = try r.str(); // work
    _ = try r.int(u16); // part
    _ = try r.str(); // author
    _ = try r.int(u8); // adapted
    _ = try r.str(); // license
    _ = try r.int(u16); // words
    var bands: [4]u16 = undefined;
    for (&bands) |*b| b.* = try r.int(u16);
    return bands;
}

/// What the fake saw of one request it read whole.
const Seen = struct {
    method: std.http.Method,
    target: []const u8,
    signed: bool,
};

const FakeR2 = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    endpoint: []const u8,
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    options: Options,
    failed: usize = 0,
    cuts: usize = 0,
    objects: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    seen: std.ArrayList(Seen) = .empty,

    const Options = struct {
        /// Requests whose target contains this fail: the first gets no answer, the later
        /// ones a 503 with `Retry-After: 0`. Empty fails nothing.
        fail: []const u8 = "",
        /// The first PUT whose target contains this is cut: 1 MiB of its body is read, then
        /// the connection is dropped with the rest unread. Empty cuts nothing.
        cut: []const u8 = "",
    };

    /// In place, since the running fake keeps a pointer to `f`.
    fn start(f: *FakeR2, options: Options) !void {
        f.* = .{ .listener = undefined, .task = undefined, .endpoint = "", .arena = .init(gpa), .options = options };
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

    /// Stores `body` under `key`, as if it had been uploaded before.
    fn object(f: *FakeR2, key: []const u8, body: []const u8) !void {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        try f.objects.put(a, try std.fmt.allocPrint(a, "/" ++ bucket ++ "/{s}", .{key}), try a.dupe(u8, body));
    }

    /// The object at `target` (`/<bucket>/<key>`), or null.
    fn get(f: *FakeR2, target: []const u8) ?[]const u8 {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        return f.objects.get(target);
    }

    /// How many objects' targets start with `head`.
    fn stored(f: *FakeR2, head: []const u8) usize {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        var n: usize = 0;
        for (f.objects.keys()) |k| n += @intFromBool(std.mem.startsWith(u8, k, head));
        return n;
    }

    /// The `method` requests read whole so far whose target contains `part`.
    fn requests(f: *FakeR2, method: std.http.Method, part: []const u8) usize {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        var n: usize = 0;
        for (f.seen.items) |s| n += @intFromBool(s.method == method and std.mem.find(u8, s.target, part) != null);
        return n;
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
            if (f.cutting(&request)) {
                const body = request.readerExpectContinue(&.{}) catch return;
                body.discardAll(1 << 20) catch {};
                return;
            }
            const answer = f.receive(&request) catch return;
            if (answer.drop) return;
            const retry_after = [_]std.http.Header{.{ .name = "retry-after", .value = "0" }};
            request.respond(answer.body, .{
                .status = answer.status,
                .keep_alive = keep_alive,
                .extra_headers = retry_after[0..@intFromBool(answer.status == .service_unavailable)],
            }) catch return;
            if (!keep_alive) return;
        }
    }

    /// Whether `request` is the PUT to cut.
    fn cutting(f: *FakeR2, request: *const std.http.Server.Request) bool {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const cut = f.options.cut.len > 0 and f.cuts == 0 and request.head.method == .PUT and
            std.mem.find(u8, request.head.target, f.options.cut) != null;
        f.cuts += @intFromBool(cut);
        return cut;
    }

    const Answer = struct { status: std.http.Status = .ok, body: []const u8 = "", drop: bool = false };

    /// Reads and records the request, then picks its answer: the failure for a target to
    /// fail, else 403 for a bad signature, the stored object for a GET (404 when missing)
    /// and storage for a PUT.
    fn receive(f: *FakeR2, request: *std.http.Server.Request) !Answer {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        const target = try a.dupe(u8, request.head.target);
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
        }
        const body = try a.alloc(u8, request.head.content_length orelse 0);
        if (body.len > 0) try (try request.readerExpectContinue(&.{})).readSliceAll(body);
        const signed = try signedBy(a, request.head.method, target, host, date, hash, authorization, body);
        try f.seen.append(a, .{ .method = request.head.method, .target = target, .signed = signed });

        if (f.options.fail.len > 0 and std.mem.find(u8, target, f.options.fail) != null) {
            f.failed += 1;
            return if (f.failed == 1) .{ .drop = true } else .{ .status = .service_unavailable };
        }
        if (!signed) return .{ .status = .forbidden };
        switch (request.head.method) {
            .PUT => {
                try f.objects.put(a, target, body);
                return .{};
            },
            .GET => return if (f.objects.get(target)) |b| .{ .body = b } else .{ .status = .not_found },
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
    if (!std.mem.eql(u8, hash, &sha256Hex(body)) or date.len != 16) return false;
    const scope = try std.fmt.allocPrint(a, "{s}/auto/s3/aws4_request", .{date[0..8]});
    const canonical = try std.fmt.allocPrint(
        a,
        "{t}\n{s}\n\nhost:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n\nhost;x-amz-content-sha256;x-amz-date\n{s}",
        .{ method, target, host, hash, date, hash },
    );
    const to_sign = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ date, scope, &sha256Hex(canonical) });
    var k: [32]u8 = undefined;
    HmacSha256.create(&k, date[0..8], "AWS4" ++ secret);
    inline for (.{ "auto", "s3", "aws4_request" }) |m| HmacSha256.create(&k, m, &k);
    HmacSha256.create(&k, to_sign, &k);
    const expected_auth = try std.fmt.allocPrint(
        a,
        "AWS4-HMAC-SHA256 Credential=" ++ key_id ++ "/{s}, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={s}",
        .{ scope, &std.fmt.bytesToHex(k, .lower) },
    );
    // AWS accepts the comma-separated parts with or without a space after each comma.
    const given = try std.mem.replaceOwned(u8, a, authorization, ", ", ",");
    return std.mem.eql(u8, given, try std.mem.replaceOwned(u8, a, expected_auth, ", ", ","));
}


/// Counts every allocation `cli.run` makes, forwarding to an arena.
const Counting = struct {
    child: Allocator,
    calls: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(usize) = .init(0),
    big: std.atomic.Value(usize) = .init(0),
    big_bytes: std.atomic.Value(usize) = .init(0),
    sizes: [16]usize = @splat(0),
    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(p: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(p));
        _ = c.calls.fetchAdd(1, .monotonic);
        _ = c.bytes.fetchAdd(len, .monotonic);
        if (len >= 1 << 20) {
            _ = c.big.fetchAdd(1, .monotonic);
            _ = c.big_bytes.fetchAdd(len, .monotonic);
            const k = c.big.raw - 1;
            if (k < 16) c.sizes[k] = len;
        }
        return c.child.rawAlloc(len, al, ra);
    }
    fn resize(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(p));
        const ok = c.child.rawResize(m, al, n, ra);
        if (ok and n > m.len) _ = c.bytes.fetchAdd(n - m.len, .monotonic);
        return ok;
    }
    fn remap(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(p));
        const r = c.child.rawRemap(m, al, n, ra);
        if (r != null and n > m.len) _ = c.bytes.fetchAdd(n - m.len, .monotonic);
        return r;
    }
    fn free(p: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(p));
        c.child.rawFree(m, al, ra);
    }
};

test "bench: publish of a 20 000-character story with realistic audio" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();

    // ~20 000 code points of Italian: 46 paragraphs of 8 sentences, ~52 chars each.
    const it_s = "Il gatto entra piano in casa e apre la porta rossa. ";
    const pt_s = "O gato entra devagar em casa e abre a porta vermelha. ";
    const n_par = 46;
    const n_sen = 8;
    var it_json: std.ArrayList(u8) = .empty;
    var pt_json: std.ArrayList(u8) = .empty;
    var times: std.ArrayList(u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var ms: u32 = 0;
    for (0..n_par) |i| {
        try it_json.appendSlice(a, if (i > 0) ",[" else "[");
        try pt_json.appendSlice(a, if (i > 0) ",[" else "[");
        try times.appendSlice(a, if (i > 0) ",[" else "[");
        if (i > 0) try text.append(a, '\n');
        for (0..n_sen) |j| {
            const s_it = try std.fmt.allocPrint(a, "{s}{d}.{d}", .{ it_s[0 .. it_s.len - 2], i, j });
            const s_pt = try std.fmt.allocPrint(a, "{s}{d}.{d}", .{ pt_s[0 .. pt_s.len - 2], i, j });
            if (j > 0) {
                try it_json.append(a, ',');
                try pt_json.append(a, ',');
                try times.append(a, ',');
                try text.append(a, ' ');
            }
            try it_json.print(a, "\"{s}\"", .{s_it});
            try pt_json.print(a, "\"{s}\"", .{s_pt});
            try text.appendSlice(a, s_it);
            try times.print(a, "[{d},{d}]", .{ ms, ms + 3300 });
            ms += 3500;
        }
        try it_json.append(a, ']');
        try pt_json.append(a, ']');
        try times.append(a, ']');
    }
    const cps = try std.unicode.utf8CountCodepoints(text.items);
    const json = try std.fmt.allocPrint(a,
        \\{{"id": "{s}", "level": 2, "genre": "classici", "tags": ["legno"], "work": "Pinocchio", "part": 1, "author": "collodi", "adapted": 1, "license": "public-domain",
        \\ "translations": {{
        \\  "it": {{"title": "Il gatto", "subtitle": "Una storia", "paragraphs": [{s}], "audio": {{"audio_ms": {d}, "text_sha256": "{s}", "times": [{s}]}}}},
        \\  "pt-BR": {{"title": "O gato", "subtitle": "Uma historia", "paragraphs": [{s}]}}
        \\ }}}}
    , .{ story_id, it_json.items, ms, &sha256Hex(text.items), times.items, pt_json.items });

    // Audio for ms/1000 s: Opus at 32 kbit/s, FLAC mono 44.1 kHz 16-bit at ~60 % of PCM.
    const secs = ms / 1000;
    const opus_len = secs * 32_000 / 8;
    const flac_len = secs * 44_100 * 2 * 6 / 10;
    var prng: std.Random.DefaultPrng = .init(1);
    const big_opus = try a.alloc(u8, opus_len);
    const big_flac = try a.alloc(u8, flac_len);
    prng.random().bytes(big_opus);
    prng.random().bytes(big_flac);
    try w.tmp.dir.createDirPath(io, "story");
    try w.tmp.dir.writeFile(io, .{ .sub_path = "story/story.json", .data = json });
    try w.tmp.dir.writeFile(io, .{ .sub_path = "story/it.opus", .data = big_opus });
    try w.tmp.dir.writeFile(io, .{ .sub_path = "story/it.flac", .data = big_flac });
    const path = try std.fmt.allocPrintSentinel(a, "{s}/story", .{w.root}, 0);

    for (0..3) |round| {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        var c: Counting = .{ .child = arena.allocator() };
        const puts0 = w.f.requests(.PUT, "/");
        const gets0 = w.f.requests(.GET, "/");
        const file = try w.tmp.dir.createFile(io, "output.txt", .{ .read = true });
        const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
        _ = std.c.dup2(file.handle, 1);
        _ = std.c.dup2(file.handle, 2);
        const t0 = Io.Clock.awake.now(io);
        const code = cli.run(io, c.allocator(), &w.env, w.tmp.dir, &.{ "postilla", "publish", path });
        const t1 = Io.Clock.awake.now(io);
        _ = std.c.dup2(saved[0], 1);
        _ = std.c.dup2(saved[1], 2);
        for (saved) |fd| _ = std.c.close(fd);
        file.close(io);
        if (code != 0) std.debug.print("OUT: {s}\n", .{try w.tmp.dir.readFileAlloc(io, "output.txt", a, .limited(1 << 20))});
        try expectEqual(0, code);
        std.debug.print("BENCH big_alloc_sizes={any}\n", .{c.sizes[0..@min(c.big.raw, 16)]});
        std.debug.print("BENCH round={d} codepoints={d} sentences={d} audio_s={d} opus_bytes={d} flac_bytes={d} json_bytes={d} wall_ms={d} alloc_calls={d} alloc_bytes={d} allocs_ge_1MiB={d} bytes_in_allocs_ge_1MiB={d} arena_capacity={d} r2_puts={d} r2_gets={d}\n", .{
            round,                     cps,                       n_par * n_sen,             secs, opus_len, flac_len, json.len,
            t0.durationTo(t1).toMilliseconds(), c.calls.raw, c.bytes.raw, c.big.raw, c.big_bytes.raw, arena.queryCapacity(),
            w.f.requests(.PUT, "/") - puts0,   w.f.requests(.GET, "/") - gets0,
        });
    }

    // The #25 fix's own cost: one copy of every upload body per try.
    const total = opus_len + flac_len;
    const dst = try a.alloc(u8, flac_len);
    const t0 = Io.Clock.awake.now(io);
    @memcpy(dst, big_flac);
    @memcpy(dst[0..opus_len], big_opus);
    const t1 = Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(dst);
    std.debug.print("BENCH memcpy_of_audio_bodies bytes={d} us={d}\n", .{ total, t0.durationTo(t1).toMicroseconds() });
}
