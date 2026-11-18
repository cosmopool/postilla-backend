const std = @import("std");
const Harness = @import("harness").Harness;

test "an unknown path gets a 404 with a one-line reason" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    var buf: [4096]u8 = undefined;
    const r = try h.send("GET /nope HTTP/1.1", "", &buf);
    try std.testing.expectEqual(404, r.status);
    try std.testing.expectEqualStrings("text/plain", r.header("content-type"));
    try std.testing.expectEqualStrings("not found\n", r.body);
}
