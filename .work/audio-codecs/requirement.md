# Audio codecs (audio-codecs)

## Summary

Vendors libopus 1.6.1, libopusenc 0.3 and libFLAC 1.5.0 as lazy `build.zig.zon`
dependencies compiled from source by `build.zig`, and adds a new `audio` module
(`src/audio.zig`) whose `encode` turns 16-bit mono PCM in memory into the two narration
files in memory: the Ogg Opus `.opus` for the app (16 kbps, mono) and the lossless `.flac`
master. `postilla narrate` (next slice) is its only caller.

## Specified

- "the PCM is encoded once to the Ogg Opus `.opus` that tilla.md describes (16 kbps,
  mono) … with vendored libopusenc over vendored libopus. libopusenc writes the Ogg
  container (headers, pages, pre-skip, end trimming) and resamples to a rate Opus takes, so
  the CLI writes no container code."
- "the same PCM is also compressed to FLAC with vendored libFLAC … a lossless copy kept for
  re-encoding later."
- "`audio_ms` is the PCM's length: its sample count ÷ its sample rate × 1000."
- AGENTS.md: "vendored C libraries (SQLite, libopus, libopusenc, libFLAC)".
- Owner (2026-11-18): a separate slice, "vendor the 3 libraries in build.zig.zon and add
  `audio.encode(pcm) → {opus, flac}`, tested on its own"; versions and hashes as fetched.
- Real Speechify output: headerless 16-bit little-endian mono PCM, 48 kHz with
  `output_format: pcm_48000`.

## Decided

- **API:** `audio.encode(a: Allocator, samples: []const i16, rate: u32) !Encoded`, where
  `Encoded` is `{ opus: []u8, flac: []u8, audio_ms: u32 }`, all in `a`. Samples are mono
  (Speechify's only layout). `rate` is a parameter because the stream says it
  (`audio/L16;rate=…`); narrate passes 48000. `audio_ms` is computed here so the formula
  lives in one place, rounded down. Rejected: taking raw bytes (narrate decodes base64
  into `i16`s anyway), writing files (narrate owns the folder).
- **Opus settings:** 16,000 bit/s, mono, `OPUS_SIGNAL_VOICE`, complexity 10, VBR (the
  default). The OpusHead input-rate field is `rate`. `OpusTags` holds only libopusenc's
  vendor string (no comments).
- **Deterministic output:** the same samples and rate give the same `.opus` and `.flac`
  bytes. libopusenc picks a random Ogg serial number by default; it is fixed with
  `OPE_SET_SERIALNO` (serial 1). Same reason as `.tilla.gz`: an unchanged narration keeps
  its sha256.
- **FLAC settings:** compression level 8, 16 bits, 1 channel, sample rate `rate`, the
  MD5 signature on (libFLAC's default), `total_samples` set before encoding so the
  STREAMINFO is complete without seeking (the encoder writes to memory).
- **Builds:** each library is compiled from its upstream `.c` files with its config as
  `-D` flags or a `b.addConfigHeader`. opus is the float build without SIMD intrinsics
  files, libFLAC without Ogg, both with only what `encode` needs (no decoder in
  production, no tools or programs). The test roots may link libFLAC's decoder and
  libopus's decoder (both already in the vendored sources) to check the outputs.
- **Errors:** a C call that reports failure returns `error.OpusEncode` or
  `error.FlacEncode`, after freeing the encoder. narrate turns them into its one line.

## Assumed

- **Zero samples is an error** (`error.NoAudio`), not an empty file: Speechify never
  streams no audio, and an empty `.opus` is useless to the app. Confirm: owner.
- **Rates libopusenc and libFLAC both take** (8,000 to 96,000 Hz) are accepted; others
  return `error.UnsupportedRate` before any C call. Blast radius: none today (48 kHz).
- **x86_64 Linux and aarch64** are the targets the build must compile for (this machine and
  the VPS); other targets aren't tested.

## Non-goals

- Decoding, playback, resampling in Zig, or any container code of our own.
- Stereo, other sample formats, other bitrates, or a bitrate setting.
- Writing files, reading Speechify, base64, `story.json`, or `narrate` itself.
- SIMD/intrinsics builds of opus or FLAC, libogg, the FLAC tools.
- Loudness changes (Speechify does them, decided for narrate).
- Streaming encode (the whole PCM is in memory: 20 min at 48 kHz is ~115 MB).

## Acceptance criteria

AC-1: Given 2 s of a 440 Hz sine at 48 kHz, when `audio.encode` runs, then `opus` is an Ogg
stream whose first page holds `OpusHead` with 1 channel, input rate 48000 and its
pre-skip, whose second holds `OpusTags`, every page's CRC checks, the serial number is the
same on every page, and the last page's granule position minus the pre-skip is the sample
count (at 48 kHz).

AC-2: Given AC-1's output, when the test decodes its Opus packets with the vendored
libopus decoder, then it gets the sample count back after dropping the pre-skip, and the
decoded signal correlates with the input (a 440 Hz peak).

AC-3: Given AC-1's output, then the average bitrate of the Opus packets is within 20% of
16 kbit/s.

AC-4: Given the same input, when `audio.encode` runs, then `flac` starts with `fLaC`, its
STREAMINFO says 48000 Hz, 1 channel, 16 bits and the sample count, and decoding it with the
vendored libFLAC decoder returns the input samples exactly, with a matching MD5.

AC-5: Given the same samples and rate twice, when `audio.encode` runs twice, then both
calls return identical `opus` and identical `flac` bytes.

AC-6: Given 24 kHz input (the rate Speechify's other formats use), when `audio.encode`
runs, then `audio_ms` is the sample count ÷ 24000 × 1000, OpusHead says 24000, the Opus
granule length is the sample count × 2, and the FLAC STREAMINFO says 24000.

AC-7: Given 120,000 samples at 48 kHz, then `audio_ms` is 2500.

AC-F1: Given zero samples, when `audio.encode` runs, then it returns `error.NoAudio` and
allocates nothing that leaks.

AC-F2: Given a rate of 0 or 200,000, when `audio.encode` runs, then it returns
`error.UnsupportedRate` and allocates nothing that leaks.

AC-F3: Given an allocator that fails, when `audio.encode` runs, then it returns
`error.OutOfMemory` with no leak (std.testing.checkAllAllocationFailures).

## Touched boundaries

| Boundary | Failure covered by |
|---|---|
| libopus/libopusenc C entry points | AC-F1, AC-F2 (rejected before the call), AC-F3 (allocation failure mid-encode) |
| libFLAC C entry points | AC-F1, AC-F2, AC-F3 |
