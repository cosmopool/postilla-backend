# audio-codecs — stage 3 measurements

Base `ed77e3cf559f507ef5398535638935ab4396c441`, branch `work/audio-codecs`, Zig 0.17.1,
x86_64 Linux, `-Doptimize=ReleaseFast`.

## What was checked and what does not apply

- **`GET /stories` latency, SQLite statements/rows per request:** not affected. `audio` is
  imported only by the test roots (`build.zig:135`); no `src/` file imports it
  (`grep -rn '@import("audio")' src` → nothing), so the server binary is unchanged.
- **Paid outside-service calls per draft:** none. `audio.encode` is pure in-memory C
  encoding; it calls no Speechify, OpenCode or R2.
- **What remains:** the flagged allocation lines (`src/audio.zig:26,34,36,49,53,61`) run
  once per narration in the CLI (`postilla narrate`, next slice), over the whole PCM.
  Measured at a typical story narration (5 min) and at the requirement's stated upper bound
  (20 min, "~115 MB").

## Harness

`.work/audio-codecs/bench_harness.zig` (copied to `test/zz_bench_audio_<N>.zig` for the run,
deleted afterwards). It wraps the allocator passed to `encode` in a counting allocator
(allocs, resizes/remaps, peak live bytes), reads `VmHWM` from `/proc/self/status` before
and after `encode`, and times `encode`. Input: 48 kHz mono voice-like signal (140 Hz
fundamental + 2 harmonics, 4 Hz amplitude envelope, ±800 uniform noise). It also times the
Zig-side work the flagged lines add (the `i16`→`i32` copy and the FLAC `dupe`) on the same
sizes.

Commands (one process per size, so `VmHWM` is not shared):

```
zig build test -Doptimize=ReleaseFast -Dtest-file=test/zz_bench_audio_5.zig
zig build test -Doptimize=ReleaseFast -Dtest-file=test/zz_bench_audio_20.zig
```

(The build reports the step as failed only because the harness prints to stderr.)

## Raw output

```
BENCH minutes=5 samples=14400000 pcm_bytes=28800000 encode_ms=5441 opus_bytes=613952 flac_bytes=20353660 audio_ms=300000 a_allocs=3 a_resizes=14 a_peak_bytes=78567612 a_live_after=20967612 hwm_before_kb=30896 hwm_after_kb=129932 rss_growth_kb=99036 zig_copies_ms=56
BENCH minutes=20 samples=57600000 pcm_bytes=115200000 encode_ms=24203 opus_bytes=2455202 flac_bytes=81421399 audio_ms=1200000 a_allocs=3 a_resizes=18 a_peak_bytes=314276601 a_live_after=83876601 hwm_before_kb=115228 hwm_after_kb=505780 rss_growth_kb=390552 zig_copies_ms=210
```

## Reading

| | 5 min | 20 min |
|---|---|---|
| `encode` wall time | 5.44 s | 24.2 s |
| Zig-side copies (`wide` fill + FLAC `dupe`) | 56 ms (1.0%) | 210 ms (0.9%) |
| allocations in `a` | 3 allocs + 14 resizes | 3 allocs + 18 resizes |
| peak live bytes in `a` | 78.6 MB (2.7× PCM) | 314.3 MB (2.7× PCM) |
| process RSS growth during `encode` | 99.0 MB | 390.6 MB |
| process peak RSS incl. caller's PCM | 130 MB | 506 MB |

- **Time:** ~99% is libopus (complexity 10) and libFLAC (level 8), settings fixed by the
  requirement. The Zig code the feature added costs ≤1% of the run. No time hotspot.
- **Allocation count:** 3 allocations plus amortised `ArrayList` growth per narration.
  Not a cost.
- **Peak memory:** the peak in `a` is reached at the final `a.dupe` (`src/audio.zig:49`),
  while all of these are live at once: `wide` (`:36`, 4 bytes/sample = 230.4 MB at 20 min,
  73% of the peak), the FLAC bytes in libc (`:34`/`:54`, 81.4 MB), their copy in `a` (81.4 MB)
  and the Opus bytes (2.5 MB). 230.4 + 81.4 + 81.4 + 2.5 + the caller's 115.2 MB PCM ≈ 511 MB,
  which matches the 505,780 kB `VmHWM`.

## Possible optimisation (numbers only; the gain/lines decision belongs to the stage)

