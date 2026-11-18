//! R2 through its S3 API: SigV4-signed, path-style uploads and downloads, and the
//! dictionary cache (docs/specification.md, Files in R2 and Vocabulary coverage).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const outbound = @import("outbound.zig");

/// What a call answers: the final status and body.
const Response = @typeInfo(@typeInfo(@TypeOf(outbound.request)).@"fn".return_type.?).error_union.payload;

pub const Client = struct {
    /// `https://<account>.r2.cloudflarestorage.com`, built by the caller.
    endpoint: []const u8,
    bucket: []const u8,
    access_key_id: []const u8,
    secret_access_key: []const u8,
    retry: outbound.Retry = .{},

    /// Uploads `body` as `key`, typed by its extension and cached as immutable.
    pub fn put(c: Client, io: Io, a: Allocator, key: []const u8, body: []const u8) !Response {
        const content_type = if (std.mem.endsWith(u8, key, ".opus")) "audio/ogg" else if (std.mem.endsWith(u8, key, ".flac")) "audio/flac" else "application/gzip";
        return c.call(io, a, .PUT, key, body, &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
        }, "");
    }

    pub fn get(c: Client, io: Io, a: Allocator, key: []const u8) !Response {
        return c.call(io, a, .GET, key, "", &.{}, "");
    }

    /// Makes `<dir>/<sha256>.db` the build `dict/latest` names, downloading, checking and
    /// gunzipping it unless it is there, then deletes every other `.db` in `dir`. Returns
    /// its path.
    pub fn dict(c: Client, io: Io, a: Allocator, dir_path: []const u8) ![]const u8 {
        const latest = try c.get(io, a, "dict/latest");
        if (latest.status != .ok) return error.R2Status;
        const line = latest.body;
        if (line.len < 67 or line[64] != ' ' or line[line.len - 1] != '\n' or
            std.mem.findNone(u8, line[0..64], "0123456789abcdef") != null or
            std.mem.findNone(u8, line[65 .. line.len - 1], "0123456789") != null) return error.BadDictLatest;
        const name = try std.fmt.allocPrint(a, "{s}.db", .{line[0..64]});
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name });
        var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        if (dir.access(io, name, .{})) |_| return path else |_| {}

        const gz = try c.call(io, a, .GET, try std.fmt.allocPrint(a, "dict/{s}.db.gz", .{line[0..64]}), "", &.{}, line);
        if (gz.status != .ok) return error.R2Status;
        var file = try dir.createFileAtomic(io, name, .{});
        defer file.deinit(io);
        var in: Io.Reader = .fixed(gz.body);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var gunzip: std.compress.flate.Decompress = .init(&in, .gzip, &window);
        var buf: [4096]u8 = undefined;
        var out = file.file.writer(io, &buf);
        _ = try gunzip.reader.streamRemaining(&out.interface);
        try out.interface.flush();
        try file.link(io);

        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (std.mem.endsWith(u8, e.name, ".db") and !std.mem.eql(u8, e.name, name)) try dir.deleteFile(io, e.name);
        }
        return path;
    }

    /// `method` on `/<bucket>/<key>`, signed with SigV4 (region `auto`, service `s3`).
    fn call(c: Client, io: Io, a: Allocator, method: std.http.Method, key: []const u8, body: []const u8, extra: []const std.http.Header, digest: []const u8) !Response {
        const secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(Io.Clock.real.now(io).toSeconds()) };
        const day = secs.getEpochDay().calculateYearDay();
        const md = day.calculateMonthDay();
        const t = secs.getDaySeconds();
        const date = try std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            day.year, md.month.numeric(), md.day_index + 1, t.getHoursIntoDay(), t.getMinutesIntoHour(), t.getSecondsIntoMinute(),
        });
        const scope = try std.fmt.allocPrint(a, "{s}/auto/s3/aws4_request", .{date[0..8]});
        const path = try std.fmt.allocPrint(a, "/{s}/{s}", .{ c.bucket, key });
        const hash = sha256(body);
        const canonical = try std.fmt.allocPrint(
            a,
            "{t}\n{s}\n\nhost:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n\nhost;x-amz-content-sha256;x-amz-date\n{s}",
            .{ method, path, c.endpoint[std.mem.find(u8, c.endpoint, "://").? + 3 ..], &hash, date, &hash },
        );
        const to_sign = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ date, scope, &sha256(canonical) });
        var k: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&k, date[0..8], try std.fmt.allocPrint(a, "AWS4{s}", .{c.secret_access_key}));
        inline for (.{ "auto", "s3", "aws4_request", to_sign }) |m| std.crypto.auth.hmac.sha2.HmacSha256.create(&k, m, &k);
        const authorization = try std.fmt.allocPrint(
            a,
            "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={s}",
            .{ c.access_key_id, scope, &std.fmt.bytesToHex(k, .lower) },
        );
        const headers = try std.mem.concat(a, std.http.Header, &.{ extra, &.{
            .{ .name = "x-amz-date", .value = date },
            .{ .name = "x-amz-content-sha256", .value = &hash },
            .{ .name = "authorization", .value = authorization },
        } });
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ c.endpoint, path });
        return outbound.request(io, a, c.retry, method, url, headers, body, digest);
    }
};

fn sha256(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
