//! Scratch: cost of the two sqlite3_prepare_v2 calls GET /stories makes per request.
const std = @import("std");
const Io = std.Io;
const server = @import("server");
const c = @import("c");
const Harness = @import("harness").Harness;
const io = std.testing.io;

fn timePrepare(d: server.db.Db, comptime sql: [:0]const u8, label: []const u8) !void {
    var samples: [2000]u64 = undefined;
    for (&samples) |*s| {
        const t = Io.Timestamp.now(io, .awake);
        const st = try d.prepare(sql);
        _ = c.sqlite3_finalize(st.handle);
        s.* = @intCast(t.untilNow(io, .awake).toNanoseconds());
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("prepare+finalize {s:<14} n=2000 median={d:.1}us p95={d:.1}us\n", .{ label, @as(f64, @floatFromInt(samples[1000])) / 1000, @as(f64, @floatFromInt(samples[1900])) / 1000 });
}

test "prepare cost" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();
    var d = try server.db.open(h.db_path);
    defer d.close();
    try timePrepare(d, "SELECT 1 FROM language WHERE id = ?1", "language check");
    try timePrepare(d, "SELECT id, lang, change, sha256, cursor, count(*) OVER () FROM story " ++
        "WHERE cursor > ?1 AND lang IN (?2, ?3, ?4, ?5) ORDER BY cursor", "feed query");
}
