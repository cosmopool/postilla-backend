# `postilla translate` (cli-translate)

## Summary

The second CLI command. `postilla translate <folder> [--force] [--redo <lang>]` checks
`story.json` with the same rules as `publish`. It reads the server's lists, finds every
language with `translate` 1 that `translations` lacks (after dropping the `--redo` language),
and when there is something to translate it moderates the Italian with Jev and writes the
scores to `moderation`. A rejected text stops the command unless `--force` is given. It then
translates each missing language with DeepSeek, paragraph by paragraph (title and subtitle
first), and writes each finished language into `story.json`. It also adds an on-demand
`zig build test-moderation` that sends a fixed Italian test set to the real Jev.

## Specified

- Command: "`postilla translate <folder> [--force] [--redo <lang>]` moderate the Italian,
  translate the missing languages"; failure prints one line naming the step and reason and
  exits 1; usage errors exit 2; `story.json` is left as it was before the failed step.
- Rules 1–8 for `story.json`: "Every command checks `story.json` before it does anything".
- "Translates the story into every language with `translate` 1 (today only `pt-BR`) that
  `translations` lacks. A rerun never overwrites a translation already there … `--redo <lang>`
  first drops that language, which must be one with `translate` 1 … When there is nothing to
  translate, the command does nothing, not even moderation."
- Moderation: "The Italian text (title, subtitle and sentences) goes to Jev (`jev-1.13`,
  OpenCode key) in `state`, with one `choice` question. Its options are `none`, `homophobic`,
  `racist`, `sexist`, `religious` and `other_hate`"; "rejected when `P(none)` is below the
  threshold: env `POSTILLA_MODERATION_THRESHOLD`, default `0.9`"; "The scores are written to
  `moderation` either way. On a rejection the command prints the six scores and the option with
  the highest probability … and exits non-zero without translating"; "`--force` … moderates
  again, writes the scores with `forced` true, and translates anyway".
- Test set: "A fixed test set of Italian texts, both clean and hateful, runs through Jev before
  this step is trusted, and stays as a regression check"; "it calls Jev for real and runs only
  on demand".
- Translation: DeepSeek `deepseek-v4.1-flash`, `temperature` 0.3, the system message and its
  `{language}`/`{level}` substitutions, the prompt-name table (`pt-BR` → `Brazilian
  Portuguese`), the user message `{"title", "previous", "sentences"}`, `previous` `[]` for the
  title paragraph and the first story paragraph; title and subtitle sent first "as one extra
  two-sentence paragraph"; "A language is written into `story.json` only once all of it is
  done … the error names the language that failed (`pt-BR: paragraph 4: wrong sentence
  count`)"; "A reply that isn't a JSON array of strings, or has the wrong number of sentences,
  counts as a failed try".
- Owner (2026-11-18): Jev at `/inference/systemone/v1/systemone`; DeepSeek through OpenCode
  Go at `/inference/go/v1/chat/completions`, which needs `user-agent` and `x-opencode-session`.

## Decided

- **Criteria texts (owner, 2026-11-18):** the question is named `hate`, `instructions` "Does
  this Italian text contain hate speech? Pick the kind, or none.", and the criteria are the
  fixture request's (`.work/fixtures/jev_request.json`), fixed in code and written into the
  spec. Rejected: writing new texts.
- **Base URL (owner):** new optional `POSTILLA_OPENCODE_URL`, default
  `https://opencode.ai/inference`; the CLI appends `/systemone/v1/systemone` and
  `/go/v1/chat/completions`. A value without `://` stops the command naming the variable, as
  `POSTILLA_R2_ENDPOINT` does. Rejected: one variable per service.
- **Writing `story.json` (owner: "aesthetics only"):** `std.json` with `.indent_2`, the
  zero-code option. Field order as parsed; a hand layout is reformatted on the first write.
  Rejected: a custom compact writer (~30 lines).
