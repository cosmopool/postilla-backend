const std = @import("std");
const server = @import("server");
const harness = @import("harness");
const Harness = harness.Harness;

const io = std.testing.io;
const expectEqual = std.testing.expectEqual;

fn get(h: *const Harness, buf: []u8) !harness.Response {
    return h.send("GET /languages HTTP/1.1", "", buf);
}

test "AC-F3: a request that arrives while postilla.db is briefly locked waits for the busy timeout and is answered, not dropped" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    // Another connection holds the file lock for a moment, the way the last WAL
    // connection does while it checkpoints on close.
    var locker = try server.db.open(h.db_path);
    var locked = true;
    defer if (locked) locker.close();
    try locker.exec("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE; SELECT count(*) FROM language;");

    var buf: [4096]u8 = undefined;
    var pending = try io.concurrent(get, .{ &h, &buf });
    try io.sleep(.fromMilliseconds(300), .awake);
    locker.exec("COMMIT;") catch {};
    locker.close();
    locked = false;

    // 300 ms is well inside the 5000 ms busy timeout, so the request must be answered.
    const r = try pending.await(io);
    try expectEqual(@as(u16, 200), r.status);
}
