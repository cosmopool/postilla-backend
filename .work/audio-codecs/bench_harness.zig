//! Temporary measurement harness for .work/audio-codecs/bench.md (not committed).
const std = @import("std");
const audio = @import("audio");

const Counting = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    resizes: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grow(self: *Counting, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(p: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(p));
        const r = self.child.rawAlloc(len, al, ra) orelse return null;
        self.allocs += 1;
        self.grow(0, len);
        return r;
    }
    fn resize(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(p));
        if (!self.child.rawResize(m, al, n, ra)) return false;
        self.resizes += 1;
        self.grow(m.len, n);
        return true;
    }
    fn remap(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(p));
        const r = self.child.rawRemap(m, al, n, ra) orelse return null;
        self.resizes += 1;
        self.grow(m.len, n);
        return r;
    }
    fn free(p: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(p));
        self.child.rawFree(m, al, ra);
        self.grow(m.len, 0);
    }
};

fn hwmKb() !usize {
    var buf: [4096]u8 = undefined;
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, "/proc/self/status", .{}, 0);
    defer _ = std.c.close(fd);
    const n = try std.posix.read(fd, &buf);
    const i = std.mem.indexOf(u8, buf[0..n], "VmHWM:").?;
    var it = std.mem.tokenizeAny(u8, buf[i + 6 .. n], " \t\n");
    return try std.fmt.parseInt(usize, it.next().?, 10);
}

fn run(minutes: usize) !void {
    const rate: u32 = 48000;
    const n = minutes * 60 * rate;
    const samples = try std.heap.page_allocator.alloc(i16, n);
    defer std.heap.page_allocator.free(samples);
    // Voice-like signal: a 140 Hz fundamental with harmonics, amplitude-modulated at 4 Hz
    // (syllable rate) and pseudo-random noise, so FLAC and Opus see non-trivial content.
    var prng = std.Random.DefaultPrng.init(1);
    for (samples, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / 48000.0;
        const env = 0.5 + 0.5 * @sin(2 * std.math.pi * 4 * t);
        const v = env * (6000 * @sin(2 * std.math.pi * 140 * t) + 3000 * @sin(2 * std.math.pi * 280 * t) + 1500 * @sin(2 * std.math.pi * 560 * t)) +
            @as(f64, @floatFromInt(prng.random().intRangeAtMost(i16, -800, 800)));
        s.* = @intFromFloat(@round(v));
    }
    const hwm0 = try hwmKb();
    var counting: Counting = .{ .child = std.heap.page_allocator };
    const io = std.testing.io;
    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const e = try audio.encode(counting.allocator(), samples, rate);
    const dt = t0.untilNow(io).raw.nanoseconds;
    const hwm1 = try hwmKb();
    defer counting.allocator().free(e.opus);
    defer counting.allocator().free(e.flac);

    // The Zig-side work the flagged lines add, on the same sizes: the i16->i32 copy and the
    // final dupe of the FLAC bytes.
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const wide = try std.heap.page_allocator.alloc(i32, n);
    for (samples, wide) |s, *w| w.* = s;
    const copy = try std.heap.page_allocator.dupe(u8, e.flac);
    const dz = t1.untilNow(io).raw.nanoseconds;
    std.mem.doNotOptimizeAway(wide);
    std.mem.doNotOptimizeAway(copy);
    std.heap.page_allocator.free(wide);
    std.heap.page_allocator.free(copy);

    std.debug.print(
        "\nBENCH minutes={d} samples={d} pcm_bytes={d} encode_ms={d} opus_bytes={d} flac_bytes={d} audio_ms={d} a_allocs={d} a_resizes={d} a_peak_bytes={d} a_live_after={d} hwm_before_kb={d} hwm_after_kb={d} rss_growth_kb={d} zig_copies_ms={d}\n",
        .{ minutes, n, n * 2, @divTrunc(dt, 1_000_000), e.opus.len, e.flac.len, e.audio_ms, counting.allocs, counting.resizes, counting.peak, counting.live, hwm0, hwm1, hwm1 - hwm0, @divTrunc(dz, 1_000_000) },
    );
}

// Copy to test/zz_bench_audio_<N>.zig and set the minutes below; delete it afterwards.
test "bench 20 min" {
    try run(20);
}
