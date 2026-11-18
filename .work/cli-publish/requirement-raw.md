Source: the docs at aacef22 plus the owner's decisions of 2026-11-18 (in this session):
- the tests run `postilla publish` against a fake R2 through a new optional POSTILLA_R2_ENDPOINT
  (replaces the endpoint built from POSTILLA_R2_ACCOUNT_ID when set);
- fold in the two r2 fixes cli-publish depends on: questions.md #25 (each try sends its own copy
  of the body; a cut send must not alter the caller's bytes) and #18 (dict.db opened read-only,
  no pragmas);
- one slice with a 450-line budget.
Commands other than `publish` (translate, narrate) are later slices.

From docs/specification.md:

## The CLI

`postilla <command> <folder>` works on one story folder. Each command reads `story.json` in the folder and writes its results back there, so the folder is the state between commands: any command can be rerun on its own, and you read and edit the files between them. Keep the story folders in git.

```
postilla translate <folder> [--force] [--redo <lang>]   moderate the Italian, translate the missing languages
postilla narrate   <folder>                             narrate every language with target 1
postilla publish   <folder>                             build the .tilla files, upload to R2, POST /stories
```

The CLI reads the lists from the server's public endpoints (`GET /languages`, `GET /genres`, `GET /tags`, `GET /authors` at `POSTILLA_SERVER_URL`), so it never needs `postilla.db`. A command that fails prints one line naming the step and the reason and exits non-zero, leaving `story.json` as it was before that step.

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
| `translations.<lang>.audio` | `narrate` | Only for a language with `target` 1, once narrated: `audio_ms`, `text_sha256` (sha256 of the text it narrated) and `times`, one `[start_ms, end_ms]` per sentence, in the shape of `paragraphs` |

Every command checks `story.json` before it does anything, and stops on the first rule it breaks (`story.json: genre: empty`):

1. It is valid JSON with the fields above and no others.
2. `title`, `subtitle`, `genre` and `license` are not empty; `license` is ASCII; `level` is 1 to 6; `adapted` is 0 or 1.
3. `work` is empty exactly when `part` is 0.
4. No tag is empty or repeated.
5. `adapted` is 1 only when `author` is not empty.
6. `translations` has `it`. Its `paragraphs` has at least 1 paragraph, every paragraph at least 1 sentence, and no sentence is empty.
7. Every other translation has the same paragraph count as `it` and, paragraph by paragraph, the same sentence count; no title, subtitle or sentence is empty.
8. The Italian is at most 20,000 characters, the narration limit.

### `postilla publish`

Builds every translation's `.tilla`, uploads the files and publishes the story. It checks first, and stops without uploading anything when any of these fail:

- `genre`, every tag and `author` are listed by the server; every language in `translations` is in `language`.
- Every language with `translate` 1 is in `translations` (run `translate`).
- Every language with `target` 1 has `audio` whose `text_sha256` matches its current text, and its `.opus` and `.flac` are in the folder (run `narrate` after changing the text).

#### Vocabulary coverage

`band_words` is four counts: how many of an Italian translation's `words` fall in each NVdB band, using `entry.band` from `dict.db` (0 outside · 1 fondamentale · 2 alto uso · 3 alta disponibilità). The four add up to `words`. Counts, not percentages, so they stay integers and the app computes the share.

