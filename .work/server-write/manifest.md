# Manifest — server-write

## Files to touch
- `src/server.zig` — `route` gets `config` and two routes: `POST /stories` and
  `DELETE /stories/<id>`, each checking the token first (SHA-256 both sides,
  `std.crypto.timing_safe.eql`), 401 with an empty body, and closing the connection on a 401
  so an unread body is never parsed as the next request. `publish` reads the body (Content-
  Length required, cap 10 222), parses STRY with `wire.Reader` (the boundary parse: the only
  code that fills the parsed value), then in one `BEGIN IMMEDIATE` checks removed and missing
  published translations, checks each `lang` against `language`, and upserts with
  `max(cursor) + 1` for new or changed rows; `remove` parses the id with
  `wire.StoryId.parse` and tombstones every row of the story with new cursors, idempotently.
  `ROLLBACK` on any error. `feed` and `list` write their bodies through `wire.Writer` /
  `wire.Lang` and `db.Stmt` instead of hand-encoding and raw `c.sqlite3_*` calls.
- `src/db.zig` — `Stmt.bindBlob` for the BLOB columns (`story.id`, `story.sha256`).
- `test/server_read.zig` — feed tests publish through `POST /stories` instead of seeding
  `story` rows with SQL, where the endpoint can produce the state.
- `docs/specification.md` — Auth: the check order and the scheme matching; `POST /stories`:
  the Content-Length rules and every reason string; `DELETE`: the reasons.
- `docs/openapi.yaml` — the 400 descriptions on `POST /stories` and `DELETE /stories/{id}`.

## New files
- `test/server_write.zig` — the integration tests for AC-1 … AC-11 and AC-F1, AC-F2. AC-12
  is covered by the existing `test/server_read.zig`.

## Public symbols to add
- None. `Stmt.bindBlob` is a method of an existing type; the handlers stay private to
  `src/server.zig`.

## Reused, not rebuilt
- `src/wire.zig:97` `Reader` (`header`, `int`, `bytes`, `lang`, `storyId`, `end`) for STRY;
  `:10` `StoryId.parse` for the DELETE path; `:66` `Writer`, `:61` `strSize`, `:40` `Lang` for
  the response bodies.
- `src/db.zig:9` `Db.exec` / `prepare`, `:31` `Stmt`.
- `src/server.zig:251` `reason`, `:108` `connection`'s `error.Sqlite` → 500 path,
  `:147` `route`.
- `test/harness.zig` `Harness`, `token`, `Response`.

## Budget
added 300 · new files 0 · new public symbols 0

## API
settled
