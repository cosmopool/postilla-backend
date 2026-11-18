# cli-publish — stage 3 measurements

Base `aacef22`, head `6c29f45` (work/cli-publish). Zig 0.17.1, x86_64-linux, ReleaseFast.

## Verdict

No measurable hotspot. Nothing to optimise.

## What the flagged lines are on

- `src/cli.zig:145,146,181,192,193` and `src/outbound.zig:26,51` all run in the authoring CLI
  (`postilla publish`), once per publish of one story, on the author's machine. One arena per run.
- The server does not import `outbound.zig` or `r2.zig` (`grep -rln 'outbound.zig\|@import("r2")' src`
  gives only `src/cli.zig` and `src/r2.zig`). `src/server.zig` is not in the diff, so `GET /stories`
  (the hot path) has no changed code: nothing to measure there.
- SQLite: the only change is `tilla.build` opening `dict.db` with `db.openReadOnly` instead of
  `db.open`. The lookup statement and how often it runs are unchanged.
- Paid outside-service calls per publish: 0. `publish` calls no OpenCode and no Speechify.
  R2 calls per publish are listed below.

## Harness

`.work/cli-publish/bench/zz_bench_cli_publish.zig`: the helpers of `test/cli_publish.zig`
(real server through the harness, fake R2 that checks SigV4 and stores the objects) plus one
test. That test runs `cli.run` 3 times on the same folder. Each run gets a counting allocator
over its own arena.

Fixture, sized to a real story:
- Italian at the rule 8 limit: 46 paragraphs × 8 sentences = 368 sentences, 20 159 code
  points including the separators (under 20 000 in sentences only). Same shape for pt-BR.
  `story.json` is 49 285 bytes.
- Audio for 1 288 s (about 21 minutes): `it.opus` 5 152 000 B (32 kbit/s) and `it.flac`
  68 160 960 B (44.1 kHz mono 16-bit at 60 % of PCM). Random bytes.

Command (from the repo root; copy the file in, run it, remove it):

```
cp .work/cli-publish/bench/zz_bench_cli_publish.zig test/ && \
zig build test -Dtest-file=test/zz_bench_cli_publish.zig -Doptimize=ReleaseFast --summary none 2>&1 | grep BENCH; \
rm test/zz_bench_cli_publish.zig
```

## Raw output (feature as committed)

```
BENCH big_alloc_sizes={ 7728128, 102241568, 5152000, 68160960 }
BENCH round=0 codepoints=20159 sentences=368 audio_s=1288 opus_bytes=5152000 flac_bytes=68160960 json_bytes=49285 wall_ms=1362 alloc_calls=266 alloc_bytes=184397649 allocs_ge_1MiB=4 bytes_in_allocs_ge_1MiB=183282656 arena_capacity=182870784 r2_puts=4 r2_gets=2
BENCH big_alloc_sizes={ 7728128, 102241568, 5152000, 68160960 }
BENCH round=1 codepoints=20159 sentences=368 audio_s=1288 opus_bytes=5152000 flac_bytes=68160960 json_bytes=49285 wall_ms=1332 alloc_calls=253 alloc_bytes=184384647 allocs_ge_1MiB=4 bytes_in_allocs_ge_1MiB=183282656 arena_capacity=182870784 r2_puts=4 r2_gets=1
BENCH big_alloc_sizes={ 7728128, 102241568, 5152000, 68160960 }
BENCH round=2 codepoints=20159 sentences=368 audio_s=1288 opus_bytes=5152000 flac_bytes=68160960 json_bytes=49285 wall_ms=1156 alloc_calls=253 alloc_bytes=184384647 allocs_ge_1MiB=4 bytes_in_allocs_ge_1MiB=183282656 arena_capacity=182870784 r2_puts=4 r2_gets=1
BENCH memcpy_of_audio_bodies bytes=73312960 us=52820
```

Two earlier runs of the same command gave wall_ms 1254 / 996 / 1135 and 1278 / 1263 / 1062,
with the same allocation counts.

## A/B: the per-try body copy (`src/outbound.zig:26`, the #25 fix) taken out

The two lines were edited in place: `const copy: []u8 = @constCast(body);` and no `@memcpy`.
Then the same command was run, and `git checkout src/outbound.zig` restored the file.

```
BENCH big_alloc_sizes={ 7728128, 102241568 }
BENCH round=0 ... wall_ms=1220 alloc_calls=261 alloc_bytes=111078986 allocs_ge_1MiB=2 bytes_in_allocs_ge_1MiB=109969696 ...
BENCH round=1 ... wall_ms=1028 alloc_calls=248 alloc_bytes=111065984 allocs_ge_1MiB=2 bytes_in_allocs_ge_1MiB=109969696 ...
BENCH round=2 ... wall_ms=1132 alloc_calls=248 alloc_bytes=111065984 allocs_ge_1MiB=2 bytes_in_allocs_ge_1MiB=109969696 ...
```

## Reading

| What | Number |
|---|---|
| Wall time of one publish, loopback server and R2 | 996–1362 ms (9 runs) |
| Same, without the #25 copy | 1028–1220 ms (3 runs), within the noise above |
| Allocations per publish | 253 calls (266 on the first run, which also downloads `dict.db`) |
| Bytes allocated per publish | 184.4 MB, of which 183.3 MB in 4 allocations ≥ 1 MiB |
| Bytes the #25 copy adds | 73 312 960 B, exactly the audio bodies (+5 calls) |
| Time of that copy (one memcpy of both audio bodies) | 34–53 ms |
| Audio reads (`cli.zig:181`, `readFileAlloc(.unlimited)`) | 7 728 128 + 102 241 568 B for 5.2 + 68.2 MB files: 1.5× the size, from list growth. The unused half is never written, so these pages are never made resident. |
| R2 requests per publish | 4 PUT (2 `.tilla.gz` + opus + flac) + 1 GET `dict/latest` (+1 GET `dict.db.gz` on the first run only) |
| Server requests per publish | 4 list GETs + 1 `POST /stories`; no `GET /stories` |
| Paid calls (OpenCode, Speechify) per publish | 0 |

The copy that the #25 fix adds is about 4 % of a loopback publish and inside its run-to-run
noise. Against a real upload it is smaller still: at 20 Mbit/s, 73 MB of audio takes about
29 s, so 50 ms is under 0.2 %. It costs about 73 MB of memory on the author's machine, once
per publish, and the process then exits. A user only waits on the upload, and the network
sets its speed. Nothing on the learner app's path changed, so no optimisation is proposed.
