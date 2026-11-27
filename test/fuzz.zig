//! Fuzz tests for hostile input (AGENTS.md, Testing): the boundary parsers and the server's
//! HTTP layer. `zig build test` replays only the corpus below, a regression suite of real and
//! broken bodies; `zig build test --fuzz` fuzzes them (Linux; see infra/README.md).
//!
//! Properties: no input panics; every rejection is one of the parser's declared errors; what a
//! parser accepts, its writer gives back byte for byte; the server answers every request (or
//! closes) and keeps serving after it.

const std = @import("std");
const Io = std.Io;
const server = @import("server");
const wire = server.wire;
const Harness = @import("harness").Harness;

const io = std.testing.io;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

/// A corpus entry for one `smith.slice`: its length (u32, little-endian), then the bytes.
fn entry(comptime bytes: []const u8) []const u8 {
    return comptime blk: {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, bytes.len, .little);
        break :blk &len ++ bytes;
    };
}

/// `b` repeated `n` times.
fn rep(comptime b: []const u8, comptime n: usize) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        for (0..n) |_| out = out ++ b;
        break :blk out;
    };
}

fn translation(comptime lang: []const u8, comptime sha: u8) []const u8 {
    return lang ++ rep("\x00", 8 - lang.len) ++ rep(&.{sha}, 32);
}

const id = rep("\x11", 16);
const valid_story = "STRY\x01" ++ id ++ "\x02" ++ translation("it", 0xaa) ++ translation("pt-BR", 0xbb);

const story_corpus = [_][]const u8{
    entry(valid_story),
    entry("STRY\x01" ++ id ++ "\x01" ++ translation("it", 0xaa)),
    entry("STRZ" ++ valid_story[4..]),
    entry("STRY\x02" ++ valid_story[5..]),
    entry(valid_story ++ "\x00"),
    entry(valid_story[0 .. valid_story.len - 1]),
    entry("STRY\x01" ++ id ++ "\x00"),
    entry("STRY\x01" ++ id ++ "\x02" ++ translation("it", 0xaa) ++ translation("it", 0xbb)),
    entry("STRY\x01" ++ id ++ "\x01" ++ translation("pt-BR", 0xaa)),
    entry("STRY\x01" ++ id ++ "\x01" ++ "i\x00t" ++ rep("\x00", 5) ++ rep("\xaa", 32)),
    entry("STRY\x01" ++ id ++ "\x01" ++ "\xc3\xa9t" ++ rep("\x00", 5) ++ rep("\xaa", 32)),
    entry("STRY"),
    entry(""),
};

test "fuzz parseStory: accepts or names its error; what it accepts writes back byte for byte" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [wire.story_max + 64]u8 = undefined;
            const body = buf[0..smith.slice(&buf)];
            var story: wire.Story = .{};
            wire.parseStory(body, &story) catch |err| {
                // A closed set: anything else would be a new failure mode the server doesn't map.
                switch (err) {
                    error.BadMagic, error.BadVersion, error.WrongLength, error.BadLang, error.RepeatedLang, error.NoOriginal => {},
                }
                if (err == error.RepeatedLang) try expect(story.n < 255);
                return;
            };
            const langs, _ = story.translations();
            try expect(langs.len >= 1);
            var original = false;
            for (langs, 0..) |l, i| {
                original = original or std.mem.eql(u8, l.text(), "it");
                for (langs[0..i]) |p| try expect(!std.mem.eql(u8, &p.bytes, &l.bytes));
            }
            try expect(original);
            var out: [wire.story_max]u8 = undefined;
            try expectEqualSlices(u8, body, wire.writeStory(&story, &out));
        }
    }.testOne, .{ .corpus = &story_corpus });
}

