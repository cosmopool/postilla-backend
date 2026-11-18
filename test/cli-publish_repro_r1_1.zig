//! A `cli.env` with `POSTILLA_R2_ENDPOINT=` (cli.env.example's commented line uncommented
//! and left blank) must get the default endpoint: docs/specification.md, CLI, says "An
//! empty value counts as missing", and the default is
//! `https://<account>.r2.cloudflarestorage.com`. The story here passes every check against
//! the real server, so the next step is the dictionary download from R2.
//!
//! The account id is `[`, which makes the default URL one `std.Uri` refuses at once, so a
//! CLI that takes the default fails on the spot, with one line and exit code 1, instead of
//! retrying a real Cloudflare host for minutes. A CLI that keeps the empty endpoint crashes
//! instead, because signing looks for `://` in it.

const std = @import("std");
const cli = @import("cli");
const harness = @import("harness");

const io = std.testing.io;
const gpa = std.testing.allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

/// The Italian as narrated: its sentences joined by one space, its paragraphs by one newline.
const it_text = "Il gatto entra in casa. Apre la porta.\nFuori tira aria di festa.";

const story_template =
    \\{
    \\  "id": "d0159518-99cc-46f0-bef2-b5b6f6f9a76d",
    \\  "level": 2,
    \\  "genre": "classici",
    \\  "tags": ["legno"],
    \\  "work": "Pinocchio",
    \\  "part": 1,
    \\  "author": "collodi",
    \\  "adapted": 1,
    \\  "license": "public-domain",
    \\  "translations": {
    \\    "it": {"title": "Il gatto e la porta", "subtitle": "Una storia di casa", "paragraphs": [["Il gatto entra in casa.", "Apre la porta."], ["Fuori tira aria di festa."]],
    \\           "audio": {"audio_ms": 5000, "text_sha256": "TEXT_SHA256", "times": [[[0, 1500], [1600, 2900]], [[3000, 4800]]]}},
    \\    "pt-BR": {"title": "O gato e a porta", "subtitle": "Uma história de casa", "paragraphs": [["O gato entra em casa.", "Abre a porta."], ["Lá fora há ar de festa."]]}
    \\  }
    \\}
    \\
;

test "AC-1: POSTILLA_R2_ENDPOINT= in cli.env counts as missing and the default endpoint is used, without a crash" {
    var h: harness.Harness = undefined;
    try h.start();
    defer h.stop();
    try h.sql("INSERT INTO tag VALUES ('legno', 'Legno', 'Madeira', 'Wood');");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    var digest: [32]u8 = undefined;
    Sha256.hash(it_text, &digest, .{});
    const json = try std.mem.replaceOwned(u8, a, story_template, "TEXT_SHA256", &std.fmt.bytesToHex(digest, .lower));
    try tmp.dir.createDirPath(io, "story");
    try tmp.dir.createDirPath(io, "dict");
    try tmp.dir.writeFile(io, .{ .sub_path = "story/story.json", .data = json });
    try tmp.dir.writeFile(io, .{ .sub_path = "story/it.opus", .data = "OggS\x00\x02 the narration for the app \xff\x00" });
    try tmp.dir.writeFile(io, .{ .sub_path = "story/it.flac", .data = "fLaC\x00\x00\x00\x22 the narration master \xff\x00" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cli.env", .data = "# R2's S3 API base URL, when it isn't the account's\nPOSTILLA_R2_ENDPOINT=\n" });

    var env: std.process.Environ.Map = .init(a);
    try env.put("POSTILLA_SERVER_URL", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{h.port}));
    try env.put("POSTILLA_AUTHOR_TOKEN", harness.token);
    try env.put("POSTILLA_OPENCODE_KEY", "test-opencode-key");
    try env.put("POSTILLA_SPEECHIFY_KEY", "test-speechify-key");
    try env.put("POSTILLA_R2_ACCOUNT_ID", "[");
    try env.put("POSTILLA_R2_ACCESS_KEY_ID", "test-key-id");
    try env.put("POSTILLA_R2_SECRET_ACCESS_KEY", "test-secret-access-key");
    try env.put("POSTILLA_R2_BUCKET", "postilla");
    try env.put("POSTILLA_DICT_DIR", try std.fmt.allocPrint(a, "{s}/dict", .{root}));

    const path = try std.fmt.allocPrintSentinel(a, "{s}/story", .{root}, 0);
    const code = cli.run(io, a, &env, tmp.dir, &.{ "postilla", "publish", path });
    try expectEqual(1, code);

    var buf: [4096]u8 = undefined;
    const feed = try h.send("GET /stories?lang=it,pt-BR HTTP/1.1", "", &buf);
    try expectEqual(200, feed.status);
    try expectEqualSlices(u8, "FEED\x01\x00\x00\x00\x00", feed.body);
}
