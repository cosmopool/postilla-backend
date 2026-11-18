# Code map — server-write

Base c32b62c: the scaffold plus server-read. Everything below exists and must be reused.

## Production

- `src/server.zig:12` `Config` — `author_token` is already read from env and required at
  startup (`readConfig`, `:60`); nothing checks it yet.
- `src/server.zig:108` `connection` — per-connection loop: idle peek, `receiveHead`, then
  `route(&request, d)`; `error.Sqlite` from a handler answers 500 with no body, any other
  error closes the connection. `route` does not receive `config`, so the token isn't
  reachable from the handlers yet.
- `src/server.zig:147` `route` — splits the target at the first `?`, then `&`; GET only
  today; everything else `reason(.not_found, "not found\n")`. **The two new routes
  (`POST /stories`, `DELETE /stories/<id>`) and the auth check go here.**
- `src/server.zig:164` `list`, `:190` `feed` — hand-encode their bodies with
  `std.Io.Writer.Allocating` and raw `c.sqlite3_*` calls in places, because `wire.zig` didn't
  compile until a398d4a. questions.md #2: move them onto `wire.Writer`.
- `src/server.zig:24` `schema` — the `story` table (`id BLOB`, `lang`, `sha256`, `change`,
  `cursor UNIQUE`, PK `(id, lang)`) the writes go into.
- `src/server.zig:251` `reason` — one-line text/plain error body; reuse for every 4xx.
- `src/db.zig:9` `Db` (`exec`, `prepare`), `:31` `Stmt` (`bindText`, `bindInt`, `step`,
  `columnInt`, `bytes`, `reset`, `finalize`), `:53` `open` (busy_timeout first, WAL).
  No blob binding yet: `story.id` and `story.sha256` are BLOBs.
- `src/wire.zig:97` `Reader` — `header(magic)`, `int`, `bytes`, `lang` (non-empty printable
  ASCII, zero padding only), `storyId`, `end`; every error is a parse failure (400). This is
  the STRY parser's building block. `:10` `StoryId.parse` / `.text` for the `<id>` in the
  DELETE path. `:66` `Writer` for response bodies.

## Tests

- `test/harness.zig` — `Harness` (`start`, `stop`, `send`, `sql`), `token = "test-token"`
  (the harness's `author_token`), `Response.parse`, `header`.
- `test/server_read.zig` — seeds `story` rows with `h.sql(...)`; with POST /stories in place,
  the feed tests can publish through the endpoint instead (requirement server-read, Assumed 2).

## Docs

- `docs/specification.md`: Auth, Error bodies, `POST /stories`, `DELETE /stories/<id>`,
  Status codes, Database (the publish and removal transactions).
- `docs/openapi.yaml`: `/stories` post, `/stories/{id}` delete. `docs/formats/stry.ksy`.

## I/O boundaries crossed

- The HTTP server: the `Authorization` header and the request body read from the socket.
- SQLite: `BEGIN IMMEDIATE` write transactions (publish, removal), cursor allocation.
