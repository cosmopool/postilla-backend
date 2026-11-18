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

test "AC-1, AC-2, AC-9, AC-11: a narrated story uploads both .tilla.gz and its audio and the feed lists both; a republish with a read-only cached dict.db moves no cursor and downloads nothing" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const path = try w.folder(try story(a, &.{}));
    const gz_key = try std.fmt.allocPrint(a, "dict/{s}.db.gz", .{&w.dict_hex});
    const cached = try std.fmt.allocPrint(a, "{s}.db", .{&w.dict_hex});

    const first = try w.publish(path);
    try expectEqual(0, first.code);

    // AC-1: every translation's .tilla.gz under the sha256 of its .tilla, and the audio
    // under the sha256 of each file, nothing else.
    const it = try tilla.build(a, try expected("it"), w.dict_path);
    const pt = try tilla.build(a, try expected("pt-BR"), w.dict_path);
    const it_key = try std.fmt.allocPrint(a, prefix ++ "it/{s}.tilla.gz", .{&std.fmt.bytesToHex(it.sha256, .lower)});
    const pt_key = try std.fmt.allocPrint(a, prefix ++ "pt-BR/{s}.tilla.gz", .{&std.fmt.bytesToHex(pt.sha256, .lower)});
    try expectEqualSlices(u8, it.tilla, try gunzip(a, w.f.get(it_key) orelse return error.TestMissingItTilla));
    try expectEqualSlices(u8, pt.tilla, try gunzip(a, w.f.get(pt_key) orelse return error.TestMissingPtTilla));
    const opus_key = try std.fmt.allocPrint(a, prefix ++ "it/{s}.opus", .{&sha256Hex(opus)});
    const flac_key = try std.fmt.allocPrint(a, prefix ++ "it/{s}.flac", .{&sha256Hex(flac)});
    try expectEqualSlices(u8, opus, w.f.get(opus_key) orelse return error.TestMissingOpus);
    try expectEqualSlices(u8, flac, w.f.get(flac_key) orelse return error.TestMissingFlac);
    try expectEqual(4, w.f.stored(prefix));

    // AC-1: the feed lists both translations, published, with those sha256s.
    const feed = try w.feed();
    try expectEqual(9 + 2 * 61, feed.len);
    try expectEqualSlices(u8, "FEED\x01\x00\x00\x00\x02", feed[0..9]);
    var langs: [2][]const u8 = undefined;
    for (&langs, 0..) |*lang, i| {
        const r = feed[9 + 61 * i ..][0..61];
        try expectEqualSlices(u8, &(try server.wire.StoryId.parse(story_id)).bytes, r[0..16]);
        lang.* = std.mem.sliceTo(r[16..24], 0);
        try expectEqual(1, r[24]);
        const want = if (std.mem.eql(u8, lang.*, "it")) it.sha256 else if (std.mem.eql(u8, lang.*, "pt-BR")) pt.sha256 else return error.TestUnexpectedLang;
        try expectEqualSlices(u8, &want, r[25..57]);
    }
    try expect(!std.mem.eql(u8, langs[0], langs[1]));

    // AC-9: the dictionary came down once, and the Italian band_words are the fixture's.
    try expectEqual(1, w.f.requests(.GET, gz_key));
    try expectEqual([4]u16{ 9, 2, 1, 1 }, try bandWords(try gunzip(a, w.f.get(it_key).?)));
    try expectEqual([4]u16{ 0, 0, 0, 0 }, try bandWords(try gunzip(a, w.f.get(pt_key).?)));

    // AC-11: the cache holds the build alone, byte for byte as R2 served it: no -wal, no
    // -shm, no journal mode switched.
    try expectEqualStrings(cached, try w.cache());
    try expect(std.mem.eql(u8, w.dict, try w.tmp.dir.readFileAlloc(io, try std.fmt.allocPrint(a, "dict/{s}", .{cached}), a, .limited(1 << 20))));

    // AC-2, AC-9, AC-11: the same folder again, with the cached build read-only.
    try w.tmp.dir.setFilePermissions(io, try std.fmt.allocPrint(a, "dict/{s}", .{cached}), .fromMode(0o444), .{});
    const second = try w.publish(path);
    try expectEqual(0, second.code);
    try expectEqualSlices(u8, feed, try w.feed());
    try expectEqual(1, w.f.requests(.GET, gz_key));
    try expectEqualStrings(cached, try w.cache());
    try expect(std.mem.eql(u8, w.dict, try w.tmp.dir.readFileAlloc(io, try std.fmt.allocPrint(a, "dict/{s}", .{cached}), a, .limited(1 << 20))));
}

