# tilla-writer: stage 3 measurements

## What the feature runs on

`tilla.build` is called by `postilla publish` (cli-publish, not wired yet) once for each
translation, on the author's machine. It is not on any server request path. Nothing
reaches it from `GET /stories`, the feed or the lists, and it makes no paid outside-service
calls. The requirement calls it "the CLI's cold path, once per translation".

The flagged lines:

| at | what | measured cost |
|---|---|---|
| src/tilla.zig:41 | `spans` = 65 536 x `words.Span` (4 B) = 256 KiB, a fixed size for each call | inside the 464 KB below |
| src/tilla.zig:42 | `key_buf` = 128 KiB, a fixed size for each call | inside the 464 KB below |
| src/tilla.zig:53 | one `sqlite3_prepare_v2` for each build (Italian only), reset for each key | 1 prepare, about 1 step per word |
| src/tilla.zig:105 | the `.tilla` buffer, sized exactly by the first pass | 52 691 B for 3 000 words |

## Setup

- A temporary test at `test/zz_bench_tilla.zig`, removed after the run. A copy is kept at
  `/tmp/claude-1000/-home-arrow-Development-postilla-backend/945d538b-48e1-4b97-9e7b-965747cfa7f8/scratchpad/zz_bench_tilla.zig`.
- `dict.db`: CONTRACT.md's schema and indexes, 50 000 `entry` rows and 250 000 `form` rows.
- Story: 40 paragraphs x 5 sentences x 15 words = 3 000 words, which is longer than a
  graded reader's usual story. About 1 word in 6 is missing from the dict, and every 10th
  word is elided (`l'…`), which gives a second lookup key.
- Each build gets a fresh `ArenaAllocator` over `std.testing.allocator`, wrapped in a
  counting allocator that counts alloc, resize and remap calls and the bytes they grow.
- 20 builds for each language. Time is `std.Io.Timestamp.now(io, .awake)` around
  `tilla.build`.
- Machine: x86_64, 16 cores, Zig 0.17.1.

## Raw numbers

Command (Debug, the default):

    zig build test -Dtest-file=test/zz_bench_tilla.zig

    BENCH it: words=3000 lookup_keys(upper bound of sqlite steps)=3400 build_us min=218092 median=243369 max=318929 allocs=14 alloc_bytes=464305 tilla=52691 gz=16109
    BENCH pt-BR: words=3000 lookup_keys(upper bound of sqlite steps)=3400 build_us min=33750 median=35745 max=55717 allocs=14 alloc_bytes=464285 tilla=52691 gz=16101

Command (ReleaseFast, how a shipped CLI is built):

    zig build test -Dtest-file=test/zz_bench_tilla.zig -Doptimize=ReleaseFast

    BENCH it: words=3000 lookup_keys(upper bound of sqlite steps)=3400 build_us min=32533 median=35423 max=63325 allocs=14 alloc_bytes=464305 tilla=52691 gz=16109
    BENCH pt-BR: words=3000 lookup_keys(upper bound of sqlite steps)=3400 build_us min=3482 median=3537 max=3664 allocs=14 alloc_bytes=464285 tilla=52691 gz=16101

(The test runner reports "failed command" only because the bench prints to stderr. Every
build succeeded.)

## Reading

- **SQLite:** one open, one prepare, and at most 3 400 indexed point lookups (one for each
  key until a key hits) for a 3 000-word Italian translation. Translations into other
  languages make no queries. The lookups take about 32 ms in ReleaseFast (it minus
  pt-BR), about 10 µs each.
- **Allocations:** 14 for each build. 393 KB of the 464 KB is the two fixed scratch
  buffers at lines 41 and 42. The rest is the exactly sized `.tilla` and the gzip
  output. The count does not grow with story length, and the arena frees everything at
  once.
- **Total:** about 35 ms in ReleaseFast for one Italian translation of an unusually long
  story, and about 3.5 ms for every other translation. `publish` runs this once for each
  translation, next to an R2 upload and a `POST /stories` that each take a network round
  trip, so no request or user waits on this time in a way that matters.

## Verdict

No hotspot is worth changing. The feature is not on a server request path. Its one loop
over realistic data (the dict lookups) costs tens of milliseconds, once for each Italian
translation, in an authoring CLI. Its allocations are a fixed 14 per build. No paid
service is called.

## Proposals

None.
