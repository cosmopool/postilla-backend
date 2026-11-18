# Stage 2, round 1: server-write

Base ref: `c32b62c41cae86e171e2d6315951797f9e4e596b`. Requirement: `.work/server-write/requirement.md`.

One finding came out of the hunt. It survived refutation, was reproduced through the running server, and the feature caused it. The decision is **fix**.

## Findings

| # | Lens | Finding | AC | Survived refutation | Chance | Criticality | Silent | Fix size | Reproduction | Base check | Decision |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | correctness | A body with lang_count 0 gets the reason `lang: no 'it'` where the spec says `body: wrong length` (`src/server.zig:270`) | AC-6 | yes | rare | major | no | 1 line | reproduced (`test/server-write_repro_r1_1.zig`) | feature (base answers 404) | fix |

## 1. lang_count 0 gets the wrong rejection reason

**Lens:** correctness. **File:** `src/server.zig:270`. **AC:** AC-6.

**Finding.** A valid-token `POST /stories` with a 22-byte body (`"STRY\x01"` + 16 id bytes + `"\x00"`) passes the length check on line 270, because `22 == 22 + 40*0` and nothing checks `body[21] == 0`. The lang loop runs zero times, and line 282 answers 400 `lang: no 'it'\n`. `docs/specification.md:209-213`, changed in this diff, says the parse rules are "checked in this order". It puts "lang_count is at least 1" under rule 2 (`body: wrong length`), ahead of rule 4 (`lang: no 'it'`). AGENTS.md:39 says the code and the spec must agree.

**Refutation.** It survived. The defect is real. Nothing upstream catches it: `wire.Reader.header` checks only the magic, the version and the minimum header length. The existing test at `test/server_write.zig:258-264` accepts either reason, so it never pins the order AC-6 requires ("the matching reason").

**Rating.** Chance is **rare**. A real client such as the postilla CLI would seldom send lang_count 0, but it can. Criticality is **major**. The status is still 400 and nothing is written, so no data is harmed. Still, AC-6 is broken and the client gets the wrong reason. The failure is not silent. The fix is about 1 added line.

**Reproduction.** Reproduced through HTTP against the running server with `zig build test -Dtest-file=test/server-write_repro_r1_1.zig`. The test fails on the body check: it expected `body: wrong length\n` and got `lang: no 'it'\n`. Production code was not changed.

**Base check.** The verdict is **feature**. On the base, the reproduction fails with `expected 400, found 404` (`.work/server-write/reports/base-check/server-write_repro_r1_1.zig.log`). The base has no `POST /stories` endpoint, so the failure there comes from the missing route, not from this defect. The bug did not exist before this feature.

**Decision.** **fix**, because `workflow.fix_matrix` gives rare × major as `fix-small`, and the 1-line estimate is within `small_fix_lines` (5). On line 270, add `or body[21] == 0` to the condition. Then make `test/server_write.zig:264` expect exactly `body: wrong length\n`, and restore the reproduction when the fix lands.

## Follow-ups (pre-existing bugs)

None.