test "AC-3: a story.json that breaks any of rules 1 to 8 exits 1 with `story.json: <reason>`, uploading nothing and publishing nothing" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    // 37 code points in the first two sentences, so the Italian is 20 001.
    const too_long = try std.fmt.allocPrint(a, "\"{s}\"", .{try letters(a, 19964)});

    const cases = [_][2][]const u8{
        // 1: not JSON, a field that isn't in the table, a field missing.
        .{ "\"level\": 2,", "\"level\": 2" },
        .{ "\"level\": 2,", "\"level\": 2, \"minutes\": 3," },
        .{ "\"subtitle\": \"Uma história de casa\",", "\"subtitle\": \"Uma história de casa\", \"summary\": \"Um gato\"," },
        .{ "\"forced\": false", "\"forced\": false, \"reviewed\": true" },
        .{ "\"license\": \"public-domain\",", "" },
        // 2
        .{ "\"title\": \"Il gatto e la porta\"", "\"title\": \"\"" },
        .{ "\"subtitle\": \"Una storia di casa\"", "\"subtitle\": \"\"" },
        .{ "\"genre\": \"classici\"", "\"genre\": \"\"" },
        .{ "\"license\": \"public-domain\"", "\"license\": \"\"" },
        .{ "\"license\": \"public-domain\"", "\"license\": \"dominio-pubblico-\u{e8}\"" },
        .{ "\"level\": 2", "\"level\": 0" },
        .{ "\"level\": 2", "\"level\": 7" },
        .{ "\"adapted\": 1", "\"adapted\": 2" },
        // 3
        .{ "\"work\": \"Pinocchio\"", "\"work\": \"\"" },
        .{ "\"part\": 1", "\"part\": 0" },
        // 4
        .{ "\"tags\": [\"legno\"]", "\"tags\": [\"legno\", \"\"]" },
        .{ "\"tags\": [\"legno\"]", "\"tags\": [\"legno\", \"legno\"]" },
        // 5
        .{ "\"author\": \"collodi\"", "\"author\": \"\"" },
        // 6
        .{ "\"it\": {", "\"en\": {" },
        .{ "[[\"Il gatto entra in casa.\", \"Apre la porta.\"], [\"Fuori tira aria di festa.\"]]", "[]" },
        .{ "[\"Fuori tira aria di festa.\"]", "[]" },
        .{ "\"Apre la porta.\"", "\"\"" },
        // 7
        .{ ", [\"Lá fora há ar de festa.\"]", "" },
        .{ ", \"Abre a porta.\"", "" },
        .{ "\"Abre a porta.\"", "\"\"" },
        .{ "\"title\": \"O gato e a porta\"", "\"title\": \"\"" },
        .{ "\"subtitle\": \"Uma história de casa\"", "\"subtitle\": \"\"" },
        // 8
        .{ "\"Fuori tira aria di festa.\"", too_long },
    };
    for (cases) |case| {
        const run = try w.publish(try w.folder(try story(a, &.{case})));
        if (run.code != 1) std.debug.print("'{s}' as '{s}' exited {d}\n", .{ case[0], case[1][0..@min(case[1].len, 60)], run.code });
        try expectEqual(1, run.code);
        try expectSays(run.out, "story.json: ");
    }
    try w.expectNothing();
}

