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

var cached: ?FakeSpeechify.Reply = null;
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

    const Options = struct {
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
        const reply = f.receive(&request) catch return;
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
        if (cached) |c| return c;
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
        // Bench: one chunk per word, its slice of the audio and its mark (the last chunk takes the tail).
        for (ws, 0..) |word, k| {
            const lo = k * o.word_ms * 48 * 2;
            const hi = if (k == ws.len - 1) bytes.len else (k + 1) * o.word_ms * 48 * 2;
            const slot: u32 = @intCast(k * o.word_ms);
            try events.append(a, try event(a, "speech.chunk", try std.fmt.allocPrint(a, "{{\"type\":\"speech.chunk\",\"audio\":\"{s}\",\"speech_marks\":[{{\"type\":\"word\",\"start\":{d},\"end\":{d},\"start_time\":{d},\"end_time\":{d},\"value\":{s}}}]}}", .{
                try base64(a, bytes[lo..hi]), word.start, word.end, slot + 10, slot + o.word_ms - 20, try std.json.Stringify.valueAlloc(a, word.value, .{}),
            })));
        }
        try events.append(a, try event(a, "speech.done", try std.fmt.allocPrint(a, "{{\"type\":\"speech.done\",\"billable_characters_count\":{d},\"audio_duration_ms\":{d}}}", .{
            try std.unicode.utf8CountCodepoints(req.input), samples.len / 48,
        })));
        if (answer == .drop) return .{ .events = try a.dupe([]const u8, &.{ events.items[0], events.items[1], events.items[2][0 .. events.items[2].len / 2] }), .chunked = false };
        cached = .{ .events = events.items };
        return cached.?;
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


/// Counts what passes through to page_allocator: calls, live bytes and the peak.
const Counting = struct {
    calls: usize = 0,
    live: usize = 0,
    peak: usize = 0,
    fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    var log: bool = false;
    fn note(self: *Counting, old: usize, new: usize) void {
        if (log) std.debug.print("BACKING op old={d} new={d} live_MiB={d:.1}\n", .{ old, new, @as(f64, @floatFromInt(self.live - old + new)) / (1024 * 1024) });
        self.calls += 1;
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(p: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(p));
        const r = std.heap.page_allocator.rawAlloc(len, al, ra) orelse return null;
        self.note(0, len);
        return r;
    }
    fn resize(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(p));
        if (!std.heap.page_allocator.rawResize(m, al, n, ra)) return false;
        self.note(m.len, n);
        return true;
    }
    fn remap(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(p));
        const r = std.heap.page_allocator.rawRemap(m, al, n, ra) orelse return null;
        self.note(m.len, n);
        return r;
    }
    fn free(p: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(p));
        std.heap.page_allocator.rawFree(m, al, ra);
        self.note(m.len, 0);
    }
};

