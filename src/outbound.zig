//! One outbound HTTP call with the owner's retry schedule and timeouts
//! (docs/specification.md, Retries). Every outside service goes through `request`, which
//! sends `user-agent: postilla/1.0` and `accept-encoding: identity`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The waits between a call's 4 tries, the longest wait allowed, and the timeouts.
pub const Retry = struct {
    waits_ms: [3]u32 = .{ 5_000, 30_000, 120_000 },
    max_wait_ms: u32 = 120_000,
    connect_timeout_ms: u32 = 10_000,
    idle_timeout_ms: u32 = 60_000,
};

/// Sends `method` to `url` in up to 4 tries. A network error, a timeout, a 429 or a 5xx is
/// retried after the scheduled wait, or after a 429's or 503's Retry-After, capped at
/// `retry.max_wait_ms`; any other status returns at once. When `digest` isn't empty, a 200
/// whose body isn't `<hex sha256> <size>\n` as `digest` says is a failed try too. Returns
/// the last status and body, in `a`, or the last error.
pub fn request(io: Io, a: Allocator, retry: Retry, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: []const u8, digest: []const u8) !struct { status: std.http.Status, body: []u8 } {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    // Each try sends its own copy: a cut send can write into the buffer it sends.
    const copy = try a.alloc(u8, body.len);
    var n: usize = 0;
    while (true) : (n += 1) {
        // The client has no timeouts: the try is a task, canceled when it hasn't connected
        // or hasn't finished in time.
        var events: [2]Io.Event = .{ .unset, .unset };
        var got: []u8 = "";
        var wait: u64 = retry.waits_ms[@min(n, 2)];
        @memcpy(copy, body);
        var task = try io.concurrent(send, .{ &client, method, uri, headers, copy, &events, &got, &wait });
        events[0].waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(retry.connect_timeout_ms), .clock = .awake } }) catch {};
        if (events[0].isSet()) events[1].waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(retry.idle_timeout_ms), .clock = .awake } }) catch {};
        if (task.cancel(io)) |status| {
            var sha: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(got, &sha, .{});
            const bad = status == .ok and digest.len > 0 and !std.mem.eql(u8, digest, try std.fmt.allocPrint(a, "{s} {d}\n", .{ &std.fmt.bytesToHex(sha, .lower), got.len }));
            if (!bad and status != .too_many_requests and status.class() != .server_error) return .{ .status = status, .body = got };
            if (n == 3) return if (bad) error.DigestMismatch else .{ .status = status, .body = got };
        } else |err| if (n == 3) return err;
        try io.sleep(.fromMilliseconds(@intCast(@min(wait, retry.max_wait_ms))), .awake);
    }
}

/// One try: sets `events[0]` once connected and both when done, the body into `got`, and a
/// 429's or 503's Retry-After into `wait`.
fn send(client: *std.http.Client, method: std.http.Method, uri: std.Uri, headers: []const std.http.Header, body: []u8, events: *[2]Io.Event, got: *[]u8, wait: *u64) !std.http.Status {
    defer for (events) |*e| e.set(client.io);
    // The client's own user-agent (`zig/…`) would come first; OpenCode Go asks for the caller's.
    // The client asks for gzip by default but `got` is read as sent, so ask for no encoding.
    var req = try client.request(method, uri, .{ .headers = .{
        .user_agent = .{ .override = "postilla/1.0" },
        .accept_encoding = .{ .override = "identity" },
    }, .extra_headers = headers });
    defer req.deinit();
    errdefer req.connection.?.closing = true;
    events[0].set(client.io);
    try req.sendBodyComplete(body);
    var response = try req.receiveHead(&.{});
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after") and (response.head.status == .too_many_requests or response.head.status == .service_unavailable))
            wait.* = 1000 * @as(u64, std.fmt.parseInt(u32, h.value, 10) catch continue);
    }
    got.* = try response.reader(&.{}).allocRemaining(client.allocator, .unlimited);
    return response.head.status;
}