test "AC-3: the 20 000-character limit counts code points, so an Italian of exactly 20 000 two-byte letters publishes" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const long = try letters(a, 19963);
    const text_sha256 = sha256Hex(try std.fmt.allocPrint(a, "Il gatto entra in casa. Apre la porta.\n{s}", .{long}));

    const run = try w.publish(try w.folder(try story(a, &.{
        .{ "\"Fuori tira aria di festa.\"", try std.fmt.allocPrint(a, "\"{s}\"", .{long}) },
        .{ "TEXT_SHA256", &text_sha256 },
    })));
    try expectEqual(0, run.code);
    try expectEqual(9 + 2 * 61, (try w.feed()).len);
}

test "AC-4, AC-5, AC-6: an id the server doesn't list, a missing translate language, or a missing or stale narration exits 1 naming what to fix, before any upload" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();

    const cases = [_]struct { edit: [2][]const u8 = .{ "\"level\": 2", "\"level\": 2" }, delete: []const u8 = "", says: []const []const u8 }{
        // AC-4
        .{ .edit = .{ "\"genre\": \"classici\"", "\"genre\": \"fiaba\"" }, .says = &.{ "genre", "fiaba" } },
        .{ .edit = .{ "\"tags\": [\"legno\"]", "\"tags\": [\"legno\", \"mare\"]" }, .says = &.{ "tag", "mare" } },
        .{ .edit = .{ "\"author\": \"collodi\"", "\"author\": \"calvino\"" }, .says = &.{ "author", "calvino" } },
        .{ .edit = .{ pt_member, pt_member ++ ",\n    " ++ scn_member }, .says = &.{"scn"} },
        // AC-5
        .{ .edit = .{ ",\n    " ++ pt_member, "" }, .says = &.{"translate"} },
        // AC-6
        .{ .edit = .{ ", " ++ audio_member, "" }, .says = &.{"narrate"} },
        .{ .edit = .{ "\"Apre la porta.\"", "\"Apre la finestra.\"" }, .says = &.{"narrate"} },
        .{ .delete = "story/it.opus", .says = &.{"narrate"} },
        .{ .delete = "story/it.flac", .says = &.{"narrate"} },
    };
    for (cases) |case| {
        const path = try w.folder(try story(a, &.{case.edit}));
        if (case.delete.len > 0) try w.tmp.dir.deleteFile(io, case.delete);
        const run = try w.publish(path);
        try expectEqual(1, run.code);
        for (case.says) |word| try expectSays(run.out, word);
    }
    try w.expectNothing();
}

test "AC-7: a republish without a published translation, once the server no longer asks for it, prints the server's 409 reason and exits 1" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    try expectEqual(0, (try w.publish(try w.folder(try story(a, &.{})))).code);
    const feed = try w.feed();

    try w.h.sql("UPDATE language SET translate = 0 WHERE id = 'pt-BR';");
    const run = try w.publish(try w.folder(try story(a, &.{.{ ",\n    " ++ pt_member, "" }})));
    try expectEqual(1, run.code);
    try expectSays(run.out, "pt-BR: published, missing from body");
    try expectEqualSlices(u8, feed, try w.feed());
}

