# Manifest — audio-codecs

## Files to touch
- `build.zig.zon` — the `opus`, `opusenc` and `flac` lazy dependencies (url and hash).
- `build.zig` — compile the three libraries' sources into the new `audio` module (config
  as `-D` flags or config headers), its translate-c header, and import `audio` in every
  test root; the test roots also get libopus's and libFLAC's decoders to check outputs.
- `docs/specification.md` — `postilla narrate`: the encoder settings (16 kbit/s voice,
  complexity 10, fixed serial so output is deterministic; FLAC level 8), the 48 kHz PCM the
  real stream sends (closes the Open item on the sample rate), the library versions.
- `docs/tilla.md` — the `.opus` line: deterministic, OpusHead input rate.
- `AGENTS.md` — the vendored library versions.

## New files
- `src/audio.zig` — `encode` and `Encoded`: PCM to `.opus` and `.flac` in memory.
- `src/audio.h` — the C headers translate-c reads (`opusenc.h`, `FLAC/stream_encoder.h`).
- `test/audio.zig` — the tests for AC-1 … AC-7 and AC-F1 … AC-F3.

## Public symbols to add
- `audio.encode` — PCM to the two files.
- `audio.Encoded` — its result: `opus`, `flac`, `audio_ms`.

## Reused, not rebuilt
- `build.zig:31-38`, `:119-146` — SQLite's lazy-dependency, translate-c and C-source
  pattern.
- `build.zig:62-105` — the test-root loop.

## Budget
added 300 · new files 2 · new public symbols 2

## API
settled
