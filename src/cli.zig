//! postilla: the authoring CLI (specification.md, The CLI). Each command works on one
//! story folder: `translate`, `narrate` and `publish`.

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
    var ok = (args.len == 3 and (std.mem.eql(u8, args[1], "publish") or std.mem.eql(u8, args[1], "narrate"))) or (args.len >= 3 and std.mem.eql(u8, args[1], "translate"));
    var force = false;
    var redo: []const u8 = "";
    var i: usize = 3;
    while (ok and i < args.len) : (i += 1) {
        if (!force and std.mem.eql(u8, args[i], "--force")) {
            force = true;
        } else if (redo.len == 0 and std.mem.eql(u8, args[i], "--redo") and i + 1 < args.len) {
            i += 1;
            redo = args[i];
        } else ok = false;
    }
    if (!ok) {
        out.interface.writeAll(usage) catch {};
        return 2;
    }
    return command(io, arena, env, cwd, args[2], &out.interface, args[1][0] == 't', args[1][0] == 'n', force, redo) catch |err| fail(&out.interface, "{s}: {t}", .{ args[1], err });
}

/// Prints one line naming what failed; returns exit code 1.
fn fail(w: *Io.Writer, comptime format: []const u8, args: anytype) u8 {
    w.print(format ++ "\n", args) catch {};
    return 1;
}

/// Asks Jev (specification.md, Moderation) for the scores of `state`, in the order of
/// `story.json`'s `moderation`, into `scores`. Returns Jev's status; `scores` is set only on
/// a 200.
pub fn moderate(io: Io, a: Allocator, base: []const u8, headers: []const std.http.Header, state: []const u8, scores: *[6]f64) !std.http.Status {
    const res = try outbound.request(io, a, .{}, .POST, try std.fmt.allocPrint(a, "{s}/systemone/v1/systemone", .{base}), headers, try std.json.Stringify.valueAlloc(a, .{
        .model = "jev-1.13",
        .state = state,
        .questions = .{ .hate = .{ .type = "choice", .instructions = "Does this Italian text contain hate speech? Pick the kind, or none.", .criteria = .{
            .none = "No hate speech: the text attacks no group for who they are",
            .homophobic = "Attacks or demeans people for their sexual orientation or gender identity",
            .racist = "Attacks or demeans people for their race, ethnicity or nationality",
            .sexist = "Attacks or demeans people for their sex or gender",
            .religious = "Attacks or demeans people for their religion",
            .other_hate = "Attacks or demeans another protected group, such as disabled people",
        } } },
    }, .{}), "");
    if (res.status != .ok) return res.status;
    const p = (try std.json.parseFromSliceLeaky(struct { answers: struct { hate: struct { probabilities: struct { none: f64, homophobic: f64, racist: f64, sexist: f64, religious: f64, other_hate: f64 } } } }, a, res.body, .{ .ignore_unknown_fields = true })).answers.hate.probabilities;
    scores.* = .{ p.none, p.homophobic, p.racist, p.sexist, p.religious, p.other_hate };
    return .ok;
}

/// The English name DeepSeek's system message gives each language with `translate` 1.
const prompt_names: std.StaticStringMap([]const u8) = .initComptime(.{.{ "pt-BR", "Brazilian Portuguese" }});

/// Speechify's `voice_id` and `language` for each language with `target` 1.
const voices: std.StaticStringMap([2][]const u8) = .initComptime(.{.{ "it", .{ "daniele-agent", "it-IT" } }});

/// DeepSeek's system message, `{0s}` the prompt name and `{1s}` the CEFR level.
const system_message =
    \\You translate short Italian stories into {0s} for {0s} speakers learning Italian.
    \\
    \\- Write natural {0s}, the way a native writer would, not word for word.
    \\- Keep each sentence's meaning inside that sentence. Never move, merge or split content between sentences.
    \\- Keep the names of people and places as they are in the Italian.
    \\- The story is CEFR level {1s}. Keep the {0s} as simple as the Italian.
    \\- The user message is a JSON object with "title" (the story's title), "previous" (the previous paragraph's Italian sentences, for context only; do not translate them) and "sentences" (the Italian sentences to translate).
    \\- Reply with only a JSON array of strings: one {0s} sentence per Italian sentence, in the same order, the same count. No commentary, no code fences.
;

