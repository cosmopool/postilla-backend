# Code map: cli-narrate

Base 2be5999 (main after audio-codecs).

## What exists and is reused

- `src/cli.zig` (343 lines): `run` accepts `publish <folder>` and `translate <folder> [...]`
  (line 34); everything else is usage + exit 2. `command(..., translate: bool, ...)` (line
  100) holds the shared start: `cli.env`, the 8 required variables, `story.json` read,
  parse and rules 1–8, and the four server lists (LANG with `target` and `translate`).
  The `if (translate)` block (line 193) is the per-command part; narrate adds its own
  block beside it, so the shared start stays one copy.
- `src/cli.zig` `translate` precedent for: an optional base-URL variable checked for `://`
  (`POSTILLA_OPENCODE_URL`, line 119-121); a per-language table fixed in code
  (`prompt_names`, line 82); a content-check retry loop around `outbound.request` (3
  tries, immediately); writing `story.json` with `.indent_2` to `story.json.tmp` then
  rename (lines 255-256).
- `src/cli.zig` `publish` computes `text_sha256` the narrate way (sentences joined by one
  space, paragraphs by one newline) and checks it against `audio.text_sha256`; it reads
  `<lang>.opus` and `<lang>.flac` from the folder. narrate must produce exactly what
  publish checks.
- `src/audio.zig`: `encode(a, samples: []const i16, rate) !Encoded{opus, flac, audio_ms}`.
- `src/outbound.zig`: `request` with 4 tries; `Retry` (`waits_ms`, `max_wait_ms`,
  `connect_timeout_ms`, `idle_timeout_ms`); `send` reads the whole body with
  `allocRemaining` while the caller waits `idle_timeout_ms` once after connect for the
  whole answer (lines 36-37, 64): the "idle" timeout is a per-try deadline (#20).
- `test/r2.zig:425` (AC-F1) and `test/r2_repro_r1_3.zig` test the timeout through
  `r2.Client` with a small `Retry`; `test/cli_translate.zig` has the fake OpenCode
  pattern (fake server on a free port, the real server for the lists, `cli.run` in-process).

## Conflicts and gaps

1. The spec's request list says "the highest-quality PCM that Speechify streams"; the real
   field is `output_format: pcm_48000` (fixture). The spec doesn't name `output_format`,
   `options`, the base URL variable, or the voice/language table.
2. "`speech.error` … counts as a failed try. The whole call is retried": `outbound.request`
   returns a 200 whose body has `speech.error`, so the content check is narrate's, like
   DeepSeek's bad reply.
3. "Words are matched to sentences by mapping the marks' character offsets onto the
   sentences": offsets are code points into `input`; the input is the narrate text, so a
   sentence's range in it follows from the join.
4. A sentence with no marks: owner chose `[end, end]` at the gap.
5. `times` must satisfy tilla.md rule 8 (`start_ms <= end_ms <= audio_ms`, starts
   non-decreasing); a last mark's `end_time` may exceed `audio_ms` by rounding.
6. The idle timeout (#20) must become a true idle timer.

## Boundaries crossed

- outbound HTTPS: Speechify (new), the server's lists (existing).
- filesystem: writing `<lang>.opus`, `<lang>.flac`, `story.json` (new).
- libopus/libFLAC through `audio.encode` (existing module).
- env: `POSTILLA_SPEECHIFY_URL` (new).