- **On-demand test set (owner):** `test/live/moderation.zig`, outside `test/*.zig` so
  `zig build test` never runs it, run by a new `zig build test-moderation` step. It reads
  `POSTILLA_OPENCODE_KEY` from the environment or `cli.env` and calls the real Jev through
  `cli.moderate`: 4 clean Italian texts must pass the 0.9 threshold, and 5 clearly hateful
  ones (one per non-`none` option) must be rejected. Rejected: running it through `cli.run`
  (clean texts would go on to spend DeepSeek calls).
- **Tries for a bad reply** (spec conflict, code-map #2): a paragraph gets 3 tries. Each is
  one full `outbound.request` (with its own network retries), and a reply that isn't a JSON
  array of strings of the right length starts the next try at once. After the third the
  command stops with `<lang>: paragraph <n>: <reason>` (n from 1, the title paragraph is 0).
  The spec wording is fixed to say so. Rejected: folding content checks into
  `outbound.request`.
- **Go headers:** `user-agent: postilla/1.0` on every OpenCode request, and
  `x-opencode-session` with one random UUID per command run on every DeepSeek request.
- **Shared checks:** `cli.env` loading, the required variables, reading and parsing
  `story.json`, rules 1–8 and fetching the four lists move out of `publish` into one
  function both commands call. Behaviour of `publish` doesn't change (its tests stay green).

## Assumed

- **Every command requires all 8 required variables**, as publish does today (the table marks
  them required without naming commands). Blast radius: someone who only translates still
  needs R2 and Speechify keys in `cli.env`. Confirm: owner.
- **When `story.json` is written:** once after moderation (the scores, including on a
  rejection), then once after each finished language. Writes go to `story.json.tmp` and are
  renamed over `story.json`, so a crash never leaves half a file. Blast radius: none for a
  rerun, which moderates again anyway. Confirm: owner.
- **`forced`** is true only when the text was rejected and `--force` let it through; a
  text that passes writes `forced` false, with or without `--force`.
- **Jev's `state`** is the title, the subtitle, then each paragraph's sentences joined by one
  space, each on its own line (the narrate text with title and subtitle in front).
- **A threshold that isn't a number from 0 to 1** stops the command naming
  `POSTILLA_MODERATION_THRESHOLD`, before any request.
- **A `translate` 1 language without a prompt name** stops the command (`<lang>: no prompt
  name`) before moderation.
- **`--redo <lang>` naming a language without `translate` 1** (including `it` and unknown ids)
  exits 1 before any OpenCode request; an unknown flag, a repeated flag or `--redo` without a
  value is a usage error (exit 2).
- **A Jev answer** without the `hate` answer or any of the six probabilities, and a DeepSeek
  answer without `choices[0].message.content`, count as a bad reply: for Jev the command stops
  (`moderation: bad reply`), for DeepSeek it is a failed try.
- **A reply wrapped in code fences** is a bad reply (no fence stripping); the system prompt
  forbids them.
- **The translated language is added after the existing ones** in `translations`; with
  `--redo` it goes back at the end too.

## Non-goals

- `postilla narrate`, Speechify, audio, and the `daniele-agent` voice.
- Moderating the translation, or any other language than the Italian.
- A JSON mode, response_format or tool calling for DeepSeek; streaming replies.
- Parallel translation of paragraphs or languages.
- Changing `publish`'s checks or output.
- Running the live test set in `zig build test` or in the pipeline; a CI hook for it.
- Keeping a hand-made `story.json` layout, key order beyond what parsing preserves, or
  comments.
- Cost tracking, token counting, or printing `usage`.
- A per-command required-variable list.

## Acceptance criteria

AC-1: Given a valid story with only `it` and the server listing `pt-BR` with `translate` 1,
when `postilla translate <folder>` runs against a fake OpenCode whose Jev answers `none`
0.98 and whose DeepSeek answers each paragraph with the right number of sentences, then it
exits 0. `story.json` then holds `moderation` with the six scores and `forced` false, plus a
`pt-BR` translation whose `title`, `subtitle` and `paragraphs` are DeepSeek's replies in
reading order.

AC-2: Given AC-1's run, then the Jev request is `POST <base>/systemone/v1/systemone` with
`Authorization: Bearer <key>`, `model` `jev-1.13`, `state` as the Italian text, and one
`choice` question `hate` with the six criteria. Each DeepSeek request is `POST
<base>/go/v1/chat/completions` with `model` `deepseek-v4.1-flash`, `temperature` 0.3, the
system message with `Brazilian Portuguese` and the story's CEFR level, and the user message
`{"title", "previous", "sentences"}`: the title paragraph first with `previous` `[]`, then each
paragraph with the previous Italian paragraph (`[]` for the first). Every OpenCode request
carries `user-agent: postilla/1.0`, and every DeepSeek request in the run carries the same
non-empty `x-opencode-session`.

AC-3: Given a story whose `translations` already has `pt-BR`, when `translate` runs, then it
exits 0, sends no request to OpenCode, and `story.json` is byte for byte unchanged.

AC-4: Given Jev answers `none` 0.5 (`racist` 0.4 highest of the rest), when `translate` runs,
then it exits 1, prints the six scores and `racist`, sends no DeepSeek request, and
`story.json` holds the scores with `forced` false and no `pt-BR`.

AC-5: Given AC-4's answer, when `translate --force` runs, then it exits 0, `moderation.forced`
is true, and `pt-BR` is written.

AC-6: Given `POSTILLA_MODERATION_THRESHOLD=0.4` and Jev answering `none` 0.5, when
`translate` runs, then it passes moderation and translates.

AC-7: Given a story with a hand-edited `pt-BR`, when `translate --redo pt-BR` runs, then
`pt-BR` is replaced by DeepSeek's translation. Given `--redo it` or `--redo xx`, it exits 1
and sends no OpenCode request.

AC-8: Given DeepSeek answers one paragraph first with the wrong sentence count, then
correctly, when `translate` runs, then it exits 0 with the correct reply written. Given it
answers paragraph 2 wrongly three times, then it exits 1 naming `pt-BR: paragraph 2`, and
`story.json` holds the moderation scores and no `pt-BR`.

AC-9: Given a `story.json` that breaks a rule (genre empty), when `translate` runs, then it
exits 1 naming the rule and sends no OpenCode request.

AC-10: Given wrong arguments (no folder, an unknown flag, `--redo` without a language), when
`translate` runs, then it exits 2 and prints the usage.

AC-F1: Given Jev answers 503 with `Retry-After: 0` on every try, when `translate` runs, then
it exits 1 after 4 tries naming `moderation` and the status, and `story.json` is unchanged.

AC-F2: Given DeepSeek answers 401, when `translate` runs, then it exits 1 after one DeepSeek
request naming `pt-BR` and the status, and `story.json` holds the moderation scores and no
`pt-BR`.

AC-F3: Given Jev's reply isn't the expected JSON, when `translate` runs, then it exits 1
naming `moderation`, and `story.json` is unchanged.

AC-F4: Given `POSTILLA_MODERATION_THRESHOLD=abc` or `POSTILLA_OPENCODE_URL=opencode.ai`,
when `translate` runs, then it exits 1 naming the variable and sends no request.

AC-F5: Given `story.json` can't be replaced (the folder is read-only), when `translate`
runs, then it exits 1 naming `story.json`, and the file is unchanged.

## Touched boundaries

| Boundary | Failure covered by |
|---|---|
| outbound HTTPS: OpenCode Jev | AC-F1 (5xx, retries), AC-F3 (bad reply) |
| outbound HTTPS: OpenCode DeepSeek | AC-F2 (4xx at once), AC-8 (bad replies, 3 tries) |
| outbound HTTPS: server lists | covered by cli-publish AC-F2 (same shared code) |
| filesystem: reading `story.json` | covered by cli-publish AC-F3 (same shared code) |
| filesystem: writing `story.json` | AC-F5 |
| env: `POSTILLA_MODERATION_THRESHOLD`, `POSTILLA_OPENCODE_URL` | AC-F4 |
