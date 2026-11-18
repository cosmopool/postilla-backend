const std = @import("std");
const Io = std.Io;
const harness = @import("harness");
const Harness = harness.Harness;

const io = std.testing.io;
const expectEqual = std.testing.expectEqual;

const clients = 8;
const requests = 400;

/// One learner app: requests the feed over a new connection each time, and counts the
/// connections the server closed without answering.
fn client(h: *const Harness, dropped: *std.atomic.Value(u32), answered: *std.atomic.Value(u32)) void {
    var buf: [4096]u8 = undefined;
    for (0..requests) |_| {
        if (h.send("GET /stories?lang=it HTTP/1.1", "", &buf)) |r| {
            if (r.status == 200) _ = answered.fetchAdd(1, .monotonic);
        } else |_| _ = dropped.fetchAdd(1, .monotonic);
    }
}

test "AC-5, AC-F3: concurrent feed requests on fresh connections are all answered, none dropped with no response" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    var dropped: std.atomic.Value(u32) = .init(0);
    var answered: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..clients) |_| try group.concurrent(io, client, .{ &h, &dropped, &answered });
    try group.await(io);

    // Each server connection opens and closes its own SQLite connection. When one closes
    // as the last, SQLite locks the file to checkpoint the WAL; a connection opening then
    // must wait for it, not drop the client with no bytes.
    try expectEqual(0, dropped.load(.monotonic));
    try expectEqual(clients * requests, answered.load(.monotonic));
}
