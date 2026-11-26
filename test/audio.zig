//! `audio.encode`: 16-bit mono PCM in memory to the narration's two files, the Ogg Opus
//! `.opus` for the app and the lossless `.flac` master. Every output is read back the way
//! a player would: the Ogg pages are walked and their CRCs checked here, and the packets
//! and the FLAC stream are decoded with the vendored libopus and libFLAC decoders the
//! test roots link.

const std = @import("std");
const audio = @import("audio");

const gpa = std.testing.allocator;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

/// `n` samples of a `freq` Hz sine at `rate`, at about a third of full scale.
fn sine(n: usize, rate: u32, freq: f64) ![]i16 {
    const out = try gpa.alloc(i16, n);
    for (out, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate));
        s.* = @intFromFloat(@round(10000 * @sin(2 * std.math.pi * freq * t)));
    }
    return out;
}

fn free(e: audio.Encoded) void {
    gpa.free(e.opus);
    gpa.free(e.flac);
}

// --- Ogg Opus (RFC 3533, RFC 7845) ---

/// The Ogg page checksum: CRC-32, polynomial 0x04c11db7, no reflection, zero initial and
/// final value, over the page with its checksum field zeroed.
const OggCrc = std.hash.crc.Generic(u32, .{
    .polynomial = 0x04c11db7,
    .initial = 0,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0,
});

const Ogg = struct {
    /// Every packet, joined across pages.
    packets: []const []const u8,
    /// The page each packet starts on.
    first_page: []const usize,
    /// The granule position of the last page.
    granule: u64,
};

/// Walks every page of `bytes`, checking the capture pattern, the CRC and that the serial
/// number never changes. Allocates in `arena`.
fn readOgg(arena: Allocator, bytes: []const u8) !Ogg {
    var packets: std.ArrayList([]const u8) = .empty;
    var first_page: std.ArrayList(usize) = .empty;
    var packet: std.ArrayList(u8) = .empty;
    var open = false;
    var serial: ?u32 = null;
    var granule: u64 = 0;
    var page: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) : (page += 1) {
        const h = bytes[at..];
        try expect(h.len >= 27);
        try expectEqualStrings("OggS", h[0..4]);
        const lacing = h[27..][0..h[26]];
        var body: usize = 0;
        for (lacing) |l| body += l;
        const len = 27 + lacing.len + body;
        try expect(h.len >= len);

        const copy = try arena.dupe(u8, h[0..len]);
        @memset(copy[22..26], 0);
        try expectEqual(std.mem.readInt(u32, h[22..26], .little), OggCrc.hash(copy));
        const s = std.mem.readInt(u32, h[14..18], .little);
        if (serial) |first| try expectEqual(first, s) else serial = s;
        granule = std.mem.readInt(u64, h[6..14], .little);

        var data = h[27 + lacing.len .. len];
        for (lacing) |l| {
            if (!open) try first_page.append(arena, page);
            open = true;
            try packet.appendSlice(arena, data[0..l]);
            data = data[l..];
            if (l < 255) {
                try packets.append(arena, try packet.toOwnedSlice(arena));
                open = false;
            }
        }
        at += len;
    }
    try expect(!open);
    return .{ .packets = packets.items, .first_page = first_page.items, .granule = granule };
}

const OpusHead = struct { channels: u8, pre_skip: u16, input_rate: u32 };

fn opusHead(packet: []const u8) !OpusHead {
    try expect(packet.len >= 19);
    try expectEqualStrings("OpusHead", packet[0..8]);
    return .{
        .channels = packet[9],
        .pre_skip = std.mem.readInt(u16, packet[10..12], .little),
        .input_rate = std.mem.readInt(u32, packet[12..16], .little),
    };
}

const OpusDecoder = opaque {};
extern fn opus_decoder_create(fs: i32, channels: c_int, err: *c_int) ?*OpusDecoder;
extern fn opus_decode(st: *OpusDecoder, data: [*]const u8, len: i32, pcm: [*]i16, frame_size: c_int, decode_fec: c_int) c_int;
extern fn opus_decoder_destroy(st: *OpusDecoder) void;

