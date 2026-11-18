//! Scratch benchmark for GET /stories (server-read). Not part of the repo.
const std = @import("std");
const Io = std.Io;
const server = @import("server");
const c = @import("c");
const Harness = @import("harness").Harness;

const io = std.testing.io;
const print = std.debug.print;

fn seed(h: *Harness, n: usize) !void {
    var buf: [1024]u8 = undefined;
    // n rows = n/2 stories x {it, pt-BR}; every 20th row removed; cursors 1..n.
    const sql = try std.fmt.bufPrintSentinel(&buf,
        \\WITH RECURSIVE k(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM k WHERE i < {d})
        \\INSERT INTO story SELECT CAST(printf('%016d', (i + 1) / 2) AS BLOB),
        \\  CASE i % 2 WHEN 1 THEN 'it' ELSE 'pt-BR' END, randomblob(32),
        \\  CASE WHEN i % 20 = 0 THEN 2 ELSE 1 END, i FROM k;
    , .{n}, 0);
    if (n > 0) try h.sql(sql);
}

const Client = struct {
    stream: Io.net.Stream,
    in_buf: [65536]u8 = undefined,
    out_buf: [4096]u8 = undefined,
    in: Io.net.Stream.Reader = undefined,
    out: Io.net.Stream.Writer = undefined,

    fn connect(cl: *Client, port: u16) !void {
        const address = try Io.net.IpAddress.parse("127.0.0.1", port);
        cl.stream = try address.connect(io, .{ .mode = .stream });
        cl.in = cl.stream.reader(io, &cl.in_buf);
        cl.out = cl.stream.writer(io, &cl.out_buf);
    }

    /// Sends one GET and reads the whole response; returns the body length.
    fn get(cl: *Client, target: []const u8, close: bool) !usize {
        try cl.out.interface.print("GET {s} HTTP/1.1\r\nhost: test\r\nconnection: {s}\r\n\r\n", .{ target, if (close) "close" else "keep-alive" });
        try cl.out.interface.flush();
        var len: usize = 0;
        while (true) {
            const line = try cl.in.interface.takeDelimiterInclusive('\n');
            if (line.len <= 2) break;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:"))
                len = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
        }
        try cl.in.interface.discardAll(len);
        return len;
    }
};

fn lessThan(_: void, a: u64, b: u64) bool {
    return a < b;
}

fn report(label: []const u8, n: usize, samples: []u64, body: usize) void {
    std.mem.sort(u64, samples, {}, lessThan);
    var sum: u64 = 0;
    for (samples) |s| sum += s;
    print("rows={d:>6} {s:<34} iters={d:>4} body={d:>8}B  median={d:>8.1}us p95={d:>8.1}us max={d:>8.1}us mean={d:>8.1}us\n", .{
        n,                                                   label,                                  samples.len, body,
        @as(f64, @floatFromInt(samples[samples.len / 2])) / 1000, @as(f64, @floatFromInt(samples[samples.len * 95 / 100])) / 1000,
        @as(f64, @floatFromInt(samples[samples.len - 1])) / 1000, @as(f64, @floatFromInt(sum / samples.len)) / 1000,
    });
}

fn keepAlive(h: *Harness, n: usize, label: []const u8, target: []const u8, iters: usize) !void {
    var cl: Client = .{ .stream = undefined };
    try cl.connect(h.port);
    defer cl.stream.close(io);
    var samples: [1000]u64 = undefined;
    var body: usize = 0;
    for (0..10) |_| _ = try cl.get(target, false); // warm-up
    for (samples[0..iters]) |*s| {
        const t = Io.Timestamp.now(io, .awake);
        body = try cl.get(target, false);
        s.* = @intCast(t.untilNow(io, .awake).toNanoseconds());
    }
    report(label, n, samples[0..iters], body);
}

fn perConnection(h: *Harness, n: usize, label: []const u8, target: []const u8, iters: usize) !void {
    var samples: [1000]u64 = undefined;
    var body: usize = 0;
    var ok: usize = 0;
    var failed: usize = 0;
    for (0..iters) |_| {
        const t = Io.Timestamp.now(io, .awake);
        var cl: Client = .{ .stream = undefined };
        try cl.connect(h.port);
        body = cl.get(target, true) catch {
            failed += 1;
            cl.stream.close(io);
            continue;
        };
        cl.stream.close(io);
        samples[ok] = @intCast(t.untilNow(io, .awake).toNanoseconds());
        ok += 1;
    }
    print("rows={d:>6} {s:<34} dropped connections (no response): {d} of {d}\n", .{ n, label, failed, iters });
    if (ok > 0) report(label, n, samples[0..ok], body);
}

