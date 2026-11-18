//! A download whose bytes keep arriving must not be cut by the idle timeout: the owner's
//! rule is "60 s with no byte received", not a limit on the whole transfer. The fake R2
//! here answers 200 at once and then sends the body one byte every 50 ms, so no gap is
//! anywhere near the idle timeout, while the whole transfer takes longer than it.

const std = @import("std");
const Io = std.Io;
const r2 = @import("r2");

const io = std.testing.io;
const gpa = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const body = "fLaC\x00\x00\x00\x22 a story's flac frames, arriving slowly";

const SlowR2 = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    tries: std.atomic.Value(usize) = .init(0),

    fn serve(f: *SlowR2) Io.Cancelable!void {
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

    fn connection(f: *SlowR2, stream: Io.net.Stream) Io.Cancelable!void {
        defer stream.close(io);
        var in_buf: [16384]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var in = stream.reader(io, &in_buf);
        var out = stream.writer(io, &out_buf);
        var http: std.http.Server = .init(&in.interface, &out.interface);
        _ = http.receiveHead() catch return;
        _ = f.tries.fetchAdd(1, .monotonic);
        const w = &out.interface;
        w.print("HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.len}) catch return;
        w.flush() catch return;
        for (body) |byte| {
            try io.sleep(.fromMilliseconds(50), .awake);
            w.writeByte(byte) catch return;
            w.flush() catch return;
        }
    }
};

test "a download that keeps receiving bytes outlasts the idle timeout and succeeds on its first try" {
    var f: SlowR2 = .{ .listener = undefined, .task = undefined };
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    f.listener = try address.listen(io, .{ .reuse_address = true });
    defer f.listener.deinit(io);
    f.task = try io.concurrent(SlowR2.serve, .{&f});
    defer f.task.cancel(io) catch {};

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c: r2.Client = .{
        .endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.listener.socket.address.getPort()}),
        .bucket = "postilla",
        .access_key_id = "test-key-id",
        .secret_access_key = "test-secret-access-key",
        // The body takes about 2 s in all; no gap between two bytes is longer than 50 ms.
        .retry = .{ .waits_ms = .{ 10, 10, 10 }, .idle_timeout_ms = 500 },
    };

    const res = try c.get(io, a, "stories/d0159518-99cc-46f0-bef2-b5b6f6f9a76d/it/story.flac");
    try expectEqual(.ok, res.status);
    try expectEqualStrings(body, res.body);
    try expectEqual(1, f.tries.load(.monotonic));
}
