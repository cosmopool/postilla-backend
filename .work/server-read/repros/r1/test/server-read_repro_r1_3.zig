const std = @import("std");
const harness = @import("harness");
const Harness = harness.Harness;

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectNotFound(h: *const Harness, head: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const r = try h.send(head, "", &buf);
    try expectEqual(@as(u16, 404), r.status);
    try expectEqualStrings("text/plain", r.header("content-type"));
    try expectEqualStrings("not found\n", r.body);
}

test "AC-10: a well-formed request with a method other than GET (PROPFIND, lowercase get) gets 404 not found" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    // Both are valid method tokens in a well-formed head, so this is AC-10, not AC-F1.
    try expectNotFound(&h, "PROPFIND /genres HTTP/1.1");
    try expectNotFound(&h, "get /languages HTTP/1.1");
}
