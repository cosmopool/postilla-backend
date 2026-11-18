//! `postilla translate <folder> [--force] [--redo <lang>]` end to end
//! (docs/specification.md, `postilla translate`): `cli.run` runs in-process with a temp
//! directory as its current directory, against the real server (harness) for the lists and
//! a fake OpenCode on a free port for Jev and DeepSeek. `args` are the command's arguments
//! after `postilla translate`. What the command prints, on stdout or stderr, is read back by
//! pointing both at a file while it runs.
//!
//! The fake OpenCode keeps every request it is sent. Jev answers the scores it is given (or
//! a fixed status, or a fixed body); DeepSeek answers each paragraph with its Italian
//! sentences each prefixed by `(pt) `, after the bad replies it is given for one paragraph,
//! or a fixed status.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("cli");
const harness = @import("harness");
const Harness = harness.Harness;

const io = std.testing.io;
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const opencode_key = "test-opencode-key";
const jev_path = "/systemone/v1/systemone";
const chat_path = "/go/v1/chat/completions";

const it_title = "Il gatto e la porta";
const it_subtitle = "Una storia di casa";
const it_paragraphs: []const []const []const u8 = &.{
    &.{ "Il gatto entra in casa.", "Apre la porta." },
    &.{"Fuori c'\u{e8} aria di festa."},
    &.{ "La gatta dorme.", "Il cane abbaia.", "Tutti ridono." },
};
/// What Jev reads: the title, the subtitle, then each paragraph's sentences joined by one
/// space, each on its own line.
const it_state = it_title ++ "\n" ++ it_subtitle ++ "\nIl gatto entra in casa. Apre la porta.\nFuori c'\u{e8} aria di festa.\nLa gatta dorme. Il cane abbaia. Tutti ridono.";

const it_member =
    \\"it": {"title": "Il gatto e la porta", "subtitle": "Una storia di casa", "paragraphs": [["Il gatto entra in casa.", "Apre la porta."], ["Fuori c'è aria di festa."], ["La gatta dorme.", "Il cane abbaia.", "Tutti ridono."]]}
;
/// A pt-BR written by hand, with the Italian's paragraph and sentence counts.
const hand_pt_member =
    \\"pt-BR": {"title": "O gato e a porta", "subtitle": "Uma história de casa", "paragraphs": [["O gato entra em casa.", "Abre a porta."], ["Lá fora há ar de festa."], ["A gata dorme.", "O cão late.", "Todos riem."]]}
;
/// A story that passes every check, at level 3 (B1), with only the Italian and no
/// moderation yet.
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

/// `story_template` with each edit's first string, which must occur exactly once, replaced
/// by its second.
fn story(a: Allocator, edits: []const [2][]const u8) ![]const u8 {
    var json: []const u8 = story_template;
    for (edits) |e| {
        try expectEqual(1, std.mem.count(u8, json, e[0]));
        json = try std.mem.replaceOwned(u8, a, json, e[0], e[1]);
    }
    return json;
}

/// The system message for pt-BR at level 3.
const system_b1 =
    \\You translate short Italian stories into Brazilian Portuguese for Brazilian Portuguese speakers learning Italian.
    \\
    \\- Write natural Brazilian Portuguese, the way a native writer would, not word for word.
    \\- Keep each sentence's meaning inside that sentence. Never move, merge or split content between sentences.
    \\- Keep the names of people and places as they are in the Italian.
    \\- The story is CEFR level B1. Keep the Brazilian Portuguese as simple as the Italian.
    \\- The user message is a JSON object with "title" (the story's title), "previous" (the previous paragraph's Italian sentences, for context only; do not translate them) and "sentences" (the Italian sentences to translate).
    \\- Reply with only a JSON array of strings: one Brazilian Portuguese sentence per Italian sentence, in the same order, the same count. No commentary, no code fences.
;

/// The question's options and their criteria, in order.
const criteria = [6][2][]const u8{
    .{ "none", "No hate speech: the text attacks no group for who they are" },
    .{ "homophobic", "Attacks or demeans people for their sexual orientation or gender identity" },
    .{ "racist", "Attacks or demeans people for their race, ethnicity or nationality" },
    .{ "sexist", "Attacks or demeans people for their sex or gender" },
    .{ "religious", "Attacks or demeans people for their religion" },
    .{ "other_hate", "Attacks or demeans another protected group, such as disabled people" },
};

