//! `postilla narrate <folder>` end to end (docs/specification.md, `postilla narrate`):
//! `cli.run` runs in-process with a temp directory as its current directory, against the
//! real server (harness) for the lists and a fake Speechify on a free port. What the command
//! prints, on stdout or stderr, is read back by pointing both at a file while it runs. The
//! last test drives `outbound.request`'s idle timer (Retries) through `r2.Client`, whose
//! `retry` sets the timeouts, against a server that sends its answer a few bytes at a time.
//!
//! The fake Speechify keeps every request it is sent and answers each stream request with
//! the next of its answers. A good stream is `.work/fixtures/speechify_stream.txt`'s shape:
//! `speech.chunk` events carrying base64 PCM (16-bit little-endian mono at 48 kHz, a sine)
//! and one word mark per word of the request's `input`, then `speech.done`. Word `k` of the
//! input gets the slot `[k * word_ms, (k + 1) * word_ms)`: its mark runs from 10 ms into the
//! slot to 20 ms before its end, and the PCM lasts every slot plus 30 samples.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("cli");
const r2 = @import("r2");
const audio = @import("audio");
const harness = @import("harness");
const Harness = harness.Harness;
const sha256Hex = harness.sha256Hex;

const io = std.testing.io;
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

const speechify_key = "test-speechify-key";
const stream_path = "/v1/audio/stream/with-timestamps";

const it_title = "Il gatto e la porta";
const it_subtitle = "Una storia di casa";
/// Two paragraphs, 2 sentences then 1, with letters of two bytes before the second
/// sentence, so code-point offsets and byte offsets differ.
const it_paragraphs: []const []const []const u8 = &.{
    &.{ "Il gatto \u{e8} gi\u{e0} in casa.", "Apre la porta." },
    &.{"Fuori c'\u{e8} aria di festa."},
};
/// What narrate sends and hashes: sentences joined by one space, paragraphs by one newline.
const it_text = "Il gatto \u{e8} gi\u{e0} in casa. Apre la porta.\nFuori c'\u{e8} aria di festa.";
/// The first and last word of each sentence, by index in `it_text`'s 14 words.
const sentence_words = [3][2]u32{ .{ 0, 5 }, .{ 6, 8 }, .{ 9, 13 } };
const word_count = 14;
/// Samples past the last word's slot, so `audio_ms` is rounded down.
const extra_samples = 30;

const it_member =
    \\"it": {"title": "Il gatto e la porta", "subtitle": "Una storia di casa", "paragraphs": [["Il gatto è già in casa.", "Apre la porta."], ["Fuori c'è aria di festa."]]}
;
/// A pt-BR written by hand, with the Italian's paragraph and sentence counts.
const pt_member =
    \\"pt-BR": {"title": "O gato e a porta", "subtitle": "Uma história de casa", "paragraphs": [["O gato já está em casa.", "Abre a porta."], ["Lá fora há ar de festa."]]}
