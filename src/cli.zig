//! postilla: the authoring CLI (specification.md, The CLI). Each command works on one
//! story folder. The commands come with their slices; `publish` is the first.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const wire = @import("server").wire;
const tilla = @import("tilla");
const r2 = @import("r2");
const outbound = @import("outbound.zig");

const usage =
    \\usage: postilla <command> <folder>
    \\
    \\  translate <folder> [--force] [--redo <lang>]   moderate the Italian, translate the missing languages
    \\  narrate   <folder>                             narrate every language with target 1
    \\  publish   <folder>                             build the .tilla files, upload to R2, POST /stories
    \\
;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    std.process.exit(run(init.io, a, init.environ_map, .cwd(), try init.minimal.args.toSlice(a)));
}

/// Runs the command in `args` (program name first) with `env` and `cwd` as the process's
/// environment and current directory, printing to stderr. Returns the exit code: 0 done,
/// 1 failed, 2 usage error.
pub fn run(io: Io, arena: Allocator, env: *std.process.Environ.Map, cwd: Io.Dir, args: []const [:0]const u8) u8 {
    var buf: [4096]u8 = undefined;
    var out = Io.File.stderr().writerStreaming(io, &buf);
    defer out.interface.flush() catch {};
    if (args.len != 3 or !std.mem.eql(u8, args[1], "publish")) {
        out.interface.writeAll(usage) catch {};
        return 2;
    }
    return publish(io, arena, env, cwd, args[2], &out.interface) catch |err| fail(&out.interface, "publish: {t}", .{err});
}

/// Prints one line naming what failed; returns exit code 1.
fn fail(w: *Io.Writer, comptime format: []const u8, args: anytype) u8 {
    w.print(format ++ "\n", args) catch {};
    return 1;
}

