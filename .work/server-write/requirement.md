# Write path of postilla-server (server-write)

## Summary

The authoring half of `postilla-server`: the bearer token on the two write endpoints,
`POST /stories` (publish or republish every translation of a story, taking new cursors in
one transaction) and `DELETE /stories/<id>` (tombstone a story). With it, the feed has a real
writer, so the feed tests publish through the endpoint. The read path's hand-written bodies
move onto `wire.Writer`, as server-read left open.

## Specified

- Auth: "`POST /stories` and `DELETE /stories/<id>` take `Authorization: Bearer <token>`,
  where the token is env `POSTILLA_AUTHOR_TOKEN`, compared in constant time. A missing or
  wrong token gets a 401 with an empty body, before the body is read."
- STRY: magic `STRY`, version 1, `id` uuid, `lang_count` u8, then `lang_count` × (`lang`,
  `sha256`); "The body is `22 + 40 × lang_count` bytes" and the four parse rules (magic and
  version; `lang_count` ≥ 1 and exact length; every `lang` non-empty ASCII followed only by
  zeros, no repeats; one `lang` is `it`).
- "Past the parse, a `lang` not in `language` gets a 400 (`lang: unknown id 'fr'`), and a
  removed story id gets a 409 (`story removed`). A story that already has a published
  translation in a language the body doesn't carry gets a 409 (`pt-BR: published, missing
  from body`) … There is no override."
- "in one `BEGIN IMMEDIATE` transaction, every translation in the body is upserted: a row whose
  sha256 changed, or that is new, gets `change` `published` and the next cursor; a row whose
  sha256 is the same keeps its cursor." Response 200, no body.
- DELETE: tombstones every translation in one `BEGIN IMMEDIATE` transaction, each row
  `change` 2 with a new cursor; already removed → 200, no new cursor; unknown id → 404;
  `<id>` not a UUID → 400; no body.
- Cursor: "`max(cursor) + 1`, the first gets 1", one sequence for every translation.

## Decided

- **Order of checks:** route (path and method) first, then the token, then the body. An
  unknown path or method is 404 without a token check; a known write route with a missing or
  wrong token is 401 before any body byte is read.
- **Token form:** `Authorization: Bearer <token>`, scheme matched case-insensitively, one
  space. The comparison hashes both values with SHA-256 and compares the digests with
  `std.crypto.timing_safe.eql`, so neither length nor content leaks through timing.
- **Body reading:** `POST /stories` needs a `Content-Length`; a missing one (or chunked
  transfer) is 400 `body: length required`, and one above 10 222 bytes (the largest valid
  STRY, `lang_count` 255) is 400 `body: too large`, both without reading the body. DELETE
  ignores any body.
- **Parse reasons:** `body: bad magic`, `body: bad version`, `body: wrong length`,
  `lang: empty or not ASCII`, `lang: repeated id 'it'`, `lang: no 'it'`,
  `lang: unknown id 'fr'`; past the parse, `story removed` and
  `pt-BR: published, missing from body`. DELETE: `id: not a UUID`, `not found`.
- **`<id>` in the path** is the UUID's written form, hex in either case; `/stories/<id>/`
  (trailing slash) or extra segments are 404.
- **Transactions:** both writes run in `BEGIN IMMEDIATE … COMMIT`; any SQLite error rolls
  back and answers 500 with no body (the existing `error.Sqlite` path), so a failed publish
  or removal leaves no row changed.
- **Response bodies on `wire.Writer`** (questions.md #2): `feed` and `list` stop hand-encoding
  and write through `wire.Writer` / `wire.Lang`; the wire bytes stay identical, which the
  server-read tests prove.
- **Feed tests publish through `POST /stories`** where they seeded `story` rows with SQL;
  tests that need a state the endpoints can't produce (a hand-edited list row, a dropped
  table) keep `h.sql`.

## Assumed

- **The CLI always sends `it`** and the server needn't know `original` beyond rule 4. Blast
  radius: none until another original language exists. Confirm: owner (v1.2+).
- **10 222 bytes is the body cap**: no future STRY grows past 255 translations. Blast radius:
  a version bump would raise it. Confirm: owner.

## Non-goals

- Restoring a removed story (roadmap, Later).
- Per-user tokens, token rotation, rate limiting.
- Checking that the files exist in R2.
- Removing a single translation.
- Any change to the FEED, list or STRY wire formats.
- Any new env variable.

## Acceptance criteria

AC-1: Given a valid STRY for a new story with `it` and `pt-BR`, when `POST /stories` is sent
      with the token, then it answers 200 with no body, and `GET /stories?lang=it,pt-BR` lists
      both translations with consecutive new cursors and their sha256s.
AC-2: Given a published story, when it is republished with `it` unchanged and `pt-BR` changed,
      then only `pt-BR` gets a new cursor; `it` keeps its cursor and the feed since the old
      maximum lists only `pt-BR`.
AC-3: Given a published story, when it is republished with nothing changed, then it answers
      200 and no cursor moves.
AC-4: Given a story published in `it` and `pt-BR`, when a STRY carries only `it`, then it
      answers 409 `pt-BR: published, missing from body` and nothing changes.
AC-5: Given a removed story, when it is published, then it answers 409 `story removed` and
      nothing changes.
AC-6: Given a STRY with a bad magic, a bad version, a wrong length, `lang_count` 0, an empty
      or non-ASCII `lang`, bytes after the padding zero, a repeated `lang`, or no `it`, then
      it answers 400 with the matching reason and nothing changes.
AC-7: Given a STRY whose `lang` is not in `language`, then it answers 400
      `lang: unknown id 'fr'` and nothing changes.
AC-8: Given a published story, when `DELETE /stories/<id>` is sent with the token, then it
      answers 200 with no body, every translation gets `change` 2 and a new cursor, and the
      feed lists them with all-zero sha256s; given it again, it answers 200 and no cursor
      moves.
AC-9: Given an id never published, `DELETE` answers 404 `not found`; given a path id that
      isn't a UUID, 400 `id: not a UUID`.
AC-10: Given `POST /stories` or `DELETE /stories/<id>` with no `Authorization`, a wrong
       token, or another scheme, then it answers 401 with an empty body, and a body that
       follows is never read (the connection is closed); given an unknown path or method,
       404 with no token check.
AC-11: Given a `POST /stories` with no `Content-Length`, or one above 10 222, then it answers
       400 `body: length required` or `body: too large` without reading the body.
AC-12: Given the read endpoints after the move onto `wire.Writer`, then every list and feed
       body is byte-for-byte what server-read's tests expect.
AC-F1: Given a SQLite failure inside the publish or removal transaction (the `story` table
       made read-only by a trigger), then it answers 500 with no body and no `story` row
       changed.
AC-F2: Given a client that sends a `POST /stories` head with a valid token and closes before
       the body is complete, then no row changes and the server keeps serving other
       connections.

## Touched boundaries

- The HTTP server (`Authorization` header, request body): AC-10, AC-11, AC-F2.
- SQLite (write transactions, cursor allocation): AC-F1.
