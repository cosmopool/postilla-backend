# Read path of postilla-server (server-read)

## Summary

The public, read-only half of `postilla-server`: on startup it creates the schema and the
seed rows of a fresh `postilla.db`; it then serves the four closed lists (`GET /genres`,
`/tags`, `/authors`, `/languages`) and the story feed (`GET /stories?since=&lang=`), the hot
path every learner app hits on each sync, with the spec's error bodies and status codes.
Writing to the feed (`POST /stories`, `DELETE /stories/<id>`, auth) is the next slice,
`server-write`.

## Specified

- Schema and seed: "Startup creates the schema and inserts the initial rows with `INSERT OR
  IGNORE`, so a fresh `postilla.db` works with no manual step." Tables, triggers and seed
  rows exactly as in requirement-raw.md, Database.
- Lists: "Public, like `GET /stories`, with no parameters. Every response is `200`,
  `Content-Type: application/octet-stream`" with the `GNRS`/`TAGS`/`AUTH`/`LANG` header
  (`magic`, `version` 1, `count` u16) and records "ascending by `id`".
- Feed: "`since` is a decimal `u32`. When it is missing it counts as 0 … Any other value gets
  a 400." / "`lang` is required: 1 to 4 comma-separated language ids (`it,pt-BR`), each in
  `language`, with no duplicates and no empty items." / records "ascending by `cursor`, one
  per translation in the listed languages with a cursor above `since`", 61 bytes each,
  "`sha256` … all zero when `removed`", "the body is `9 + 61 × count` bytes".
- Errors: "Every 4xx except 401 carries a one-line English reason as `text/plain`, naming
  the rule and the field" / "A 500 carries no body." / Status codes: 404 "Any other path or
  method", 500 "SQLite error".
- Process: "Each connection opens its own SQLite connection"; WAL with a busy timeout.

## Decided

- **Rows for tests come from SQL.** Feed tests insert rows into the documented `story`
  schema on the harness's temp database, because no endpoint writes them until
  `server-write`; that slice moves the tests to `POST /stories`. Rejected: testing only the
  empty feed (the hot path would ship untested), swapping the slice order.
- **A malformed request head, or one over the 8 KiB head buffer, gets `400` with
  `bad request head`, then the connection closes.** Rejected: closing silently (Caddy would
  report a 502).
- **An idle connection closes after 30 s** with no bytes from the client (the head read times
  out). The value is a `Config` field (`idle_timeout_ms`, default 30 000), not an env
  variable, so tests can use a short one. Rejected: no timeout.
- **Schema version:** startup sets `PRAGMA user_version = 1` when it creates the schema, and
  refuses to start (logged, exit 1) on a database whose `user_version` is above 1. Rejected:
  no version until the first migration.
- `since`: 1 to 10 ASCII digits, value ≤ 4294967295; leading zeros allowed. `since=` (empty),
  a sign, spaces or any other byte gets a 400. Unknown query parameters are ignored; a
  repeated `since` or `lang` gets a 400.
- "Ascending by `id`" is SQLite's default `BINARY` collation (byte order): `en`, `it`,
  `pt-BR`.
- Error reasons (exact text): `since: not a u32`, `since: repeated`, `lang: missing`,
  `lang: repeated`, `lang: empty id`, `lang: more than 4 ids`, `lang: duplicate id 'it'`,
  `lang: unknown id 'fr'`, `bad request head`, `not found`.
- Responses carry `Content-Type: application/octet-stream` (bodies) or `text/plain`
  (reasons) and `Content-Length`; no caching headers.
- Any method other than GET on these paths, HEAD included, is `404 not found`, as is any
  other path.
- The feed is one prepared query per request on the connection's own SQLite connection:
  `WHERE cursor > ? AND lang IN (…) ORDER BY cursor`, using the `UNIQUE(cursor)` index; the
  response body is written into one buffer sized once from the row count, with no
  allocation per record.
- `feed.ksy`'s doc line "The last record's `cursor` is the value the app sends next time" is
  replaced by a pointer to app-handoff.md §2 (which cursor the app stores).

## Assumed

- **Caddy is the only client** (the server binds `127.0.0.1`). Blast radius if wrong: no
  limit on concurrent connections beyond the idle timeout. Confirm: owner (deployment).
- **Seeded `story` rows in tests match what `POST /stories` will write** (same columns,
  `change` 1 or 2, zeroed nothing: the removed row keeps its sha and FEED zeroes it). Blast
  radius: server-write may need to adjust a few tests. Confirm: server-write's requirement.
- **A hand edit to a seed row survives restarts**: `INSERT OR IGNORE` never overwrites a
  renamed genre or language. Blast radius: none expected. Confirm: owner.

## Non-goals

- `POST /stories`, `DELETE /stories/<id>`, the bearer token: `server-write`.
- Caching (ETag, `Cache-Control`, 304), gzip or any `Content-Encoding` on responses.
- Pagination or a cap on feed size; `since=0` returns everything.
- Rate limiting, CORS, `OPTIONS`, `HEAD`, 405.
- Migrations beyond the `user_version` stamp and the refusal of a newer schema.
- Connection pooling or any SQLite connection shared between connections.
- Precomputed or cached list or feed responses.
- Any new env variable.

## Acceptance criteria

AC-1: Given a fresh database, when `GET /languages` is called, then it answers 200,
      `application/octet-stream`, a `LANG` v1 body with 3 records in order `en` (English,
      0, 0), `it` (Italiano, 1, 0), `pt-BR` (Português brasileiro, 0, 1).
AC-2: Given a fresh database, when `GET /genres` is called, then the `GNRS` v1 body has the
      7 seed genres ascending by id (`classici` … `viaggio`), each with its `it`, `pt_br`
      and `en` names as in the spec's seed table.
AC-3: Given a fresh database, when `GET /tags` is called, then the `TAGS` v1 body is the
      7-byte header with `count` 0; and given a tag inserted by hand with SQL, the next
      `GET /tags` lists it.
AC-4: Given a fresh database, when `GET /authors` is called, then the `AUTH` v1 body has one
      record, `collodi` / `Carlo Collodi`.
AC-5: Given `story` rows in `it` and `pt-BR` with cursors 1–4, one of them removed, when
      `GET /stories?since=1&lang=it,pt-BR` is called, then the `FEED` v1 body holds exactly
      the rows with cursor above 1 in those languages, ascending by cursor, 61 bytes each
      (`id`, zero-padded `lang`, `change`, `sha256`, `cursor`), the removed row with an
      all-zero `sha256`, and the body length is `9 + 61 × count`.
AC-6: Given the same rows, when `lang` lists only `it`, then no `pt-BR` row is returned; and
      when `since` is missing, it counts as 0.
AC-7: Given rows whose cursors are all at or below `since`, when the feed is requested,
      then the body is the 9-byte header with `count` 0.
AC-8: Given `since` that is empty, signed, non-decimal, longer than 10 digits, above
      4294967295, or given twice, when the feed is requested, then it answers 400
      `text/plain` with the matching reason.
AC-9: Given `lang` that is missing, empty, given twice, has an empty item, more than 4
      ids, a duplicate id, or an id not in `language`, when the feed is requested, then it
      answers 400 `text/plain` with the matching reason.
AC-10: Given any other path, or any method other than GET (HEAD included) on a known path,
       then it answers 404 `text/plain` `not found`.
AC-11: Given a fresh database file, when the server starts, then the schema, the triggers
       and the seed rows exist and `user_version` is 1; and given a restart on that file
       after a seed row was renamed by hand, the rename is kept.
AC-12: Given a database, when SQL tries to delete a `language` or `author` row or change its
       id, then the trigger refuses it.
AC-F1: Given a malformed request head, or a head over 8 KiB, then the server answers 400
       `bad request head` and closes the connection.
AC-F2: Given a connection that sends nothing for `idle_timeout_ms`, then the server closes
       it (tested with a short timeout).
AC-F3: Given a SQLite error while answering (the `story` table dropped by hand), when the
       feed is requested, then it answers 500 with no body, and the connection's next
       request to a list still works.
AC-F4: Given a database whose `user_version` is 2, or a database path in a directory that
       doesn't exist, when the server starts, then startup fails before binding.

## Touched boundaries

- SQLite (schema creation, seed, queries): AC-11, AC-12, AC-F3, AC-F4.
- The HTTP server (socket, request head, query string): AC-8, AC-9, AC-10, AC-F1, AC-F2.
- The filesystem (database path): AC-F4.

Env at startup is not touched: no variable is added or changed, and `readConfig` (slice 0)
keeps its exit-1 behaviour.