;
/// A story that passes every check, with only the Italian.
const story_template =
    \\{
    \\  "id": "d0159518-99cc-46f0-bef2-b5b6f6f9a76d",
    \\  "level": 3,
    \\  "genre": "classici",
    \\  "tags": [],
    \\  "work": "Pinocchio",
    \\  "part": 1,
    \\  "author": "collodi",
    \\  "adapted": 1,
    \\  "license": "public-domain",
    \\  "translations": {
    \\
++ it_member ++ "\n  }\n}\n";

/// `story.json` as rule 1 allows it: no field outside the table.
const Story = struct {
    id: []const u8,
    level: u8,
    genre: []const u8,
    tags: []const []const u8,
    work: []const u8,
    part: u16,
    author: []const u8,
    adapted: u8,
    license: []const u8,
    moderation: ?std.json.Value = null,
    translations: std.json.ArrayHashMap(Translation),
};
const Translation = struct {
    title: []const u8,
    subtitle: []const u8,
    paragraphs: []const []const []const u8,
    audio: ?Audio = null,
};
const Audio = struct { audio_ms: u32, text_sha256: []const u8, times: []const []const [2]u32 };

/// The fake's PCM for `words` words at `word_ms` each, plus `extra_samples`: a `tone` Hz
/// sine at 48 kHz.
fn pcm(a: Allocator, words: usize, word_ms: u32, tone: f64) ![]i16 {
    const out = try a.alloc(i16, words * word_ms * 48 + extra_samples);
    for (out, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / 48000;
        s.* = @intFromFloat(@round(8000 * @sin(2 * std.math.pi * tone * t)));
    }
    return out;
}

/// The sentence times the fake's marks give at `word_ms`: each sentence from its first
/// word's mark start to its last word's mark end.
fn times(word_ms: u32) [3][2]u32 {
    var out: [3][2]u32 = undefined;
    for (sentence_words, &out) |w, *t| t.* = .{ w[0] * word_ms + 10, w[1] * word_ms + word_ms - 20 };
    return out;
}

/// `t`'s audio is the narration of `it_text` at `word_ms`, with `want` as its three times
/// in the shape of `it_paragraphs`.
fn expectAudio(t: ?Translation, word_ms: u32, want: [3][2]u32) !void {
    const got = (t orelse return error.TestNoTranslation).audio orelse return error.TestNoAudio;
    try expectEqual((word_count * word_ms * 48 + extra_samples) / 48, got.audio_ms);
    try expectEqualStrings(&sha256Hex(it_text), got.text_sha256);
    try expectEqual(2, got.times.len);
    try expectEqual(2, got.times[0].len);
    try expectEqual(1, got.times[1].len);
    try expectEqual(want[0], got.times[0][0]);
    try expectEqual(want[1], got.times[0][1]);
    try expectEqual(want[2], got.times[1][0]);
}

/// What a run of the command gave: its exit code and everything it printed.
const Run = struct { code: u8, out: []const u8 };

/// The world a narrate runs in: the real server (which lists `it` with target 1 and pt-BR
/// with target 0), a fake Speechify, and a temp directory that is the command's current
/// directory, with the story folder at `story/`.
const World = struct {
    h: Harness,
    f: FakeSpeechify,
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    /// The temp directory's absolute path.
    root: [:0]const u8,
    /// Every required variable, pointing at the server, and `POSTILLA_SPEECHIFY_URL` at
    /// the fake.
    env: std.process.Environ.Map,

    /// In place, since the running server and fake keep pointers into `w`.
    fn start(w: *World, options: FakeSpeechify.Options) !void {
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

        w.env = .init(a);
        try w.env.put("POSTILLA_SERVER_URL", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{w.h.port}));
        try w.env.put("POSTILLA_AUTHOR_TOKEN", harness.token);
        try w.env.put("POSTILLA_OPENCODE_KEY", "test-opencode-key");
        try w.env.put("POSTILLA_SPEECHIFY_KEY", speechify_key);
        try w.env.put("POSTILLA_SPEECHIFY_URL", w.f.base);
        try w.env.put("POSTILLA_R2_ACCOUNT_ID", "test-account");
        try w.env.put("POSTILLA_R2_ACCESS_KEY_ID", "test-key-id");
        try w.env.put("POSTILLA_R2_SECRET_ACCESS_KEY", "test-secret-access-key");
        try w.env.put("POSTILLA_R2_BUCKET", "postilla");
    }

    fn stop(w: *World) void {
        w.arena.deinit();
        w.tmp.cleanup();
        w.f.stop();
        w.h.stop();
    }

    /// Writes the story folder with `story.json` as `json` and returns its absolute path.
    fn folder(w: *World, json: []const u8) ![:0]const u8 {
        try w.tmp.dir.createDirPath(io, "story");
        try w.tmp.dir.writeFile(io, .{ .sub_path = "story/story.json", .data = json });
        return std.fmt.allocPrintSentinel(w.arena.allocator(), "{s}/story", .{w.root}, 0);
    }

    /// Runs `postilla <command> <args>` with `w.env`, stdout and stderr captured.
    fn run(w: *World, command: [:0]const u8, args: []const [:0]const u8) !Run {
        const a = w.arena.allocator();
        const argv = try std.mem.concat(a, [:0]const u8, &.{ &.{ "postilla", command }, args });
        const output = try w.tmp.dir.createFile(io, "output.txt", .{ .read = true });
        defer output.close(io);
        const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
        _ = std.c.dup2(output.handle, 1);
        _ = std.c.dup2(output.handle, 2);
        const code: u8 = cli.run(io, a, &w.env, w.tmp.dir, argv);
        _ = std.c.dup2(saved[0], 1);
        _ = std.c.dup2(saved[1], 2);
        for (saved) |fd| _ = std.c.close(fd);
        return .{ .code = code, .out = try w.tmp.dir.readFileAlloc(io, "output.txt", a, .limited(1 << 20)) };
    }

    /// `story/<name>` as it is on disk.
    fn file(w: *World, name: []const u8) ![]const u8 {
        return w.tmp.dir.readFileAlloc(io, try std.fmt.allocPrint(w.arena.allocator(), "story/{s}", .{name}), w.arena.allocator(), .unlimited);
    }

    /// `story/story.json` parsed, failing when it breaks rule 1.
    fn read(w: *World) !Story {
        return std.json.parseFromSliceLeaky(Story, w.arena.allocator(), try w.file("story.json"), .{});
    }

    /// The names in the story folder, sorted and joined by spaces.
    fn listing(w: *World) ![]const u8 {
        const a = w.arena.allocator();
        var dir = try w.tmp.dir.openDir(io, "story", .{ .iterate = true });
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

    /// `it.opus` and `it.flac` are `samples` encoded: the bytes `audio.encode` gives at
    /// 48 kHz, an Ogg stream, and a FLAC whose STREAMINFO has the samples' MD5.
    fn expectFiles(w: *World, samples: []const i16) !void {
        const a = w.arena.allocator();
        const want = try audio.encode(a, samples, 48000);
        const opus = try w.file("it.opus");
        const flac = try w.file("it.flac");
        try expect(std.mem.startsWith(u8, opus, "OggS"));
        try expectEqualSlices(u8, want.opus, opus);
        try expectEqualSlices(u8, want.flac, flac);
        var md5: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(std.mem.sliceAsBytes(samples), &md5, .{});
        try expect(flac.len >= 42);
        try expectEqualSlices(u8, &md5, flac[26..42]);
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

/// What the fake saw of one request.
const Seen = struct {
    method: std.http.Method,
    target: []const u8,
    authorization: []const u8 = "",
    body: []const u8 = "",
};

const FakeSpeechify = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    /// `http://127.0.0.1:<port>`.
    root: []const u8,
    /// `root` plus `/speechify`, as `POSTILLA_SPEECHIFY_URL`.
    base: []const u8,
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    options: Options,
    streams: usize = 0,
    seen: std.ArrayList(Seen) = .empty,
    /// Requests seen so far, numbering each for its chaos fault, and the faults injected.
    count: u64 = 0,
    faults: usize = 0,

    const Options = struct {
        /// When set, every request draws a fault (harness.Chaos) from this seed and the
        /// request's number, overriding `answers`: a closed connection, a cut request, a 503
        /// with `Retry-After: 0`, a slow answer, or a stream that stops after two events.
        chaos: ?u64 = null,
        /// The answer to each stream request, in order; past the end, the last one.
        answers: []const Answer = &.{.good},
        /// Each word's slot in a good stream.
        word_ms: u32 = 100,
        /// The good stream's sine.
        tone: f64 = 440,
        /// Words, by index in the input, a good stream sends no mark for.
        unmarked: []const usize = &.{},
        /// Not 0: the last word's mark ends at this time instead.
        last_end: u32 = 0,
    };

    const Answer = enum {
        /// A good stream, as the fixture.
        good,
        /// A 200 whose stream sends some audio, then `speech.error`.
        speech_error,
        /// A 200 whose body runs until the connection closes, which happens two events and
        /// a half into a good stream, before `speech.done`.
        drop,
        /// 401 with Speechify's error body.
        unauthorized,
        /// 503 with `Retry-After: 0`.
        unavailable,
    };

    /// In place, since the running fake keeps a pointer to `f`.
    fn start(f: *FakeSpeechify, options: Options) !void {
        f.* = .{ .listener = undefined, .task = undefined, .root = "", .base = "", .arena = .init(gpa), .options = options };
        errdefer f.arena.deinit();
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        f.listener = try address.listen(io, .{ .reuse_address = true });
        errdefer f.listener.deinit(io);
        const a = f.arena.allocator();
        f.root = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.listener.socket.address.getPort()});
        f.base = try std.fmt.allocPrint(a, "{s}/speechify", .{f.root});
        f.task = try io.concurrent(serve, .{f});
    }

    fn stop(f: *FakeSpeechify) void {
        f.task.cancel(io) catch {};
        f.listener.deinit(io);
        f.arena.deinit();
    }

    /// The requests so far whose target ends with `path`, in the order they came.
    fn requests(f: *FakeSpeechify, a: Allocator, path: []const u8) ![]const Seen {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        var out: std.ArrayList(Seen) = .empty;
        for (f.seen.items) |s| if (std.mem.endsWith(u8, s.target, path)) try out.append(a, s);
        return out.items;
    }

    /// How many requests it has been sent, to any path.
    fn total(f: *FakeSpeechify) usize {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        return f.seen.items.len;
    }

    fn serve(f: *FakeSpeechify) Io.Cancelable!void {
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

    /// One request per connection: every answer closes it.
    fn connection(f: *FakeSpeechify, stream: Io.net.Stream) Io.Cancelable!void {
        defer stream.close(io);
        var in_buf: [16384]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var in = stream.reader(io, &in_buf);
        var out = stream.writer(io, &out_buf);
        var http: std.http.Server = .init(&in.interface, &out.interface);
        var request = http.receiveHead() catch return;
        const fault = f.chaosFault();
        switch (fault) {
            .drop => return,
            .cut => {
                const body = request.readerExpectContinue(&.{}) catch return;
                body.discardAll((request.head.content_length orelse 0) / 2) catch {};
                return;
            },
            .slow => io.sleep(.fromMilliseconds(20), .awake) catch return,
            else => {},
        }
        var reply = f.receive(&request) catch return;
        if (fault == .unavailable or fault == .stored_unavailable) reply = .{ .status = .service_unavailable };
        if (fault == .short_body and reply.status == .ok) {
            // The stream ends after two events, before `speech.done`, with no chunked framing.
            reply.events = reply.events[0..@min(2, reply.events.len)];
            reply.chunked = false;
        }
        switch (reply.status) {
            .ok => {},
            .service_unavailable => {
                request.respond("", .{ .status = reply.status, .keep_alive = false, .extra_headers = &.{.{ .name = "retry-after", .value = "0" }} }) catch {};
                return;
            },
            else => {
                request.respond(reply.body, .{ .status = reply.status, .keep_alive = false }) catch {};
                return;
            },
        }
        // A stream: chunked, or (`drop`) a body that runs until the connection closes.
        const w = &out.interface;
        w.print("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n{s}\r\n", .{if (reply.chunked) "transfer-encoding: chunked\r\n" else ""}) catch return;
        for (reply.events) |e| {
            if (reply.chunked) w.print("{x}\r\n{s}\r\n", .{ e.len, e }) catch return else w.writeAll(e) catch return;
            w.flush() catch return;
        }
        if (reply.chunked) w.writeAll("0\r\n\r\n") catch return;
        w.flush() catch return;
    }

    /// The next request's fault (harness.Chaos): `none` unless chaos is on.
    fn chaosFault(f: *FakeSpeechify) harness.Chaos {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        f.count += 1;
        const fault: harness.Chaos = .pick(f.options.chaos, f.count);
        f.faults += @intFromBool(fault != .none);
        return fault;
    }

    const Reply = struct { status: std.http.Status = .ok, body: []const u8 = "", events: []const []const u8 = &.{}, chunked: bool = true };

    /// Reads and records the request, then builds its answer: 404 off the stream path, 400
    /// for a body without `input`, else the next of `options.answers`.
    fn receive(f: *FakeSpeechify, request: *std.http.Server.Request) !Reply {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        var seen: Seen = .{ .method = request.head.method, .target = try a.dupe(u8, request.head.target) };
        var headers = request.iterateHeaders();
        while (headers.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) seen.authorization = try a.dupe(u8, h.value);
        }
        const body = try a.alloc(u8, request.head.content_length orelse 0);
        if (body.len > 0) try (try request.readerExpectContinue(&.{})).readSliceAll(body);
        seen.body = body;
        try f.seen.append(a, seen);

        if (!std.mem.endsWith(u8, seen.target, stream_path)) return .{ .status = .not_found };
        const req = std.json.parseFromSliceLeaky(struct { input: []const u8 }, a, body, .{ .ignore_unknown_fields = true }) catch
            return .{ .status = .bad_request };
        const o = f.options;
        const answer = o.answers[@min(f.streams, o.answers.len - 1)];
        f.streams += 1;
        switch (answer) {
            .unauthorized => return .{ .status = .unauthorized, .body = "{\"error\":{\"code\":\"unauthorized\",\"message\":\"Invalid API key\"}}" },
            .unavailable => return .{ .status = .service_unavailable },
            .speech_error => {
                const other = try pcm(a, 1, 100, 1000);
                return .{ .events = try a.dupe([]const u8, &.{
                    try event(a, "speech.chunk", try std.fmt.allocPrint(a, "{{\"type\":\"speech.chunk\",\"audio\":\"{s}\"}}", .{try base64(a, std.mem.sliceAsBytes(other))})),
                    try event(a, "speech.error", "{\"type\":\"speech.error\",\"error\":{\"code\":\"voice_unavailable\",\"message\":\"Voice temporarily unavailable\"}}"),
                }) };
            },
            .good, .drop => {},
        }

        const ws = try words(a, req.input);
        const samples = try pcm(a, ws.len, o.word_ms, o.tone);
        const bytes = std.mem.sliceAsBytes(samples);
        var events: std.ArrayList([]const u8) = .empty;
        // Four chunks: the first with audio only, each of the others with a third of the marks.
        for (0..4) |c| {
            var json: Io.Writer.Allocating = .init(a);
            try json.writer.print("{{\"type\":\"speech.chunk\",\"audio\":\"{s}\"", .{try base64(a, bytes[samples.len * c / 4 * 2 .. samples.len * (c + 1) / 4 * 2])});
            if (c > 0) {
                try json.writer.writeAll(",\"speech_marks\":[");
                var first = true;
                const lo = ws.len * (c - 1) / 3;
                for (ws[lo .. ws.len * c / 3], lo..) |word, k| {
                    if (std.mem.indexOfScalar(usize, o.unmarked, k) != null) continue;
                    const slot: u32 = @intCast(k * o.word_ms);
                    const end_time = if (k == ws.len - 1 and o.last_end > 0) o.last_end else slot + o.word_ms - 20;
                    try json.writer.print("{s}{{\"type\":\"word\",\"start\":{d},\"end\":{d},\"start_time\":{d},\"end_time\":{d},\"value\":{s}}}", .{
                        if (first) "" else ",", word.start, word.end, slot + 10, end_time, try std.json.Stringify.valueAlloc(a, word.value, .{}),
                    });
                    first = false;
                }
                try json.writer.writeAll("]");
            }
            try json.writer.writeAll("}");
            try events.append(a, try event(a, "speech.chunk", json.written()));
        }
        try events.append(a, try event(a, "speech.done", try std.fmt.allocPrint(a, "{{\"type\":\"speech.done\",\"billable_characters_count\":{d},\"audio_duration_ms\":{d}}}", .{
            try std.unicode.utf8CountCodepoints(req.input), samples.len / 48,
        })));
        if (answer == .drop) return .{ .events = try a.dupe([]const u8, &.{ events.items[0], events.items[1], events.items[2][0 .. events.items[2].len / 2] }), .chunked = false };
        return .{ .events = events.items };
    }

    const Word = struct { start: usize, end: usize, value: []const u8 };

    /// The words of `input`, split at spaces and newlines, with their code-point offsets.
    fn words(a: Allocator, input: []const u8) ![]const Word {
        var out: std.ArrayList(Word) = .empty;
        var cp: usize = 0;
        var start_byte: ?usize = null;
        var start_cp: usize = 0;
        for (input, 0..) |b, i| {
            if (b == ' ' or b == '\n') {
                if (start_byte) |s| try out.append(a, .{ .start = start_cp, .end = cp, .value = input[s..i] });
                start_byte = null;
            } else if (start_byte == null) {
                start_byte = i;
                start_cp = cp;
            }
            if (b & 0xc0 != 0x80) cp += 1;
        }
        if (start_byte) |s| try out.append(a, .{ .start = start_cp, .end = cp, .value = input[s..] });
        return out.items;
    }

    /// One Server-Sent Event, separated from the next as in the fixture.
    fn event(a: Allocator, kind: []const u8, data: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "event: {s}\ndata: {s}\n\n\n", .{ kind, data });
    }

    fn base64(a: Allocator, bytes: []const u8) ![]const u8 {
        const out = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        return std.base64.standard.Encoder.encode(out, bytes);
    }
};

