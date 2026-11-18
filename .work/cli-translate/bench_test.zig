
/// Counts every allocation the command makes into its arena.
const Counting = struct {
    child: Allocator,
    allocs: usize = 0,
    bytes: usize = 0,
    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(p: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(p));
        c.allocs += 1;
        c.bytes += len;
        return c.child.rawAlloc(len, al, ra);
    }
    fn resize(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(p));
        if (n > m.len) c.bytes += n - m.len;
        return c.child.rawResize(m, al, n, ra);
    }
    fn remap(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(p));
        if (n > m.len) c.bytes += n - m.len;
        return c.child.rawRemap(m, al, n, ra);
    }
    fn free(p: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(p));
        c.child.rawFree(m, al, ra);
    }
};

test "BENCH: translate a 20,000-character story (spec rule 8 maximum)" {
    var w: World = undefined;
    try w.start(.{});
    defer w.stop();
    const a = w.arena.allocator();
    const P = 63;
    const S = 5;
    // ~60 code points per sentence: 66 * 5 * 60 = 19,800, under rule 8's 20,000.
    const sentence = "Il gatto entra piano in casa e guarda la porta del giardino.";
    var paras: std.ArrayList(u8) = .empty;
    for (0..P) |p| {
        try paras.appendSlice(a, if (p == 0) "[" else ", [");
        for (0..S) |s| try paras.print(a, "{s}\"{d} {s}\"", .{ if (s == 0) "" else ", ", p, sentence });
        try paras.append(a, ']');
    }
    const it_big = try std.fmt.allocPrint(a, "\"it\": {{\"title\": \"Il gatto e la porta\", \"subtitle\": \"Una storia di casa\", \"paragraphs\": [{s}]}}", .{paras.items});
    const json = try story(a, &.{.{ it_member, it_big }});
    const path = try w.folder(json);

    const argv = try std.mem.concat(a, [:0]const u8, &.{ &.{ "postilla", "translate" }, &.{path} });
    var cmd_arena: std.heap.ArenaAllocator = .init(gpa);
    defer cmd_arena.deinit();
    var counting: Counting = .{ .child = cmd_arena.allocator() };
    const t0 = Io.Clock.awake.now(io);
    const code = cli.run(io, counting.allocator(), &w.env, w.tmp.dir, argv);
    const ns = t0.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
    try expectEqual(0, code);
    const out = try w.bytes();
    std.debug.print(
        \\BENCH story.json in={d}B out={d}B paragraphs={d} sentences={d}
        \\BENCH jev_requests={d} deepseek_requests={d} total_requests={d}
        \\BENCH arena_allocs={d} arena_requested_bytes={d} arena_capacity_bytes={d}
        \\BENCH wall_ms={d} (fake OpenCode on loopback, includes server list fetch)
        \\
    , .{ json.len, out.len, P, P * S, (try w.f.requests(a, jev_path)).len, (try w.f.requests(a, chat_path)).len, w.f.total(), counting.allocs, counting.bytes, cmd_arena.queryCapacity(), @divTrunc(ns, 1_000_000) });
    var body_bytes: usize = 0;
    for (try w.f.requests(a, chat_path)) |r| body_bytes += r.body.len;
    std.debug.print("BENCH deepseek_request_body_bytes_total={d}\n", .{body_bytes});
}