/// VmRSS or VmHWM from /proc/self/status, in KiB.
fn procKiB(field: []const u8) !u64 {
    var buf: [8192]u8 = undefined;
    const text = try Io.Dir.cwd().readFile(io, "/proc/self/status", &buf);
    const at = std.mem.find(u8, text, field).? + field.len + 1;
    var it = std.mem.tokenizeAny(u8, text[at..], " \t");
    return std.fmt.parseInt(u64, it.next().?, 10);
}
fn resetHwm() !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "/proc/self/clear_refs", .data = "5" });
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "bench: narrate a 20,000-character Italian story (rule 8 maximum), ~20 min of audio" {
    const word_ms = 350;
    var w: World = undefined;
    try w.start(.{ .word_ms = word_ms });
    defer w.stop();
    const a = w.arena.allocator();

    // 20 paragraphs of 13 sentences, each sentence 76 code points with accented letters.
    const sentence = "Il vecchio pescatore guard\u{f2} il mare calmo, poi torn\u{f2} verso la citt\u{e0} gi\u{e0}.";
    var json: Io.Writer.Allocating = .init(a);
    try json.writer.writeAll(story_template[0 .. std.mem.find(u8, story_template, "\"paragraphs\"").? + 13]);
    try json.writer.writeAll(" [");
    var cps: usize = 0;
    var sentences: usize = 0;
    for (0..20) |pi| {
        try json.writer.writeAll(if (pi > 0) ", [" else "[");
        for (0..13) |si| {
            try json.writer.print("{s}\"{s}\"", .{ if (si > 0) ", " else "", sentence });
            cps += try std.unicode.utf8CountCodepoints(sentence);
            sentences += 1;
        }
        try json.writer.writeAll("]");
    }
    try json.writer.writeAll("]}\n  }\n}\n");
    const path = try w.folder(json.written());

    // Run 1 warms the fake (it builds and caches the stream); runs 2..4 are measured.
    const r = try w.run("narrate", &.{path});
    if (r.code != 0) std.debug.print("{s}\n", .{r.out});
    try expectEqual(0, r.code);
    const body_bytes = blk: {
        var n: usize = 0;
        for (cached.?.events) |e| n += e.len;
        break :blk n;
    };

    var best_total: u64 = std.math.maxInt(u64);
    var counting: Counting = .{};
    var narrate_touched: u64 = 0;
    var encode_touched: u64 = 0;
    for (0..3) |ri| {
        _ = ri;
        counting = .{};
        var arena: std.heap.ArenaAllocator = .init(counting.allocator());
        defer arena.deinit();
        const argv = [_][:0]const u8{ "postilla", "narrate", path };
        const output = try w.tmp.dir.createFile(io, "output.txt", .{ .read = true });
        const saved = std.c.dup(2);
        _ = std.c.dup2(output.handle, 2);
        try resetHwm();
        const rss0 = try procKiB("VmRSS:");
        const t0 = nowNs();
        const code = cli.run(io, arena.allocator(), &w.env, w.tmp.dir, &argv);
        const t1 = nowNs();
        narrate_touched = (try procKiB("VmHWM:")) - rss0;
        _ = std.c.dup2(saved, 2);
        _ = std.c.close(saved);
        output.close(io);
        try expectEqual(0, code);
        best_total = @min(best_total, t1 - t0);
    }

    // audio.encode alone (pre-existing) on the same PCM, best of 3.
    const s = try w.read();
    const it = s.translations.map.get("it").?;
    const all = try pcm(gpa, 260 * 13, word_ms, 440);
    defer gpa.free(all);
    var best_encode: u64 = std.math.maxInt(u64);
    var enc_count: Counting = .{};
    for (0..3) |_| {
        enc_count = .{};
        var arena: std.heap.ArenaAllocator = .init(enc_count.allocator());
        defer arena.deinit();
        try resetHwm();
        const rss0 = try procKiB("VmRSS:");
        const t0 = nowNs();
        _ = try audio.encode(arena.allocator(), all, 48000);
        encode_touched = (try procKiB("VmHWM:")) - rss0;
        best_encode = @min(best_encode, nowNs() - t0);
    }

    // The flagged input/starts loop (cli.zig:278-283) alone, best of 3.
    var best_starts: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const t0 = nowNs();
        var input: Io.Writer.Allocating = .init(aa);
        var starts: std.ArrayList(usize) = .empty;
        for (it.paragraphs, 0..) |p, i| for (p, 0..) |sx, j| {
            try input.writer.writeAll(if (j > 0) " " else if (i > 0) "\n" else "");
            try starts.append(aa, try std.unicode.utf8CountCodepoints(input.written()));
            try input.writer.writeAll(sx);
        };
        std.mem.doNotOptimizeAway(starts.items.ptr);
        best_starts = @min(best_starts, nowNs() - t0);
    }

    var ru: std.c.rusage = undefined;
    _ = std.c.getrusage(0, &ru);
    std.debug.print(
        \\BENCH code_points={d} sentences={d} words={d} audio_ms={d} sse_body_bytes={d} events={d}
        \\BENCH narrate_total_ms(best of 3)={d:.1}
        \\BENCH audio_encode_ms(best of 3, pre-existing)={d:.1}
        \\BENCH narrate_minus_encode_ms={d:.1}
        \\BENCH input_starts_loop_us(best of 3)={d:.1}
        \\BENCH backing_alloc_calls(last run)={d} backing_peak_MiB={d:.1}
        \\BENCH encode_backing_peak_MiB={d:.1} encode_calls={d}
        \\BENCH narrate_rss_peak_delta_MiB(last run)={d:.1} encode_rss_peak_delta_MiB={d:.1}
        \\BENCH process_maxrss_MiB={d:.1}
        \\
    , .{
        cps,                                                       sentences,                                      it.paragraphs.len * 13 * 13, it.audio.?.audio_ms, body_bytes, cached.?.events.len,
        @as(f64, @floatFromInt(best_total)) / 1e6,
        @as(f64, @floatFromInt(best_encode)) / 1e6,
        @as(f64, @floatFromInt(best_total -| best_encode)) / 1e6,
        @as(f64, @floatFromInt(best_starts)) / 1e3,
        counting.calls, @as(f64, @floatFromInt(counting.peak)) / (1024 * 1024),
        @as(f64, @floatFromInt(enc_count.peak)) / (1024 * 1024), enc_count.calls,
        @as(f64, @floatFromInt(narrate_touched)) / 1024, @as(f64, @floatFromInt(encode_touched)) / 1024,
        @as(f64, @floatFromInt(ru.maxrss)) / 1024,
    });
}