/// Runs the feed SQL on its own connection and prints SQLite's per-statement counters.
fn stmtStats(h: *Harness, n: usize, since: i64) !void {
    try stmtStatsOf(h, n, since, "SELECT id, lang, change, sha256, cursor, count(*) OVER () FROM story " ++
        "WHERE cursor > ?1 AND lang IN (?2, ?3, ?4, ?5) ORDER BY cursor", "current (window count)");
    try stmtStatsOf(h, n, since, "SELECT id, lang, change, sha256, cursor FROM story " ++
        "WHERE cursor > ?1 AND lang IN (?2, ?3, ?4, ?5) ORDER BY cursor", "variant (no window)");
    try stmtStatsOf(h, n, since, "SELECT count(*) FROM story " ++
        "WHERE cursor > ?1 AND lang IN (?2, ?3, ?4, ?5)", "variant (count only)");
    try stmtStatsOf(h, n, since, "SELECT id, lang, change, sha256, cursor, count(*) OVER (ORDER BY cursor ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM story " ++
        "WHERE cursor > ?1 AND lang IN (?2, ?3, ?4, ?5) ORDER BY cursor", "variant (window by cursor)");
}

fn stmtStatsOf(h: *Harness, n: usize, since: i64, comptime sql: [:0]const u8, label: []const u8) !void {
    var d = try server.db.open(h.db_path);
    defer d.close();
    const st = try d.prepare(sql);
    defer _ = c.sqlite3_finalize(st.handle);
    _ = c.sqlite3_bind_int64(st.handle, 1, since);
    _ = c.sqlite3_bind_text(st.handle, 2, "it", 2, null);
    _ = c.sqlite3_bind_text(st.handle, 3, "pt-BR", 5, null);
    var rows: usize = 0;
    while (try st.step()) rows += 1;
    // SQL-only time: 50 runs (10 for 100k), median.
    var t_samples: [50]u64 = undefined;
    const runs: usize = if (n >= 100_000) 10 else 50;
    for (t_samples[0..runs]) |*ts| {
        _ = c.sqlite3_reset(st.handle);
        const t = Io.Timestamp.now(io, .awake);
        while (try st.step()) {}
        ts.* = @intCast(t.untilNow(io, .awake).toNanoseconds());
    }
    std.mem.sort(u64, t_samples[0..runs], {}, lessThan);
    print("rows={d:>6} since={d} {s:<27} sql-only median={d:.1}us\n", .{ n, since, label, @as(f64, @floatFromInt(t_samples[runs / 2])) / 1000 });
    print("rows={d:>6} since={d} feed stmt (cumulative over {d} runs): returned={d} vm_steps={d} fullscan_steps={d} sorts={d} autoindex={d}\n", .{
        n,                                                                    since, runs + 1, rows,
        c.sqlite3_stmt_status(st.handle, c.SQLITE_STMTSTATUS_VM_STEP, 0),       c.sqlite3_stmt_status(st.handle, c.SQLITE_STMTSTATUS_FULLSCAN_STEP, 0),
        c.sqlite3_stmt_status(st.handle, c.SQLITE_STMTSTATUS_SORT, 0),          c.sqlite3_stmt_status(st.handle, c.SQLITE_STMTSTATUS_AUTOINDEX, 0),
    });
    if (since == 0) {
        const eq = try d.prepare("EXPLAIN QUERY PLAN " ++ sql);
        defer _ = c.sqlite3_finalize(eq.handle);
        while (try eq.step()) print("  plan[{s}]: {s}\n", .{ label, eq.bytes(3) });
    }
}

test "bench GET /stories" {
    const sizes = [_]usize{ 0, 1_000, 10_000, 100_000 };
    for (sizes) |n| {
        var h: Harness = undefined;
        try h.start();
        defer h.stop();
        try seed(&h, n);
        try stmtStats(&h, n, 0);
        const inc_since: usize = if (n > 10) n - 10 else 0;
        try stmtStats(&h, n, @intCast(inc_since));
        var inc_buf: [128]u8 = undefined;
        const inc = try std.fmt.bufPrint(&inc_buf, "/stories?since={d}&lang=it,pt-BR", .{inc_since});
        const iters: usize = if (n >= 100_000) 100 else 1000;
        try keepAlive(&h, n, "full sync since=0 keep-alive", "/stories?since=0&lang=it,pt-BR", iters);
        try keepAlive(&h, n, "incremental (<=10 new) keep-alive", inc, 1000);
        try perConnection(&h, n, "incremental (<=10 new) new conn", inc, 1000);
        try keepAlive(&h, n, "GET /languages keep-alive (ref)", "/languages", 1000);
    }
}
