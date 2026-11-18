# Code map — cli-publish

Base aacef22 (scaffold, server-read, server-write, words, tilla-writer, r2).

## Reuse

- `src/cli.zig:15` `main` — prints usage and exits 2. **`publish` is wired here.**
- `src/tilla.zig:11` `Input` (story header, `lang`, `original`, title, subtitle, paragraphs,
  optional narration: `audio_ms`, opus sha256 and size, per-sentence times), `:37`
  `build(arena, input, dict_path)` → `.tilla`, `.gz`, sha256 of the `.tilla`. It refuses bad
  input with `error.Empty`, `BadSentence`, `TooManyWords`, `TooMany`, `BadNarration`. It opens
  `dict.db` through `db.open`, which sets WAL (questions.md #18: switch to read-only).
- `src/r2.zig:12` `Client` (endpoint, bucket, key id, secret, `outbound.Retry`) with `:21`
  `put` (Content-Type by extension, immutable Cache-Control, signed), `:29` `get`, `:36`
  `dict(dir)` → path of the current `dict.db`.
- `src/outbound.zig:9` `Retry` (waits 5 s / 30 s / 2 min, 10 s connect, 60 s per try), `:21`
  `request` — the one outbound call; reused for the server's list GETs and POST /stories.
  questions.md #25: `send` passes `@constCast(body)` to `sendBodyComplete`, which writes into
  the caller's buffer on a cut send, so the retry sends altered bytes. **Fix here.**
- `src/wire.zig` `Reader` (to parse GNRS/TAGS/AUTH/LANG list bodies), `Writer` (to build the
  STRY body), `Lang`, `StoryId.parse` (the `story.json` id).
- `src/server.zig` `listen`/`serve` and `test/harness.zig` — the tests start the real server
  in-process, publish through it and read the feed back.
- `test/r2.zig` `FakeR2` — a fake R2 that verifies SigV4 and stores objects; the cli-publish
  tests need the same (copy or import it).
- `build.zig` — the `cli` module (`src/cli.zig`) must import what `tilla`, `r2` and `server`
  need; Zig allows a file in one module only (`server.zig` owns `wire.zig` and `db.zig`, and
  `tilla` reaches them through `@import("server")`).

## Contract

- `docs/specification.md`, The CLI: the story folder, `story.json` and its 8 rules,
  `postilla publish` (the three checks, vocabulary coverage, building and uploading), Retries;
  Configuration, CLI (`cli.env` in the current directory, env wins, required variables);
  `POST /stories` (STRY layout, 409 reasons).
- `cli.env.example` lists the CLI's variables; it gains `POSTILLA_R2_ENDPOINT`.

## I/O boundaries crossed

- The filesystem (the story folder, `cli.env`, the dict cache), env at startup (`cli.env` and
  the process environment), outbound HTTPS (R2 and the server), SQLite (`dict.db`).