/// Decodes the audio packets at 48 kHz mono, pre-skip included. The caller frees it.
fn decodeOpus(packets: []const []const u8) ![]i16 {
    var err: c_int = 0;
    const dec = opus_decoder_create(48000, 1, &err) orelse return error.OpusDecoder;
    defer opus_decoder_destroy(dec);
    try expectEqual(0, err);
    var out: std.ArrayList(i16) = .empty;
    errdefer out.deinit(gpa);
    for (packets) |p| {
        var pcm: [5760]i16 = undefined; // 120 ms, the longest Opus packet
        const got = opus_decode(dec, p.ptr, @intCast(p.len), &pcm, pcm.len, 0);
        try expect(got > 0);
        try out.appendSlice(gpa, pcm[0..@intCast(got)]);
    }
    return out.toOwnedSlice(gpa);
}

/// The Goertzel power of `freq` Hz in `x`.
fn power(x: []const i16, rate: f64, freq: f64) f64 {
    const coeff = 2 * @cos(2 * std.math.pi * freq / rate);
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (x) |v| {
        const s0 = @as(f64, @floatFromInt(v)) + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

// --- FLAC ---

const StreamInfo = struct { rate: u32, channels: u8, bits: u8, samples: u64, md5: [16]u8 };

/// The STREAMINFO block, which FLAC requires right after `fLaC`.
fn streamInfo(flac: []const u8) !StreamInfo {
    try expect(flac.len >= 42);
    try expectEqualStrings("fLaC", flac[0..4]);
    try expectEqual(0, flac[4] & 0x7f);
    try expectEqual(34, std.mem.readInt(u24, flac[5..8], .big));
    const fields = std.mem.readInt(u64, flac[18..26], .big);
    return .{
        .rate = @intCast(fields >> 44),
        .channels = @intCast((fields >> 41 & 0x7) + 1),
        .bits = @intCast((fields >> 36 & 0x1f) + 1),
        .samples = fields & 0xf_ffff_ffff,
        .md5 = flac[26..42].*,
    };
}

/// FLAC's MD5 signature: of the samples as signed little-endian 16-bit integers.
fn md5(samples: []const i16) [16]u8 {
    var h = std.crypto.hash.Md5.init(.{});
    for (samples) |s| {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, s, .little);
        h.update(&b);
    }
    var out: [16]u8 = undefined;
    h.final(&out);
    return out;
}

const FlacDecoder = opaque {};
const FlacRead = fn (?*const FlacDecoder, [*]u8, *usize, ?*anyopaque) callconv(.c) c_int;
const FlacWrite = fn (?*const FlacDecoder, *const anyopaque, [*]const [*]const i32, ?*anyopaque) callconv(.c) c_int;
const FlacError = fn (?*const FlacDecoder, c_int, ?*anyopaque) callconv(.c) void;
extern fn FLAC__stream_decoder_new() ?*FlacDecoder;
extern fn FLAC__stream_decoder_delete(d: *FlacDecoder) void;
extern fn FLAC__stream_decoder_set_md5_checking(d: *FlacDecoder, value: c_int) c_int;
extern fn FLAC__stream_decoder_init_stream(
    d: *FlacDecoder,
    read: *const FlacRead,
    seek: ?*const anyopaque,
    tell: ?*const anyopaque,
    length: ?*const anyopaque,
    eof: ?*const anyopaque,
    write: *const FlacWrite,
    metadata: ?*const anyopaque,
    err: *const FlacError,
    client: ?*anyopaque,
) c_int;
extern fn FLAC__stream_decoder_process_until_end_of_stream(d: *FlacDecoder) c_int;
extern fn FLAC__stream_decoder_finish(d: *FlacDecoder) c_int;

const FlacStream = struct {
    bytes: []const u8,
    at: usize = 0,
    samples: std.ArrayList(i16) = .empty,
    failed: bool = false,

    fn read(_: ?*const FlacDecoder, buf: [*]u8, len: *usize, client: ?*anyopaque) callconv(.c) c_int {
        const f: *FlacStream = @ptrCast(@alignCast(client));
        const n = @min(len.*, f.bytes.len - f.at);
        @memcpy(buf[0..n], f.bytes[f.at..][0..n]);
        f.at += n;
        len.* = n;
        return if (n == 0) 1 else 0; // END_OF_STREAM, CONTINUE
    }

    /// A `FLAC__Frame` starts with its header, whose first field is the block size.
    fn write(_: ?*const FlacDecoder, frame: *const anyopaque, buffer: [*]const [*]const i32, client: ?*anyopaque) callconv(.c) c_int {
        const f: *FlacStream = @ptrCast(@alignCast(client));
        const block: u32 = @as(*const u32, @ptrCast(@alignCast(frame))).*;
        for (buffer[0][0..block]) |s| {
            const sample = std.math.cast(i16, s) orelse {
                f.failed = true;
                return 1; // ABORT
            };
            f.samples.append(gpa, sample) catch {
                f.failed = true;
                return 1;
            };
        }
        return 0; // CONTINUE
    }

    fn fail(_: ?*const FlacDecoder, _: c_int, client: ?*anyopaque) callconv(.c) void {
        const f: *FlacStream = @ptrCast(@alignCast(client));
        f.failed = true;
    }
};

/// Decodes `flac` with libFLAC's MD5 check on. The caller frees the samples.
fn decodeFlac(flac: []const u8) ![]i16 {
    const dec = FLAC__stream_decoder_new() orelse return error.FlacDecoder;
    defer FLAC__stream_decoder_delete(dec);
    try expect(FLAC__stream_decoder_set_md5_checking(dec, 1) != 0);
    var f: FlacStream = .{ .bytes = flac };
    errdefer f.samples.deinit(gpa);
    try expectEqual(0, FLAC__stream_decoder_init_stream(dec, FlacStream.read, null, null, null, null, FlacStream.write, null, FlacStream.fail, &f));
    try expect(FLAC__stream_decoder_process_until_end_of_stream(dec) != 0);
    // finish answers false when the decoded samples' MD5 differs from STREAMINFO's.
    try expect(FLAC__stream_decoder_finish(dec) != 0);
    try expect(!f.failed);
    return f.samples.toOwnedSlice(gpa);
}

// --- Tests ---

test "AC-1, AC-2, AC-3: 2 s of a 440 Hz sine at 48 kHz encode to a 16 kbit/s mono Ogg Opus that decodes back to it" {
    const n = 96_000;
    const samples = try sine(n, 48000, 440);
    defer gpa.free(samples);
    const e = try audio.encode(gpa, samples, 48000);
    defer free(e);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ogg = try readOgg(arena.allocator(), e.opus);
    try expect(ogg.packets.len > 2);

    // OpusHead alone on the first page, OpusTags opening the second.
    const head = try opusHead(ogg.packets[0]);
    try expectEqual(0, ogg.first_page[0]);
    try expectEqual(1, ogg.first_page[1]);
    try expect(ogg.packets[1].len >= 8);
    try expectEqualStrings("OpusTags", ogg.packets[1][0..8]);
    try expectEqual(1, head.channels);
    try expectEqual(48000, head.input_rate);
    try expectEqual(n, ogg.granule - head.pre_skip);

    // Decoded, trimmed to the last granule, minus the pre-skip: the input's length and tone.
    const audio_packets = ogg.packets[2..];
    const decoded = try decodeOpus(audio_packets);
    defer gpa.free(decoded);
    try expect(decoded.len >= ogg.granule);
    const signal = decoded[head.pre_skip..@intCast(ogg.granule)];
    try expectEqual(n, signal.len);
    const tone = power(signal, 48000, 440);
    for ([_]f64{ 220, 330, 660, 880, 1000, 2000, 4000 }) |other| try expect(tone > 10 * power(signal, 48000, other));

    var bytes: usize = 0;
    for (audio_packets) |p| bytes += p.len;
    const bitrate = @as(f64, @floatFromInt(bytes * 8)) / (@as(f64, n) / 48000);
    try expect(bitrate >= 16000 * 0.8);
    try expect(bitrate <= 16000 * 1.2);
}

test "AC-4: the same 2 s at 48 kHz compress to a FLAC that decodes to the input exactly" {
    const n = 96_000;
    const samples = try sine(n, 48000, 440);
    defer gpa.free(samples);
    const e = try audio.encode(gpa, samples, 48000);
    defer free(e);

    const info = try streamInfo(e.flac);
    try expectEqual(48000, info.rate);
    try expectEqual(1, info.channels);
    try expectEqual(16, info.bits);
    try expectEqual(n, info.samples);
    try expectEqualSlices(u8, &md5(samples), &info.md5);

    const decoded = try decodeFlac(e.flac);
    defer gpa.free(decoded);
    try expectEqualSlices(i16, samples, decoded);
}

test "AC-5, AC-7: 120,000 samples at 48 kHz encode to the same bytes twice and last 2500 ms" {
    const samples = try sine(120_000, 48000, 440);
    defer gpa.free(samples);
    const first = try audio.encode(gpa, samples, 48000);
    defer free(first);
    const second = try audio.encode(gpa, samples, 48000);
    defer free(second);

    try expectEqual(2500, first.audio_ms);
    try expectEqual(2500, second.audio_ms);
    try expectEqualSlices(u8, first.opus, second.opus);
    try expectEqualSlices(u8, first.flac, second.flac);
}

test "AC-6: 24 kHz input keeps its rate in OpusHead and STREAMINFO, its length in audio_ms rounded down, and twice its samples in granules" {
    // 1500.5 ms: audio_ms is rounded down.
    const n = 36_012;
    const samples = try sine(n, 24000, 440);
    defer gpa.free(samples);
    const e = try audio.encode(gpa, samples, 24000);
    defer free(e);

    try expectEqual(n * 1000 / 24000, e.audio_ms);
    try expectEqual(1500, e.audio_ms);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ogg = try readOgg(arena.allocator(), e.opus);
    const head = try opusHead(ogg.packets[0]);
    try expectEqual(24000, head.input_rate);
    try expectEqual(1, head.channels);
    try expectEqual(n * 2, ogg.granule - head.pre_skip);

    const info = try streamInfo(e.flac);
    try expectEqual(24000, info.rate);
    try expectEqual(n, info.samples);
    const decoded = try decodeFlac(e.flac);
    defer gpa.free(decoded);
    try expectEqualSlices(i16, samples, decoded);
}

test "AC-F1, AC-F2: no samples, or a rate the codecs don't take, is an error that leaks nothing" {
    const samples = try sine(4800, 48000, 440);
    defer gpa.free(samples);
    try expectError(error.NoAudio, audio.encode(gpa, &.{}, 48000));
    try expectError(error.UnsupportedRate, audio.encode(gpa, samples, 0));
    try expectError(error.UnsupportedRate, audio.encode(gpa, samples, 200_000));
}

fn encodeAndFree(a: Allocator, samples: []const i16) !void {
    const e = try audio.encode(a, samples, 48000);
    a.free(e.opus);
    a.free(e.flac);
}

test "AC-F3: every allocation failure during an encode returns error.OutOfMemory with no leak" {
    const samples = try sine(4800, 48000, 440);
    defer gpa.free(samples);
    // On gpa, the .opus list's growth sometimes stays in place and sometimes moves, so the
    // allocation count changes between runs. A fixed buffer grows the same way every time;
    // the failing allocator still counts a leak as allocated bytes never freed.
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var fixed: std.heap.FixedBufferAllocator = .init(buf);
    try std.testing.checkAllAllocationFailures(fixed.allocator(), encodeAndFree, .{samples});
}
