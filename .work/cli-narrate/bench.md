# cli-narrate — bench (stage 3)

## What was measured, and why only this

`cli-narrate` adds no server code: `GET /stories`, its SQLite statements and its
allocations per request are untouched by the diff (`git diff 2be5999 HEAD -- src` changes
only `src/cli.zig` and `src/outbound.zig`). The only path a person waits on is the author
running `postilla narrate <folder>` on their own machine, once per story. So the
measurement is one `narrate` run on the largest story rule 8 allows, against a fake
Speechify on loopback.

The four flagged lines (`src/cli.zig:281, 299, 333, 341`) are all in that run:

| Line | What it allocates | Size at the maximum story |
|---|---|---|
| 281 | `starts.append` + `utf8CountCodepoints(input.written())` per sentence (O(sentences x input)) | 260 sentences, 18,720 code points |
| 299 | `bytes.addManyAsSlice` per `speech.chunk`, the decoded PCM | 3,381 events, 113.6 MB PCM |
| 333 | `shaped`, one slice per paragraph | 20 slices |
| 341 | the `<lang>.opus` / `<lang>.flac` names | 2 short strings |

Lines 333 and 341 are constant-size and are not measured further.

## Setup

- Harness: `.work/cli-narrate/bench/bench_narrate.zig`, the helpers and `FakeSpeechify` of
  `test/cli_narrate.zig` with two changes: the good stream sends **one `speech.chunk` per
  word** (that word's audio and its mark) instead of four big chunks, and the fake caches its
  stream after the first build so the measured runs don't pay for generating it.
- Story: 20 paragraphs x 13 sentences of 72 code points (with accented letters) =
  **18,720 code points** (rule 8 max is 20,000), 3,380 words, 350 ms per word, giving
  **audio_ms = 1,183,000 (19.7 min)**, a **152,015,271-byte** SSE body in **3,381 events**.
- `cli.run(io, arena, ...)` is called in-process with an `ArenaAllocator` over a counting
  wrapper of `std.heap.page_allocator` (as `main` uses the process arena). Run 1 warms the
  fake; runs 2-4 are measured and the best wall time is kept.
- Peak memory: `/proc/self/clear_refs` <- `5` before the run, then `VmHWM - VmRSS(before)`
  after it (real touched pages, not reserved address space).
- ReleaseFast, 16 cores, 7.8 GiB RAM, Linux 7.0.14, Zig 0.17.1.

Command (copy the harness into `test/` to run it, then remove it):

```
cp .work/cli-narrate/bench/bench_narrate.zig test/bench_narrate_tmp.zig
zig build test -Dtest-file=test/bench_narrate_tmp.zig -Doptimize=ReleaseFast 2>&1 | grep BENCH
rm test/bench_narrate_tmp.zig
```

## Raw numbers

Last run (three full runs gave the same picture; their totals were 19,596.0 / 19,957.8 /
19,644.9 / 19,766.8 ms and encode 18,372.3 / 18,510.6 / 18,541.6 / 18,416.8 ms):

```
BENCH code_points=18720 sentences=260 words=3380 audio_ms=1183000 sse_body_bytes=152015271 events=3381
BENCH narrate_total_ms(best of 3)=19766.8
BENCH audio_encode_ms(best of 3, pre-existing)=18416.8
BENCH narrate_minus_encode_ms=1350.0
BENCH input_starts_loop_us(best of 3)=1893.9
BENCH backing_alloc_calls(last run)=23 backing_peak_MiB=1552.6
BENCH encode_backing_peak_MiB=341.0 encode_calls=17
BENCH narrate_rss_peak_delta_MiB(last run)=887.9 encode_rss_peak_delta_MiB=240.9
BENCH process_maxrss_MiB=1719.0
```

- `narrate_total_ms`: all of `cli.run narrate`: config, `story.json` check, the server's
  lists, the Speechify stream over loopback, SSE/JSON parse, base64 decode, mark matching,
  `audio.encode`, three writes.
- `audio_encode_ms`: `audio.encode` alone (pre-existing, audio-codecs feature) on the same
  56.8 M samples. `narrate_minus_encode_ms` is therefore everything this feature added,
  plus the pre-existing list fetch and file writes: **1.10-1.45 s across runs**.
- `input_starts_loop_us`: the flagged line 281 loop alone on the same paragraphs:
  **1.9-2.4 ms**. Quadratic, but bounded by rule 8, and four orders of magnitude below the run.
- `backing_peak_MiB`: address space the arena requested (its own chunks grow geometrically:
  924 MB, 496 MB, 147 MB, 43 MB, ... freed at deinit). It overstates memory use, because
  untouched pages are never resident; the RSS delta is the real number.
- `narrate_rss_peak_delta_MiB`: **888 MiB** resident at peak for one narrate of the
  maximum story; `audio.encode` alone is 241 MiB of that. The stream part (body + decoded
  PCM + arena growth copies) is about **647 MiB**, against 145 MiB body + 108 MiB PCM =
  253 MiB that must exist at once.

## Paid outside-service calls per run

Counted by the fake's request log in `test/cli_narrate.zig` (passing suite, not a new
measurement):

