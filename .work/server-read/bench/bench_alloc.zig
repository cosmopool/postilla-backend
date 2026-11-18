//! Scratch: Zig-heap allocations per request on the server side (counting wrapper around gpa).
const std = @import("std");
const Io = std.Io;
const server = @import("server");
const Harness = @import("harness").Harness;
const io = std.testing.io;

fn measure(h: *Harness, target: []const u8, reps: usize) !void {
    const address = try Io.net.IpAddress.parse("127.0.0.1", h.port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var in_buf: [65536]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var in = stream.reader(io, &in_buf);
    var out = stream.writer(io, &out_buf);
    const a0 = server.allocs.load(.monotonic);
    const r0 = server.resizes.load(.monotonic);
    const b0 = server.bytes.load(.monotonic);
    for (0..reps) |_| {
        try out.interface.print("GET {s} HTTP/1.1\r\nhost: t\r\n\r\n", .{target});
        try out.interface.flush();
        var len: usize = 0;
        while (true) {
            const line = try in.interface.takeDelimiterInclusive('\n');
            if (line.len <= 2) break;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:"))
                len = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
        }
        try in.interface.discardAll(len);
    }
    std.debug.print("{s:<40} reps={d} allocs/req={d:.2} resizes/req={d:.2} bytes/req={d:.0}\n", .{
        target, reps,
        @as(f64, @floatFromInt(server.allocs.load(.monotonic) - a0)) / @as(f64, @floatFromInt(reps)),
        @as(f64, @floatFromInt(server.resizes.load(.monotonic) - r0)) / @as(f64, @floatFromInt(reps)),
        @as(f64, @floatFromInt(server.bytes.load(.monotonic) - b0)) / @as(f64, @floatFromInt(reps)),
    });
}

test "allocations per request" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();
    try h.sql(
        \\WITH RECURSIVE k(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM k WHERE i < 1000)
        \\INSERT INTO story SELECT CAST(printf('%016d', (i + 1) / 2) AS BLOB),
        \\  CASE i % 2 WHEN 1 THEN 'it' ELSE 'pt-BR' END, randomblob(32),
        \\  CASE WHEN i % 20 = 0 THEN 2 ELSE 1 END, i FROM k;
    );
    try measure(&h, "/stories?since=0&lang=it,pt-BR", 100);
    try measure(&h, "/stories?since=990&lang=it,pt-BR", 100);
    try measure(&h, "/stories?since=1000&lang=it,pt-BR", 100);
    try measure(&h, "/stories?since=x&lang=it", 100);
    try measure(&h, "/languages", 100);
    try measure(&h, "/genres", 100);
}