/// Jev's probabilities for the options of `criteria`, in order.
const clean = [6]f64{ 0.98, 0.0, 0.01, 0.0, 0.0, 0.01 };
/// `P(none)` 0.5, `racist` the highest of the rest.
const flagged = [6]f64{ 0.5, 0.02, 0.4, 0.03, 0.01, 0.04 };

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
    moderation: ?Moderation = null,
    translations: std.json.ArrayHashMap(Translation),
};
const Moderation = struct { none: f64, homophobic: f64, racist: f64, sexist: f64, religious: f64, other_hate: f64, forced: bool };
const Translation = struct {
    title: []const u8,
    subtitle: []const u8,
    paragraphs: []const []const []const u8,
    audio: ?std.json.Value = null,
};

/// What a run of the command gave: its exit code and everything it printed.
const Run = struct { code: u8, out: []const u8 };

/// The world a translate runs in: the real server (which lists pt-BR with translate 1), a
/// fake OpenCode, and a temp directory that is the command's current directory, with the
/// story folder at `story/`.
const World = struct {
    h: Harness,
    f: FakeOpenCode,
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    /// The temp directory's absolute path.
    root: [:0]const u8,
    /// Every required variable, pointing at the server, and `POSTILLA_OPENCODE_URL` at the
    /// fake.
    env: std.process.Environ.Map,

    /// In place, since the running server and fake keep pointers into `w`.
    fn start(w: *World, options: FakeOpenCode.Options) !void {
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
        try w.env.put("POSTILLA_OPENCODE_KEY", opencode_key);
        try w.env.put("POSTILLA_OPENCODE_URL", w.f.base);
        try w.env.put("POSTILLA_SPEECHIFY_KEY", "test-speechify-key");
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

    /// Runs `postilla translate <args>` with `w.env`, stdout and stderr captured.
    fn translate(w: *World, args: []const [:0]const u8) !Run {
        const a = w.arena.allocator();
        const argv = try std.mem.concat(a, [:0]const u8, &.{ &.{ "postilla", "translate" }, args });
        const file = try w.tmp.dir.createFile(io, "output.txt", .{ .read = true });
        defer file.close(io);
        const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
        _ = std.c.dup2(file.handle, 1);
        _ = std.c.dup2(file.handle, 2);
        const code: u8 = cli.run(io, a, &w.env, w.tmp.dir, argv);
        _ = std.c.dup2(saved[0], 1);
        _ = std.c.dup2(saved[1], 2);
        for (saved) |fd| _ = std.c.close(fd);
        return .{ .code = code, .out = try w.tmp.dir.readFileAlloc(io, "output.txt", a, .limited(1 << 20)) };
    }

    /// `story/story.json` as it is on disk.
    fn bytes(w: *World) ![]const u8 {
        return w.tmp.dir.readFileAlloc(io, "story/story.json", w.arena.allocator(), .limited(1 << 20));
    }

    /// `story/story.json` parsed, failing when it breaks rule 1.
    fn read(w: *World) !Story {
        return std.json.parseFromSliceLeaky(Story, w.arena.allocator(), try w.bytes(), .{});
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

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try expectEqual(want.len, got.len);
    for (want, got) |x, y| try expectEqualStrings(x, y);
}

/// `m` holds `scores`, in the order of `criteria`, and `forced`.
fn expectScores(m: ?Moderation, scores: [6]f64, forced: bool) !void {
    const got = m orelse return error.TestNoModeration;
    try expectEqual(scores, [6]f64{ got.none, got.homophobic, got.racist, got.sexist, got.religious, got.other_hate });
    try expectEqual(forced, got.forced);
}

/// `s` is the story_template's header and Italian, unchanged.
fn expectHeader(s: Story) !void {
    try expectEqualStrings("d0159518-99cc-46f0-bef2-b5b6f6f9a76d", s.id);
    try expectEqual(3, s.level);
    try expectEqualStrings("classici", s.genre);
    try expectEqual(0, s.tags.len);
    try expectEqualStrings("Pinocchio", s.work);
    try expectEqual(1, s.part);
    try expectEqualStrings("collodi", s.author);
    try expectEqual(1, s.adapted);
    try expectEqualStrings("public-domain", s.license);
    const it = s.translations.map.get("it") orelse return error.TestNoItalian;
    try expectEqualStrings(it_title, it.title);
    try expectEqualStrings(it_subtitle, it.subtitle);
    try expectEqual(it_paragraphs.len, it.paragraphs.len);
    for (it_paragraphs, it.paragraphs) |want, got| try expectStrings(want, got);
}

/// `t` is the fake DeepSeek's translation of the Italian: every sentence, title and
/// subtitle the Italian one prefixed by `(pt) `, in reading order.
fn expectTranslated(t: ?Translation) !void {
    const got = t orelse return error.TestNoTranslation;
    try expectEqualStrings("(pt) " ++ it_title, got.title);
    try expectEqualStrings("(pt) " ++ it_subtitle, got.subtitle);
    try expectEqual(it_paragraphs.len, got.paragraphs.len);
    for (it_paragraphs, got.paragraphs) |want, p| {
        try expectEqual(want.len, p.len);
        for (want, p) |s, g| {
            try expect(std.mem.startsWith(u8, g, "(pt) "));
            try expectEqualStrings(s, g[5..]);
        }
    }
}

/// The languages in `s.translations`, in file order, joined by spaces.
fn langs(a: Allocator, s: Story) ![]const u8 {
    return std.mem.join(a, " ", s.translations.map.keys());
}

/// What the fake saw of one request.
const Seen = struct {
    method: std.http.Method,
    target: []const u8,
    authorization: []const u8 = "",
    user_agent: []const u8 = "",
    session: []const u8 = "",
    body: []const u8 = "",
    /// A DeepSeek request's first Italian sentence; "" for any other.
    first: []const u8 = "",
};

const FakeOpenCode = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    /// `http://127.0.0.1:<port>`.
    root: []const u8,
    /// `root` plus `/inference`, as `POSTILLA_OPENCODE_URL`.
    base: []const u8,
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    options: Options,
    bad_sent: usize = 0,
    seen: std.ArrayList(Seen) = .empty,

    const Options = struct {
        /// Jev's probabilities, for the options of `criteria` in order.
        scores: [6]f64 = clean,
        /// Not ok: Jev answers this on every request (a 503 with `Retry-After: 0`).
        jev_status: std.http.Status = .ok,
        /// Not empty: Jev answers this body with a 200.
        jev_body: []const u8 = "",
        /// Not ok: DeepSeek answers this on every request.
        deepseek_status: std.http.Status = .ok,
        /// The paragraph, by its first Italian sentence, whose first replies are `bad`, in
        /// order, before the right one.
        bad_for: []const u8 = "",
        bad: []const Bad = &.{},
    };

    const Bad = enum {
        /// A JSON array of strings with one sentence too many.
        count,
        /// Prose, not JSON.
        text,
        /// The right array inside a code fence.
        fence,
    };

    /// In place, since the running fake keeps a pointer to `f`.
    fn start(f: *FakeOpenCode, options: Options) !void {
        f.* = .{ .listener = undefined, .task = undefined, .root = "", .base = "", .arena = .init(gpa), .options = options };
        errdefer f.arena.deinit();
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        f.listener = try address.listen(io, .{ .reuse_address = true });
        errdefer f.listener.deinit(io);
        const a = f.arena.allocator();
        f.root = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.listener.socket.address.getPort()});
        f.base = try std.fmt.allocPrint(a, "{s}/inference", .{f.root});
        f.task = try io.concurrent(serve, .{f});
    }

    fn stop(f: *FakeOpenCode) void {
        f.task.cancel(io) catch {};
        f.listener.deinit(io);
        f.arena.deinit();
    }

    /// The requests so far whose target ends with `path`, in the order they came.
    fn requests(f: *FakeOpenCode, a: Allocator, path: []const u8) ![]const Seen {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        var out: std.ArrayList(Seen) = .empty;
        for (f.seen.items) |s| if (std.mem.endsWith(u8, s.target, path)) try out.append(a, s);
        return out.items;
    }

    /// How many requests it has been sent, to any path.
    fn total(f: *FakeOpenCode) usize {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        return f.seen.items.len;
    }

    fn serve(f: *FakeOpenCode) Io.Cancelable!void {
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

    fn connection(f: *FakeOpenCode, stream: Io.net.Stream) Io.Cancelable!void {
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
            const retry_after = [_]std.http.Header{.{ .name = "retry-after", .value = "0" }};
            request.respond(answer.body, .{
                .status = answer.status,
                .keep_alive = keep_alive,
                .extra_headers = retry_after[0..@intFromBool(answer.status == .service_unavailable)],
            }) catch return;
            if (!keep_alive) return;
        }
    }

    const Answer = struct { status: std.http.Status = .ok, body: []const u8 = "" };

    /// Reads and records the request, then answers it as Jev, as DeepSeek, or with a 404.
    fn receive(f: *FakeOpenCode, request: *std.http.Server.Request) !Answer {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        var seen: Seen = .{ .method = request.head.method, .target = try a.dupe(u8, request.head.target) };
        var headers = request.iterateHeaders();
        while (headers.next()) |h| {
            const v = try a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) seen.authorization = v;
            if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) seen.user_agent = v;
            if (std.ascii.eqlIgnoreCase(h.name, "x-opencode-session")) seen.session = v;
        }
        const body = try a.alloc(u8, request.head.content_length orelse 0);
        if (body.len > 0) try (try request.readerExpectContinue(&.{})).readSliceAll(body);
        seen.body = body;

        if (std.mem.endsWith(u8, seen.target, jev_path)) {
            try f.seen.append(a, seen);
            if (f.options.jev_status != .ok) return .{ .status = f.options.jev_status };
            if (f.options.jev_body.len > 0) return .{ .body = f.options.jev_body };
            return .{ .body = try jev(a, f.options.scores) };
        }
        if (!std.mem.endsWith(u8, seen.target, chat_path)) {
            try f.seen.append(a, seen);
            return .{ .status = .not_found };
        }
        const sentences = italian(a, body) catch {
            try f.seen.append(a, seen);
            return .{ .status = .bad_request };
        };
        seen.first = if (sentences.len > 0) sentences[0] else "";
        try f.seen.append(a, seen);
        if (f.options.deepseek_status != .ok) return .{ .status = f.options.deepseek_status };
        var bad: ?Bad = null;
        if (f.options.bad_for.len > 0 and std.mem.eql(u8, seen.first, f.options.bad_for)) {
            if (f.bad_sent < f.options.bad.len) bad = f.options.bad[f.bad_sent];
            f.bad_sent += 1;
        }
        return .{ .body = try deepseek(a, sentences, bad) };
    }

    /// The Italian sentences in a chat request's user message.
    fn italian(a: Allocator, body: []const u8) ![]const []const u8 {
        const req = try std.json.parseFromSliceLeaky(struct {
            messages: []const struct { role: []const u8, content: []const u8 },
        }, a, body, .{ .ignore_unknown_fields = true });
        for (req.messages) |m| {
            if (!std.mem.eql(u8, m.role, "user")) continue;
            const user = try std.json.parseFromSliceLeaky(struct { sentences: []const []const u8 }, a, m.content, .{ .ignore_unknown_fields = true });
            return user.sentences;
        }
        return error.NoUserMessage;
    }

    /// Jev's answer, in the shape of `.work/fixtures/jev_response.json`.
    fn jev(a: Allocator, p: [6]f64) ![]const u8 {
        var top: usize = 0;
        for (p, 0..) |x, i| {
            if (x > p[top]) top = i;
        }
        return std.fmt.allocPrint(a,
            \\{{"model":"jev-1.13","answers":{{"hate":{{"type":"choice","choice":"{s}","confidence":{d},"probabilities":{{"none":{d},"homophobic":{d},"racist":{d},"sexist":{d},"religious":{d},"other_hate":{d}}}}}}},"usage":{{"input_tokens":468,"output_tokens":67,"cost":0.00001966}}}}
        , .{ criteria[top][0], p[top], p[0], p[1], p[2], p[3], p[4], p[5] });
    }

    /// DeepSeek's answer, in the shape of `.work/fixtures/deepseek_go_response.json`: every
    /// sentence prefixed by `(pt) `, or the `bad` reply.
    fn deepseek(a: Allocator, sentences: []const []const u8, bad: ?Bad) ![]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (sentences) |s| try out.append(a, try std.fmt.allocPrint(a, "(pt) {s}", .{s}));
        if (bad == .count) try out.append(a, "(pt) Uma frase a mais.");
        const array = try std.json.Stringify.valueAlloc(a, out.items, .{});
        const content: []const u8 = if (bad) |b| switch (b) {
            .count => array,
            .text => "Aqui está a tradução do parágrafo.",
            .fence => try std.fmt.allocPrint(a, "```json\n{s}\n```", .{array}),
        } else array;
        return std.fmt.allocPrint(a,
            \\{{"id":"gw-test","object":"chat.completion","created":1795019615,"model":"deepseek-v4.1-flash","choices":[{{"index":0,"finish_reason":"stop","message":{{"role":"assistant","content":{s},"reasoning_content":"Translate each Italian sentence."}}}}],"usage":{{"prompt_tokens":245,"completion_tokens":281,"total_tokens":526}}}}
        , .{try std.json.Stringify.valueAlloc(a, content, .{})});
    }
};

