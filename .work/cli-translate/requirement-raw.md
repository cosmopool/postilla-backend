Source: the docs at d085737 plus the owner's decisions of 2026-11-18 (in this session):
- Jev: model `jev-1.13` on https://opencode.ai/inference/systemone/v1/systemone (OpenCode
  key, billed to credits). Recorded request/response: .work/fixtures/jev_request.json,
  .work/fixtures/jev_response.json (criteria texts in that request are a draft).
- DeepSeek: model `deepseek-v4.1-flash` through the OpenCode Go subscription,
  https://opencode.ai/inference/go/v1/chat/completions, which requires a `user-agent` naming
  the client and an `x-opencode-session` header ("Use Go anyway", over the docs' "coding agent
  traffic" note). Recorded request/response: .work/fixtures/deepseek_go_request.json,
  .work/fixtures/deepseek_go_response.json.
- Speechify voice `daniele-agent` stays (owner: available for simba-3.5); narrate is a later slice.
Commands other than `translate` (narrate) are later slices.

From docs/specification.md:

## The CLI

`postilla <command> <folder>` works on one story folder. Each command reads `story.json` in the folder and writes its results back there, so the folder is the state between commands: any command can be rerun on its own, and you read and edit the files between them. Keep the story folders in git.

```
postilla translate <folder> [--force] [--redo <lang>]   moderate the Italian, translate the missing languages
postilla narrate   <folder>                             narrate every language with target 1
postilla publish   <folder>                             build the .tilla files, upload to R2, POST /stories
```

The CLI reads the lists from the server's public endpoints (`GET /languages`, `GET /genres`, `GET /tags`, `GET /authors` at `POSTILLA_SERVER_URL`), so it never needs `postilla.db`. A command that fails prints one line naming the step and the reason and exits non-zero, leaving `story.json` as it was before that step. The exit code is 0 on success, 1 on any failure and 2 for a usage error (an unknown command or a missing folder).

### Story folder

```
stories/pinocchio-1/
  story.json      the story: header, every translation, moderation scores, narration times
  it.opus         written by narrate: the app's audio for each language with target 1
  it.flac         written by narrate: its lossless master
```

`story.json`:

```json
{
  "id": "d0159518-99cc-46f0-bef2-b5b6f6f9a76d",
  "level": 2,
  "genre": "classici",
  "tags": [],
  "work": "Pinocchio",
  "part": 1,
  "author": "collodi",
  "adapted": 1,
  "license": "public-domain",
  "moderation": {"none": 0.98, "homophobic": 0.0, "racist": 0.01, "sexist": 0.0, "religious": 0.0, "other_hate": 0.01, "forced": false},
  "translations": {
    "it": {
      "title": "Il pezzo di legno",
      "subtitle": "Mastro Ciliegia trova un pezzo di legno che parla",
      "paragraphs": [["C'era una volta…", "Un re!"], ["No, ragazzi, avete sbagliato."]],
      "audio": {"audio_ms": 252000, "text_sha256": "3f2a…", "times": [[[0, 2140], [2300, 3010]], [[3200, 5900]]]}
    },
    "pt-BR": {
      "title": "O pedaço de madeira",
      "subtitle": "Mestre Cereja encontra um pedaço de madeira que fala",
      "paragraphs": [["Era uma vez…", "Um rei!"], ["Não, crianças, vocês erraram."]]
    }
  }
}
```

| Field | Written by | Value |
|---|---|---|
| `id` | you | Story UUID in its written form |
| `level`, `genre`, `tags`, `work`, `part`, `author`, `adapted`, `license` | you | The story-level fields ([Stories and translations](#stories-and-translations)) |
| `moderation` | `translate` | Jev's probability for each option, and `forced` true when `--force` let a rejected text through. Missing before the first `translate` |
| `translations` | you (`it`), `translate` (the others) | One object per language, keyed by language id |
| `translations.<lang>.title`, `.subtitle` | | Title and subtitle in that language |
| `translations.<lang>.paragraphs` | | Paragraphs in reading order, each an array of sentences |
| `translations.<lang>.audio` | `narrate` | Only for a language with `target` 1, once narrated: `audio_ms`, `text_sha256` (sha256 of the text it narrated: the sentences joined by one space within a paragraph and the paragraphs by one newline) and `times`, one `[start_ms, end_ms]` per sentence, in the shape of `paragraphs` |

Every command checks `story.json` before it does anything, and stops on the first rule it breaks (`story.json: genre: empty`):

1. It is valid JSON with the fields above and no others (`moderation` and `audio` may be missing).
2. `title`, `subtitle`, `genre` and `license` are not empty; `license` is ASCII; `level` is 1 to 6; `adapted` is 0 or 1.
3. `work` is empty exactly when `part` is 0.
4. No tag is empty or repeated.
5. `adapted` is 1 only when `author` is not empty.
6. `translations` has `it`. Its `paragraphs` has at least 1 paragraph, every paragraph at least 1 sentence, and no sentence is empty.
7. Every other translation has the same paragraph count as `it` and, paragraph by paragraph, the same sentence count; no title, subtitle or sentence is empty.
8. The Italian is at most 20,000 characters, the narration limit: Unicode code points of its sentences, the unit Speechify counts in.

### `postilla translate`

Translates the story into every language with `translate` 1 (today only `pt-BR`) that `translations` lacks. A rerun never overwrites a translation already there, so hand edits survive it. `--redo <lang>` first drops that language, which must be one with `translate` 1, then translates it again. When there is nothing to translate, the command does nothing, not even moderation.

**Moderation** runs first, every time the command translates something. The Italian text (title, subtitle and sentences) goes to Jev (`jev-1.13`, OpenCode key) in `state`, with one `choice` question. Its options are `none`, `homophobic`, `racist`, `sexist`, `religious` and `other_hate`, each described in the question's `criteria`.

- Jev returns a probability for each option and no explanation.
- The text is rejected when `P(none)` is below the threshold: env `POSTILLA_MODERATION_THRESHOLD`, default `0.9`.
- The scores are written to `moderation` either way. On a rejection the command prints the six scores and the option with the highest probability, so a rejection says what was flagged, and exits non-zero without translating.
- `--force` is the override for a false positive: the command moderates again, writes the scores with `forced` true, and translates anyway.
- Jev's docs don't say whether it reads Italian. A fixed test set of Italian texts, both clean and hateful, runs through Jev before this step is trusted, and stays as a regression check. If Jev handles Italian poorly, moderation moves to the Portuguese translation.

Request: `POST https://opencode.ai/inference/systemone/v1/systemone`, with `Authorization: Bearer $POSTILLA_OPENCODE_KEY`.

**Translation** uses DeepSeek (`deepseek-v4.1-flash`, OpenCode key), one pass per language. A language is written into `story.json` only once all of it is done, so after a failure a rerun redoes only the languages without a finished translation, and the error names the language that failed (`pt-BR: paragraph 4: wrong sentence count`).

Each pass translates paragraph by paragraph, in reading order. It sends the title and subtitle first, as one extra two-sentence paragraph with the same request shape and length check, so every translation gets its own `title` and `subtitle` with no other code path. Each request carries one paragraph's Italian sentences, and the reply must be a JSON array of strings of the same length. That keeps the 1:1 sentence alignment the app needs (TRA-08).

- A reply that isn't a JSON array of strings, or has the wrong number of sentences, counts as a failed try (see [Retries](#retries)).
- After the third failed try the command stops, and the error names the language and the paragraph.

OpenCode Zen documents no JSON mode for this model, so the length check above is the only guarantee.

Request: `POST https://opencode.ai/inference/openai/v1/chat/completions` (OpenAI-compatible), with `Authorization: Bearer $POSTILLA_OPENCODE_KEY`. The request sets `model` to `deepseek-v4.1-flash` and `temperature` to `0.3`, and has two messages.

System message, with `{language}` replaced by the target language's English prompt name and `{level}` by `A1`, `A2`, `B1`, `B2`, `C1` or `C2`:

```
You translate short Italian stories into {language} for {language} speakers learning Italian.

- Write natural {language}, the way a native writer would, not word for word.
- Keep each sentence's meaning inside that sentence. Never move, merge or split content between sentences.
- Keep the names of people and places as they are in the Italian.
- The story is CEFR level {level}. Keep the {language} as simple as the Italian.
- The user message is a JSON object with "title" (the story's title), "previous" (the previous paragraph's Italian sentences, for context only; do not translate them) and "sentences" (the Italian sentences to translate).
- Reply with only a JSON array of strings: one {language} sentence per Italian sentence, in the same order, the same count. No commentary, no code fences.
```

The prompt names are fixed in code, by language id. Adding a language with `translate` 1 adds one here:

| Language | Prompt name |
|---|---|
| `pt-BR` | `Brazilian Portuguese` |

User message, a JSON object:

```json
{"title": "Il treno per Bologna", "previous": ["…"], "sentences": ["Sono le otto.", "Ana è a Roma."]}
```

`previous` is `[]` for the title paragraph and for the first story paragraph.

Read the translation in `story.json` and fix it by hand before narrating and publishing.


### Retries

Each call to an outside service (OpenCode, Speechify, R2) and to the server goes through `outbound.request` (`src/outbound.zig`) and gets 4 tries in all (1 + 3 retries), waiting 5 s, 30 s, then 2 min between them. A network error, a timeout, a 429 or a 5xx counts as a failed try; a `Retry-After` in seconds on a 429 or a 503 replaces the scheduled wait, capped at 2 min. Any other status ends the call at once with that status.

Each try sends its own copy of the body, so a try cut mid-send can't change what the next one sends. A try times out after 10 s without a connection, or 60 s after connecting without the whole answer. The HTTP client has no timeouts of its own, so the try runs as a task that is canceled when either time runs out.

After the fourth failed try, the command stops with the step that failed and the error. Rerunning it starts that step over, keeping what `story.json` already holds.


### CLI

[`cli.env.example`](../cli.env.example) lists every variable with its default. Copy it to `cli.env`, which git ignores. The CLI loads `cli.env` from the current directory when it is there; a variable already set in the environment wins over the file. Its lines are `KEY=value`, with no quotes or escapes (the same form as `.env`); blank lines and lines starting with `#` are skipped, and a line without `=` stops the command naming its line number. An empty value counts as missing.

| Variable | Default | What it is |
|---|---|---|
| `POSTILLA_SERVER_URL` | required | Base URL of `postilla-server` (`https://api.example.com`) |
| `POSTILLA_AUTHOR_TOKEN` | required | The server's bearer token, for `POST /stories` |
| `POSTILLA_OPENCODE_KEY` | required | OpenCode key, for Jev and DeepSeek |
| `POSTILLA_SPEECHIFY_KEY` | required | Speechify key |
| `POSTILLA_R2_ACCOUNT_ID` | required | Cloudflare account id |
| `POSTILLA_R2_ENDPOINT` | `https://<account>.r2.cloudflarestorage.com` | R2's S3 API base URL, when it isn't the account's |
| `POSTILLA_R2_ACCESS_KEY_ID` | required | R2 S3 access key id |
| `POSTILLA_R2_SECRET_ACCESS_KEY` | required | R2 S3 secret key |
| `POSTILLA_R2_BUCKET` | required | The public bucket: stories and the dictionary |
| `POSTILLA_DICT_DIR` | `./dict` | Where the CLI caches the current `dict.db` build |
| `POSTILLA_MODERATION_THRESHOLD` | `0.9` | Minimum `P(none)` to pass moderation |


## Tests

Integration tests through the public entry points only (see `.agents/rules/testing.md`): HTTP for the server, and for the CLI its commands run on a temp story folder against a real server. Each suite gets a free port and a temp SQLite file.

`zig build test` runs every `test/*.zig` (each its own test binary) except `test/harness.zig`, which starts the real server in-process on a free port with a temp SQLite file under `.zig-cache/tmp/`, and sends raw HTTP over TCP so a test can send any bytes. `-Dtest-file=test/<name>.zig` runs one file; `-Dcoverage` runs them under `kcov` into `coverage/kcov`. Malformed `since`, `lang` and `STRY` bodies are integration cases like any other.

OpenCode, Speechify and R2 are system boundaries. Tests point their base URLs at local fake servers that return recorded responses, so no test spends credits or needs network access. The Italian moderation test set is the exception: it calls Jev for real and runs only on demand.

