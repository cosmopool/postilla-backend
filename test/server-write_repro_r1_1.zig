const std = @import("std");
const harness = @import("harness");
const Harness = harness.Harness;

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const auth = "\r\nauthorization: Bearer " ++ harness.token;

test "AC-6: a STRY with lang_count 0 gets 400 'body: wrong length', rule 2 before rule 4" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();

    // 22 bytes: magic, version, a story id, and lang_count 0. specification.md checks the
    // parse rules in order, and rule 2 (`lang_count` is at least 1) comes before rule 4
    // (no `it`), so the reason is the length one.
    const body = "STRY\x01" ++ @as([16]u8, @splat(0x11)) ++ "\x00";
    var buf: [4096]u8 = undefined;
    const r = try h.send("POST /stories HTTP/1.1" ++ auth, body, &buf);
    try expectEqual(400, r.status);
    try expectEqualStrings("text/plain", r.header("content-type"));
    try expectEqualStrings("body: wrong length\n", r.body);
}
