//! Thin SQLite wrapper. One `Db` per thread: the amalgamation is built in multi-thread
//! mode (SQLITE_THREADSAFE=2), so a connection is never shared between threads.

const std = @import("std");
const c = @import("c");

const log = std.log.scoped(.db);

pub const Db = struct {
    handle: ?*c.sqlite3 = null,

    pub fn close(d: *Db) void {
        _ = c.sqlite3_close_v2(d.handle);
        d.handle = null;
    }

    /// Runs one or more statements that return no rows.
    pub fn exec(d: Db, sql: [:0]const u8) error{Sqlite}!void {
        if (c.sqlite3_exec(d.handle, sql.ptr, null, null, null) != c.SQLITE_OK) return fail(d);
    }

    /// Compiles one statement; the caller finalizes `handle`.
    pub fn prepare(d: Db, sql: [:0]const u8) error{Sqlite}!Stmt {
        var s: Stmt = .{ .db = d };
        if (c.sqlite3_prepare_v2(d.handle, sql.ptr, -1, &s.handle, null) != c.SQLITE_OK) return fail(d);
        return s;
    }
};

/// A prepared statement of `db`.
pub const Stmt = struct {
    handle: ?*c.sqlite3_stmt = null,
    db: Db,

    /// True when a row is ready, false when the statement is done.
    pub fn step(s: Stmt) error{Sqlite}!bool {
        return switch (c.sqlite3_step(s.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => fail(s.db),
        };
    }

    /// The bytes of a TEXT or BLOB column; SQLite gives an empty one no pointer.
    pub fn bytes(s: Stmt, i: c_int) []const u8 {
        const p: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(s.handle, i));
        return (p orelse return "")[0..@intCast(c.sqlite3_column_bytes(s.handle, i))];
    }
};

/// Opens (creating if needed) the database at `path` in WAL mode, with a busy timeout so
/// a writer waits for another writer instead of failing.
pub fn open(path: [:0]const u8) error{Sqlite}!Db {
    var d: Db = .{};
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
    if (c.sqlite3_open_v2(path.ptr, &d.handle, flags, null) != c.SQLITE_OK) {
        const err = fail(d);
        d.close();
        return err;
    }
    d.exec(
        \\PRAGMA busy_timeout = 5000;
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = NORMAL;
        \\PRAGMA foreign_keys = ON;
    ) catch |err| {
        d.close();
        return err;
    };
    return d;
}

/// Opens the database at `path` read-only and sets no pragmas, so reading it never writes
/// the file or a `-wal` or `-shm` beside it (`dict.db`).
pub fn openReadOnly(path: [:0]const u8) error{Sqlite}!Db {
    var d: Db = .{};
    if (c.sqlite3_open_v2(path.ptr, &d.handle, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX, null) == c.SQLITE_OK) return d;
    const err = fail(d);
    d.close();
    return err;
}

/// Logs the connection's last error as a warning; the caller decides what the failure
/// means (a 500, or a startup that stops).
fn fail(d: Db) error{Sqlite} {
    log.warn("{s}", .{c.sqlite3_errmsg(d.handle)});
    return error.Sqlite;
}
