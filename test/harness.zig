//! Starts the real server on a free port with a temp SQLite file, and talks HTTP to it
//! over a plain TCP socket, so a test can send any bytes it wants.

const std = @import("std");
const Io = std.Io;
const server = @import("server");

const io = std.testing.io;

pub const Harness = struct {
    tmp: std.testing.TmpDir,
    db_path: [:0]u8,
    config: server.Config,
    listener: Io.net.Server,
    task: Io.Future(Io.Cancelable!void),
    port: u16,

    /// In place, since the running server keeps pointers into `h`.
    pub fn start(h: *Harness) !void {
        h.tmp = std.testing.tmpDir(.{});
        errdefer h.tmp.cleanup();
        h.db_path = try std.fmt.allocPrintSentinel(
            std.testing.allocator,
            ".zig-cache/tmp/{s}/postilla.db",
            .{h.tmp.sub_path},
            0,
        );
        errdefer std.testing.allocator.free(h.db_path);
        h.config = .{ .port = 0, .db_path = h.db_path, .author_token = token };
        h.listener = try server.listen(io, &h.config);
        errdefer h.listener.deinit(io);
        h.port = h.listener.socket.address.getPort();
        h.task = try io.concurrent(server.serve, .{ io, &h.listener, &h.config });
    }

    pub fn stop(h: *Harness) void {
        h.task.cancel(io) catch {};
        h.listener.deinit(io);
        std.testing.allocator.free(h.db_path);
        h.tmp.cleanup();
    }

    /// Sends one request with `Connection: close` and reads the whole response into
    /// `buf`. `head` is the request line and headers without the final blank line, so a
    /// test can send anything, malformed requests included.
    pub fn send(h: *const Harness, head: []const u8, body: []const u8, buf: []u8) !Response {
        const address = try Io.net.IpAddress.parse("127.0.0.1", h.port);
        const stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var out_buf: [4096]u8 = undefined;
        var out = stream.writer(io, &out_buf);
        try out.interface.print("{s}\r\nhost: test\r\nconnection: close\r\ncontent-length: {d}\r\n\r\n", .{ head, body.len });
        try out.interface.writeAll(body);
        try out.interface.flush();
        var in_buf: [4096]u8 = undefined;
        var in = stream.reader(io, &in_buf);
        const n = try in.interface.readSliceShort(buf);
        return Response.parse(buf[0..n]);
    }

    /// Runs `text` on the harness's database with its own connection, the way an
    /// operator edits `postilla.db` by hand.
    pub fn sql(h: *const Harness, text: [:0]const u8) !void {
        var d = try server.db.open(h.db_path);
        defer d.close();
        try d.exec(text);
    }
};

pub const token = "test-token";

pub const Response = struct {
    status: u16,
    head: []const u8,
    body: []const u8,

    pub fn parse(raw: []const u8) !Response {
        const split = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.NoHead;
        const head = raw[0..split];
        if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.1 ")) return error.BadStatusLine;
        return .{
            .status = try std.fmt.parseInt(u16, head[9..12], 10),
            .head = head,
            .body = raw[split + 4 ..],
        };
    }

    /// The value of header `name` (case-insensitive), or "" when it's missing.
    pub fn header(r: Response, name: []const u8) []const u8 {
        var lines = std.mem.splitSequence(u8, r.head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return "";
    }
};