test "AC-8, AC-F4: cli.env in the current directory fills what the environment lacks and the environment wins over it; a variable in neither, or a line without =, exits 1 naming it" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const path = try w.folder(try story(a, &.{}));
    const server_url = try a.dupe(u8, w.env.get("POSTILLA_SERVER_URL").?);
    try expect(w.env.swapRemove("POSTILLA_SERVER_URL"));
    try expect(w.env.swapRemove("POSTILLA_R2_SECRET_ACCESS_KEY"));

    // In neither.
    try w.tmp.dir.writeFile(io, .{ .sub_path = "cli.env", .data = try std.fmt.allocPrint(a,
        \\# postilla CLI configuration for the tests
        \\
        \\POSTILLA_SERVER_URL={s}
        \\
    , .{server_url}) });
    const missing = try w.publish(path);
    try expectEqual(1, missing.code);
    try expectSays(missing.out, "POSTILLA_R2_SECRET_ACCESS_KEY");
    try w.expectNothing();

    // Line 7 has no =.
    try w.tmp.dir.writeFile(io, .{ .sub_path = "cli.env", .data = try std.fmt.allocPrint(a,
        \\# postilla CLI configuration for the tests
        \\
        \\POSTILLA_SERVER_URL={s}
        \\POSTILLA_R2_SECRET_ACCESS_KEY={s}
        \\
        \\# the bucket, written without its =
        \\POSTILLA_R2_BUCKET elsewhere
        \\
    , .{ server_url, secret }) });
    const bad = try w.publish(path);
    try expectEqual(1, bad.code);
    try expectSays(bad.out, "cli.env");
    try expectNumber(bad.out, 7);
    try w.expectNothing();

    // The file gives the server and the secret; the bucket and the token it gives lose to
    // the environment's.
    try w.tmp.dir.writeFile(io, .{ .sub_path = "cli.env", .data = try std.fmt.allocPrint(a,
        \\# postilla CLI configuration for the tests
        \\
        \\POSTILLA_SERVER_URL={s}
        \\POSTILLA_R2_SECRET_ACCESS_KEY={s}
        \\
        \\# the environment's values win over these two
        \\POSTILLA_R2_BUCKET=elsewhere
        \\POSTILLA_AUTHOR_TOKEN=not-the-token
        \\
    , .{ server_url, secret }) });
    const good = try w.publish(path);
    try expectEqual(0, good.code);
    try expectEqual(4, w.f.stored(prefix));
    try expectEqual(0, w.f.requests(.PUT, "/elsewhere/"));
    try expectEqual(9 + 2 * 61, (try w.feed()).len);
}

test "AC-F3: a folder that doesn't exist, or has no story.json, exits 1 naming the path" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();

    const nowhere = try std.fmt.allocPrintSentinel(a, "{s}/nowhere", .{w.root}, 0);
    const gone = try w.publish(nowhere);
    try expectEqual(1, gone.code);
    try expectSays(gone.out, nowhere);

    try w.tmp.dir.createDirPath(io, "empty");
    const empty = try std.fmt.allocPrintSentinel(a, "{s}/empty", .{w.root}, 0);
    const bare = try w.publish(empty);
    try expectEqual(1, bare.code);
    try expectSays(bare.out, empty);
    try w.expectNothing();
}

test "AC-F5: a cached dict.db that isn't a SQLite database, or has no form table, exits 1 naming the dictionary before any upload" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const path = try w.folder(try story(a, &.{}));
    const cached = try std.fmt.allocPrint(a, "dict/{s}.db", .{&w.dict_hex});

    const no_form = try std.fmt.allocPrintSentinel(a, "{s}/no_form.db", .{w.root}, 0);
    {
        var d = try server.db.open(no_form);
        defer d.close();
        try d.exec("CREATE TABLE entry (id INTEGER PRIMARY KEY, band INTEGER NOT NULL); PRAGMA journal_mode = DELETE;");
    }
    const builds = [_][]const u8{
        "this is not a SQLite database, only a line of text standing where the dictionary build should be, and nothing more\n",
        try w.tmp.dir.readFileAlloc(io, "no_form.db", a, .limited(1 << 20)),
    };
    try w.tmp.dir.createDirPath(io, "dict");
    for (builds) |build| {
        try w.tmp.dir.writeFile(io, .{ .sub_path = cached, .data = build });
        const run = try w.publish(path);
        try expectEqual(1, run.code);
        try expectSays(run.out, "dict");
    }
    try w.expectNothing();
}