test "AC-1, AC-2: a story whose Italian has 2 paragraphs is narrated in one Speechify stream into it.opus, it.flac and the audio of story.json, one time per sentence from its first word to its last" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const path = try w.folder(story_template);

    const run = try w.run("narrate", &.{path});
    if (run.code != 0) std.debug.print("{s}\n", .{run.out});
    try expectEqual(0, run.code);

    // AC-1: the files, then `audio`, with the rest of the story as it was.
    try w.expectFiles(try pcm(a, word_count, 100, 440));
    const s = try w.read();
    try expectEqualStrings("d0159518-99cc-46f0-bef2-b5b6f6f9a76d", s.id);
    try expectEqual(1, s.translations.map.count());
    const it = s.translations.map.get("it") orelse return error.TestNoItalian;
    try expectEqualStrings(it_title, it.title);
    try expectEqualStrings(it_subtitle, it.subtitle);
    try expectEqual(it_paragraphs.len, it.paragraphs.len);
    for (it_paragraphs, it.paragraphs) |want, got| {
        try expectEqual(want.len, got.len);
        for (want, got) |x, y| try expectEqualStrings(x, y);
    }
    try expectAudio(it, 100, times(100));

    // AC-2: one request, its body exactly these fields.
    const sent = try w.f.requests(a, stream_path);
    try expectEqual(1, sent.len);
    try expectEqual(.POST, sent[0].method);
    try expectEqualStrings("/speechify" ++ stream_path, sent[0].target);
    try expectEqualStrings("Bearer " ++ speechify_key, sent[0].authorization);
    const body = try std.json.parseFromSliceLeaky(struct {
        input: []const u8,
        voice_id: []const u8,
        model: []const u8,
        language: []const u8,
        output_format: []const u8,
        options: struct { loudness_normalization: bool },
    }, a, sent[0].body, .{});
    try expectEqualStrings(it_text, body.input);
    try expectEqualStrings("daniele-agent", body.voice_id);
    try expectEqualStrings("simba-3.5", body.model);
    try expectEqualStrings("it-IT", body.language);
    try expectEqualStrings("pcm_48000", body.output_format);
    try expect(body.options.loudness_normalization);
}

