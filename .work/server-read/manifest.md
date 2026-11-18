# Manifest — server-read

## Files to touch
- `src/server.zig` — `listen` creates the schema, triggers and seed rows on startup (spec
  SQL verbatim, `INSERT OR IGNORE`), stamps `user_version` 1 and refuses a higher one.
  `Config` gains `idle_timeout_ms` (default 30 000, no env variable). `connection` opens
  the connection's own `db.Db`, sets the idle timeout on the socket, routes `GET /stories`,
  `/genres`, `/tags`, `/authors`, `/languages` (everything else 404), parses `since` and
  `lang` at the boundary, answers 400 `bad request head` and closes on a bad or oversized
  head, and answers 500 with no body on `error.Sqlite`. The handlers live in this file.
  Re-exports `db` (`pub const db`) so the test harness can seed rows with SQL.
- `src/db.zig` — prepared statements: `Db.prepare`, and on the statement `bindInt`,
  `bindText`, `step`, `columnInt`, `columnText`, `columnBlob`, `finalize`. Every error
  path logs `sqlite3_errmsg` and returns `error.Sqlite`, like `exec`.
- `test/harness.zig` — `Harness.sql(text)`: runs SQL on the harness's temp database
  through `server.db`, for seeding `story` rows and hand edits.
- `build.zig` — `b.dependOnDirectoryContents(b.path("test"))`, so Zig 0.17's cached configure
  phase reruns when a file is added to `test/` (found during stage 1: new test files,
  including stage 2's reproductions, were skipped until the cache was cleared). Added
  after approval, with the owner's OK; already committed as 61fa368.
- `docs/specification.md` — Database: the `user_version` stamp and the refusal of a newer
  schema; Process: the idle timeout and the `400 bad request head` rule; Error bodies: the
  exact reasons for `since` and `lang`.
- `docs/openapi.yaml` — `/stories` 400 description lists the new reasons; the shared
  Errors section mentions `bad request head`.
- `docs/formats/feed.ksy` — replace the "last record's cursor" doc line with a pointer to
  app-handoff.md §2.

## New files
- `test/server_read.zig` — the integration tests for AC-1 … AC-12 and AC-F1 … AC-F4. One
  file, because every test goes through the same harness and HTTP surface.

## Public symbols to add
- `db.Stmt` (`src/db.zig`) — a prepared statement; the read queries can't be expressed
  with `exec`, which returns no rows.
- `server.db` (`src/server.zig`) — re-export of `db.zig`, so `test/harness.zig` reaches
  SQLite through the same wrapper instead of a second one.

## Reused, not rebuilt
- `src/wire.zig:66` `Writer`, `:61` `strSize`, `:40` `Lang` (`fromText`, `text`): every
  response body and the `lang` parse.
- `src/db.zig:25` `open` (WAL, busy timeout) and `:18` `Db.exec`: schema creation and the
  per-connection connection.
- `src/server.zig:60` `serve` and `:78` `connection`: the accept loop and the per-request
  loop the routing goes into.
- `test/harness.zig:10` `Harness` (`start`, `stop`, `send`, `Response.header`).

## Budget
added 350 · new files 1 · new public symbols 2

Raised from the default 300 before implementation: the schema, triggers and seed rows are
about 60 lines of SQL copied from the spec, on top of about 240 of handler and statement
code.

## API
settled
