# Manifest — cli-translate

## Files to touch
- `src/cli.zig` — `run` parses `translate <folder> [--force] [--redo <lang>]` next to
  `publish`; the shared start (`cli.env`, required variables, `story.json` read, parse and
  rules 1–8, the four server lists) moves out of `publish` into one function both commands
  call; `translate`: the languages to do, `moderate` (Jev), the per-paragraph DeepSeek loop
  with 3 tries, and the `story.json` write (temp file, rename).
- `build.zig` — a `test-moderation` step that runs `test/live/moderation.zig` with the `cli`
  module; `zig build test` still runs only `test/*.zig`.
- `cli.env.example` — `POSTILLA_OPENCODE_URL` (optional).
- `docs/specification.md` — `postilla translate`: the criteria texts, `state`, when
  `story.json` is written, `forced`, the 3 tries for a bad reply, the Go URL with
  `user-agent` and `x-opencode-session`, `--redo` and flag errors; Configuration, CLI:
  `POSTILLA_OPENCODE_URL`; Tests: `zig build test-moderation`.

## New files
- `test/cli_translate.zig` — the tests for AC-1 … AC-10 and AC-F1 … AC-F5, with a fake
  OpenCode (Jev and DeepSeek) on a free port and the real server for the lists.
- `test/live/moderation.zig` — the on-demand Italian test set against the real Jev.

## Public symbols to add
- `cli.moderate` — one Jev call returning the six scores; the live test set calls it.

## Reused, not rebuilt
- `src/cli.zig:30` `run`, `:42` `fail`, `:50` `publish`'s config, parse, rules and list code
  (moved, not copied).
- `src/outbound.zig:21` `request`, `:9` `Retry`.
- `src/wire.zig` `Reader` (the lists).
- `test/harness.zig` `Harness` (the real server for the lists).
- `.work/fixtures/jev_response.json`, `.work/fixtures/deepseek_go_response.json` (the fake's
  answer shapes).

## Budget
added 300 · new files 2 · new public symbols 1

## API
settled
