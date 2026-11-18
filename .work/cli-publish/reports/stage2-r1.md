# cli-publish — stage 2, round 1

Base ref: `aacef22ecee1528252e039b27342be19877fcdc7`. Three findings came out of the hunt. All three survived refutation and were reproduced with a failing test. The feature caused all three, and all three will be fixed.

## Findings

1. **An empty POSTILLA_R2_ENDPOINT crashes the CLI instead of using the default.** Lens: correctness. AC-8. `src/cli.zig:68`
   - **Why it survived refutation:** `env.get` returns `""`, not null, so the `orelse` default is skipped. Then `src/r2.zig:84` unwraps `std.mem.find(..., "://").?` on that empty string and panics. `docs/specification.md:509` says "An empty value counts as missing", so the code breaks the documented rule. `POSTILLA_DICT_DIR=` (line 186) has the same gap and ends in `dict: FileNotFound` instead of using `./dict`.
   - **Rating:** rare, critical (crash). It is not silent.
   - **Reproduction:** reproduced in `test/cli-publish_repro_r1_1.zig`.
   - **Base check:** the test does not compile on the base, because the publish command did not exist there. The feature caused it.
   - **Decision:** fix, about 3 lines. Treat an empty value as unset for both variables.

2. **The first publish fails with `dict: FileNotFound` when the dict cache directory does not exist.** Lens: correctness. AC-9. `src/cli.zig:186`
   - **Why it survived refutation:** git cannot track an empty `./dict`, so a fresh checkout does not have it. `r2.dict` opens the directory at `src/r2.zig:45` without creating it. The AC-9 test hid this because it creates `dict` first (`test/cli_publish.zig:192`). `r2.dict` already existed before this feature, but this diff adds its first caller.
   - **Rating:** common, major (AC-9 broken on the normal path).
   - **Reproduction:** reproduced in `test/cli-publish_repro_r1_2.zig`.
   - **Base check:** the test does not compile on the base. The feature caused it.
   - **Decision:** fix, about 1 line. Call `createDirPath` before `client.dict`, and remove the directory setup from the AC-9 test.

3. **An empty or scheme-less POSTILLA_R2_ENDPOINT crashes publish instead of failing with a message.** Lens: input. `src/cli.zig:68`
   - **Why it survived refutation:** this has the same root cause as finding 1 and also covers a value with no `://`, such as `acct.r2.cloudflarestorage.com`. Before the diff the endpoint was always built with a scheme, so the unwrap could not be reached. The new variable makes it reachable.
   - **Rating:** rare, critical (panic in Debug and ReleaseSafe, undefined behaviour in ReleaseFast).
   - **Reproduction:** reproduced in `test/cli-publish_repro_r1_3.zig`.
   - **Base check:** the test does not compile on the base. The feature caused it.
   - **Decision:** fix, about 3 lines. Shares a fix with finding 1, and also rejects a value without `://` with `POSTILLA_R2_ENDPOINT: not a URL` before the first R2 call.

The base-check logs are in `.work/cli-publish/reports/base-check/`. Each ends with `compile test debug native 1 errors`. Under RULES.md, a test that does not compile on the base counts as caused by the feature.

There are no follow-ups for bugs that already existed before this feature.

## Table

| # | Finding | Lens | AC | Survived refutation | Chance | Criticality | Reproduction | Base check | Decision |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Empty POSTILLA_R2_ENDPOINT / POSTILLA_DICT_DIR not treated as missing | correctness | AC-8 | yes, the spec says an empty value counts as missing | rare | critical | reproduced (`repro_r1_1`) | feature (no compile on base) | fix (~3 lines) |
| 2 | The missing `./dict` directory is never created | correctness | AC-9 | yes, the test setup hid it | common | major | reproduced (`repro_r1_2`) | feature (no compile on base) | fix (~1 line) |
| 3 | Empty or scheme-less endpoint panics in `r2.call` | input | none | yes, the new variable makes the unwrap reachable | rare | critical | reproduced (`repro_r1_3`) | feature (no compile on base) | fix (~3 lines, shared with #1) |

Two critical findings were confirmed in this round, so the loop goes on to another round after the fixes.