test "AC-1, AC-2, AC-3: a story with only the Italian is moderated by Jev and translated into pt-BR paragraph by paragraph, title first; a rerun sends nothing and leaves story.json byte for byte" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const path = try w.folder(try story(a, &.{}));

    const run = try w.translate(&.{path});
    if (run.code != 0) std.debug.print("{s}\n", .{run.out});
    try expectEqual(0, run.code);

    // AC-1: the scores with forced false, then the translation in reading order, after the
    // Italian.
    const s = try w.read();
    try expectHeader(s);
    try expectScores(s.moderation, clean, false);
    try expectEqualStrings("it pt-BR", try langs(a, s));
    try expectTranslated(s.translations.map.get("pt-BR"));

    // AC-2: one Jev request.
    const jev = try w.f.requests(a, jev_path);
    try expectEqual(1, jev.len);
    try expectEqual(.POST, jev[0].method);
    try expectEqualStrings("/inference" ++ jev_path, jev[0].target);
    try expectEqualStrings("Bearer " ++ opencode_key, jev[0].authorization);
    try expectEqualStrings("postilla/1.0", jev[0].user_agent);
    const moderation = try std.json.parseFromSliceLeaky(struct {
        model: []const u8,
        state: []const u8,
        questions: std.json.ArrayHashMap(struct {
            type: []const u8,
            instructions: []const u8,
            criteria: std.json.ArrayHashMap([]const u8),
        }),
    }, a, jev[0].body, .{ .ignore_unknown_fields = true });
    try expectEqualStrings("jev-1.13", moderation.model);
    try expectEqualStrings(it_state, moderation.state);
    try expectEqual(1, moderation.questions.map.count());
    const hate = moderation.questions.map.get("hate") orelse return error.TestNoHateQuestion;
    try expectEqualStrings("choice", hate.type);
    try expectEqualStrings("Does this Italian text contain hate speech? Pick the kind, or none.", hate.instructions);
    try expectEqual(criteria.len, hate.criteria.map.count());
    for (criteria) |c| try expectEqualStrings(c[1], hate.criteria.map.get(c[0]) orelse return error.TestMissingCriterion);

    // AC-2: the title paragraph, then each paragraph with the Italian one before it, all in
    // one session.
    const sent: []const []const []const u8 = &.{ &.{ it_title, it_subtitle }, it_paragraphs[0], it_paragraphs[1], it_paragraphs[2] };
    const previous: []const []const []const u8 = &.{ &.{}, &.{}, it_paragraphs[0], it_paragraphs[1] };
    const chat = try w.f.requests(a, chat_path);
    try expectEqual(sent.len, chat.len);
    try expect(chat[0].session.len > 0);
    for (chat, sent, previous) |r, sentences, prev| {
        try expectEqual(.POST, r.method);
        try expectEqualStrings("/inference" ++ chat_path, r.target);
        try expectEqualStrings("Bearer " ++ opencode_key, r.authorization);
        try expectEqualStrings("postilla/1.0", r.user_agent);
        try expectEqualStrings(chat[0].session, r.session);
        const req = try std.json.parseFromSliceLeaky(struct {
            model: []const u8,
            temperature: f64,
            messages: []const struct { role: []const u8, content: []const u8 },
        }, a, r.body, .{ .ignore_unknown_fields = true });
        try expectEqualStrings("deepseek-v4.1-flash", req.model);
        try expectEqual(0.3, req.temperature);
        try expectEqual(2, req.messages.len);
        try expectEqualStrings("system", req.messages[0].role);
        try expectEqualStrings(system_b1, req.messages[0].content);
        try expectEqualStrings("user", req.messages[1].role);
        const user = try std.json.parseFromSliceLeaky(struct {
            title: []const u8,
            previous: []const []const u8,
            sentences: []const []const u8,
        }, a, req.messages[1].content, .{});
        try expectEqualStrings(it_title, user.title);
        try expectStrings(prev, user.previous);
        try expectStrings(sentences, user.sentences);
    }

    // AC-3: pt-BR is there now, so a rerun has nothing to do.
    const before = try w.bytes();
    const sent_before = w.f.total();
    const again = try w.translate(&.{path});
    try expectEqual(0, again.code);
    try expectEqual(sent_before, w.f.total());
    try expectEqualStrings(before, try w.bytes());
}

