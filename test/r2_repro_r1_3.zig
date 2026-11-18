//! A try that fails while its body is being sent must not hand its connection to the next
//! try: the owner's rule retries "network errors, timeouts", and a retry is only a retry
//! when it reaches R2 afresh. The fake R2 here reads the head of the first connection's
//! request and then never reads its body, so the client's upload of a large `.flac` stalls
//! with the socket buffers full until the idle timeout cancels the try. Every later
//! connection is served normally: the whole body is read and answered 200. A client that
//! puts the stalled connection back in its pool writes try 2 behind try 1's unsent body,
//! stalls again, and fails all 4 tries on that one socket although R2 has recovered.

const std = @import("std");
const Io = std.Io;
const r2 = @import("r2");

const io = std.testing.io;
const gpa = std.testing.allocator;
const expectEqual = std.testing.expectEqual;

/// Far larger than the loopback socket buffers, so the first try's write blocks.
const body_len = 64 << 20;

const StallFirstR2 = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    accepts: std.atomic.Value(usize) = .init(0),
    /// Bodies read whole and answered 200.
    stored: std.atomic.Value(usize) = .init(0),

    fn serve(f: *StallFirstR2) Io.Cancelable!void {
        var group: Io.Group = .init;
        defer group.cancel(io);
        while (true) {
            const stream = f.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            const n = f.accepts.fetchAdd(1, .monotonic);
            group.concurrent(io, connection, .{ f, stream, n == 0 }) catch stream.close(io);
        }
    }

    fn connection(f: *StallFirstR2, stream: Io.net.Stream, stall: bool) Io.Cancelable!void {
        defer stream.close(io);
        var in_buf: [16384]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var in = stream.reader(io, &in_buf);
        var out = stream.writer(io, &out_buf);
        var http: std.http.Server = .init(&in.interface, &out.interface);
        while (true) {
            var request = http.receiveHead() catch return;
            // The first connection hangs once the head is in, never reading the body.
            if (stall) return io.sleep(.fromSeconds(30), .awake);
            const keep_alive = request.head.keep_alive;
            const len = request.head.content_length orelse 0;
            const got = gpa.alloc(u8, len) catch return;
            defer gpa.free(got);
            if (len > 0) (request.readerExpectContinue(&.{}) catch return).readSliceAll(got) catch return;
            if (len == body_len) _ = f.stored.fetchAdd(1, .monotonic);
            request.respond("", .{ .status = .ok, .keep_alive = keep_alive }) catch return;
            if (!keep_alive) return;
        }
    }
};

test "an upload whose first try times out mid-body is retried on a fresh connection and succeeds once R2 answers" {
    var f: StallFirstR2 = .{ .listener = undefined, .task = undefined };
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    f.listener = try address.listen(io, .{ .reuse_address = true });
    defer f.listener.deinit(io);
    f.task = try io.concurrent(StallFirstR2.serve, .{&f});
    defer f.task.cancel(io) catch {};

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c: r2.Client = .{
        .endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.listener.socket.address.getPort()}),
        .bucket = "postilla",
        .access_key_id = "test-key-id",
        .secret_access_key = "test-secret-access-key",
        .retry = .{ .waits_ms = .{ 10, 10, 10 }, .connect_timeout_ms = 2_000, .idle_timeout_ms = 1_500 },
    };

    const flac = try a.alloc(u8, body_len);
    @memset(flac, 0x5a);
    @memcpy(flac[0..4], "fLaC");

    const res = c.put(io, a, "stories/d0159518-99cc-46f0-bef2-b5b6f6f9a76d/it/" ++
        "9f2c1e0d4b7a65839c0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e.flac", flac) catch |err| {
        // Every try ran on the stalled first connection: one accept for 4 tries.
        std.log.err("put failed with {t} after {d} accepted connection(s)", .{ err, f.accepts.load(.monotonic) });
        return err;
    };
    try expectEqual(.ok, res.status);
    try expectEqual(1, f.stored.load(.monotonic));
    try expectEqual(2, f.accepts.load(.monotonic));
}