/// `postilla translate`, `narrate` and `publish <folder>` (specification.md, The CLI): the
/// configuration, `story.json`'s rules and the server's lists, which all share, then
/// `translate`'s moderation and translations, `narrate`'s Speechify streams, or `publish`'s
/// `.tilla` builds, uploads and last `POST /stories`. Nothing goes to OpenCode, Speechify or
/// R2 until every check has passed.
fn command(io: Io, a: Allocator, env: *std.process.Environ.Map, cwd: Io.Dir, folder: []const u8, w: *Io.Writer, translate: bool, narrate: bool, force: bool, redo: []const u8) !u8 {
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
    const endpoint = env.get("POSTILLA_R2_ENDPOINT") orelse "";
    if (endpoint.len > 0 and std.mem.find(u8, endpoint, "://") == null) return fail(w, "POSTILLA_R2_ENDPOINT: not a URL", .{});
    const opencode_env = env.get("POSTILLA_OPENCODE_URL") orelse "";
    const opencode = if (opencode_env.len > 0) opencode_env else "https://opencode.ai/inference";
    if (translate and std.mem.find(u8, opencode, "://") == null) return fail(w, "POSTILLA_OPENCODE_URL: not a URL", .{});
    const speechify_env = env.get("POSTILLA_SPEECHIFY_URL") orelse "";
    const speechify = if (speechify_env.len > 0) speechify_env else "https://api.speechify.ai";
    if (narrate and std.mem.find(u8, speechify, "://") == null) return fail(w, "POSTILLA_SPEECHIFY_URL: not a URL", .{});
    const threshold_env = env.get("POSTILLA_MODERATION_THRESHOLD") orelse "";
    const threshold = std.fmt.parseFloat(f64, if (threshold_env.len > 0) threshold_env else "0.9") catch -1;
    if (translate and !(threshold >= 0 and threshold <= 1)) return fail(w, "POSTILLA_MODERATION_THRESHOLD: not a number from 0 to 1", .{});
    const client: r2.Client = .{
        .endpoint = if (endpoint.len > 0) endpoint else try std.fmt.allocPrint(a, "https://{s}.r2.cloudflarestorage.com", .{env.get("POSTILLA_R2_ACCOUNT_ID").?}),
        .bucket = env.get("POSTILLA_R2_BUCKET").?,
        .access_key_id = env.get("POSTILLA_R2_ACCESS_KEY_ID").?,
        .secret_access_key = env.get("POSTILLA_R2_SECRET_ACCESS_KEY").?,
    };

    var dir = cwd.openDir(io, folder, .{}) catch |err| return fail(w, "{s}: {t}", .{ folder, err });
    defer dir.close(io);
    const json = dir.readFileAlloc(io, "story.json", a, .limited(1 << 24)) catch |err| return fail(w, "{s}/story.json: {t}", .{ folder, err });
    var story = std.json.parseFromSliceLeaky(struct {
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
    if (translate) {
        // The languages to do: translate 1, and missing or the one --redo names.
        if (redo.len > 0 and (lists[3].get(redo) orelse [2]u8{ 0, 0 })[1] != 1) return fail(w, "--redo {s}: not a language with translate 1", .{redo});
        var todo: std.ArrayList([2][]const u8) = .empty;
        for (lists[3].keys(), lists[3].values()) |lang, flags| {
            if (flags[1] == 1 and (!translations.contains(lang) or std.mem.eql(u8, lang, redo)))
                try todo.append(a, .{ lang, prompt_names.get(lang) orelse return fail(w, "{s}: no prompt name", .{lang}) });
        }
        if (todo.items.len == 0) return 0;

        // Jev reads the title, the subtitle, then each paragraph's sentences joined by a space.
        var state: Io.Writer.Allocating = .init(a);
        try state.writer.print("{s}\n{s}", .{ it.title, it.subtitle });
        for (it.paragraphs) |p| for (p, 0..) |s, j| try state.writer.print("{s}{s}", .{ if (j > 0) " " else "\n", s });
        var session: wire.StoryId = .{};
        io.random(&session.bytes);
        const session_text = session.text();
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{env.get("POSTILLA_OPENCODE_KEY").?}) },
            .{ .name = "x-opencode-session", .value = &session_text },
        };
        var scores: [6]f64 = undefined;
        const status = moderate(io, a, opencode, headers[0..1], state.written(), &scores) catch |err| return fail(w, "moderation: {t}", .{err});
        if (status != .ok) return fail(w, "moderation: {d}", .{@backingInt(status)});
        const rejected = !(scores[0] >= threshold);
        story.moderation = .{ .none = scores[0], .homophobic = scores[1], .racist = scores[2], .sexist = scores[3], .religious = scores[4], .other_hate = scores[5], .forced = rejected and force };

        // story.json is written after moderation, then after each finished language.
        const title = [2][]const u8{ it.title, it.subtitle };
        const chat = try std.fmt.allocPrint(a, "{s}/go/v1/chat/completions", .{opencode});
        for (0..todo.items.len + 1) |n| {
            if (n > 0) {
                const lang = todo.items[n - 1][0];
                const system = try std.fmt.allocPrint(a, system_message, .{ todo.items[n - 1][1], "A1A2B1B2C1C2"[2 * story.level - 2 ..][0..2] });
                var done: std.ArrayList([]const []const u8) = .empty;
                // The title paragraph (0), then each paragraph with the Italian one before it.
                for (0..it.paragraphs.len + 1) |p| {
                    const sentences: []const []const u8 = if (p == 0) &title else it.paragraphs[p - 1];
                    const previous: []const []const u8 = if (p < 2) &.{} else it.paragraphs[p - 2];
                    const body = try std.json.Stringify.valueAlloc(a, .{ .model = "deepseek-v4.1-flash", .temperature = 0.3, .messages = .{
                        .{ .role = "system", .content = system },
                        .{ .role = "user", .content = try std.json.Stringify.valueAlloc(a, .{ .title = it.title, .previous = previous, .sentences = sentences }, .{}) },
                    } }, .{});
                    // 3 tries: a reply that isn't a JSON array of the right length, or has an empty sentence, starts the next.
                    var reason: []const u8 = "";
                    try done.append(a, tries: for (0..3) |_| {
                        const res = outbound.request(io, a, .{}, .POST, chat, &headers, body, "") catch |err| return fail(w, "{s}: paragraph {d}: {t}", .{ lang, p, err });
                        if (res.status != .ok) return fail(w, "{s}: paragraph {d}: {d}", .{ lang, p, @backingInt(res.status) });
                        reason = "not a JSON array of strings";
                        const reply = std.json.parseFromSliceLeaky(struct { choices: [1]struct { message: struct { content: []const u8 } } }, a, res.body, .{ .ignore_unknown_fields = true }) catch continue;
                        const got = std.json.parseFromSliceLeaky([]const []const u8, a, reply.choices[0].message.content, .{}) catch continue;
                        reason = "wrong sentence count";
                        if (got.len != sentences.len) continue;
                        reason = "empty sentence";
                        for (got) |s| if (s.len == 0) continue :tries;
                        break got;
                    } else return fail(w, "{s}: paragraph {d}: {s}", .{ lang, p, reason }));
                }
                _ = story.translations.map.orderedRemove(lang);
                try story.translations.map.put(a, lang, .{ .title = done.items[0][0], .subtitle = done.items[0][1], .paragraphs = done.items[1..] });
            }
            const json_out = try std.json.Stringify.valueAlloc(a, story, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
            dir.writeFile(io, .{ .sub_path = "story.json.tmp", .data = json_out }) catch |err| return fail(w, "story.json: {t}", .{err});
            dir.rename("story.json.tmp", dir, "story.json", io) catch |err| return fail(w, "story.json: {t}", .{err});
            if (n == 0 and rejected and !force) {
                var top: usize = 1;
                for (2..6) |k| top = if (scores[k] > scores[top]) k else top;
                return fail(w, "moderation: rejected, none {d} below {d} (homophobic {d}, racist {d}, sexist {d}, religious {d}, other_hate {d}): {s}", .{ scores[0], threshold, scores[1], scores[2], scores[3], scores[4], scores[5], ([_][]const u8{ "", "homophobic", "racist", "sexist", "religious", "other_hate" })[top] });
            }
        }
        return 0;
    }
    if (narrate) {
        for (translations.keys()) |lang| if ((lists[3].get(lang) orelse [2]u8{ 0, 0 })[0] == 1 and !voices.has(lang)) return fail(w, "{s}: no voice", .{lang});
        const url = try std.fmt.allocPrint(a, "{s}/v1/audio/stream/with-timestamps", .{speechify});
        const headers = [_]std.http.Header{.{ .name = "authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{env.get("POSTILLA_SPEECHIFY_KEY").?}) }};
        for (translations.keys(), translations.values()) |lang, *t| {
            if ((lists[3].get(lang) orelse [2]u8{ 0, 0 })[0] != 1) continue;
            // The input, which is also what is hashed: sentences joined by a space, paragraphs
            // by a newline; and the code point each sentence starts at in it.
            var input: Io.Writer.Allocating = .init(a);
            var starts: std.ArrayList(usize) = .empty;
            for (t.paragraphs, 0..) |p, i| for (p, 0..) |s, j| {
                try input.writer.writeAll(if (j > 0) " " else if (i > 0) "\n" else "");
                try starts.append(a, try std.unicode.utf8CountCodepoints(input.written()));
                try input.writer.writeAll(s);
            };
            const voice = voices.get(lang).?;
            const body = try std.json.Stringify.valueAlloc(a, .{ .input = input.written(), .voice_id = voice[0], .model = "simba-3.5", .language = voice[1], .output_format = "pcm_48000", .options = .{ .loudness_normalization = true } }, .{});

            // 3 tries: a stream with speech.error, an event that isn't JSON or base64 audio,
            // a mark time outside u32 ms, an odd byte count or no speech.done starts the next.
            // A mark's sentence is the one its start falls in; the sentence runs from its first
            // mark to its last.
            var reason: []const u8 = "";
            const pcm: []align(2) u8, const times: [][2]u32 = tries: for (0..3) |_| {
                const res = outbound.request(io, a, .{}, .POST, url, &headers, body, "") catch |err| return fail(w, "{s}: narration: {t}", .{ lang, err });
                if (res.status != .ok) return fail(w, "{s}: narration: {d}", .{ lang, @backingInt(res.status) });
                var bytes: std.array_list.Aligned(u8, .of(i16)) = .empty;
                const got = try a.alloc([2]u32, starts.items.len);
                @memset(got, .{ std.math.maxInt(u32), 0 });
                var lines = std.mem.splitScalar(u8, res.body, '\n');
                while (lines.next()) |line| {
                    if (!std.mem.startsWith(u8, line, "data:")) continue;
                    reason = "an event isn't JSON";
                    const e = std.json.parseFromSliceLeaky(struct { type: []const u8 = "", audio: []const u8 = "", speech_marks: []const struct { start: usize, start_time: f64, end_time: f64 } = &.{}, @"error": struct { message: []const u8 = "" } = .{} }, a, line[5..], .{ .ignore_unknown_fields = true }) catch continue :tries;
                    reason = "audio isn't base64";
                    const decoder = std.base64.standard.Decoder;
                    decoder.decode(try bytes.addManyAsSlice(a, decoder.calcSizeForSlice(e.audio) catch continue :tries), e.audio) catch continue :tries;
                    for (e.speech_marks) |m| {
                        var k = got.len - 1;
                        while (starts.items[k] > m.start) k -= 1;
                        reason = "a mark's time is out of range";
                        if (!(m.start_time >= 0 and m.end_time >= 0 and m.start_time < 0x1p32 and m.end_time < 0x1p32)) continue :tries;
                        got[k] = .{ @min(got[k][0], @as(u32, @intFromFloat(m.start_time))), @max(got[k][1], @as(u32, @intFromFloat(m.end_time))) };
                    }
                    reason = e.@"error".message;
                    if (std.mem.eql(u8, e.type, "speech.error")) continue :tries;
                    reason = "odd audio byte count";
                    const done = std.mem.eql(u8, e.type, "speech.done");
                    if (done and bytes.items.len % 2 == 0) break :tries .{ bytes.items, got };
                    if (done) continue :tries;
                } else reason = "no speech.done";
            } else return fail(w, "{s}: narration: {s}", .{ lang, reason });

            // A sentence without marks gets [e, e] at the previous one's end; no end passes the audio.
            const encoded = try @import("audio").encode(a, std.mem.bytesAsSlice(i16, pcm), 48000);
            var end: u32 = 0;
            for (times) |*time| {
                if (time[0] == std.math.maxInt(u32)) time.* = .{ end, end };
                time[1] = @min(time[1], encoded.audio_ms);
                end = time[1];
            }
            const shaped = try a.alloc([]const [2]u32, t.paragraphs.len);
            var at: usize = 0;
            for (t.paragraphs, shaped) |p, *s| {
                s.* = times[at..][0..p.len];
                at += p.len;
            }
            var sha: [32]u8 = undefined;
            Sha256.hash(input.written(), &sha, .{});
            t.audio = .{ .audio_ms = encoded.audio_ms, .text_sha256 = try a.dupe(u8, &std.fmt.bytesToHex(sha, .lower)), .times = shaped };

            // The audio files, then story.json, each as a temp file renamed into place.
            const json_out = try std.json.Stringify.valueAlloc(a, story, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
            for ([_][]const u8{ try std.fmt.allocPrint(a, "{s}.opus", .{lang}), try std.fmt.allocPrint(a, "{s}.flac", .{lang}), "story.json" }, [_][]const u8{ encoded.opus, encoded.flac, json_out }) |name, data| {
                const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{name});
                dir.writeFile(io, .{ .sub_path = tmp, .data = data }) catch |err| return fail(w, "{s}/{s}: {t}", .{ folder, name, err });
                dir.rename(tmp, dir, name, io) catch |err| return fail(w, "{s}/{s}: {t}", .{ folder, name, err });
            }
        }
        return 0;
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

    const dict_env = env.get("POSTILLA_DICT_DIR") orelse "";
    const dict_dir = if (dict_env.len > 0) dict_env else "./dict";
    cwd.createDirPath(io, dict_dir) catch |err| if (err != error.NotDir) return fail(w, "dict: {t}", .{err});
    const dict = try a.dupeSentinel(u8, client.dict(io, a, dict_dir) catch |err| return fail(w, "dict: {t}", .{err}), 0);
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