test "AC-3: a story whose translations already has pt-BR, written by hand, exits 0 without moderating, and story.json is byte for byte unchanged" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const json = try story(a, &.{.{ it_member, it_member ++ ",\n    " ++ hand_pt_member }});
    const path = try w.folder(json);

    const run = try w.translate(&.{path});
    try expectEqual(0, run.code);
    try expectEqual(0, w.f.total());
    try expectEqualStrings(json, try w.bytes());
}

test "AC-4, AC-5: a text Jev flags is rejected, printing the six scores and the top option, with the scores written and nothing translated; --force moderates again and translates with forced true" {
    var w: World = undefined;
    try w.start(.{ .scores = flagged });
    defer w.stop();
    const a = w.arena.allocator();
    const path = try w.folder(try story(a, &.{}));

    // AC-4
    const rejected = try w.translate(&.{path});
    try expectEqual(1, rejected.code);
    for ([_][]const u8{ "racist", "0.5", "0.02", "0.4", "0.03", "0.01", "0.04" }) |word| try expectSays(rejected.out, word);
    try expectEqual(1, (try w.f.requests(a, jev_path)).len);
    try expectEqual(0, (try w.f.requests(a, chat_path)).len);
    const after = try w.read();
    try expectHeader(after);
    try expectScores(after.moderation, flagged, false);
    try expectEqualStrings("it", try langs(a, after));

    // AC-5
    const forced = try w.translate(&.{ path, "--force" });
    if (forced.code != 0) std.debug.print("{s}\n", .{forced.out});
    try expectEqual(0, forced.code);
    try expectEqual(2, (try w.f.requests(a, jev_path)).len);
    const s = try w.read();
    try expectHeader(s);
    try expectScores(s.moderation, flagged, true);
    try expectEqualStrings("it pt-BR", try langs(a, s));
    try expectTranslated(s.translations.map.get("pt-BR"));
}