/// `postilla publish <folder>` (specification.md, `postilla publish`): the configuration,
/// `story.json`'s rules, the server's lists, then every `.tilla` built, every file uploaded,
/// and last `POST /stories`. Nothing is uploaded until every check has passed.
fn publish(io: Io, a: Allocator, env: *std.process.Environ.Map, cwd: Io.Dir, folder: []const u8, w: *Io.Writer) !u8 {
    if (cwd.readFileAlloc(io, "cli.env", a, .limited(1 << 20))) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse 0;
            if (eq == 0) return fail(w, "cli.env: line {d}: not KEY=value", .{n});
            if (!env.contains(line[0..eq])) try env.put(line[0..eq], line[eq + 1 ..]);
        }
    } else |err| if (err != error.FileNotFound) return err;
    for ([_][]const u8{
        "POSTILLA_SERVER_URL",    "POSTILLA_AUTHOR_TOKEN",     "POSTILLA_OPENCODE_KEY",         "POSTILLA_SPEECHIFY_KEY",
        "POSTILLA_R2_ACCOUNT_ID", "POSTILLA_R2_ACCESS_KEY_ID", "POSTILLA_R2_SECRET_ACCESS_KEY", "POSTILLA_R2_BUCKET",
    }) |name| if (@as([]const u8, env.get(name) orelse "").len == 0) return fail(w, "{s}: required", .{name});
    const server_url = env.get("POSTILLA_SERVER_URL").?;
    const client: r2.Client = .{
        .endpoint = env.get("POSTILLA_R2_ENDPOINT") orelse try std.fmt.allocPrint(a, "https://{s}.r2.cloudflarestorage.com", .{env.get("POSTILLA_R2_ACCOUNT_ID").?}),
        .bucket = env.get("POSTILLA_R2_BUCKET").?,
        .access_key_id = env.get("POSTILLA_R2_ACCESS_KEY_ID").?,
        .secret_access_key = env.get("POSTILLA_R2_SECRET_ACCESS_KEY").?,
    };

    var dir = cwd.openDir(io, folder, .{}) catch |err| return fail(w, "{s}: {t}", .{ folder, err });
    defer dir.close(io);
    const json = dir.readFileAlloc(io, "story.json", a, .limited(1 << 24)) catch |err| return fail(w, "{s}/story.json: {t}", .{ folder, err });
    const story = std.json.parseFromSliceLeaky(struct {
        id: []const u8,
        level: u8,
        genre: []const u8,
        tags: []const []const u8,
        work: []const u8,
        part: u16,
        author: []const u8,
        adapted: u8,
        license: []const u8,
        moderation: ?struct { none: f64, homophobic: f64, racist: f64, sexist: f64, religious: f64, other_hate: f64, forced: bool } = null,
        translations: std.json.ArrayHashMap(struct {
            title: []const u8,
            subtitle: []const u8,
            paragraphs: []const []const []const u8,
            audio: ?struct { audio_ms: u32, text_sha256: []const u8, times: []const []const [2]u32 } = null,
        }),
    }, a, json, .{}) catch |err| return fail(w, "story.json: {t}", .{err});
    const id = try wire.StoryId.parse(story.id);
    const translations = story.translations.map;

    var ascii = true;
    for (story.license) |ch| ascii = ascii and ch < 0x80;
    const broken: []const u8 = if (story.genre.len == 0) "genre: empty" else if (story.license.len == 0) "license: empty" else if (!ascii) "license: not ASCII" else if (story.level < 1 or story.level > 6) "level: not 1 to 6" else if (story.adapted > 1) "adapted: not 0 or 1" else if ((story.work.len == 0) != (story.part == 0)) "work: empty but part isn't 0, or the reverse" else if (story.adapted == 1 and story.author.len == 0) "adapted: 1 without an author" else "";
    if (broken.len > 0) return fail(w, "story.json: {s}", .{broken});
    for (story.tags, 0..) |tag, i| {
        if (tag.len == 0) return fail(w, "story.json: tags: empty", .{});
        for (story.tags[0..i]) |prev| if (std.mem.eql(u8, prev, tag)) return fail(w, "story.json: tags: '{s}' repeated", .{tag});
    }
    const it = translations.get("it") orelse return fail(w, "story.json: translations: no 'it'", .{});
    if (it.paragraphs.len == 0) return fail(w, "story.json: it: no paragraphs", .{});
    for (translations.keys(), translations.values()) |lang, t| {
        if (t.title.len == 0 or t.subtitle.len == 0) return fail(w, "story.json: {s}: empty title or subtitle", .{lang});
        if (t.paragraphs.len != it.paragraphs.len) return fail(w, "story.json: {s}: paragraph count differs from it", .{lang});
        for (t.paragraphs, it.paragraphs) |p, it_p| {
            if (p.len == 0 or p.len != it_p.len) return fail(w, "story.json: {s}: sentence count differs from it", .{lang});
            for (p) |s| if (s.len == 0) return fail(w, "story.json: {s}: empty sentence", .{lang});
        }
    }
    var chars: usize = 0;
    for (it.paragraphs) |p| for (p) |s| {
        chars += try std.unicode.utf8CountCodepoints(s);
    };
    if (chars > 20_000) return fail(w, "story.json: it: {d} characters, above 20 000", .{chars});

    // The server's lists, each id with its `target` and `translate` (/languages only).
    var lists: [4]std.StringArrayHashMapUnmanaged([2]u8) = @splat(.empty);
    for (&lists, [_][]const u8{ "genres", "tags", "authors", "languages" }, [_]*const [4]u8{ "GNRS", "TAGS", "AUTH", "LANG" }, [_]usize{ 3, 3, 1, 1 }) |*l, path, magic, names| {
        const res = try outbound.request(io, a, .{}, .GET, try std.fmt.allocPrint(a, "{s}/{s}", .{ server_url, path }), &.{}, "", "");
        if (res.status != .ok) return fail(w, "GET /{s}: {d}", .{ path, @backingInt(res.status) });
        var r: wire.Reader = .{ .buf = res.body };
        try r.header(magic);
        for (0..try r.int(u16)) |_| {
            const list_id = try r.str();
            for (0..names) |_| _ = try r.str();
            try l.put(a, list_id, if (magic[0] == 'L') .{ try r.int(u8), try r.int(u8) } else .{ 0, 0 });
        }
    }
    if (!lists[0].contains(story.genre)) return fail(w, "genre: '{s}' not listed by the server", .{story.genre});
    for (story.tags) |tag| if (!lists[1].contains(tag)) return fail(w, "tags: '{s}' not listed by the server", .{tag});
    if (story.author.len > 0 and !lists[2].contains(story.author)) return fail(w, "author: '{s}' not listed by the server", .{story.author});
    for (lists[3].keys(), lists[3].values()) |lang, flags| {
        if (flags[1] == 1 and !translations.contains(lang)) return fail(w, "{s}: missing, run translate", .{lang});
    }

    // Every translation's input, and the audio of each language with target 1.
    var inputs: std.ArrayList(tilla.Input) = .empty;
    var audio: std.ArrayList([2][]const u8) = .empty;
    for (translations.keys(), translations.values()) |lang, t| {
        const flags = lists[3].get(lang) orelse return fail(w, "translations: '{s}' not in language", .{lang});
        var in: tilla.Input = .{
            .id = id,
            .lang = try .fromText(lang),
            .original = try .fromText("it"),
            .title = t.title,
            .subtitle = t.subtitle,
            .level = story.level,
            .genre = story.genre,
            .tags = story.tags,
            .work = story.work,
            .part = story.part,
            .author = story.author,
            .adapted = story.adapted == 1,
            .license = story.license,
            .paragraphs = t.paragraphs,
        };
        if (flags[0] == 1) {
            // What narrate hashes: sentences joined by a space, paragraphs by a newline.
            var text: Sha256 = .init(.{});
            for (t.paragraphs, 0..) |p, i| for (p, 0..) |s, j| {
                text.update(if (j > 0) " " else if (i > 0) "\n" else "");
                text.update(s);
            };
            if (t.audio == null or !std.mem.eql(u8, t.audio.?.text_sha256, &std.fmt.bytesToHex(text.finalResult(), .lower)))
                return fail(w, "{s}: no narration of the current text, run narrate", .{lang});
            var sha: [2][32]u8 = undefined;
            for (&sha, [_][]const u8{ "opus", "flac" }) |*h, ext| {
                const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ lang, ext });
                const file = dir.readFileAlloc(io, name, a, .unlimited) catch |err| return fail(w, "{s}/{s}: {t}, run narrate", .{ folder, name, err });
                Sha256.hash(file, h, .{});
                try audio.append(a, .{ try std.fmt.allocPrint(a, "stories/{s}/{s}/{s}.{s}", .{ &id.text(), lang, &std.fmt.bytesToHex(h.*, .lower), ext }), file });
            }
            var times: std.ArrayList(std.meta.Child(@FieldType(@FieldType(tilla.Input, "narration"), "times"))) = .empty;
            for (t.audio.?.times) |p| for (p) |time| try times.append(a, .{ .start_ms = time[0], .end_ms = time[1] });
            in.narration = .{ .audio_ms = t.audio.?.audio_ms, .opus_sha256 = sha[0], .opus_size = @intCast(audio.items[audio.items.len - 2][1].len), .times = times.items };
        }
        try inputs.append(a, in);
    }

    const dict = try a.dupeSentinel(u8, client.dict(io, a, env.get("POSTILLA_DICT_DIR") orelse "./dict") catch |err| return fail(w, "dict: {t}", .{err}), 0);
    var uploads: std.ArrayList([2][]const u8) = .empty;
    var body: wire.Writer = .{ .buf = try a.alloc(u8, 22 + 40 * inputs.items.len) };
    body.header("STRY");
    body.bytes(&id.bytes);
    body.int(u8, @intCast(inputs.items.len));
    for (inputs.items) |*in| {
        const built = tilla.build(a, in.*, dict) catch |err| return fail(w, "{s}.tilla: {t} (dict.db {s})", .{ in.lang.text(), err, dict });
        try uploads.append(a, .{ try std.fmt.allocPrint(a, "stories/{s}/{s}/{s}.tilla.gz", .{ &id.text(), in.lang.text(), &std.fmt.bytesToHex(built.sha256, .lower) }), built.gz });
        body.bytes(&in.lang.bytes);
        body.bytes(&built.sha256);
    }
    try uploads.appendSlice(a, audio.items);
    for (uploads.items) |u| {
        const res = client.put(io, a, u[0], u[1]) catch |err| return fail(w, "upload {s}: {t}", .{ u[0], err });
        if (res.status != .ok) return fail(w, "upload {s}: {d}", .{ u[0], @backingInt(res.status) });
        try w.print("uploaded {s}\n", .{u[0]});
    }

    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{env.get("POSTILLA_AUTHOR_TOKEN").?});
    const res = try outbound.request(io, a, .{}, .POST, try std.fmt.allocPrint(a, "{s}/stories", .{server_url}), &.{.{ .name = "authorization", .value = auth }}, body.written(), "");
    if (res.status != .ok) return fail(w, "POST /stories: {d} {s}", .{ @backingInt(res.status), std.mem.trimEnd(u8, res.body, "\n") });
    try w.print("published {s}\n", .{&id.text()});
    return 0;
}
