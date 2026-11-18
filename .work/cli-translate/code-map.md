# Code map: cli-translate

Base d085737 (main after cli-publish).

## What exists and is reused

- `src/cli.zig` (215 lines): `main`, `run(io, arena, env, cwd, args) u8`, `fail`, and
  `publish`. `run` accepts only `publish <folder>` (args.len == 3); every other shape prints
  usage and exits 2. `publish` does, in order, work that translate needs too:
  1. `cli.env` loading and the required-variable check (lines 51-65), all 8 variables;
  2. opening the folder and reading `story.json` (76-78);
  3. the `story.json` struct and parse (79-96) and the 8 rules (100-122);
  4. fetching the four server lists (124-136), LANG with `target` and `translate` flags.
  Translate reuses 1-4 unchanged: they move out of `publish` into one function both
  commands call, so the rules can't drift between commands (AGENTS.md: no duplication).
  Publish-only parts (genre/tag/author checks against the lists, narration, tilla, R2,
  POST /stories) stay in `publish`.
- `src/outbound.zig`: `request(io, a, retry, method, url, headers, body, digest)` with the
  4-try schedule, Retry-After, the 10 s connect / 60 s per-try timeouts and a body copy per
  try. Jev and DeepSeek calls go through it. `digest` is R2-specific; translate passes "".
  `Retry` is a parameter, so tests can shrink the waits only through the fakes' Retry-After
  (tests in cli_publish.zig answer 503 + `Retry-After: 0`).
- `std.json` parses replies (Jev answer, DeepSeek `choices[0].message.content`, then the
  content as `[]const []const u8`) and writes `story.json` back.
- `test/cli_publish.zig`: the pattern for CLI tests: `cli.run` in-process, temp folder as
  cwd, the real server from `test/harness.zig` for the lists, a fake on a free port,
  stderr/stdout captured to a file. `World`, `FakeR2` are private to that file; a fake
  OpenCode server is new and lives in the new test file.
- `build.zig`: `cli` module already importable from tests; no new module needed when the
  code stays in `src/cli.zig` (one file per module rule).

## Conflicts and gaps in the spec

1. **Base URLs for the fakes.** The spec says tests point OpenCode's base URL at a fake, but
   `docs/specification.md` hardcodes `https://opencode.ai/...` and there's no variable.
   publish solved the same gap with `POSTILLA_R2_ENDPOINT`.
2. **Tries for a bad reply.** "A reply that isn't a JSON array … counts as a failed try (see
   Retries)" but "After the third failed try the command stops", while Retries gives 4
   tries. `outbound.request` retries only on status, so a content check needs its own loop.
3. **DeepSeek URL.** The spec says `/inference/openai/v1/chat/completions`; the owner chose
   Go (`/inference/go/v1/chat/completions`), which needs `user-agent` and
   `x-opencode-session` (fixture call answered 400 MissingSessionID without it).
4. **Criteria text** for the six options and the question's `instructions` aren't written
   anywhere; the fixture request holds a draft.
5. **Writing `story.json`.** No code writes it yet. std.json's `.indent_2` puts every array
   element on its own line, so `times` (3 levels of numbers) would take one line per
   number. The file is hand-edited and kept in git.
6. **The Italian moderation test set** ("runs only on demand", calls Jev for real): no build
   step for on-demand tests exists; every `test/*.zig` runs in `zig build test`.
7. **Which variables translate requires.** The table marks 8 variables required; publish
   checks all 8, though it doesn't use OpenCode or Speechify.

## Boundaries crossed

- outbound HTTPS: OpenCode Jev and DeepSeek (new), the server's list endpoints (existing).
- the filesystem: reading `story.json`, writing it back (new), `cli.env` (existing).
- env read at startup: `POSTILLA_MODERATION_THRESHOLD` (new), the existing variables.
