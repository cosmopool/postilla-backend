# Stage 1 — cli-translate

Base ref: d0857375c2d1fd111aa77fe910891d5043fed9aa. API: settled.

## AC-to-test map

Output of `scripts/pipeline/ac-map.sh --slug cli-translate`. Every AC has a test, with no uncovered or unknown IDs, and all of them are in test/cli_translate.zig.

| AC | Test (test/cli_translate.zig) |
|---|---|
| AC-1 | :482 AC-1, AC-2, AC-3: a story with only the Italian is moderated by Jev and translated |
| AC-2 | :482 (same test) |
| AC-3 | :482, and :569 a story whose translations already has pt-BR, written by hand, exits 0 |
| AC-4 | :583 AC-4, AC-5: a text Jev flags is rejected, printing the six scores and the top one |
| AC-5 | :583, and :613 AC-6, AC-5 |
| AC-6 | :613 POSTILLA_MODERATION_THRESHOLD lowers the bar so P(none) 0.5 passes |
| AC-7 | :641 --redo pt-BR replaces a hand-edited pt-BR with DeepSeek's translation |
| AC-8 | :668 a paragraph whose reply has the wrong sentence count, isn't JSON or is fenced |
| AC-9 | :710 a story.json that breaks a rule exits 1 naming it and sends no OpenCode request |
| AC-10 | :733 no folder, an unknown flag, a repeated flag or --redo without a language |
| AC-F1 | :757 Jev answering 503 on every try stops the command after 4 tries |
| AC-F2 | :773 DeepSeek answering 401 stops the command after one request |
| AC-F3 | :790 a Jev reply that isn't the expected JSON stops the command naming moderation |
| AC-F4 | :814 a POSTILLA_MODERATION_THRESHOLD that isn't a number from 0 to 1 |
| AC-F5 | :842 a story folder where story.json can't be replaced exits 1 naming story.json |

## Candidates

Lines added by each candidate: 148, 134 and 135.

## Winner: candidate 2 (134 added lines)

The steps that publish and translate share (cli.env, the required variables, reading story.json, rules 1-8 and the four lists) are now in one `command` function in src/cli.zig. After them, an `if (translate)` block runs the moderation, the DeepSeek loop with 3 tries per paragraph, and the story.json write (a temp file, then a rename). The only new public symbol is `pub fn moderate`.

## Minimality review

Accepted on minimality in round 1. The reviewer found no violations.

**Budget:** `budget.sh --base d0857375c2d1fd111aa77fe910891d5043fed9aa --max-added 300 --max-new-files 2 --max-new-symbols 1` exited 0 with:

```
{"added": 134, "removed": 8, "new_files": 0, "new_public_symbols": 1, "exceeded": [], "within_budget": true}
```

**What the diff changes:** src/cli.zig, plus two small files the manifest approves, `cli.env.example` and `docs/specification.md`.

**Why nothing was flagged:**
- **No duplication.** UUIDs come from `wire.StoryId` (src/wire.zig:10). HTTP calls go through `outbound.request`. The story struct's existing `moderation` and `translations` fields are reused. The reviewer looked for an existing CEFR-level table and for a temp-file-and-rename helper and found neither.
- **The shared checks were moved, not copied.** `publish` was renamed to `command` and given a `translate` flag, so the shared start is written once. This is smaller than splitting it out into a separate function.
- **No new types or extra layers.** The only new public symbol is `cli.moderate`, which the manifest approves. No parameter or branch goes beyond the ACs.
- **story.json is written the zero-code way.** It uses `std.json` with `.indent_2`, as the owner decided ("aesthetics only"), instead of a custom writer.

## Flagged but not fixed

The reviewer fixed nothing and left no minimality finding open. One gap is outside the review's scope: two manifest items are missing from the diff, the `test-moderation` step in `build.zig` and `test/live/moderation.zig`. Until they exist, `pub fn moderate` has no caller outside `cli.zig`. This is unfinished manifest work, not extra code, and it has to be done before the feature is complete.
