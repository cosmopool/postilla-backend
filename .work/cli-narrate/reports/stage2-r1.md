# Stage 2, round 1: cli-narrate

Base ref: `2be599996f7a0a49b9be79f0e591827ca388a745`. Round 1 produced one finding. It survived refutation, was reproduced, and was caused by the feature. The fix matrix (`rare` × `critical`) says **fix**.

## Summary

| # | Title | Lens | Refuted | Chance | Criticality | Silent | Repro | Base check | Decision |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Out-of-range Speechify mark time panics in `@intFromFloat` | input | no | rare | critical | no | reproduced (`test/cli-narrate_repro_r1_1.zig`, SIGABRT) | feature | fix |

## Finding 1: a Speechify word mark time outside u32 crashes narrate

`src/cli.zig:311`. Lens: input (outside-service responses are untrusted, from the Agent 3 mr-review rule and `AGENTS.md:20`).

**Problem.** The `speech.chunk` event struct parses `start_time` and `end_time` as plain `f64` (line 304), and nothing checks their range. Line 311 then casts them with `@as(u32, @intFromFloat(...))`. If Speechify, or the fake at `POSTILLA_SPEECHIFY_URL`, sends a value of -1 or less, or 2^32 or more, the cast is illegal behaviour. In Debug and ReleaseSafe it panics and exits with 134. In ReleaseFast it is undefined behaviour. The run never reaches the `continue :tries` bad-stream path or the `<lang>: narration: <reason>` message. The clamp to `audio_ms` at lines 320-322 runs after the cast, so it comes too late to help.

**Refutation.** The finding was not refuted. The code matches the claim. The `start: usize` field already rejects negative offsets, but the two time fields have no check. The fake in `test/cli_narrate.zig:443-445` only sends small non-negative times, so no existing test covers this case.

**Rating.** The chance is **rare**. Real Speechify sends non-negative millisecond offsets, and a time of 2^32 ms or more would mean a stream about 49 days long. Small negatives such as -0.5 truncate to 0 and still fit. So it takes a malformed or buggy response to trigger it. The criticality is **critical** because the process crashes. It is **not silent**, because the process aborts with exit 134.

**Reproduction: reproduced.** `test/cli-narrate_repro_r1_1.zig` runs the real `cli.run` with `postilla narrate <folder>`. The lists come from the real harness server, and Speechify is a fake, which is the only mock and sits at the outside-service boundary. On every call the fake answers 200 with one `speech.chunk` containing 100 ms of silent PCM and one mark with `"start_time": -1`, then sends `speech.done`. The test expects exit 1 naming `it: narration`, 3 tries, and no `it.opus` or `it.flac`. Running `zig build test -Dtest-file=test/cli-narrate_repro_r1_1.zig` instead crashed the test binary (`terminated with signal ABRT`, 0 pass, 1 crash) with `panic: integer part of floating point value out of bounds` at `src/cli.zig:311:62`. No production code was changed.

**Base check: feature.** The narrate implementation does not exist on the base ref. There `src/cli.zig` mentions `narrate` only in the help text and in "run narrate" error hints, and it has no `@intFromFloat`. The bug comes from this branch's code. One caveat: the base-check run log (`.work/cli-narrate/reports/base-check/cli-narrate_repro_r1_1.zig.log`) did not run the test at all. It shows a build-infrastructure failure: LLD reported `No file descriptors available` while linking the vendored `codecs` lib. So the verdict rests on the code being absent from the base, not on a test result from the base.

**Decision: fix.** The matrix gives `rare` × `critical` = fix, and the change is about one line. Options:

- Replace each cast with a saturating `std.math.lossyCast(u32, m.start_time)`, and the same for `end_time`. This also handles NaN, and the existing `audio_ms` clamp then bounds the result.
- Add a range check before line 311 that sets a reason and runs `continue :tries`, for example `reason = "a mark's time is out of range"`, so the bad stream gets the documented retry and failure message.

The second option matches the expected behaviour in the repro test (exit 1, `it: narration`, 3 tries). Once the fix is in, the repro test should pass, and it stays as the regression test.

## Pre-existing bugs (follow-up)

None this round.
