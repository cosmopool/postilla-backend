# Manifest — cli-narrate

## Files to touch
- `src/cli.zig` — `run` accepts `narrate <folder>`; a narrate block beside translate's in
  `command`: the voice table, the Speechify request, reading the SSE events (base64 PCM,
  word marks, `speech.done`/`speech.error`) with 3 tries for a bad stream, the sentence
  times, `audio.encode`, writing `<lang>.opus`, `<lang>.flac` and `story.json` (temp,
  rename). `POSTILLA_SPEECHIFY_URL`.
- `src/outbound.zig` — the true idle timer: `idle_timeout_ms` from the last byte received.
- `build.zig` — the `cli` module imports `audio`.
- `cli.env.example` — `POSTILLA_SPEECHIFY_URL` (optional).
- `docs/specification.md` — `postilla narrate`: the request body (`output_format`,
  `options`), the voice table, the input join, the mark matching and `[e, e]`, the cap at
  `audio_ms`, the 3 tries for a bad stream, the write order; Retries: the idle timer;
  Configuration, CLI: `POSTILLA_SPEECHIFY_URL`.

## New files
- `test/cli_narrate.zig` — the tests for AC-1 … AC-10 and AC-F1 … AC-F4, with a fake
  Speechify on a free port and the real server for the lists.

## Public symbols to add
None.

## Reused, not rebuilt
- `src/cli.zig:100` `command`'s shared start, `:82` the `prompt_names` table pattern, the
  translate try loop and `story.json.tmp` write.
- `src/audio.zig:12` `encode`.
- `src/outbound.zig:21` `request`, `:9` `Retry`.
- `test/harness.zig` `Harness`; `test/cli_translate.zig`'s fake-server pattern;
  `test/r2.zig:425`'s small-`Retry` timeout test pattern.

## Budget
added 300 · new files 0 · new public symbols 0

## API
settled