test "AC-6, AC-5: POSTILLA_MODERATION_THRESHOLD lowers the bar so P(none) 0.5 passes; at the default 0.9 a P(none) of exactly 0.9 passes, with or without --force, and forced stays false" {
    var w: World = undefined;
    try w.start(.{ .scores = flagged });
    defer w.stop();
    const a = w.arena.allocator();

    try w.env.put("POSTILLA_MODERATION_THRESHOLD", "0.4");
    const lowered = try w.translate(&.{try w.folder(try story(a, &.{}))});
    if (lowered.code != 0) std.debug.print("{s}\n", .{lowered.out});
    try expectEqual(0, lowered.code);
    const s = try w.read();
    try expectScores(s.moderation, flagged, false);
    try expectTranslated(s.translations.map.get("pt-BR"));

    try expect(w.env.swapRemove("POSTILLA_MODERATION_THRESHOLD"));
    const edge = [6]f64{ 0.9, 0.02, 0.04, 0.02, 0.01, 0.01 };
    w.f.options.scores = edge;
    for ([_][]const [:0]const u8{ &.{}, &.{"--force"} }) |flags| {
        const path = try w.folder(try story(a, &.{}));
        const run = try w.translate(try std.mem.concat(a, [:0]const u8, &.{ &.{path}, flags }));
        if (run.code != 0) std.debug.print("{s}\n", .{run.out});
        try expectEqual(0, run.code);
        const t = try w.read();
        try expectScores(t.moderation, edge, false);
        try expectTranslated(t.translations.map.get("pt-BR"));
    }
}