- Feed libFLAC in fixed chunks through a stack `[4096]i32` buffer instead of allocating
  `wide` for the whole PCM: removes one allocation and its `OutOfMemory` path; saves
  57.6 MB at 5 min and 230.4 MB at 20 min (the peak in `a` falls from 2.7× to 0.7× the PCM;
  the process peak at 20 min falls from ~506 MB to ~276 MB). Estimated +4 to +5 added lines,
  since the single chained `if … or` in `:41-45` would be split around a loop. Not
  implemented or measured here.
- Dropping the FLAC `dupe` (81.4 MB at 20 min) would need the write callback to append to
  `a` and carry the error out of the C callback: more lines for a smaller gain.

Whether either matters depends on the memory of the machine that runs `postilla narrate`.
At a typical 5-min narration the whole encode peaks at 130 MB of RSS; the 2.7× factor only
shows at the 20-min upper bound, which the requirement accepts as in memory (non-goal:
streaming encode).

## Proposals

### P1: feed libFLAC from a stack `[4096]i32` chunk instead of allocating `wide`

- **Measured before:** `wide` (`src/audio.zig:36`) is 4 bytes/sample over the whole PCM, which
  is 73% of the peak live bytes in `a`: 57.6 MB of 78.6 MB at 5 min and 230.4 MB of 314.3 MB at
  20 min. Process peak RSS (`VmHWM`) 130 MB at 5 min, 506 MB at 20 min.
- **Expected after:** the peak in `a` falls from 2.7x to 0.7x the PCM (about 21 MB at 5 min,
  84 MB at 20 min); process peak about 72 MB at 5 min and about 276 MB at 20 min. Wall time
  unchanged within noise: the `wide` fill is part of the 56/210 ms Zig-side share (1%), and
  the chunked copy does the same per-sample work. One allocation and its `OutOfMemory`
  path go away (AC-F3 keeps passing, with one failure point fewer). This is arithmetic from
  the measured peak breakdown above, not a measurement of the changed code; re-run the
  harness after the change to confirm.
- **Added lines:** net +2 in `src/audio.zig` (lines 36-38 and the tail of the `if` chain at
  43-45 are rewritten; about 8 lines added, 6 removed). +5 if written with a hand-kept index
  instead of `std.mem.window`. Sketch:

  ```zig
      if (… set_* … == 0 or
          c.FLAC__stream_encoder_init_stream(f, flacWrite, null, null, flacStreamInfo, &flac) != c.FLAC__STREAM_ENCODER_INIT_STATUS_OK) return error.FlacEncode;
      var wide: [4096]i32 = undefined;
      var parts = std.mem.window(i16, samples, wide.len, wide.len);
      while (parts.next()) |part| {
          for (part, wide[0..part.len]) |s, *w| w.* = s;
          if (c.FLAC__stream_encoder_process_interleaved(f, &wide, @intCast(part.len)) == 0) return error.FlacEncode;
      }
      if (c.FLAC__stream_encoder_finish(f) == 0) return error.FlacEncode;
  ```

  libFLAC buffers input up to its own blocksize (4096 at level 8) whatever the call size, so
  the `.flac` bytes should not change; AC-4 (exact decode + MD5) and AC-5 (identical bytes)
  check that. It also follows AGENTS.md ("fixed-size arrays or stack buffers").
- **User-visible on the VPS:** not today. `audio` is linked only into the test roots now, and
  its first caller, `postilla narrate`, runs on the author's machine (v1.0), where 230 MB at
  the 20-min upper bound will not be noticed. It becomes operator-visible only if narration
  moves into the server worker on the "small Linux VPS" (roadmap v1.2), where a 20-min
  narration would peak at about 506 MB in that process next to `postilla-server`.

### Not proposed

- **Dropping the FLAC `a.dupe`** (`:49`, 81.4 MB at 20 min): the write callback would have to
  append to `a` and carry the Zig error out of the C callback, which needs a context struct
  (a new type) and more lines than P1 for about a third of its gain.
- **Time:** ~99% of the 5.4 s / 24.2 s is libopus (complexity 10) and libFLAC (level 8), both
  fixed by the requirement; the Zig code is ≤1%. Nothing to take.
- **Allocation count:** 3 allocations + 14/18 amortised resizes per narration, run once per
  narration. Pre-sizing the Opus list would save nothing measurable.
- **`GET /stories`, SQLite, paid calls:** 0 affected paths, 0 calls. Nothing to optimise.