test "AC-3: a sentence without marks gets [e, e] at the previous sentence's end, [0, 0] when it is the first, and a last mark past the audio ends at audio_ms" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const t = times(100);
    const audio_ms = (word_count * 100 * 48 + extra_samples) / 48;
    try expect(t[2][1] < audio_ms);

    const cases = [_]struct { unmarked: []const usize = &.{}, last_end: u32 = 0, want: [3][2]u32 }{
        // The second sentence's words, then the first's.
        .{ .unmarked = &.{ 6, 7, 8 }, .want = .{ t[0], .{ t[0][1], t[0][1] }, t[2] } },
        .{ .unmarked = &.{ 0, 1, 2, 3, 4, 5 }, .want = .{ .{ 0, 0 }, t[1], t[2] } },
        .{ .last_end = audio_ms + 300, .want = .{ t[0], t[1], .{ t[2][0], audio_ms } } },
    };
    for (cases) |case| {
        w.f.options.unmarked = case.unmarked;
        w.f.options.last_end = case.last_end;
        const run = try w.run("narrate", &.{try w.folder(story_template)});
        if (run.code != 0) std.debug.print("{s}\n", .{run.out});
        try expectEqual(0, run.code);
        try expectAudio((try w.read()).translations.map.get("it"), 100, case.want);
    }
}

