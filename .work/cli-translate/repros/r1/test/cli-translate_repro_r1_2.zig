//! A DeepSeek reply with the right number of sentences, one of them empty, must not end up
//! in `story.json`: every command checks `story.json` first (no empty sentence), so a
//! translation written with an empty story sentence blocks every later command,
//! `translate --redo pt-BR` included, until the file is edited by hand.
//!
//! The story has only `it`; the real server (harness) lists `pt-BR` with translate 1. A fake
//! OpenCode answers Jev `none` 0.98 and DeepSeek each paragraph with its Italian sentences
//! prefixed by `(pt) `, except "Apre la porta.", which it answers with "", so paragraph 1's
//! content is `["(pt) Il gatto entra in casa.", ""]`.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli");
const harness = @import("harness");

const io = std.testing.io;
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const it_dropped = "Apre la porta.";
const story_json =
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
    \\    "it": {"title": "Il gatto e la porta", "subtitle": "Una storia di casa", "paragraphs": [["Il gatto entra in casa.", "Apre la porta."], ["Fuori c'è aria di festa."]]}
    \\  }
    \\}
    \\
;

const Fake = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,

    fn serve(f: *Fake) Io.Cancelable!void {
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

    fn connection(f: *Fake, stream: Io.net.Stream) Io.Cancelable!void {
        defer stream.close(io);
        var in_buf: [16384]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var in = stream.reader(io, &in_buf);
        var out = stream.writer(io, &out_buf);
        var http: std.http.Server = .init(&in.interface, &out.interface);
        while (true) {
            var request = http.receiveHead() catch return;
            const keep_alive = request.head.keep_alive;
            const body = f.answer(&request) catch return;
            request.respond(body, .{ .keep_alive = keep_alive }) catch return;
            if (!keep_alive) return;
        }
    }

    fn answer(f: *Fake, request: *std.http.Server.Request) ![]const u8 {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        const is_jev = std.mem.endsWith(u8, request.head.target, "/systemone/v1/systemone");
        const body = try a.alloc(u8, request.head.content_length orelse 0);
        if (body.len > 0) try (try request.readerExpectContinue(&.{})).readSliceAll(body);
        if (is_jev) return
        \\{"model":"jev-1.13","answers":{"hate":{"type":"choice","choice":"none","confidence":0.98,"probabilities":{"none":0.98,"homophobic":0.0,"racist":0.01,"sexist":0.0,"religious":0.0,"other_hate":0.01}}},"usage":{"input_tokens":468,"output_tokens":67,"cost":0.00001966}}
        ;
        const req = try std.json.parseFromSliceLeaky(struct {
            messages: []const struct { role: []const u8, content: []const u8 },
        }, a, body, .{ .ignore_unknown_fields = true });
        const user = try std.json.parseFromSliceLeaky(struct { sentences: []const []const u8 }, a, req.messages[1].content, .{ .ignore_unknown_fields = true });
        var out: std.ArrayList([]const u8) = .empty;
        for (user.sentences) |s| try out.append(a, if (std.mem.eql(u8, s, it_dropped)) "" else try std.fmt.allocPrint(a, "(pt) {s}", .{s}));
        const content = try std.json.Stringify.valueAlloc(a, out.items, .{});
        return std.fmt.allocPrint(a,
            \\{{"id":"gw-test","object":"chat.completion","created":1795019615,"model":"deepseek-v4.1-flash","choices":[{{"index":0,"finish_reason":"stop","message":{{"role":"assistant","content":{s}}}}}]}}
        , .{try std.json.Stringify.valueAlloc(a, content, .{})});
    }
};

/// Runs `postilla translate <args>` with its output sent to a file, returning the exit code
/// and the output.
fn translate(a: std.mem.Allocator, env: *std.process.Environ.Map, tmp: std.testing.TmpDir, args: []const [:0]const u8) !struct { u8, []const u8 } {
    const argv = try std.mem.concat(a, [:0]const u8, &.{ &.{ "postilla", "translate" }, args });
    const file = try tmp.dir.createFile(io, "output.txt", .{ .read = true });
    defer file.close(io);
    const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
    _ = std.c.dup2(file.handle, 1);
    _ = std.c.dup2(file.handle, 2);
    const code: u8 = cli.run(io, a, env, tmp.dir, argv);
    _ = std.c.dup2(saved[0], 1);
    _ = std.c.dup2(saved[1], 2);
    for (saved) |fd| _ = std.c.close(fd);
    return .{ code, try tmp.dir.readFileAlloc(io, "output.txt", a, .limited(1 << 20)) };
}

test "repro: a DeepSeek reply with an empty story sentence is never written, so story.json stays valid and a later translate --redo pt-BR still runs" {
    var h: harness.Harness = undefined;
    try h.start();
    defer h.stop();
    var f: Fake = .{ .listener = undefined, .task = undefined, .arena = .init(gpa) };
    defer f.arena.deinit();
    f.listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer f.listener.deinit(io);
    f.task = try io.concurrent(Fake.serve, .{&f});
    defer f.task.cancel(io) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "story");
    try tmp.dir.writeFile(io, .{ .sub_path = "story/story.json", .data = story_json });
    const path = try std.fmt.allocPrintSentinel(a, "{s}/story", .{root}, 0);

    var env: std.process.Environ.Map = .init(a);
    try env.put("POSTILLA_SERVER_URL", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{h.port}));
    try env.put("POSTILLA_AUTHOR_TOKEN", harness.token);
    try env.put("POSTILLA_OPENCODE_KEY", "test-opencode-key");
    try env.put("POSTILLA_OPENCODE_URL", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/inference", .{f.listener.socket.address.getPort()}));
    try env.put("POSTILLA_SPEECHIFY_KEY", "test-speechify-key");
    try env.put("POSTILLA_R2_ACCOUNT_ID", "test-account");
    try env.put("POSTILLA_R2_ACCESS_KEY_ID", "test-key-id");
    try env.put("POSTILLA_R2_SECRET_ACCESS_KEY", "test-secret-access-key");
    try env.put("POSTILLA_R2_BUCKET", "postilla");

    const first = try translate(a, &env, tmp, &.{path});
    std.debug.print("first translate: exit {d}: {s}\n", .{ first[0], first[1] });

    // Whatever the first run did, it must not have written a pt-BR that rule 8 rejects.
    const written = try std.json.parseFromSliceLeaky(struct {
        translations: std.json.ArrayHashMap(struct { paragraphs: []const []const []const u8 }),
    }, a, try tmp.dir.readFileAlloc(io, "story/story.json", a, .limited(1 << 20)), .{ .ignore_unknown_fields = true });
    var empty_written = false;
    if (written.translations.map.get("pt-BR")) |pt| for (pt.paragraphs) |p| for (p) |s| {
        empty_written = empty_written or s.len == 0;
    };
    std.debug.print("pt-BR written with an empty sentence: {}\n", .{empty_written});

    // And the folder is not blocked: a later --redo pt-BR gets past the shared checks.
    const redo = try translate(a, &env, tmp, &.{ path, "--redo", "pt-BR" });
    std.debug.print("translate --redo pt-BR: exit {d}: {s}\n", .{ redo[0], redo[1] });
    try expect(!empty_written);
    try expect(std.mem.find(u8, redo[1], "story.json: pt-BR: empty") == null);
}
