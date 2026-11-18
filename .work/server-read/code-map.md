# Code map — server-read

The repo holds only the slice-0 scaffold (b2a30cb). Everything below exists and must be
reused, not rebuilt.

## Production

- `src/server.zig:11` `Config` — port, bind, db_path, author_token; `readConfig` (`:31`)
  reads env once and exits 1 on a bad value.
- `src/server.zig:52` `listen` — opens the database once to check it, then binds. **This is
  where startup must create the schema and insert the seed rows** (spec, Database:
  "Startup creates the schema and inserts the initial rows with `INSERT OR IGNORE`").
- `src/server.zig:60` `serve` — accept loop; one `Io.Group.concurrent` task per connection.
- `src/server.zig:78` `connection` — per-connection loop over `std.http.Server.receiveHead`;
  today answers every request `404 not found` (text/plain) and closes when the request is
  not keep-alive. **Routing goes here.** It takes `config` but opens no database yet: the
  spec says each connection opens its own SQLite connection.
- `src/db.zig:25` `open` — WAL, synchronous NORMAL, busy_timeout 5000, foreign_keys ON;
  `Db.exec` (`:18`) runs statements without rows; errors log `sqlite3_errmsg` and return
  `error.Sqlite`. **No prepared statements yet** (prepare/bind/step/column) — the read
  queries need them.
- `src/wire.zig` — the shared binary encoding. `Writer` (`:66`) writes into a buffer the
  caller sizes up front (`header`, `int`, `bytes`, `str`), `strSize` (`:61`) for sizing;
  `Lang` (`:40`) with `fromText` (1–8 printable ASCII) and `text`; `StoryId` (`:10`) with
  `text` (written form). FEED, GNRS, TAGS, AUTH and LANG bodies are all built from these.
- `src/c.h` — `#include <sqlite3.h>`, translated as module `c`.

## Tests

- `test/harness.zig:10` `Harness` — `start` (in place: free port, temp SQLite under
  `.zig-cache/tmp/`, server task), `stop`, `send` (raw request head + body over TCP with
  `connection: close`, whole response into a caller buffer), `Response` with `status`,
  `head`, `body`, `header(name)`. Tests that need rows in `story` must get them through
  SQL on `h.db_path` only until `server-write` adds `POST /stories` — note: seeding rows
  no production code writes is flagged by review as "tests that check a state nothing
  produces"; `story` rows are written by `POST /stories` in the next slice.
- `test/smoke.zig` — the one existing test (unknown path → 404).

## Docs that describe this slice

- `docs/specification.md`: Languages, genres, tags and authors (lists + `GET` bodies),
  Cursor, Error bodies, `GET /stories`, Status codes, Database (schema, seed rows), Process.
- `docs/openapi.yaml`: `/stories` get, `/genres`, `/tags`, `/authors`, `/languages`.
- `docs/formats/feed.ksy`, `gnrs.ksy`, `tags.ksy`, `auth.ksy`, `lang.ksy`, `postilla_enums.ksy`.
  `feed.ksy:8-11` says "The last record's `cursor` is the value the app sends next time",
  which contradicts app-handoff.md §2 (store only the highest cursor below which every
  record was applied) — fix the doc line in this slice.

## I/O boundaries crossed

- SQLite: schema creation and seed at startup; read queries per request.
- The HTTP server: request head (method, target, query string) from the socket.
- Env at startup: already handled by `readConfig`.
- The filesystem: the database file path.

## Not here yet (later slices)

- Auth, `POST /stories`, `DELETE /stories/<id>` (server-write); `words`, `.tilla` (lane B).