test "AC-4: narrating a narrated folder again replaces it.opus, it.flac and audio with the new stream's" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const path = try w.folder(story_template);

    const first = try w.run("narrate", &.{path});
    try expectEqual(0, first.code);
    const old_flac = try w.file("it.flac");

    w.f.options.word_ms = 130;
    w.f.options.tone = 660;
    const again = try w.run("narrate", &.{path});
    if (again.code != 0) std.debug.print("{s}\n", .{again.out});
    try expectEqual(0, again.code);
    try expectEqual(2, (try w.f.requests(a, stream_path)).len);
    try w.expectFiles(try pcm(a, word_count, 130, 660));
    try expect(!std.mem.eql(u8, old_flac, try w.file("it.flac")));
    try expectAudio((try w.read()).translations.map.get("it"), 130, times(130));
    try expectEqualStrings("it.flac it.opus story.json", try w.listing());
}

test "AC-5, AC-6: with it and pt-BR in the story, only it (target 1) is narrated, in one request, and publish then finds the narration current" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const json = try std.mem.replaceOwned(u8, a, story_template, it_member, it_member ++ ",\n    " ++ pt_member);
    const path = try w.folder(json);

    // AC-5
    const run = try w.run("narrate", &.{path});
    if (run.code != 0) std.debug.print("{s}\n", .{run.out});
    try expectEqual(0, run.code);
    const sent = try w.f.requests(a, stream_path);
    try expectEqual(1, sent.len);
    try expectEqualStrings(it_text, (try std.json.parseFromSliceLeaky(struct { input: []const u8 }, a, sent[0].body, .{ .ignore_unknown_fields = true })).input);
    const s = try w.read();
    try expectEqualStrings("it pt-BR", try std.mem.join(a, " ", s.translations.map.keys()));
    try expectAudio(s.translations.map.get("it"), 100, times(100));
    try expect((s.translations.map.get("pt-BR") orelse return error.TestNoTranslation).audio == null);
    try expectEqualStrings("it.flac it.opus story.json", try w.listing());

    // AC-6: publish's checks pass the narration and the files; it stops later, at the
    // dictionary, which the fake (as R2) doesn't have.
    try w.env.put("POSTILLA_R2_ENDPOINT", w.f.root);
    const published = try w.run("publish", &.{path});
    try expectEqual(1, published.code);
    if (std.ascii.findIgnoreCase(published.out, "run narrate") != null) {
        std.debug.print("publish asked for narrate:\n{s}\n", .{published.out});
        return error.TestNarrationNotCurrent;
    }
    try expectSays(published.out, "dict");
}

