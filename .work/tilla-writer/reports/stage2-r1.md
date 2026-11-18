# Stage 2, round 1: tilla-writer

Base ref: f2367df566fc9e667c24616ce74e0f89021bb2ac. Requirement: `.work/tilla-writer/requirement.md`.

Round 1 hunted the whole feature diff and found one bug, from the input lens. The refuter could not refute it. It was reproduced through the public entry point `tilla.build`, and the base check marks it as caused by this feature. It is critical, so the decision is **fix**.

## Finding 1: counts over 65 535 crash the build instead of being refused

- **Lens:** input
- **Location:** `src/tilla.zig:113` (also `:125` and `:128`)
- **Defect:** the first pass (lines 39 and 69-101) only checks for empty values, sentence length and total words. It never checks `in.tags.len`, `in.paragraphs.len` or the per-paragraph `p.len`. The second pass then narrows each count with `@intCast` into `u16`. In Debug and ReleaseSafe builds this panics with "integer does not fit in destination type", and `postilla publish` aborts. In ReleaseFast it is undefined behaviour: in practice the count is truncated, the file breaks reader rule 2, and the app rejects the file. The 65 535-word cap does not catch these inputs, because sentences such as "." or "—" contain no words.
- **Contradicts:** the requirement says input errors are refusals, raised as errors before any byte is written, and that every reader rule (1-8) holds for every file written. `docs/tilla.md` says the writer makes rules 2, 5, 6 and 8 hold by construction.
- **Refutation:** the bug survived. The code path is exactly as described, and `build.zig` uses `standardOptimizeOption`, so the CLI can be built in any mode. No existing test covers it: `test/tilla.zig` uses only two tags and one 65 536-byte sentence.
- **Rating:** chance is **rare**. Drafts from the authoring app never look like this, but a hand-edited or generated `story.json` passed to `postilla publish` can, so the path is reachable by a real user and is not test-only. Criticality is **critical**, because the result is a crash. The failure is not silent: the panic is visible in safe builds.
- **Reproduction:** **reproduced**. `test/tilla-writer_repro_r1_1.zig` has two tests that call `tilla.build` with an otherwise valid pt-BR input. No dict.db is opened and nothing is mocked. One test passes 65 536 tags and the other passes one paragraph of 65 536 "—" sentences. Both expect an error. Both crash with SIGABRT: the first at `src/tilla.zig:113:16` and the second at `src/tilla.zig:128:20`. The result was 0/2 passed, 2 crashed.
- **Base check:** **feature**. On the base the reproduction does not compile (`error: no module named 'tilla' available within module 'root'`, see `reports/base-check/tilla-writer_repro_r1_1.zig.log`), because the tilla module comes with this feature.
- **Decision:** **fix**. Fix cost is about 2 lines. In the first pass, return an error such as `error.TooMany` when `in.tags.len > 65535` or `in.paragraphs.len > 65535` (extend line 39). Add a `p.len > 65535` check next to the existing `p.len == 0` check (line 70). Then add the limit to the refusal list in `docs/tilla.md`. The reproduction test is restored when the fix is applied.

## Summary table

| # | Finding | Lens | Survived refutation | Chance | Criticality | Silent | Reproduction | Base check | Decision |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Counts over 65 535 (tags, paragraphs, sentences per paragraph) panic in `@intCast` instead of being refused (`src/tilla.zig:113/125/128`) | input | yes: the first pass has no count checks, and the word cap misses zero-word sentences | rare | critical | no | reproduced (2/2 crash, `test/tilla-writer_repro_r1_1.zig`) | feature (does not compile on base) | fix (~2 lines) |

No pre-existing bugs were found, so this round has no follow-ups.
