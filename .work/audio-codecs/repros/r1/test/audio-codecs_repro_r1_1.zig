//! A rate inside 8,000 to 96,000 Hz that libFLAC's streamable subset refuses (at or above
//! 65,536 Hz and not a multiple of 10) must be turned away as `error.UnsupportedRate`
//! before any C call, not run a whole Opus encode and then fail as `error.FlacEncode`.

const std = @import("std");
const audio = @import("audio");

const gpa = std.testing.allocator;

test "AC-F2: a rate libFLAC refuses, 88,201 Hz, returns error.UnsupportedRate, not error.FlacEncode" {
    const samples = try gpa.alloc(i16, 88201);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| s.* = @intCast(@as(i32, @intCast(i % 200)) * 50 - 5000);
    const result = audio.encode(gpa, samples, 88201);
    if (result) |e| {
        gpa.free(e.opus);
        gpa.free(e.flac);
    } else |_| {}
    try std.testing.expectError(error.UnsupportedRate, result);
}