test "AC-7: a stream with speech.error is tried again at once and the good one is kept; three of them stop the command naming it: narration and the message, writing nothing" {
    {
        var w: World = undefined;
        try w.start(.{ .answers = &.{ .speech_error, .good } });
        defer w.stop();
        const a = w.arena.allocator();

        const run = try w.run("narrate", &.{try w.folder(story_template)});
        if (run.code != 0) std.debug.print("{s}\n", .{run.out});
        try expectEqual(0, run.code);
        try expectEqual(2, (try w.f.requests(a, stream_path)).len);
        try w.expectFiles(try pcm(a, word_count, 100, 440));
        try expectAudio((try w.read()).translations.map.get("it"), 100, times(100));
    }
    var w: World = undefined;
    try w.start(.{ .answers = &.{.speech_error} });
    defer w.stop();
    const a = w.arena.allocator();

    const run = try w.run("narrate", &.{try w.folder(story_template)});
    try expectEqual(1, run.code);
    try expectSays(run.out, "it: narration");
    try expectSays(run.out, "Voice temporarily unavailable");
    try expectEqual(3, (try w.f.requests(a, stream_path)).len);
    try expectEqualStrings(story_template, try w.file("story.json"));
    try expectEqualStrings("story.json", try w.listing());
}

test "AC-8: a stream closed before speech.done three times stops the command naming it: narration, writing nothing" {
    var w: World = undefined;
    try w.start(.{ .answers = &.{.drop} });
    defer w.stop();
    const a = w.arena.allocator();

    const run = try w.run("narrate", &.{try w.folder(story_template)});
    try expectEqual(1, run.code);
    try expectSays(run.out, "it: narration");
    try expectEqual(3, (try w.f.requests(a, stream_path)).len);
    try expectEqualStrings(story_template, try w.file("story.json"));
    try expectEqualStrings("story.json", try w.listing());
}

