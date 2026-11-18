# Stage 2, round 1: cli-translate

Base ref: `d0857375c2d1fd111aa77fe910891d5043fed9aa`.

Three findings came out of the hunt. All three survived refutation, all three were
reproduced with a failing test, and the base check says the feature caused all three.
All three are fixed.

## Findings

**1. translate writes empty DeepSeek sentences that its own rules then reject** (`src/cli.zig:245`, correctness lens).
The try loop checks only `got.len == sentences.len`. A reply like `["O trem", ""]` is
accepted and written into story.json. After that, the shared rule checks fail and every
later `publish`, `translate` and `translate --redo pt-BR` exits 1. The finding survived
refutation because nothing between the reply and the write rejects empty strings.
Rated rare and major. The error is not silent, because later commands fail loudly.
Reproduced by `test/cli-translate_repro_r1_1.zig`.

**2. A reply with an empty sentence is written and then blocks every command, --redo included** (`src/cli.zig:245`, input lens).
This is the same root cause as finding 1, found by a different lens. It stresses that
`--redo` cannot repair the story, because the shared checks stop the command before it
runs. It survived refutation for the same reason as finding 1. Rated rare and major, and
marked silent, because the first run exits 0. Reproduced by
`test/cli-translate_repro_r1_2.zig`. The fix for finding 1 covers it too.

**3. A NaN P(none) from Jev passes moderation** (`src/cli.zig:217`, input lens).
std.json parses the string `"nan"` into an f64 NaN. `scores[0] < threshold` is false for
NaN, so text that never passed moderation goes on to translation. It survived refutation
because `moderate` accepts the string token and nothing checks for NaN. Rated rare and
major, and silent. Reproduced by `test/cli-translate_repro_r1_3.zig`.

## Base check

On the base, every reproduction stops at the usage error (exit 2), because the base has
no `translate` command. The tests fail there only because the command is missing, so
the verdict is that the feature caused all three. Logs are in `reports/base-check/`.

## Table

| # | Finding | Lens | Survived refutation | Chance | Criticality | Silent | Fix lines | Reproduction | Base check | Decision |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Empty DeepSeek sentence accepted and written | correctness | yes: only the length is checked | rare | major | no | 2 | reproduced (`test/cli-translate_repro_r1_1.zig`) | feature | fix |
| 2 | Empty sentence written, then blocks every command, --redo included | input | yes: same root cause as #1 | rare | major | yes | 2 (shared with #1) | reproduced (`test/cli-translate_repro_r1_2.zig`) | feature | fix |
| 3 | NaN P(none) passes moderation | input | yes: NaN fails `<` | rare | major | yes | 1 | reproduced (`test/cli-translate_repro_r1_3.zig`) | feature | fix |

## Fixes

- Findings 1 and 2: label the try loop `tries:`, set `reason = "empty sentence"`, and add
  `for (got) |s| if (s.len == 0) continue :tries;` before `break got`. An empty string
  then counts as a failed try, the same as a wrong length.
- Finding 3: fail closed with `const rejected = !(scores[0] >= threshold);`.

There are no pre-existing bugs and no follow-ups from this round.
