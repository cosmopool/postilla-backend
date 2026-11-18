Source: the docs at ed77e3c plus the owner's decisions of 2026-11-18 (in this session):
- Narrate is split in two slices: first `audio-codecs`, "vendor the 3 libraries in
  build.zig.zon and add `audio.encode(pcm) → {opus, flac}`, tested on its own (like
  tilla-writer before publish)", then `cli-narrate` (Speechify, the times, story.json).
- The real Speechify stream (one call, 2026-11-18, `output_format: pcm_48000`) answered
  `audio/L16;rate=48000;channels=1`: headerless 16-bit little-endian mono PCM at 48 kHz
  (267,456 samples = the 5,572 ms `audio_duration_ms` it reported). Recorded in
  .work/fixtures/speechify_stream.txt (copied from the main checkout).
- Upstream releases fetched (zig fetch, hashes):
  opus 1.6.1  https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz
              N-V-__8AAAmivwH7RvCrZo25NNu0lx2Sw-ogZhmqGXvorlHg
  libopusenc 0.3  https://downloads.xiph.org/releases/opus/libopusenc-0.3.tar.gz
              N-V-__8AANB3GQBtrxMa9xyAbZBStXmHzjUSq-s95bcFjzuO
  flac 1.5.0  https://downloads.xiph.org/releases/flac/flac-1.5.0.tar.xz
              N-V-__8AAHSrwgDkuwylGkEyZxj-_xKsppp8z8563UYjXs2B
Speechify and narrate itself are the next slice.

From docs/specification.md, `postilla narrate`:

The stream yields three outputs:

- **Sentence times:** each sentence's `start_ms` and `end_ms` run from its first word's `start_time` to its last word's `end_time`. Words are matched to sentences by mapping the marks' character offsets onto the sentences.
- **App audio:** the PCM is encoded once to the Ogg Opus `.opus` that tilla.md describes (16 kbps, mono), written as `<lang>.opus`, with vendored libopusenc over vendored libopus. libopusenc writes the Ogg container (headers, pages, pre-skip, end trimming) and resamples to a rate Opus takes, so the CLI writes no container code. `audio_ms` is the PCM's length: its sample count ÷ its sample rate × 1000.
- **Master:** the same PCM is also compressed to FLAC with vendored libFLAC, written as `<lang>.flac`. It is a lossless copy kept for re-encoding later. The app never downloads it.

The times, `audio_ms` and the sha256 of the input text go to the translation's `audio` in `story.json`. Listen to the `.opus` before publishing.

From docs/tilla.md:

The `.opus` is Ogg Opus, 16 kbps, mono, encoded once from the narration's PCM; sentence times are in milliseconds from the start of the decoded audio. A reader checks a downloaded `.opus` against `opus_size` and `opus_sha256`.

From AGENTS.md:

The backend is Zig (0.17, the `minimum_zig_version` in `build.zig.zon`) with vendored C libraries (SQLite, libopus, libopusenc, libFLAC). The design lives in [docs/specification.md](docs/specification.md).