test "AC-F1: an upload R2 fails on every try stops the command naming its key, and no POST /stories reaches the server; a failed .tilla.gz stops it before any audio upload" {
    var key_buf: [128]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "stories/" ++ story_id ++ "/it/{s}.flac", .{&sha256Hex(flac)});
    {
        var w: World = undefined;
        try w.start(.{ .fail = key });
        defer w.stop();
        const a = w.arena.allocator();

        const run = try w.publish(try w.folder(try story(a, &.{})));
        try expectEqual(1, run.code);
        try expectSays(run.out, key);
        try expectEqual(4, w.f.requests(.PUT, key));
        try expectEqualSlices(u8, "FEED\x01\x00\x00\x00\x00", try w.feed());
    }

    // Every .tilla.gz upload fails: the first one tried takes all four tries, then the
    // command stops, before the other translation, the audio and the POST.
    var w: World = undefined;
    try w.start(.{ .fail = ".tilla.gz" });
    defer w.stop();
    const a = w.arena.allocator();

    const run = try w.publish(try w.folder(try story(a, &.{})));
    try expectEqual(1, run.code);
    const keys = [_][]const u8{
        try std.fmt.allocPrint(a, "stories/" ++ story_id ++ "/it/{s}.tilla.gz", .{&std.fmt.bytesToHex((try tilla.build(a, try expected("it"), w.dict_path)).sha256, .lower)}),
        try std.fmt.allocPrint(a, "stories/" ++ story_id ++ "/pt-BR/{s}.tilla.gz", .{&std.fmt.bytesToHex((try tilla.build(a, try expected("pt-BR"), w.dict_path)).sha256, .lower)}),
    };
    if (std.mem.find(u8, run.out, keys[0]) == null) try expectSays(run.out, keys[1]);
    try expectEqual(4, w.f.requests(.PUT, ".tilla.gz"));
    try expectEqual(0, w.f.requests(.PUT, ".opus"));
    try expectEqual(0, w.f.requests(.PUT, ".flac"));
    try expectEqual(0, w.f.stored(prefix));
    try expectEqualSlices(u8, "FEED\x01\x00\x00\x00\x00", try w.feed());
}

test "AC-F2: a server that answers no list request fails after the retries and exits 1 before any upload" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    var down: FakeR2 = undefined;
    try down.start(.{ .fail = "/" });
    defer down.stop();
    try w.env.put("POSTILLA_SERVER_URL", down.endpoint);

    const run = try w.publish(try w.folder(try story(a, &.{})));
    try expectEqual(1, run.code);
    try expectEqual(4, down.seen.items.len);
    try expectEqual(0, w.f.requests(.PUT, "/"));
}

test "AC-10: an upload whose first try is cut mid-body is retried with exactly the original bytes and a valid signature, and the caller's buffer is unchanged" {
    var f: FakeR2 = undefined;
    try f.start(.{ .cut = ".flac" });
    defer f.stop();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c: r2.Client = .{
        .endpoint = f.endpoint,
        .bucket = bucket,
        .access_key_id = key_id,
        .secret_access_key = secret,
        .retry = .{ .waits_ms = .{ 10, 10, 10 } },
    };
    const key = try std.fmt.allocPrint(a, "stories/" ++ story_id ++ "/it/{s}.flac", .{&sha256Hex(flac)});

    // Far larger than the loopback socket buffers, so the cut lands while it is being sent,
    // and no two neighbouring bytes are equal, so a shifted byte shows.
    const body = try a.alloc(u8, 32 << 20);
    for (body, 0..) |*b, i| b.* = @truncate(i % 251);
    const original = try a.dupe(u8, body);

    const res = try c.put(io, a, key, body);
    try expectEqual(1, f.cuts);
    try expectEqual(.ok, res.status);
    try expect(std.mem.eql(u8, original, body));
    try expect(std.mem.eql(u8, original, f.get(try std.fmt.allocPrint(a, "/" ++ bucket ++ "/{s}", .{key})) orelse return error.TestMissingFlac));
    try expectEqual(1, f.requests(.PUT, key));
    try expect(f.seen.items[f.seen.items.len - 1].signed);
}
