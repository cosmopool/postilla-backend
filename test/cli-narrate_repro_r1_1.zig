//! A Speechify word mark whose `start_time` is negative (or an `end_time` at or above 2^32 ms)
//! is an outside service's answer, so it must be treated as a bad stream: a failed try,
//! then `it: narration: <reason>` and exit 1 after the third, nothing written. It must not
//! crash the command.
//!
//! The story has only `it`; the real server (harness) lists `it` with target 1. A fake
//! Speechify answers every stream request with a 200 holding one `speech.chunk` (100 ms of
//! silent PCM and one mark with `start_time` -1), then `speech.done`.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli");
const harness = @import("harness");

const io = std.testing.io;
const gpa = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

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
    streams: usize = 0,

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
        var request = http.receiveHead() catch return;
        const body = f.answer(&request) catch return;
        request.respond(body, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }} }) catch return;
    }

    fn answer(f: *Fake, request: *std.http.Server.Request) ![]const u8 {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        const body = try a.alloc(u8, request.head.content_length orelse 0);
        if (body.len > 0) try (try request.readerExpectContinue(&.{})).readSliceAll(body);
        f.streams += 1;
        // 100 ms of silence at 48 kHz, 16-bit mono.
        const pcm = try a.alloc(u8, 4800 * 2);
        @memset(pcm, 0);
        const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(pcm.len));
        _ = std.base64.standard.Encoder.encode(b64, pcm);
        return std.fmt.allocPrint(a,
            \\event: speech.chunk
            \\data: {{"type":"speech.chunk","audio":"{s}","speech_marks":[{{"type":"word","start":0,"end":2,"start_time":-1,"end_time":50,"value":"Il"}}]}}
            \\
            \\
            \\event: speech.done
            \\data: {{"type":"speech.done","billable_characters_count":63,"audio_duration_ms":100}}
            \\
            \\
            \\
        , .{b64});
    }
};

test "repro: a Speechify word mark with a negative start_time fails the try instead of crashing narrate" {
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
    try env.put("POSTILLA_SPEECHIFY_KEY", "test-speechify-key");
    try env.put("POSTILLA_SPEECHIFY_URL", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/speechify", .{f.listener.socket.address.getPort()}));
    try env.put("POSTILLA_R2_ACCOUNT_ID", "test-account");
    try env.put("POSTILLA_R2_ACCESS_KEY_ID", "test-key-id");
    try env.put("POSTILLA_R2_SECRET_ACCESS_KEY", "test-secret-access-key");
    try env.put("POSTILLA_R2_BUCKET", "postilla");

    const file = try tmp.dir.createFile(io, "output.txt", .{ .read = true });
    const saved = [2]c_int{ std.c.dup(1), std.c.dup(2) };
    _ = std.c.dup2(file.handle, 1);
    _ = std.c.dup2(file.handle, 2);
    const code: u8 = cli.run(io, a, &env, tmp.dir, &.{ "postilla", "narrate", path });
    _ = std.c.dup2(saved[0], 1);
    _ = std.c.dup2(saved[1], 2);
    for (saved) |fd| _ = std.c.close(fd);
    file.close(io);
    const out = try tmp.dir.readFileAlloc(io, "output.txt", a, .limited(1 << 20));
    std.debug.print("narrate: exit {d}: {s}\n", .{ code, out });

    try expectEqual(1, code);
    try expect(std.mem.find(u8, out, "it: narration") != null);
    try expectEqual(3, f.streams);
    try expect(std.meta.isError(tmp.dir.access(io, "story/it.opus", .{})));
    try expect(std.meta.isError(tmp.dir.access(io, "story/it.flac", .{})));
}