test "AC-7: --redo pt-BR replaces a hand-edited pt-BR with DeepSeek's translation, back after the Italian; --redo of a language without translate 1 exits 1 sending no OpenCode request" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    // pt-BR first in the file.
    const hand = try story(a, &.{.{ it_member, hand_pt_member ++ ",\n    " ++ it_member }});

    for ([_][:0]const u8{ "it", "xx", "en" }) |lang| {
        const path = try w.folder(hand);
        const run = try w.translate(&.{ path, "--redo", lang });
        try expectEqual(1, run.code);
        try expectEqual(0, w.f.total());
        try expectEqualStrings(hand, try w.bytes());
    }

    const run = try w.translate(&.{ try w.folder(hand), "--redo", "pt-BR" });
    if (run.code != 0) std.debug.print("{s}\n", .{run.out});
    try expectEqual(0, run.code);
    try expectEqual(1, (try w.f.requests(a, jev_path)).len);
    const s = try w.read();
    try expectHeader(s);
    try expectScores(s.moderation, clean, false);
    try expectEqualStrings("it pt-BR", try langs(a, s));
    try expectTranslated(s.translations.map.get("pt-BR"));
}

test "AC-8: a paragraph whose reply has the wrong sentence count, isn't JSON or is fenced is tried again, up to 3 tries; after a third bad reply the command stops naming the language and paragraph, keeping the scores and writing no pt-BR" {
    const recovered = [_]FakeOpenCode.Options{
        // Paragraph 1: the wrong count, then right.
        .{ .bad_for = it_paragraphs[0][0], .bad = &.{.count} },
        // The title paragraph: prose, a fenced array, then right on the third try.
        .{ .bad_for = it_title, .bad = &.{ .text, .fence } },
    };
    for (recovered) |options| {
        var w: World = undefined;
        try w.start(options);
        defer w.stop();
        const a = w.arena.allocator();

        const run = try w.translate(&.{try w.folder(try story(a, &.{}))});
        if (run.code != 0) std.debug.print("{s}\n", .{run.out});
        try expectEqual(0, run.code);
        const s = try w.read();
        try expectScores(s.moderation, clean, false);
        try expectTranslated(s.translations.map.get("pt-BR"));
        var tries: usize = 0;
        for (try w.f.requests(a, chat_path)) |r| tries += @intFromBool(std.mem.eql(u8, r.first, options.bad_for));
        try expectEqual(options.bad.len + 1, tries);
    }

    // Paragraph 2 is answered badly every time.
    var w: World = undefined;
    try w.start(.{ .bad_for = it_paragraphs[1][0], .bad = &.{ .count, .text, .count, .count, .count } });
    defer w.stop();
    const a = w.arena.allocator();

    const run = try w.translate(&.{try w.folder(try story(a, &.{}))});
    try expectEqual(1, run.code);
    try expectSays(run.out, "pt-BR: paragraph 2");
    var tries: usize = 0;
    for (try w.f.requests(a, chat_path)) |r| tries += @intFromBool(std.mem.eql(u8, r.first, it_paragraphs[1][0]));
    try expectEqual(3, tries);
    const s = try w.read();
    try expectHeader(s);
    try expectScores(s.moderation, clean, false);
    try expectEqualStrings("it", try langs(a, s));
}