A word takes the most common band among the lemmas its form leads to in `dict.db` (1 before 2 before 3 before 0): "porta" (*portare* 1, *porgere* 2) counts as band 1. A word with no lemma counts as band 0. Words are split, normalized and looked up by the shared `words` module, the same way the app looks them up on tap ([tilla.md, Words](tilla.md#words)).

The CLI gets `dict.db` the same way the app does: it reads `dict/latest` from the public bucket, downloads that build into `POSTILLA_DICT_DIR` if it doesn't have it, and computes `band_words` from it. The build is kept as `<POSTILLA_DICT_DIR>/<sha256>.db`, named by the `.gz`'s sha256; when that file is there nothing is downloaded. Otherwise the `.gz` is checked against `dict/latest`'s size and sha256 (a mismatch is a failed try), gunzipped into an unnamed temp file in the same directory and linked into place. It keeps only the current build there and deletes every other `*.db` once it has switched. A `dict/latest` that isn't the line CONTRACT.md describes fails at once. An R2 failure there is a failed try like any other R2 call. An older story's `band_words` reflect the bands at its publish time until it is republished.

A `.tilla` word is only a span, looked up by form; `dict.db` entry ids change between builds (ARQ-35) and nothing stores them, so a dictionary rebuild never touches a published story.

#### Building and uploading

The CLI writes one `.tilla` per translation ([tilla.md](tilla.md)): the story-level fields, the translation's title, subtitle and sentences, its word spans by the word rule in tilla.md, `words`, `band_words`, and, for a narrated translation, `audio_ms`, `opus_sha256`, `opus_size` and the sentence times. `tilla.build` (`src/tilla.zig`) writes it, with its gzip and sha256, and refuses the inputs tilla.md lists under Reader rules. For `band_words` it tries each of `words.lookupKeys`'s keys against `form`, then `form_norm`; the first key that finds a row decides the word's band. `dict.db` is opened only for the Italian original; a `dict.db` that can't be opened or read fails the build. The sha256 is taken of the `.tilla` before gzip, so an unchanged translation keeps its sha256, its key and its cursor whatever the gzip library or level does; the gzip needs no fixed settings.

It uploads every translation's `.tilla.gz`, `.opus` and `.flac` to R2 under the keys in [Files in R2](#files-in-r2). Keys are content-addressed, so uploading a file that is already there writes the same bytes again. Last, after every file is in R2, it sends `POST /stories` with every translation's `lang` and `sha256`, and the server takes the cursors. A 409 for a missing published translation means the folder lacks a language the story was published in: add it back.

### Retries

Each call to an outside service (OpenCode, Speechify, R2) goes through `outbound.request` (`src/outbound.zig`) and gets 4 tries in all (1 + 3 retries), waiting 5 s, 30 s, then 2 min between them. A network error, a timeout, a 429 or a 5xx counts as a failed try; a `Retry-After` in seconds on a 429 or a 503 replaces the scheduled wait, capped at 2 min. Any other status ends the call at once with that status.

A try times out after 10 s without a connection, or 60 s after connecting without the whole answer. The HTTP client has no timeouts of its own, so the try runs as a task that is canceled when either time runs out.

After the fourth failed try, the command stops with the step that failed and the error. Rerunning it starts that step over, keeping what `story.json` already holds.

### CLI

[`cli.env.example`](../cli.env.example) lists every variable with its default. Copy it to `cli.env`, which git ignores. The CLI loads `cli.env` from the current directory when it is there; a variable already set in the environment wins over the file.

| Variable | Default | What it is |
|---|---|---|
| `POSTILLA_SERVER_URL` | required | Base URL of `postilla-server` (`https://api.example.com`) |
| `POSTILLA_AUTHOR_TOKEN` | required | The server's bearer token, for `POST /stories` |
| `POSTILLA_OPENCODE_KEY` | required | OpenCode key, for Jev and DeepSeek |
| `POSTILLA_SPEECHIFY_KEY` | required | Speechify key |
| `POSTILLA_R2_ACCOUNT_ID` | required | Cloudflare account id |
| `POSTILLA_R2_ACCESS_KEY_ID` | required | R2 S3 access key id |
| `POSTILLA_R2_SECRET_ACCESS_KEY` | required | R2 S3 secret key |
| `POSTILLA_R2_BUCKET` | required | The public bucket: stories and the dictionary |
| `POSTILLA_DICT_DIR` | `./dict` | Where the CLI caches the current `dict.db` build |
| `POSTILLA_MODERATION_THRESHOLD` | `0.9` | Minimum `P(none)` to pass moderation |

### `POST /stories`

Publishes or republishes every translation of one story, whose files are already in R2 under the keys in [Files in R2](#files-in-r2). `postilla publish` uploads them first; the server doesn't check that they exist. Body:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `STRY` |
| `version` | `u8` | `1` |
| `id` | `uuid` | Story id |
| `lang_count` | `u8` | Number of translations that follow |

Then `lang_count` translations:

| Field | Type | Value |
|---|---|---|
| `lang` | `lang` | The translation's language |
| `sha256` | `sha256` | sha256 of its `.tilla`, before gzip |

The body is `22 + 40 × lang_count` bytes. It needs a `Content-Length`: a missing one (or chunked transfer) gets a 400 `body: length required`, and one above 10 222 bytes (the largest valid body, `lang_count` 255) a 400 `body: too large`, both without reading the body. The boundary parse rejects with 400 when any of these fail, checked in this order:

1. The magic is `STRY` and the version is 1 (`body: bad magic`, `body: bad version`).
2. `lang_count` is at least 1, and the body is exactly `22 + 40 × lang_count` bytes (`body: wrong length`).
3. Every `lang` is non-empty ASCII followed only by zero bytes (`lang: empty or not ASCII`), and no `lang` repeats (`lang: repeated id 'it'`).
4. One `lang` is `it`, the original (`lang: no 'it'`).

Past the parse, a `lang` not in `language` (compared byte for byte) gets a 400 (`lang: unknown id 'fr'`), and a removed story id gets a 409 (`story removed`). A story that already has a published translation in a language the body doesn't carry gets a 409 (`pt-BR: published, missing from body`), so a republish can't leave an old translation next to a new original with different paragraph counts. There is no override: a republish carries every language the story was published in.

Then, in one `BEGIN IMMEDIATE` transaction, every translation in the body is upserted: a row whose sha256 changed, or that is new, gets `change` `published` and the next cursor; a row whose sha256 is the same keeps its cursor ([Cursor](#cursor)). So a syncing app sees all of a story's changed translations or none.

The response is `200` with no body.
