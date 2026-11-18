# Manifest — cli-publish

## Files to touch
- `src/cli.zig` — `run` (args, `cli.env` loading, config), and `publish`: parse and check
  `story.json`, fetch the server's lists, `r2.dict`, `tilla.build` per translation, upload,
  `POST /stories`. `main` calls `run` with the process env and cwd.
- `src/outbound.zig` — #25: each try sends its own copy of the body.
- `src/db.zig` — #18: a read-only open (`SQLITE_OPEN_READONLY`, no pragmas).
- `src/tilla.zig` — open `dict.db` with the read-only open.
- `build.zig` — the `cli` module imports what `tilla`, `r2` and `server` need (one file in one
  module); the test roots import `cli`.
- `cli.env.example` — `POSTILLA_R2_ENDPOINT` (optional).
- `docs/specification.md` — The CLI: `cli.env` format, exit codes, the `text_sha256` input,
  the 20 000-character unit, upload order and output; Configuration, CLI:
  `POSTILLA_R2_ENDPOINT`.

## New files
- `test/cli_publish.zig` — the tests for AC-1 … AC-11 and AC-F1 … AC-F5, with a fake R2 and a
  fixture `dict.db`.

## Public symbols to add
- `cli.run` — the command entry point the tests and `main` call.
- `db.openReadOnly` — the read-only open for `dict.db`.

## Reused, not rebuilt
- `src/tilla.zig:37` `build`, `:11` `Input`.
- `src/r2.zig:12` `Client` (`put`, `get`, `dict`).
- `src/outbound.zig:21` `request`, `:9` `Retry`.
- `src/wire.zig` `Reader`, `Writer`, `Lang`, `StoryId`.
- `src/server.zig` and `test/harness.zig` (the real server in tests); `test/r2.zig` `FakeR2`.

## Budget
added 450 · new files 0 · new public symbols 2

Raised from the default 300 before implementation, by the owner (2026-11-18): the command is
one unit (config, parse, checks, build, upload, POST), and its tests are end-to-end runs.

## API
settled
