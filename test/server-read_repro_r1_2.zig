const std = @import("std");
const harness = @import("harness");
const Harness = harness.Harness;

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectReason(h: *const Harness, head: []const u8, status: u16, reason: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const r = try h.send(head, "", &buf);
    try expectEqual(status, r.status);
    try expectEqualStrings("text/plain", r.header("content-type"));
    try expectEqualStrings(reason, r.body);
}

test "AC-10: a path that only starts with a known path before '&' gets 404 not found" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    // The path ends at the first '?'; '&' is part of the path, so these are other paths.
    try expectReason(&h, "GET /genres&x HTTP/1.1", 404, "not found\n");
    try expectReason(&h, "GET /languages&x HTTP/1.1", 404, "not found\n");
    try expectReason(&h, "GET /stories&lang=it HTTP/1.1", 404, "not found\n");
}

test "AC-6, AC-9: a second '?' inside the query is part of a value, not a separator" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    // The query is `lang=it?since=5`: one parameter, whose value is the id `it?since=5`.
    try expectReason(&h, "GET /stories?lang=it?since=5 HTTP/1.1", 400, "lang: unknown id 'it?since=5'\n");
}
