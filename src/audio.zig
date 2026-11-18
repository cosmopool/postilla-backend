//! The narration's PCM to its two files in memory: the Ogg Opus `.opus` for the app
//! (libopusenc over libopus) and the lossless `.flac` master (libFLAC).

const std = @import("std");
const c = @import("c");

/// The two files and the audio's length, all in the allocator given to `encode`.
pub const Encoded = struct { opus: []u8, flac: []u8, audio_ms: u32 };

/// Encodes 16-bit mono `samples` at `rate` Hz. Opus: 16 kbit/s voice, complexity 10, Ogg
/// serial 1, so the same samples give the same bytes. FLAC: level 8, with its MD5.
pub fn encode(a: std.mem.Allocator, samples: []const i16, rate: u32) !Encoded {
    if (samples.len == 0) return error.NoAudio;
    if (rate < 8000 or rate > 96000) return error.UnsupportedRate;

    const comments = c.ope_comments_create() orelse return error.OpusEncode;
    defer c.ope_comments_destroy(comments);
    const enc = c.ope_encoder_create_pull(comments, @intCast(rate), 1, 0, null) orelse return error.OpusEncode;
    defer c.ope_encoder_destroy(enc);
    if (c.ope_encoder_ctl(enc, c.OPE_SET_SERIALNO_REQUEST, @as(i32, 1)) != 0 or
        c.ope_encoder_ctl(enc, c.OPUS_SET_BITRATE_REQUEST, @as(i32, 16000)) != 0 or
        c.ope_encoder_ctl(enc, c.OPUS_SET_SIGNAL_REQUEST, @as(i32, c.OPUS_SIGNAL_VOICE)) != 0 or
        c.ope_encoder_ctl(enc, c.OPUS_SET_COMPLEXITY_REQUEST, @as(i32, 10)) != 0 or
        c.ope_encoder_write(enc, samples.ptr, @intCast(samples.len)) != 0 or
        c.ope_encoder_drain(enc) != 0) return error.OpusEncode;
    var opus: std.ArrayList(u8) = .empty;
    errdefer opus.deinit(a);
    var page: [*c]u8 = undefined;
    var len: i32 = 0;
    while (c.ope_encoder_get_page(enc, &page, &len, 1) == 1) try opus.appendSlice(a, page[0..@intCast(len)]);

    // libFLAC writes through callbacks, which can't return a Zig error: they append with
    // libc's malloc, and the result is copied into `a` once.
    var flac: std.ArrayList(u8) = .empty;
    defer flac.deinit(std.heap.c_allocator);
    const wide = try a.alloc(i32, samples.len);
    defer a.free(wide);
    for (samples, wide) |s, *w| w.* = s;
    const f = c.FLAC__stream_encoder_new() orelse return error.FlacEncode;
    defer c.FLAC__stream_encoder_delete(f);
    if (c.FLAC__stream_encoder_set_channels(f, 1) & c.FLAC__stream_encoder_set_bits_per_sample(f, 16) & c.FLAC__stream_encoder_set_sample_rate(f, rate) &
        c.FLAC__stream_encoder_set_compression_level(f, 8) & c.FLAC__stream_encoder_set_total_samples_estimate(f, samples.len) == 0 or
        c.FLAC__stream_encoder_init_stream(f, flacWrite, null, null, flacStreamInfo, &flac) != c.FLAC__STREAM_ENCODER_INIT_STATUS_OK or
        c.FLAC__stream_encoder_process_interleaved(f, wide.ptr, @intCast(samples.len)) == 0 or
        c.FLAC__stream_encoder_finish(f) == 0) return error.FlacEncode;

    const opus_out = try opus.toOwnedSlice(a);
    errdefer a.free(opus_out);
    return .{ .opus = opus_out, .flac = try a.dupe(u8, flac.items), .audio_ms = @intCast(samples.len * 1000 / rate) };
}

fn flacWrite(_: ?*const c.FLAC__StreamEncoder, bytes: [*c]const u8, len: usize, _: u32, _: u32, out: ?*anyopaque) callconv(.c) c.FLAC__StreamEncoderWriteStatus {
    const list: *std.ArrayList(u8) = @ptrCast(@alignCast(out));
    list.appendSlice(std.heap.c_allocator, bytes[0..len]) catch return c.FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR;
    return c.FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
}

/// With no seek callback, libFLAC hands over the final STREAMINFO at the end instead of
/// rewriting it: its MD5 goes in place, after `fLaC` and the block header.
fn flacStreamInfo(_: ?*const c.FLAC__StreamEncoder, info: [*c]const c.FLAC__StreamMetadata, out: ?*anyopaque) callconv(.c) void {
    const list: *std.ArrayList(u8) = @ptrCast(@alignCast(out));
    @memcpy(list.items[26..42], &info.*.data.stream_info.md5sum);
}
