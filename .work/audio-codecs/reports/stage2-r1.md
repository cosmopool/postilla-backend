# Stage 2, round 1: audio-codecs

Base ref: `ed77e3cf559f507ef5398535638935ab4396c441`. One finding came out of this round. It survived refutation and was reproduced. The feature caused it. It is minor and test-only, so it is reported and not fixed. No critical bug was found this round.

## Finding 1: the rate check lets through rates libFLAC rejects (input lens)

`src/audio.zig:14` only checks `rate < 8000 or rate > 96000`. libopusenc takes any rate above 0, so the full Opus encode runs first. Then `FLAC__stream_encoder_init_stream` returns `NOT_STREAMABLE` for any rate of 65536 or more that is not divisible by 10, because `streamable_subset` is on by default (stream_encoder.c:2625, format.c:228-236, stream_encoder.c:799-803) and `src/audio.zig` never turns it off. The caller gets `error.FlacEncode` instead of `error.UnsupportedRate`. The requirement's assumption says out-of-range rates should be rejected before any C call, so this goes against it.

**Refutation:** survived. The code reading is correct, and the tests (`test/audio.zig:359-360`) only try 0 and 200000. It is rated **test-only**: nothing calls this in production yet, narrate (the next slice) passes 48000, and Speechify only uses standard rates. It is rated **minor** and **not silent**: the call still fails, just with the wrong error variant, narrate maps both variants to the same error line, nothing is corrupted, and the wasted Opus work is local CPU, not a repeated paid call.

**Reproduction:** reproduced in `test/audio-codecs_repro_r1_1.zig`, which calls `audio.encode` on 1 s of 16-bit mono PCM at 88201 Hz. It uses the real vendored libopusenc and libFLAC with no mocks. It fails with "expected error.UnsupportedRate, found error.FlacEncode", raised from the FLAC chain at `src/audio.zig:45`. Production code is unchanged.

**Base check:** the feature caused it. On the base the reproduction does not compile (`no module named 'audio' available within module 'root'`, see `reports/base-check/audio-codecs_repro_r1_1.zig.log`), because the audio module does not exist there.

**Decision:** report. Under `workflow.fix_matrix`, a feature-caused, test-only, minor finding is reported without changing code. If someone fixes it later, it is one line: `or (rate >= 65536 and rate % 10 != 0)` added to the guard at line 14.

## Summary table

| # | Finding | Lens | Survived refutation | Chance | Criticality | Silent | Repro | Base check | Decision |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Rate check at `src/audio.zig:14` lets through rates libFLAC refuses (for example 88201), so they return `error.FlacEncode` after a full Opus encode | input | yes: the code reading and the vendored libFLAC behaviour are both confirmed | test-only | minor | no | reproduced (`test/audio-codecs_repro_r1_1.zig`) | feature (does not compile on base) | report |
