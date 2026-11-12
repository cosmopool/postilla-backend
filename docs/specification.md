# Story feed backend

Tells the app which stories were published since it last asked. The app sends the newest cursor it has; the backend answers with the id and sha256 of every story published after it. The app then downloads each one (`.tilla.gz` and `.opus`, format in [TILLA.md](../../docs/TILLA.md)) from the R2 bucket.

The backend never serves story files. They live in Cloudflare R2; the backend only holds their metadata in a local SQLite, and every R2 key follows from it.

Stories reach the feed in one of two ways:

- `POST /stories` publishes files that were already built and uploaded.
- `POST /drafts` starts a draft from Italian text. The backend moderates it, translates it, waits for your approval, narrates it, builds the files and publishes them ([Drafts](#drafts)).
- `POST /stories/<id>/narrate` adds narration to a story that's already published. It starts a draft at `narrating` from the published text ([Adding narration](#adding-narration)).

## Encoding

Every binary body, in requests and responses, follows the same conventions as TILLA.md:

- Big-endian (network byte order) throughout, with no padding.
- `u8`, `u16`, `u32`: unsigned integers of 1, 2 and 4 bytes.
- `str`: a `u32` byte length, then that many bytes of UTF-8.
- `uuid`: 16 bytes, the UUID's 32 hex digits as bytes in written order.

Every body starts with a 4-byte ASCII magic and a `u8` version, which is `1` for every format here. A request whose magic is wrong or whose version is unknown gets a 400.

| Magic | Body |
|---|---|
| `FEED` | `GET /stories` response |
| `STRY` | `POST /stories` request |
| `DNEW` | `POST /drafts` request |
| `DLST` | `GET /drafts` response |
| `DRFT` | `GET /drafts/<id>` response |
| `TRNS` | `PUT /drafts/<id>/translation` request |

A body made of a single `u32` (a cursor or a draft id) has no magic or version.

The same layouts are in machine-readable form: [openapi.yaml](openapi.yaml) for the endpoints, and one Kaitai Struct file per body in [formats/](formats/) (`feed.ksy`, `stry.ksy`, `dnew.ksy`, `dlst.ksy`, `drft.ksy`, `trns.ksy`, `u32_body.ksy`).

## Cursor

The cursor is a publish counter, a `u32`. Every publish takes the next value (`max(cursor) + 1`, the first publish gets 1) and stores it in the story's row.

- A new story gets a new cursor.
- A republished story (same id, new sha256) gets a new cursor too, replacing its old one. Its old value is never reused, so the cursors in the table can have gaps.
- A republish with the same sha256 changes nothing and keeps the cursor.

So `cursor > X` is exactly "published or corrected after the app's last sync". The app stores the largest cursor it received and sends it next time.

## Files in R2

All files are in one public bucket, keyed by the story id and the sha256 of its `.tilla.gz`:

```
stories/<id>/<sha256>.tilla.gz    the story (TILLA.md)
stories/<id>/<sha256>.opus        narration for the app: Opus, 16 kbps, mono
stories/<id>/<sha256>.flac        narration master: lossless, never downloaded by the app
```

`<id>` is the UUID in its written form (`d0159518-99cc-46f0-bef2-b5b6f6f9a76d`) and `<sha256>` is 64 lowercase hex digits.

- A republish writes new keys, so no cache can serve a stale file. Every object can be served with `Cache-Control: public, max-age=31536000, immutable`.
- After a republish commits, the previous version's three objects are deleted.
- The app builds each URL from a feed record's `id` and `sha256`.
- A story without narration has no `.opus`. The app learns this from its `.tilla`, where every `it_sent_times` is empty (TILLA.md).
- Only drafts produce a `.flac`. A story published through `POST /stories` has none.

## Endpoints

### `GET /stories?since=<cursor>`

`since` is a decimal `u32`. When it is missing it counts as 0, which returns every story. Any other value gets a 400.

The response is `200`, `Content-Type: application/octet-stream`:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `FEED` |
| `version` | `u8` | `1` |
| `count` | `u32` | Number of records that follow |

Then `count` records, ascending by `cursor`, one per story:

| Field | Type | Value |
|---|---|---|
| `id` | `uuid` | Story id |
| `sha256` | 32 bytes | sha256 of the story's `.tilla.gz` |
| `cursor` | `u32` | The story's cursor |

Each record is 52 bytes, so the body is `9 + 52 × count` bytes. When nothing is new the body is the 9-byte header with `count` 0. The last record's `cursor` is the new value the app stores.

### `POST /stories`

Publishes or republishes one story whose files were already uploaded to R2.

Auth: `Authorization: Bearer <token>`, where the token is env `POSTILLA_PUBLISH_TOKEN` and is compared in constant time. A missing or wrong token gets a 401 before the body is read. Every `/drafts` endpoint uses the same check.

Body:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `STRY` |
| `version` | `u8` | `1` |
| `id` | `uuid` | Story id |
| `sha256` | 32 bytes | sha256 of the `.tilla.gz` |
| `has_opus` | `u8` | 1 when the story has a `.opus`, 0 for a story without narration |

The body is always 54 bytes. The files must already be in R2 under the keys in [Files in R2](#files-in-r2); the server doesn't check that they exist.

The boundary parse is the only code that reads the body. It rejects with 400 when any of these fail:

1. The magic is `STRY` and the version is 1.
2. The body is exactly 54 bytes.
3. `has_opus` is 0 or 1.

The response is `200`, and its body is the story's cursor as a `u32` (4 bytes): the new one, or the existing one for a same-sha no-op.

## Drafts

A draft turns an Italian story into a published one in steps. Each step runs on a worker thread, and the draft's `state` records where it is:

```
moderating ──▶ rejected
    │
    ▼
translating ──▶ review ──approve──▶ narrating ──▶ publishing ──▶ published
    ▲             │
    └─retranslate─┘
```

Any step can also end in `failed`. The draft then stores the step that failed and its error, and `POST /drafts/<id>/resume` reruns that step. `POST /drafts/<id>/discard` drops a draft in `review` or `failed` into `discarded`. `rejected`, `published` and `discarded` are final.

| Step | Service | What happens |
|---|---|---|
| `moderating` | Jev (`jev-1.13`, OpenCode key) | Decides whether the Italian text contains hate speech |
| `translating` | DeepSeek (`deepseek-v4.1-flash`, OpenCode key) | Translates every Italian sentence into Portuguese |
| `review` | You | Read the translation, then edit it, retranslate it, or approve it |
| `narrating` | Speechify (`simba-3.5`, Speechify key) | Generates the Italian narration and the sentence times |
| `publishing` | R2 and the feed | Builds the files, uploads them, and takes the next cursor |

Only the review step waits on you. Every other step starts as soon as the one before it ends, and the cursor increases only when `publishing` finishes.

Each draft has its own id, a `u32`. Its story id is a field of the draft. A story can have any number of drafts over time, such as its first version and later corrections, and finished drafts stay as history.

A story has at most one draft in progress, meaning in any state that isn't final. `POST /drafts` and `POST /stories/<id>/narrate` get a 409 while the story has one. Without this rule, two drafts would both publish and the later one would overwrite the earlier one's changes. To start over on a stuck draft, discard it first.

State values, as the `u8` the binary bodies carry:

| Value | State |
|---|---|
| 1 | `moderating` |
| 2 | `rejected` |
| 3 | `translating` |
| 4 | `review` |
| 5 | `narrating` |
| 6 | `publishing` |
| 7 | `published` |
| 8 | `failed` |
| 9 | `discarded` |

### Adding narration

`POST /stories/<id>/narrate` starts a narration-only draft for a published story. `<id>` is the story UUID in its written form.

- Auth: the same bearer token. No body.
- The response is `202` with the new draft id as a `u32`. A story id that isn't in the feed gets a 404.

The draft skips moderation, translation and review, and starts at `narrating`:

1. The worker downloads the story's current `.tilla.gz` from R2 and reads it with the reader rules of TILLA.md.
2. It copies the header and every Italian and Portuguese sentence into the draft unchanged. The text was already moderated and reviewed when it was first published.
3. From there it runs the normal `narrating` and `publishing` steps.

The new `.tilla` carries the sentence times, so its sha256 changes. The story gets new R2 keys and a new cursor, and every app downloads the narrated version on its next sync, as with any republish (see [Cursor](#cursor)).

- A `.tilla` that fails the reader rules, or a story over the 20,000-character narration limit, fails the draft at `narrating`.
- This works for stories published through `POST /stories` too, since the text comes from the `.tilla`, not from an earlier draft.
- A story that already has narration is narrated again, and its new audio replaces the old.

### Retries

Each call to an outside service (OpenCode, Speechify, R2) is tried up to 3 times, waiting 5 s, 30 s, then 2 min between tries. A network error, a 429 or a 5xx counts as a failed try.

After the third failed try, the draft becomes `failed`. It stores the step that failed, the error, and the attempt count.

`POST /drafts/<id>/resume` reruns the failed step from scratch with a fresh try count. Work from earlier steps is kept: an approved translation is never redone.

### Moderation

The draft's Italian text goes to Jev in `state`, with one `choice` question. Its options are `none`, `homophobic`, `racist`, `sexist`, `religious` and `other_hate`, each described in the question's `criteria`.

- Jev returns a probability for each option and no explanation.
- The draft is `rejected` when `P(none)` is below the threshold: env `POSTILLA_MODERATION_THRESHOLD`, default `0.9`.
- The stored error names the option with the highest probability, so a rejection says what was flagged.
- Jev's docs don't say whether it reads Italian. A fixed test set of Italian texts, both clean and hateful, runs through Jev before this step is trusted, and stays as a regression check. If Jev handles Italian poorly, moderation moves to the Portuguese translation.

Request: `POST https://opencode.ai/inference/systemone/v1/systemone`, with `Authorization: Bearer $POSTILLA_OPENCODE_KEY`.

### Translation

DeepSeek translates paragraph by paragraph, in reading order. Each request carries one paragraph's Italian sentences, and the reply must be a JSON array of Portuguese strings of the same length. That keeps the 1:1 sentence alignment the app needs (TRA-08).

- A reply that isn't a JSON array of strings, or has the wrong number of sentences, counts as a failed try (see [Retries](#retries)).
- After the third failed try the draft fails, and the error names the paragraph.

OpenCode Zen documents no JSON mode for this model, so the length check above is the only guarantee.

Request: `POST https://opencode.ai/inference/openai/v1/chat/completions` (OpenAI-compatible), with `Authorization: Bearer $POSTILLA_OPENCODE_KEY`. The request sets `model` to `deepseek-v4.1-flash` and `temperature` to `0.3`, and has two messages.

System message, with `{level}` replaced by `A1`, `A2`, `B1` or `B2`:

```
You translate short Italian stories into Brazilian Portuguese for Brazilians learning Italian.

- Write natural Brazilian Portuguese, the way a Brazilian writer would, not word for word.
- Keep each sentence's meaning inside that sentence. Never move, merge or split content between sentences.
- Keep the names of people and places as they are in the Italian.
- The story is CEFR level {level}. Keep the Portuguese as simple as the Italian.
- The user message is a JSON object with "title" (the story's title), "previous" (the previous paragraph's Italian sentences, for context only; do not translate them) and "sentences" (the Italian sentences to translate).
- Reply with only a JSON array of strings: one Portuguese sentence per Italian sentence, in the same order, the same count. No commentary, no code fences.
```

User message, a JSON object:

```json
{"title": "Il treno per Bologna", "previous": ["…"], "sentences": ["Sono le otto.", "Ana è a Roma."]}
```

`previous` is `[]` for the first paragraph.

### Review

At `review`, these endpoints are open:

- **Read:** `GET /drafts/<id>` returns the Italian and Portuguese sentences.
- **Edit:** `PUT /drafts/<id>/translation` replaces the Portuguese sentences. Every paragraph must keep its sentence count, or the request gets a 400. The draft stays in `review`.
- **Retranslate:** `POST /drafts/<id>/retranslate` discards the current Portuguese and goes back to `translating`.
- **Approve:** `POST /drafts/<id>/approve` freezes the Portuguese and starts `narrating`.

`GET /drafts?state=review` lists the drafts waiting for you.

### Narration

One streamed call narrates the whole story: `POST https://api.speechify.ai/v1/audio/stream/with-timestamps` (Server-Sent Events), with `Authorization: Bearer $POSTILLA_SPEECHIFY_KEY`. The request sets:

- `model` to `simba-3.5`
- `voice_id` to `daniele-agent`; every story uses this voice
- `language` to `it-IT`
- the highest-quality PCM that Speechify streams

That endpoint takes up to 20,000 spoken characters. `POST /drafts` already rejects a longer story.

The input is the Italian paragraphs joined in reading order. The worker reads the events:

- `speech.chunk` events carry the audio and word marks. Each mark has `start` and `end` (character offsets into the input) and `start_time` and `end_time` in ms.
- `speech.done` ends the stream.
- `speech.error`, or a dropped connection, counts as a failed try. The whole call is retried, since one stream can't resume halfway.

The stream yields three outputs:

- **Sentence times:** each sentence's `(start_ms, end_ms)` in `it_sent_times` runs from its first word's `start_time` to its last word's `end_time`. Words are matched to sentences by mapping the marks' character offsets onto the `it_sents` spans.
- **App audio:** the PCM is encoded once with vendored libopus to the `.opus` that TILLA.md describes (16 kbps, mono).
- **Master:** the same PCM is also compressed to FLAC with vendored libFLAC. It is a lossless copy kept for re-encoding later. The app never downloads it.

### Publishing

The worker computes `it_words`, `it_sents` and `pt_sents` with the same word and sentence rules as the pipeline (CONTRACT.md). It writes the `.tilla.gz`, then uploads the `.tilla.gz`, `.opus` and `.flac` to R2 under the keys in [Files in R2](#files-in-r2). Last, it runs the same transaction as `POST /stories`, with `has_opus` 1, which assigns the story's cursor. Only then is the draft `published`.

### `POST /drafts`

Starts a draft from the story's header and its Italian sentences. Body:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `DNEW` |
| `version` | `u8` | `1` |
| `id` | `uuid` | Story id |
| `title` | `str` | Title |
| `subtitle` | `str` | Subtitle |
| `level` | `u8` | 1 A1 · 2 A2 · 3 B1 · 4 B2 |
| `genre` | `str` | A `genre.id` |
| `work` | `str` | Work name; `''` outside a work |
| `part` | `u16` | Part of the work; 0 outside a work |
| `paragraph_count` | `u16` | Number of paragraphs that follow |

Then `paragraph_count` paragraphs, in reading order:

| Field | Type | Value |
|---|---|---|
| `sentence_count` | `u16` | Number of sentences that follow |
| `sentences` | `str` × `sentence_count` | Italian sentences |

The boundary parse rejects with 400 when any of these fail:

1. The magic is `DNEW` and the version is 1.
2. Every length fits in the body, and no bytes are left after the last paragraph.
3. Every `str` is valid UTF-8.
4. `title`, `subtitle` and `genre` are not empty; `level` is 1 to 4.
5. `work` is empty exactly when `part` is 0.
6. `paragraph_count` is at least 1, every `sentence_count` is at least 1, and no sentence is empty.
7. The story is at most 20,000 characters, the narration limit.

The response is `202`, and its body is the new draft id as a `u32`. The worker starts `moderating`.

A draft for a story id that is already published counts as a republish: on publish, the story gets a new cursor (see [Cursor](#cursor)).

### `GET /drafts?state=<state>`

`state` is a state's name (`review`, `failed`…). When it is missing, every draft is listed. An unknown name gets a 400.

The response is `200`:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `DLST` |
| `version` | `u8` | `1` |
| `count` | `u32` | Number of records that follow |

Then `count` records, newest draft first:

| Field | Type | Value |
|---|---|---|
| `draft_id` | `u32` | Draft id |
| `id` | `uuid` | Story id |
| `state` | `u8` | Current state |
| `title` | `str` | Title |

### `GET /drafts/<id>`

The response is `200`:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `DRFT` |
| `version` | `u8` | `1` |
| `draft_id` | `u32` | Draft id |
| `id` | `uuid` | Story id |
| `state` | `u8` | Current state |
| `failed_step` | `u8` | The state that failed, when `state` is `failed`; 0 otherwise |
| `attempts` | `u8` | Tries made by the current or failed step |
| `error` | `str` | Stored error; `''` when there is none |
| `moderation` | `u16` × 6 | Probabilities of `none`, `homophobic`, `racist`, `sexist`, `religious`, `other_hate`, in thousandths (0 to 1000); all 0 before moderation |
| `title` | `str` | Title |
| `subtitle` | `str` | Subtitle |
| `level` | `u8` | Level |
| `genre` | `str` | Genre id |
| `work` | `str` | Work name |
| `part` | `u16` | Part |
| `paragraph_count` | `u16` | Number of paragraphs that follow |

Then `paragraph_count` paragraphs, each a `sentence_count` (`u16`) followed by that many sentence pairs:

| Field | Type | Value |
|---|---|---|
| `it` | `str` | Italian sentence |
| `pt` | `str` | Portuguese sentence; `''` before translation |

### `PUT /drafts/<id>/translation`

Replaces the Portuguese sentences. Body:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `TRNS` |
| `version` | `u8` | `1` |
| `paragraph_count` | `u16` | Must equal the draft's |

Then each paragraph: a `sentence_count` (`u16`, which must equal the draft's for that paragraph), followed by that many `str` Portuguese sentences, none empty.

A body that fails the parse or doesn't match the draft's counts gets a 400. The response is `200` with no body.

### `POST /drafts/<id>/retranslate`, `/approve`, `/resume`, `/discard`

No body. The response is `200` with no body.

- `retranslate` and `approve` need the draft in `review`.
- `resume` needs the draft in `failed`.
- `discard` needs the draft in `review` or `failed`. A draft that a worker is running can't be discarded until it stops.

Any other state gets a 409.

### Status codes

| Code | When |
|---|---|
| 200 | Success |
| 202 | Draft created |
| 400 | Bad `since` or `state`, or a body that fails the parse (including a translation edit that changes a sentence count) |
| 401 | Missing or wrong bearer token on `POST /stories`, `/narrate`, or any `/drafts` request |
| 404 | Any other path, an unknown draft id, or an unknown story id on `/narrate` |
| 405 | Any other method on `/stories`, `/narrate` or `/drafts` |
| 409 | An action on a draft that isn't in the state it needs, or a new draft for a story that already has one in progress |
| 500 | SQLite error |

## Database

```sql
CREATE TABLE story (
  id        BLOB PRIMARY KEY,           -- 16 bytes
  sha256    BLOB NOT NULL,              -- 32 bytes
  cursor    INTEGER NOT NULL UNIQUE,
  has_opus  INTEGER NOT NULL          -- 0 or 1
) WITHOUT ROWID;
```

The `UNIQUE` on `cursor` gives the index the GET query uses (`WHERE cursor > ? ORDER BY cursor`).

A publish runs in one `BEGIN IMMEDIATE` transaction: read the current row, then, if the sha256 differs or the row is new, read `coalesce(max(cursor), 0) + 1` and upsert. The write lock keeps two concurrent publishes from taking the same cursor.

A `draft` table holds each draft's id, story id, header fields, state, failed step, attempt count, error and moderation probabilities. Its sentences go in a `draft_sentence` table keyed by `(draft_id, paragraph, pos)` with `it` and `pt`. The exact columns are left to the implementation.

Creating a draft checks for a draft in progress and inserts the new one in the same `BEGIN IMMEDIATE` transaction, so two requests at once can't both pass the check.

## Configuration

Everything comes from env, read and checked once at startup. A missing required value stops the server before it binds.

[`.env.example`](../.env.example) lists every variable with its default. Copy it to `.env`, which git ignores. The same file works as the systemd `EnvironmentFile`.

| Variable | Default | What it is |
|---|---|---|
| `POSTILLA_PORT` | `8080` | HTTP port |
| `POSTILLA_BIND` | `127.0.0.1` | Bind address; TLS is the reverse proxy's job |
| `POSTILLA_DB` | `./postilla.db` | SQLite path |
| `POSTILLA_PUBLISH_TOKEN` | required | Bearer token for `POST /stories` and `/drafts` |
| `POSTILLA_OPENCODE_KEY` | required | OpenCode key, for Jev and DeepSeek |
| `POSTILLA_SPEECHIFY_KEY` | required | Speechify key |
| `POSTILLA_R2_ACCOUNT_ID` | required | Cloudflare account id |
| `POSTILLA_R2_ACCESS_KEY_ID` | required | R2 S3 access key id |
| `POSTILLA_R2_SECRET_ACCESS_KEY` | required | R2 S3 secret key |
| `POSTILLA_R2_BUCKET` | required | The public story bucket |
| `POSTILLA_MODERATION_THRESHOLD` | `0.9` | Minimum `P(none)` to pass moderation |

## Process

- A self-contained Zig project in `backend/`, with its own `build.zig` and `build.zig.zon`. It vendors the same SQLite amalgamation as the pipeline.
- Thread per connection on `std.http.Server`. Each thread opens its own SQLite connection; the database runs in WAL mode with a busy timeout so reads never block on a publish.
- Draft steps run on worker threads, never on a request thread. A draft caught mid-step by a restart is resumed from its stored `state`.
- Vendored C libraries, besides SQLite: libopus and libFLAC. It also needs HTTPS client calls to OpenCode, Speechify and R2, and SigV4 signing for the R2 uploads.

## Deployment

- One small Linux VPS runs the static binary under systemd, with the env from a root-only file.
- Caddy in front terminates TLS and proxies to `127.0.0.1:8080`.
- Litestream streams the SQLite WAL to R2 continuously, so a lost VPS restores to within seconds. The backup goes to a separate **private** bucket, never the public story bucket, because the database holds drafts that haven't been reviewed.

## Tests

Integration tests through HTTP only (see `.agents/rules/testing.md`). Each suite gets a free port and a temp SQLite file. Fuzz tests with fixed seeds cover every request body parse and the HTTP head, since they are hostile input.

OpenCode, Speechify and R2 are system boundaries. Tests point their base URLs at local fake servers that return recorded responses, so no test spends credits or needs network access. The Italian moderation test set is the exception: it calls Jev for real and runs only on demand.

## Open

- Which PCM sample rate the streaming endpoint actually delivers. The docs list `pcm_48000` but default streaming to 24 kHz. The first real call settles it.
- Where the app gets the bucket's public base URL. Only the manifest URL is built into the app (ARQ-06), so the manifest could carry it.
- Whether `POST /drafts` checks `genre` against a genre list, and where the backend gets that list. Today it lives in `stories/genres.txt`.