test "fuzz StoryId.parse: what it accepts is the written form, lowercase or not" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const written = buf[0..smith.slice(&buf)];
            const story_id = wire.StoryId.parse(written) catch |err| {
                try expect(err == error.BadUuid);
                return;
            };
            const text = story_id.text();
            try expect(std.ascii.eqlIgnoreCase(&text, written));
            try expectEqualSlices(u8, &story_id.bytes, &(try wire.StoryId.parse(&text)).bytes);
        }
    }.testOne, .{ .corpus = &.{
        entry("d0159518-99cc-46f0-bef2-b5b6f6f9a76d"),
        entry("D0159518-99CC-46F0-BEF2-B5B6F6F9A76D"),
        entry("d0159518-99cc-46f0-bef2-b5b6f6f9a76"),
        entry("d0159518x99cc-46f0-bef2-b5b6f6f9a76d"),
        entry("g0159518-99cc-46f0-bef2-b5b6f6f9a76d"),
    } });
}

test "fuzz Reader.lang: a lang is non-empty printable ASCII then only zeros, and reads back" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = @splat(0);
            _ = smith.slice(&buf);
            var r: wire.Reader = .{ .buf = &buf };
            const l = r.lang() catch |err| {
                try expect(err == error.BadLang);
                return;
            };
            const tag = l.text();
            try expect(tag.len >= 1 and tag.len <= 8);
            for (tag) |ch| try expect(ch > ' ' and ch <= '~');
            try expectEqualSlices(u8, &buf, &(try wire.Lang.fromText(tag)).bytes);
        }
    }.testOne, .{ .corpus = &.{ entry("it"), entry("pt-BR\x00\x00\x00"), entry("i\x00t"), entry("\xc3\xa9"), entry("") } });
}

/// One request's bytes, exactly as given, then the write half closed so the server never waits
/// for more; reads until the server closes.
fn raw(port: u16, bytes: []const u8) !void {
    const address = try Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out = stream.writer(io, &.{});
    out.interface.writeAll(bytes) catch {};
    stream.shutdown(io, .send) catch {};
    var in_buf: [4096]u8 = undefined;
    var in = stream.reader(io, &in_buf);
    while (true) {
        in.interface.fillMore() catch break;
        in.interface.tossBuffered();
    }
}

test "fuzz the server's HTTP layer: any request bytes, and it keeps serving" {
    var h: Harness = undefined;
    try h.start();
    defer h.stop();
    const auth = "authorization: Bearer test-token\r\n";
    try std.testing.fuzz(&h, struct {
        fn testOne(harness: *Harness, smith: *std.testing.Smith) anyerror!void {
            var buf: [16 * 1024]u8 = undefined;
            try raw(harness.port, buf[0..smith.slice(&buf)]);
            var resp_buf: [4096]u8 = undefined;
            const r = try harness.send("GET /languages HTTP/1.1", "", &resp_buf);
            try expect(r.status == 200);
        }
    }.testOne, .{ .corpus = &.{
        entry("GET /stories?since=0&lang=it,pt-BR HTTP/1.1\r\nhost: x\r\n\r\n"),
        entry("GET /stories?since=99999999999&lang=it HTTP/1.1\r\n\r\n"),
        entry("GET /stories?lang=,,,,, HTTP/1.1\r\n\r\n"),
        entry("GET /stories?since=1&since=2&lang=it HTTP/1.1\r\n\r\n"),
        entry("POST /stories HTTP/1.1\r\n" ++ auth ++ "content-length: 102\r\n\r\n" ++ valid_story),
        entry("POST /stories HTTP/1.1\r\n" ++ auth ++ "content-length: 5\r\n\r\nSTRY\x01"),
        entry("POST /stories HTTP/1.1\r\n" ++ auth ++ "content-length: 999999999\r\n\r\n"),
        entry("POST /stories HTTP/1.1\r\n" ++ auth ++ "transfer-encoding: chunked\r\n\r\n5\r\nSTRY\x01\r\n0\r\n\r\n"),
        entry("DELETE /stories/not-a-uuid HTTP/1.1\r\n" ++ auth ++ "\r\n"),
        entry("DELETE /stories/" ++ "d0159518-99cc-46f0-bef2-b5b6f6f9a76d" ++ " HTTP/1.1\r\n\r\n"),
        entry("GET / HTTP/9.9\r\n\r\n"),
        entry("\x00\x01\x02\xff\r\n\r\n"),
        entry("GET " ++ rep("/a", 4000) ++ " HTTP/1.1\r\n\r\n"),
    } });
}
