# Stage 2, round 2: cli-narrate

Base ref: `2be599996f7a0a49b9be79f0e591827ca388a745`. Round 2 produced one finding. It survived refutation, but it is a documentation gap that no test can reproduce, so it is marked untestable. Untestable findings are fixed only when critical. This one is `rare` × `minor`, so the decision is **report**. No new critical bug turned up this round.

## Summary

| # | Title | Lens | Refuted | Chance | Criticality | Silent | Est. lines | Repro | Base check | Decision |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | New bad-stream condition (mark time outside u32 ms) is not in the spec's bad-stream list | correctness | no | rare | minor | no | 1 | untestable (no test file) | feature | report |

## Finding 1: the spec's bad-stream list leaves out the out-of-range mark time

`src/cli.zig:313`, `docs/specification.md:412`. Lens: correctness (docs must change in the same change, `AGENTS.md:33-34`).

**Problem.** The round-1 fix (`a7f1278`) added a new bad-stream case at `src/cli.zig:312-313`. A word mark whose `start_time` or `end_time` is negative, or at least 2^32 ms, now starts the next try. After 3 tries narrate exits 1 with `<lang>: narration: a mark's time is out of range`. The comment at `src/cli.zig:290-291` was updated in that commit, but `docs/specification.md` was not. Line 412 there still lists only `speech.error`, a missing `speech.done`, bad base64, an odd byte count and non-JSON events. So the documented contract no longer matches the retry behaviour, the exit behaviour or the reason the operator sees.

**Refutation: survived.** The code matches the claim. The commit touched only `src/cli.zig` and the repro test. Nothing else in the spec covers mark-time ranges: line 407 says only "start_time and end_time in ms". Nothing upstream stops the code path either, because the JSON parse reads both fields as `f64` with no range check.

**Rating.** The chance is **rare**. Speechify would have to send a negative time or one of 49 days or more, while input is capped at 20,000 characters, which is roughly tens of minutes of speech. The criticality is **minor**: this is a doc/code mismatch. The failure is **not silent**, because the command exits 1 with a clear reason. The 3 billed tries are the same documented bad-stream behaviour that applies to every other bad stream, so they are not a new repeated paid call.

**Reproduction: untestable.** The runtime behaviour can be reached (a fake that sends a mark with `start_time: -1` gets 3 tries and exit 1). But that is the intended result of the round-1 fix, and the round-1 repro (`test/cli-narrate_repro_r1_1.zig`) already checks it as correct. The defect is in the spec text, and no test reads that text. Any test that followed the spec's literal list would contradict the round-1 fix and would still fail after the right fix. No test file was written and no production code was changed.

**Base check: feature.** Narrate and its bad-stream handling do not exist on the base ref, so the gap comes from this branch. No base-check run applies, because there is no repro test.

**Decision: report.** Untestable findings are fixed only in the critical column (RULES.md, "Fix-or-report table"), and this one is minor. The suggested one-line fix, for whoever picks it up: in `docs/specification.md:412`, add "or has a word mark whose `start_time` or `end_time` is negative or not below 2^32 ms" to the bad-stream sentence, and change the matching line in `.work/cli-narrate/requirement.md:55` the same way.

## Pre-existing bugs (follow-up)

None this round.