test "AC-9: a story.json that breaks a rule exits 1 naming it, sends no OpenCode request and leaves story.json as it was" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();

    const cases = [_]struct { edit: [2][]const u8, says: []const u8 }{
        .{ .edit = .{ "\"genre\": \"classici\"", "\"genre\": \"\"" }, .says = "genre" },
        .{ .edit = .{ "\"level\": 3", "\"level\": 7" }, .says = "level" },
        .{ .edit = .{ "\"Apre la porta.\"", "\"\"" }, .says = "story.json" },
        .{ .edit = .{ it_member, it_member ++ ",\n    " ++ "\"pt-BR\": {\"title\": \"O gato\", \"subtitle\": \"Uma história\", \"paragraphs\": [[\"O gato entra em casa.\"]]}" }, .says = "pt-BR" },
    };
    for (cases) |case| {
        const json = try story(a, &.{case.edit});
        const run = try w.translate(&.{try w.folder(json)});
        try expectEqual(1, run.code);
        try expectSays(run.out, "story.json");
        try expectSays(run.out, case.says);
        try expectEqualStrings(json, try w.bytes());
    }
    try expectEqual(0, w.f.total());
}

test "AC-10: no folder, an unknown flag, a repeated flag or --redo without a language exits 2 printing the usage, sending no OpenCode request" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const json = try story(a, &.{});
    const path = try w.folder(json);

    const cases = [_][]const [:0]const u8{
        &.{},
        &.{ path, "--fast" },
        &.{ path, "--force", "--force" },
        &.{ path, "--redo" },
    };
    for (cases) |args| {
        const run = try w.translate(args);
        try expectEqual(2, run.code);
        try expectSays(run.out, "usage");
        try expectSays(run.out, "translate <folder>");
    }
    try expectEqual(0, w.f.total());
    try expectEqualStrings(json, try w.bytes());
}