test "AC-9: narrate without a folder, or with an extra argument, exits 2 printing the usage and sends nothing" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const path = try w.folder(story_template);

    for ([_][]const [:0]const u8{ &.{}, &.{ path, "extra" } }) |args| {
        const run = try w.run("narrate", args);
        try expectEqual(2, run.code);
        try expectSays(run.out, "usage");
        try expectSays(run.out, "narrate");
    }
    try expectEqual(0, w.f.total());
    try expectEqualStrings(story_template, try w.file("story.json"));
    try expectEqualStrings("story.json", try w.listing());
}

test "AC-F1, AC-F2: Speechify answering 401 stops the command after one request naming it and the status; 503 on every try stops it after 4 tries; neither writes anything" {
    const cases = [_]struct { answer: FakeSpeechify.Answer, tries: usize, status: u32 }{
        .{ .answer = .unauthorized, .tries = 1, .status = 401 },
        .{ .answer = .unavailable, .tries = 4, .status = 503 },
    };
    for (cases) |case| {
        var w: World = undefined;
        try w.start(.{ .answers = &.{case.answer} });
        defer w.stop();
        const a = w.arena.allocator();

        const run = try w.run("narrate", &.{try w.folder(story_template)});
        try expectEqual(1, run.code);
        try expectSays(run.out, "it:");
        try expectNumber(run.out, case.status);
        try expectEqual(case.tries, (try w.f.requests(a, stream_path)).len);
        try expectEqualStrings(story_template, try w.file("story.json"));
        try expectEqualStrings("story.json", try w.listing());
    }
}

test "AC-F3: a POSTILLA_SPEECHIFY_URL without :// exits 1 naming the variable before any request" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    // The lists come from the fake too, so a request to the server would show.
    try w.env.put("POSTILLA_SERVER_URL", w.f.root);
    try w.env.put("POSTILLA_SPEECHIFY_URL", "api.speechify.ai");

    const run = try w.run("narrate", &.{try w.folder(story_template)});
    try expectEqual(1, run.code);
    try expectSays(run.out, "POSTILLA_SPEECHIFY_URL");
    try expectEqual(0, w.f.total());
    try expectEqualStrings(story_template, try w.file("story.json"));
}

test "AC-F4: a read-only story folder exits 1 naming the audio file it couldn't write, and story.json is unchanged" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const path = try w.folder(story_template);
    try w.tmp.dir.setFilePermissions(io, "story", .fromMode(0o555), .{});
    defer w.tmp.dir.setFilePermissions(io, "story", .fromMode(0o755), .{}) catch {};

    const run = try w.run("narrate", &.{path});
    try expectEqual(1, run.code);
    if (std.ascii.findIgnoreCase(run.out, "it.opus") == null and std.ascii.findIgnoreCase(run.out, "it.flac") == null) {
        std.debug.print("expected the output to name it.opus or it.flac, got:\n{s}\n", .{run.out});
        return error.TestExpectedSays;
    }
    try expectEqualStrings(story_template, try w.file("story.json"));
    try expectEqualStrings("story.json", try w.listing());
}

