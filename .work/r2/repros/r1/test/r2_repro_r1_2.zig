//! A retried R2 call must sign every try afresh: requirement.md decided "The signature is
//! recomputed for every try, since `x-amz-date` changes". R2, like S3, answers 403
//! RequestTimeTooSkewed to a request whose x-amz-date is too far from its own clock (15 min
//! for the real service). The fake R2 here keeps that rule with a window scaled down to 1 s,
//! answers the first try 503 with `Retry-After: 2`, and has recovered by the second. A
//! client that reuses the first try's x-amz-date sends a date 2 s old on its second try and
//! is turned away, although R2 is up again.

const std = @import("std");
const Io = std.Io;
const r2 = @import("r2");

const io = std.testing.io;
const gpa = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// The fake's tolerance for a request's x-amz-date, in seconds (R2's is 15 min).
const skew_s = 1;

const SkewR2 = struct {
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    mutex: Io.Mutex = .init,
    tries: usize = 0,
    /// The x-amz-date of each try, in order.
    dates: [4][16]u8 = undefined,

    fn serve(f: *SkewR2) Io.Cancelable!void {
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

    fn connection(f: *SkewR2, stream: Io.net.Stream) Io.Cancelable!void {
        defer stream.close(io);
        var in_buf: [16384]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var in = stream.reader(io, &in_buf);
        var out = stream.writer(io, &out_buf);
        var http: std.http.Server = .init(&in.interface, &out.interface);
        while (true) {
            var request = http.receiveHead() catch return;
            const keep_alive = request.head.keep_alive;
            var date: []const u8 = "";
            var headers = request.iterateHeaders();
            while (headers.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "x-amz-date")) date = h.value;
            }
            var date_copy: [16]u8 = @splat('?');
            if (date.len == 16) @memcpy(&date_copy, date);
            const len = request.head.content_length orelse 0;
            var body_buf: [256]u8 = undefined;
            if (len > 0) (request.readerExpectContinue(&.{}) catch return).readSliceAll(body_buf[0..len]) catch return;

            f.mutex.lockUncancelable(io);
            const n = f.tries;
            if (n < f.dates.len) f.dates[n] = date_copy;
            f.tries += 1;
            f.mutex.unlock(io);

            const now: i64 = Io.Clock.real.now(io).toSeconds();
            const skewed = if (dateSeconds(&date_copy)) |at| @abs(now - at) > skew_s else true;
            const retry_after = [_]std.http.Header{.{ .name = "retry-after", .value = "2" }};
            if (n == 0) {
                request.respond("", .{ .status = .service_unavailable, .keep_alive = keep_alive, .extra_headers = &retry_after }) catch return;
            } else if (skewed) {
                request.respond("<Error><Code>RequestTimeTooSkewed</Code></Error>", .{ .status = .forbidden, .keep_alive = keep_alive }) catch return;
            } else {
                request.respond("", .{ .status = .ok, .keep_alive = keep_alive }) catch return;
            }
            if (!keep_alive) return;
        }
    }
};

/// Seconds since the epoch of an x-amz-date `YYYYMMDDTHHMMSSZ`, or null when it isn't one.
fn dateSeconds(d: *const [16]u8) ?i64 {
    if (d[8] != 'T' or d[15] != 'Z') return null;
    const year = std.fmt.parseInt(u16, d[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, d[4..6], 10) catch return null;
    const day = std.fmt.parseInt(u8, d[6..8], 10) catch return null;
    const hh = std.fmt.parseInt(i64, d[9..11], 10) catch return null;
    const mm = std.fmt.parseInt(i64, d[11..13], 10) catch return null;
    const ss = std.fmt.parseInt(i64, d[13..15], 10) catch return null;
    if (month < 1 or month > 12) return null;
    var days: i64 = 0;
    var y: u16 = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    days += day - 1;
    return days * 86400 + hh * 3600 + mm * 60 + ss;
}

test "a retried upload is signed again for each try, so R2 that has recovered after a Retry-After accepts it" {
    var f: SkewR2 = .{ .listener = undefined, .task = undefined };
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    f.listener = try address.listen(io, .{ .reuse_address = true });
    defer f.listener.deinit(io);
    f.task = try io.concurrent(SkewR2.serve, .{&f});
    defer f.task.cancel(io) catch {};

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c: r2.Client = .{
        .endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.listener.socket.address.getPort()}),
        .bucket = "postilla",
        .access_key_id = "test-key-id",
        .secret_access_key = "test-secret-access-key",
        .retry = .{ .waits_ms = .{ 10, 10, 10 }, .max_wait_ms = 3_000 },
    };

    const res = try c.put(io, a, "stories/d0159518-99cc-46f0-bef2-b5b6f6f9a76d/it/" ++
        "9f2c1e0d4b7a65839c0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e.opus", "OggS a story's narration");
    try expectEqual(2, f.tries);
    try expectEqual(.ok, res.status);
    // The second try carries its own, later date.
    if (std.mem.eql(u8, &f.dates[0], &f.dates[1])) {
        try expectEqualStrings("a fresh x-amz-date on try 2", &f.dates[1]);
    }
}
