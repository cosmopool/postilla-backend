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
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = NORMAL;
        \\PRAGMA busy_timeout = 5000;
        \\PRAGMA foreign_keys = ON;
    ) catch |err| {
        d.close();
        return err;
    };
    return d;
}

/// Logs the connection's last error as a warning; the caller decides what the failure
/// means (a 500, or a startup that stops).
pub fn fail(d: Db) error{Sqlite} {
    log.warn("{s}", .{c.sqlite3_errmsg(d.handle)});
    return error.Sqlite;
}