| Case | Speechify streams | Test |
|---|---|---|
| good stream | 1 per `target` 1 language (today 1) | AC-1, AC-5 (`requests(a, stream_path)).len` = 1) |
| `speech.error`, then good | 2 | AC-7, line 582 |
| bad stream every time | 3, then stop | AC-7 / AC-8, lines 645, 659 |
| 5xx / 429 | up to 4 HTTP tries inside one `outbound.request` (unbilled per Speechify's errors) | AC-F2, line 696 |

No path repeats a billed call beyond what the requirement decided (3 tries of a bad
stream, assumed and flagged to the owner).

## Reading

- **Time:** the feature's own work is ~1.1-1.45 s of a ~19.7 s local run; ~93% is the
  pre-existing `audio.encode` (libopus complexity 10 + FLAC level 8 on 20 min). In real use
  the wait is dominated by Speechify generating ~20 min of audio, which the CLI cannot
  shorten. No time hotspot.
- **Memory:** 888 MiB peak resident on the largest story, about 3.5x the requirement's
  stated assumption ("about 160 MB of base64 ... plus the decoded PCM"). The excess over
  the 253 MiB floor comes from geometric growth inside an arena, which can't free the
  buffers it outgrows: the body's `Io.Writer.Allocating` in `outbound.send` (the same
  pattern as the base's `allocRemaining`) and `bytes` at `cli.zig:299`. That fits easily on
  an author's machine, runs once per story, and the requirement already accepts holding the
  whole stream in memory. A bad-stream retry keeps the failed try's body and PCM in the
  arena too, so a third try can roughly triple the stream part (not measured).
- No hotspot that someone waits on. The memory number is recorded for the owner, against
  the requirement's "Assumed" entry.

## Proposals

### 1. Reserve the PCM buffer from the body size before decoding (`src/cli.zig:298`)

```zig
var bytes: std.array_list.Aligned(u8, .of(i16)) = .empty;
try bytes.ensureTotalCapacityPrecise(a, res.body.len / 4 * 3);
```

- **Measurement behind it:** `narrate_rss_peak_delta_MiB` = **887.9 MiB** on the largest
  story, against a 253 MiB floor (145 MiB body + 108 MiB PCM). Part of the excess is `bytes`
  growing geometrically inside the arena: every growth copies, because the per-event JSON
  parse allocates between two growths, so the arena can't resize in place and keeps each
  outgrown buffer resident.
- **Why the bound is safe:** every event's `audio` is a substring of `res.body`, so the
  decoded total is at most `body.len / 4 * 3`. An `audio` that isn't a multiple of 4 already
  fails `calcSizeForSlice` and starts the next try. If the bound were ever too small, the list
  would just grow as it does today.
- **Tried, not estimated:** I applied it in a scratch copy of the tree and ran the same
  harness, baseline first, then with the line added (ReleaseFast, same machine):

  | | baseline (copy) | with the line |
  |---|---|---|
  | `narrate_rss_peak_delta_MiB` | 887.9 | **659.0** (-228.9, -26%) |
  | `process_maxrss_MiB` | 1719.2 | 1489.6 |
  | `narrate_minus_encode_ms` | 1304.0 | 986.0 (one run each; earlier runs spread from 1103 to 1447) |
  | `narrate_total_ms` | 19702.2 | 19408.7 (noise next to `audio.encode`) |
  | `backing_peak_MiB` (reserved, mostly untouched) | 1552.6 | 1704.7 |

  `zig build test -Dtest-file=test/cli_narrate.zig` passes with it (exit 0).
- **Cost:** 1 added line, no new symbol, type or branch.
- **Who notices:** the author running `postilla narrate` on their own machine, once per
  story: about 229 MiB less peak memory (more per extra try, since a bad-stream retry keeps
  every earlier try's buffers in the arena). Nothing changes on the VPS, for clients or for
  the operator.

### Considered and not proposed

- **The body buffer in `outbound.send` (`Io.Writer.Allocating`).** This is the rest of the
  excess. But the SSE answer is chunked and has no Content-Length to size it from, so fixing
  it means streaming the parse or adding a size guess. That is more code than the memory
  number justifies on an author's machine.
- **`cli.zig:281` quadratic `utf8CountCodepoints`.** Measured at 1.9-2.4 ms in a 19.6 s run
  (about 0.01%), and rule 8 caps the input. Not worth a line.
- **Time in general.** The feature's own work is 1.1-1.45 s of the run (about 6%).
  `audio.encode` (pre-existing) takes about 18.4 s and is out of scope.
- **Paid calls.** At most 3 billed streams per language, which is the cap the requirement
  set. There is nothing to cut.