/// A server that answers every request with a 200 and `body`, `piece` bytes at a time.
/// `stall` makes the first answer stop after its head; the later ones come whole.
const Trickle = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    endpoint: [32]u8,
    endpoint_len: usize,
    stall: bool,
    mutex: Io.Mutex = .init,
    requests: usize = 0,

    const body = "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef";
    const piece = 4;
    const gap_ms = 40;

    fn start(t: *Trickle, stall: bool) !void {
        t.* = .{ .listener = undefined, .task = undefined, .endpoint = undefined, .endpoint_len = 0, .stall = stall };
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        t.listener = try address.listen(io, .{ .reuse_address = true });
        errdefer t.listener.deinit(io);
        t.endpoint_len = (try std.fmt.bufPrint(&t.endpoint, "http://127.0.0.1:{d}", .{t.listener.socket.address.getPort()})).len;
        t.task = try io.concurrent(serve, .{t});
    }

    fn stop(t: *Trickle) void {
        t.task.cancel(io) catch {};
        t.listener.deinit(io);
    }

    fn client(t: *const Trickle, idle_timeout_ms: u32) r2.Client {
        return .{
            .endpoint = t.endpoint[0..t.endpoint_len],
            .bucket = "postilla",
            .access_key_id = "test-key-id",
            .secret_access_key = "test-secret-access-key",
            .retry = .{ .waits_ms = .{ 10, 10, 10 }, .idle_timeout_ms = idle_timeout_ms },
        };
    }

    fn count(t: *Trickle) usize {
        t.mutex.lockUncancelable(io);
        defer t.mutex.unlock(io);
        return t.requests;
    }

    fn serve(t: *Trickle) Io.Cancelable!void {
        var group: Io.Group = .init;
        defer group.cancel(io);
        while (true) {
            const stream = t.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            group.concurrent(io, connection, .{ t, stream }) catch stream.close(io);
        }
    }

    fn connection(t: *Trickle, stream: Io.net.Stream) Io.Cancelable!void {
        defer stream.close(io);
        var in_buf: [16384]u8 = undefined;
        var out_buf: [256]u8 = undefined;
        var in = stream.reader(io, &in_buf);
        var out = stream.writer(io, &out_buf);
        var http: std.http.Server = .init(&in.interface, &out.interface);
        _ = http.receiveHead() catch return;
        t.mutex.lockUncancelable(io);
        t.requests += 1;
        const n = t.requests;
        t.mutex.unlock(io);
        const w = &out.interface;
        w.print("HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.len}) catch return;
        w.flush() catch return;
        if (t.stall and n == 1) return io.sleep(.fromMilliseconds(3000), .awake);
        var at: usize = 0;
        while (at < body.len) : (at += piece) {
            if (!t.stall) try io.sleep(.fromMilliseconds(gap_ms), .awake);
            w.writeAll(body[at..][0..piece]) catch return;
            w.flush() catch return;
        }
    }
};

test "AC-10: an answer that keeps arriving runs past idle_timeout_ms on its first try, while a head followed by silence fails the try and the call retries" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    {
        // 24 pieces 40 ms apart: about 1 s, four times the idle timeout.
        var t: Trickle = undefined;
        try t.start(false);
        defer t.stop();
        const started = Io.Clock.awake.now(io);
        const res = try t.client(250).get(io, a, "dict/latest");
        const took = started.untilNow(io, .awake).toMilliseconds();
        try expectEqual(.ok, res.status);
        try expectEqualStrings(Trickle.body, res.body);
        try expectEqual(1, t.count());
        try expect(took >= 4 * 250 - 100);
    }
    {
        var t: Trickle = undefined;
        try t.start(true);
        defer t.stop();
        const started = Io.Clock.awake.now(io);
        const res = try t.client(200).get(io, a, "dict/latest");
        const took = started.untilNow(io, .awake).toMilliseconds();
        try expectEqual(.ok, res.status);
        try expectEqualStrings(Trickle.body, res.body);
        try expectEqual(2, t.count());
        try expect(took < 2500);
    }
}

test "chaos: under seeded Speechify faults a narrate succeeds or exits 1, never a narration that disagrees with its files, and a clean rerun converges" {
    // Seeds from the runner's --seed, as in cli_publish.zig's chaos test.
    for (0..3) |i| {
        const seed: u64 = (@as(u64, std.testing.random_seed) << 8) | i;
        errdefer std.debug.print("chaos: failed with seed {d} (runner --seed=0x{x})\n", .{ seed, std.testing.random_seed });
        var w: World = undefined;
        try w.start(.{ .chaos = seed });
        defer w.stop();
        const a = w.arena.allocator();
        const path = try w.folder(story_template);

        const run = try w.run("narrate", &.{path});
        w.f.mutex.lockUncancelable(io);
        const faults = w.f.faults;
        w.f.options.chaos = null;
        w.f.mutex.unlock(io);
        std.debug.print("chaos: seed {d}: {d} faults, exit {d}\n", .{ seed, faults, run.code });
        try expect(run.code == 0 or run.code == 1);
        // A narration in story.json always matches the files beside it; a failed run writes none.
        const it = (try w.read()).translations.map.get("it") orelse return error.TestNoItalian;
        if (run.code == 0) {
            try w.expectFiles(try pcm(a, word_count, 100, 440));
            try expectAudio(it, 100, times(100));
        } else try expect(it.audio == null);

        const again = try w.run("narrate", &.{path});
        try expectEqual(0, again.code);
        try w.expectFiles(try pcm(a, word_count, 100, 440));
        try expectAudio((try w.read()).translations.map.get("it"), 100, times(100));
    }
}