test "AC-F1: Jev answering 503 on every try stops the command after 4 tries naming moderation and the status, with no DeepSeek request and story.json unchanged" {
    var w: World = undefined;
    try w.start(.{ .jev_status = .service_unavailable });
    defer w.stop();
    const a = w.arena.allocator();
    const json = try story(a, &.{});

    const run = try w.translate(&.{try w.folder(json)});
    try expectEqual(1, run.code);
    try expectSays(run.out, "moderation");
    try expectNumber(run.out, 503);
    try expectEqual(4, (try w.f.requests(a, jev_path)).len);
    try expectEqual(0, (try w.f.requests(a, chat_path)).len);
    try expectEqualStrings(json, try w.bytes());
}

test "AC-F2: DeepSeek answering 401 stops the command after one request naming pt-BR and the status, keeping the moderation scores and writing no pt-BR" {
    var w: World = undefined;
    try w.start(.{ .deepseek_status = .unauthorized });
    defer w.stop();
    const a = w.arena.allocator();

    const run = try w.translate(&.{try w.folder(try story(a, &.{}))});
    try expectEqual(1, run.code);
    try expectSays(run.out, "pt-BR");
    try expectNumber(run.out, 401);
    try expectEqual(1, (try w.f.requests(a, chat_path)).len);
    const s = try w.read();
    try expectHeader(s);
    try expectScores(s.moderation, clean, false);
    try expectEqualStrings("it", try langs(a, s));
}

test "AC-F3: a Jev reply that isn't the expected JSON stops the command naming moderation, with no DeepSeek request and story.json unchanged" {
    const bodies = [_][]const u8{
        "upstream gateway error, not JSON",
        \\{"model":"jev-1.13","answers":{}}
        ,
        \\{"model":"jev-1.13","answers":{"hate":{"type":"choice","choice":"none","confidence":1,"probabilities":{"none":1,"homophobic":0,"racist":0,"sexist":0,"religious":0}}}}
        ,
    };
    for (bodies) |body| {
        var w: World = undefined;
        try w.start(.{ .jev_body = body });
        defer w.stop();
        const a = w.arena.allocator();
        const json = try story(a, &.{});

        const run = try w.translate(&.{try w.folder(json)});
        try expectEqual(1, run.code);
        try expectSays(run.out, "moderation");
        try expectEqual(1, (try w.f.requests(a, jev_path)).len);
        try expectEqual(0, (try w.f.requests(a, chat_path)).len);
        try expectEqualStrings(json, try w.bytes());
    }
}

test "AC-F4: a POSTILLA_MODERATION_THRESHOLD that isn't a number from 0 to 1, or a POSTILLA_OPENCODE_URL without ://, exits 1 naming the variable before any request" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const json = try story(a, &.{});
    const path = try w.folder(json);
    // The lists come from the fake too, so a request to the server would show.
    try w.env.put("POSTILLA_SERVER_URL", w.f.root);

    const cases = [_][2][]const u8{
        .{ "POSTILLA_MODERATION_THRESHOLD", "abc" },
        .{ "POSTILLA_MODERATION_THRESHOLD", "1.5" },
        .{ "POSTILLA_OPENCODE_URL", "opencode.ai" },
    };
    for (cases) |case| {
        const saved = w.env.get(case[0]);
        const restore = if (saved) |v| try a.dupe(u8, v) else null;
        try w.env.put(case[0], case[1]);
        const run = try w.translate(&.{path});
        try expectEqual(1, run.code);
        try expectSays(run.out, case[0]);
        if (restore) |v| try w.env.put(case[0], v) else _ = w.env.swapRemove(case[0]);
    }
    try expectEqual(0, w.f.total());
    try expectEqualStrings(json, try w.bytes());
}

test "AC-F5: a story folder where story.json can't be replaced exits 1 naming story.json, and the file is unchanged" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const json = try story(a, &.{});
    const path = try w.folder(json);
    try w.tmp.dir.setFilePermissions(io, "story", .fromMode(0o555), .{});
    defer w.tmp.dir.setFilePermissions(io, "story", .fromMode(0o755), .{}) catch {};

    const run = try w.translate(&.{path});
    try expectEqual(1, run.code);
    try expectSays(run.out, "story.json");
    try expectEqualStrings(json, try w.bytes());
}
