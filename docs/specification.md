# Story feed backend

Tells the app which story translations were published or removed since it last asked. The app sends the newest cursor it has and the languages it reads; the backend answers with one record per changed translation. The app then downloads each published translation (`.tilla.gz`, and its `.opus` when it has narration; format in [tilla.md](tilla.md)) from the R2 bucket.

The backend never serves story files. They live in Cloudflare R2; the backend only holds their metadata in a local SQLite (`postilla.db`), and every R2 key follows from it.

Every story comes from a draft. The backend moderates it, translates it, waits for your review, narrates it, lets you listen, builds the files and publishes them ([Drafts](#drafts)):

- `POST /drafts` starts a draft from Italian text.
- `POST /stories/<id>/edit` starts a draft from a published story, at `review` ([Editing a published story](#post-storiesidedit)).
- `POST /stories/<id>/narrate` starts a draft from a published story, at `narrating` ([Narrating a published story again](#post-storiesidnarrate)).
- `DELETE /stories/<id>` removes a story ([Removing a story](#delete-storiesid)).

What the learner app does with what this backend serves is in [app-handoff.md](app-handoff.md); what postilla-content has to do is in [content-handoff.md](content-handoff.md).

## Encoding

Every binary body, in requests and responses, follows the same conventions as tilla.md:

- Big-endian (network byte order) throughout, with no padding.
- `u8`, `u16`, `u32`: unsigned integers of 1, 2 and 4 bytes.
- `str`: a `u32` byte length, then that many bytes of UTF-8.
- `uuid`: 16 bytes, the UUID's 32 hex digits as bytes in written order.
- `lang`: 8 bytes, a language id (a BCP 47 tag) in ASCII, zero-padded (`it\0\0\0\0\0\0`, `pt-BR\0\0\0`), so every record keeps a fixed size.
- `sha256`: 32 bytes.

Every body starts with a 4-byte ASCII magic and a `u8` version, which is `1` for every format here. A request whose magic is wrong or whose version is unknown gets a 400.

| Magic | Body |
|---|---|
| `FEED` | `GET /stories` response |
| `GNRS` | `GET /genres` response |
| `TAGS` | `GET /tags` response |
| `AUTH` | `GET /authors` response |
| `LANG` | `GET /languages` response |
| `PUBL` | `GET /published` response |
| `DNEW` | `POST /drafts` request |
| `DLST` | `GET /drafts` response |
| `DRFT` | `GET /drafts/<id>` response |
| `TRNS` | `PUT /drafts/<id>/translation` request |
| `HEDR` | `PUT /drafts/<id>/header` request |

A body made of a single `u32` (a draft id) has no magic or version.

The same layouts are in machine-readable form: [openapi.yaml](openapi.yaml) for the endpoints, and one Kaitai Struct file per body in [formats/](formats/) (`feed.ksy`, `gnrs.ksy`, `tags.ksy`, `auth.ksy`, `lang.ksy`, `publ.ksy`, `dnew.ksy`, `dlst.ksy`, `drft.ksy`, `trns.ksy`, `hedr.ksy`, `u32_body.ksy`; shared types in `postilla_str.ksy` and `postilla_enums.ksy`).

The app isn't published yet, so these formats changed in place and kept version 1. After launch, a format changes only with a version bump, and the backend bumps a version only together with an app release that reads it ([app-handoff.md](app-handoff.md#9-format-versions-and-errors)).

## Stories and translations

A story is split by language, so that any two of its languages can be the learner's target and native language (Italian for a Brazilian today, Portuguese for an Italian later).

- **Story-level fields** don't depend on language: `id`, `original` (the language it was written in, always `it` today), `level`, `genre`, `tags`, `author`, `adapted`, `license`, `work`, `part`. `level` is the original's; translations are written to the same level.
- **Translation fields** depend on it: `title`, `subtitle`, the sentences, `words`, `band_words`, `audio_ms` and the narration. The original is the translation whose language is `original`.

Every translation of a story has the same paragraph count and, paragraph by paragraph, the same sentence count, so paragraph *p*, sentence *s* means the same thing in every language and any two translations line up by index. The translation step and `PUT /drafts/<id>/translation` check it.

Each translation is its own `.tilla` file ([tilla.md](tilla.md)), which also carries the story-level fields so it stands alone. The worker writes every translation from the same draft, so the copies can't disagree; a change to a story-level field republishes every translation of the story.

| Field | Type | Meaning |
|---|---|---|
| `level` | `u8` | 1 A1 · 2 A2 · 3 B1 · 4 B2 · 5 C1 · 6 C2 |
| `genre` | `genre.id` | Exactly one; decides where the story sits in the app's shelves |
| `tags` | `tag.id` × 0 or more | What genre can't say: topic (`cibo`, `lavoro`), place (`sicilia`, `roma`), form (`dialogo`) |
| `author` | `author.id` | Original author (`collodi`); `''` for a story written for Postilla |
| `adapted` | 0/1 | 1 when the text is adapted from `author`'s work (Pinocchio), 0 when written for Postilla or used as is |
| `license` | text | SPDX id (`CC-BY-SA-4.0`), `public-domain`, or `LicenseRef-Postilla` (all rights reserved) |
| `work`, `part` | text, `u16` | `''` and 0 outside a work |
| `words` | count | Words in the translation, by the word rule in tilla.md |
| `band_words` | 4 counts | How many of `words` fall in each NVdB band ([Vocabulary coverage](#vocabulary-coverage)) |
| `audio_ms` | ms | Length of the translation's `.opus`; 0 without narration |

A story written for Postilla has `author` `''`, `adapted` 0 and `license` `LicenseRef-Postilla`. The app computes reading time from `words`; there is no `minutes` field.

Word data (`band_words`) exists only for Italian. A translation in any other language still lists its word spans, but its four `band_words` are 0. A language can be a target only once it has a dictionary, so for now Italian is the only target; Portuguese works as a native language from the start.

## Languages, genres, tags and authors

Four closed lists in `postilla.db`, edited by hand with SQL; there is no endpoint that changes them. Startup creates them with their initial rows ([Database](#database)).

- **`language`**: `id` (a BCP 47 tag of at most 8 ASCII bytes: `it`, `pt-BR`, later variants like `pt-PT` or dialects like `scn`), `name` (the language's own name, as language pickers show it, naming the variant where there is one: `Italiano`, `Português brasileiro`), `target` (1 when the language can be learned: it has a dictionary and a narration voice; today only `it`) and `translate` (1 when drafts are translated into it; today only `pt-BR`). `en` is a row too (`target` 0, `translate` 0), there for genre and tag names. Language ids are permanent: a row is never deleted and its `id` never changes, because every installed app sends its ids on each sync and an unknown one gets a 400. Triggers refuse both. `name` and `target` can change; `target` 0 only stops the app offering the language as something to learn, and learners already using it keep syncing.
- **`genre`** and **`tag`**: an `id` and a mandatory name in every language of `language`, one column per language, named by its id lowercased with `-` turned into `_` (`it`, `pt_br`, `en`). Adding a language adds a column to both tables, which is a schema migration and a `GNRS`/`TAGS` version bump. Removing a genre or tag that published stories still carry is allowed: their `.tilla` keeps the id.
- **`author`**: `id` and `name`. One name, because author names aren't translated. Authors are permanent: a row is never deleted and its id never changes (triggers refuse both), and only `name` can be corrected. Some licences (`CC-BY-SA-4.0`) require the author to be credited, so an author's name must always be available to the app.

Wherever a body lists a story's languages "in `language` order", that means the story's original first, then the other languages ascending by `id` (`it`, then `en`, `pt-BR`…).

`POST /drafts` and `PUT /drafts/<id>/header` check `genre`, `tags` and `author` against the tables, and an unknown id gets a 400. How the app caches the lists and handles an id it doesn't know: [app-handoff.md](app-handoff.md#7-genres-tags-and-authors).

Adding a language to `language` doesn't backfill: stories published before it keep the languages they had, so a story can lack the learner's native language (the app shows it target-only). The gap is filled the next time the story is edited or narrated: an `/edit` or `/narrate` copy that lacks a language with `translate` 1 first goes through `translating` for just those languages.

### `GET /genres`, `GET /tags`, `GET /authors`, `GET /languages`

Public, like `GET /stories`, with no parameters. Every response is `200`, `Content-Type: application/octet-stream`, and starts with the same header:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `GNRS`, `TAGS`, `AUTH` or `LANG` |
| `version` | `u8` | `1` |
| `count` | `u16` | Number of records that follow |

Then `count` records, ascending by `id`. `GNRS` and `TAGS` records:

| Field | Type | Value |
|---|---|---|
| `id` | `str` | Genre or tag id |
| `it` | `str` | Italian name |
| `pt_br` | `str` | Brazilian Portuguese name |
| `en` | `str` | English name |

`AUTH` records:

| Field | Type | Value |
|---|---|---|
| `id` | `str` | Author id |
| `name` | `str` | Author name |

`LANG` records:

| Field | Type | Value |
|---|---|---|
| `id` | `str` | Language id |
| `name` | `str` | The language's own name |
| `target` | `u8` | 1 when the language can be a target, 0 otherwise |
| `translate` | `u8` | 1 when stories are translated into it |

## Cursor

The cursor is a publish counter, a `u32`, kept per translation. Every change to a translation takes the next value (`max(cursor) + 1`, the first gets 1) from one sequence shared by every translation of every story, and stores it in the translation's row.

- A new translation gets a new cursor.
- A republished translation (same story and language, new sha256) gets a new cursor too, replacing its old one. Its old value is never reused, so the cursors in the table can have gaps.
- A republish of a translation with the same sha256 changes nothing and keeps its cursor. So an edit that leaves a translation unchanged (say, a Portuguese typo fix leaves the Italian alone) touches only the translations that changed.
- Removing a story gives every one of its translations a new cursor ([Removing a story](#delete-storiesid)).

So `cursor > X` is exactly "published, corrected or removed after the app's last sync". Which cursor the app stores is in [app-handoff.md](app-handoff.md#2-syncing).

Cursors are `max(cursor) + 1`, so a Litestream restore that loses the last seconds of publishes gives the next publishes the lost cursors again. A phone that synced in that window then misses translations until cursors pass its own. This is accepted: it takes a crash plus a sync in those seconds, and those phones catch up once new cursors pass the ones they had. The lost stories themselves have to be published again.

## Files in R2

All files are in one public bucket, keyed by story id, language and the sha256 of the file itself:

```
stories/<id>/<lang>/<sha256>.tilla.gz       one translation (tilla.md); sha256 of the .gz
stories/<id>/<lang>/<opus_sha256>.opus      its narration for the app: Ogg Opus, 16 kbps, mono
stories/<id>/<lang>/<flac_sha256>.flac      narration master: lossless, never downloaded by the app
dict/latest                                 pointer to the current dictionary (CONTRACT.md)
dict/<sha256>.db.gz                         a dictionary build
```

`<id>` is the UUID in its written form (`d0159518-99cc-46f0-bef2-b5b6f6f9a76d`), `<lang>` is the language id verbatim (`pt-BR`), and every `<sha256>` is 64 lowercase hex digits.

- A new version writes new keys, so no cache can serve a stale file. Every object can be served with `Cache-Control: public, max-age=31536000, immutable`.
- Nothing is ever deleted from R2. A republish leaves the previous `.tilla.gz`, `.opus` and `.flac` in place, and a removal leaves every file, so a phone never gets a 404 for a file the feed or a `.tilla` named.
- An edit that reuses the audio keeps its keys, so nothing is copied and no app downloads it again. The `.tilla` names its `.opus` by `opus_sha256`.
- The app builds each `.tilla.gz` URL from a feed record's `id`, `lang` and `sha256`, and the `.opus` URL from the `.tilla`.
- A translation without narration has no `.opus` or `.flac`; its `.tilla` has `audio_ms` 0.
- The `dict/` keys belong to the postilla-content build ([content-handoff.md](content-handoff.md#3-publishing-dictdb)); the backend only reads them, and the build never touches `stories/`.

## Endpoints

### Auth

The authoring endpoints (`/drafts` and everything under it, `POST /stories/<id>/edit`, `POST /stories/<id>/narrate`, `DELETE /stories/<id>`, `GET /published`) take `Authorization: Bearer <token>`, where the token is env `POSTILLA_AUTHOR_TOKEN`, compared in constant time. A missing or wrong token gets a 401 with an empty body, before the body is read. `GET /stories`, `GET /genres`, `GET /tags`, `GET /authors` and `GET /languages` are public.

The authoring clients are native, desktop and CLI apps, so the backend sends no CORS headers.

### Error bodies

Every 4xx except 401 carries a one-line English reason as `text/plain`, naming the rule and the field: `tags: unknown id 'rom'`, `story removed`. A 409 for a story with a draft in progress names that draft (`draft in progress: 42`), so a client whose `POST /drafts` or `/edit` response was lost can find the draft it created. A revision mismatch names the current revision (`draft changed: revision 7`). The authoring app shows the line as is. A 401 stays empty, so it reveals nothing before the token is checked. A 500 carries no body.

### `GET /stories?since=<cursor>&lang=<ids>`

`since` is a decimal `u32`. When it is missing it counts as 0, which returns every translation in the listed languages. Any other value gets a 400.

`lang` is required: 1 to 4 comma-separated language ids (`it,pt-BR`), each in `language`, with no duplicates and no empty items. A missing, empty or malformed `lang`, or an id not in `language`, gets a 400.

The response is `200`, `Content-Type: application/octet-stream`:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `FEED` |
| `version` | `u8` | `1` |
| `count` | `u32` | Number of records that follow |

Then `count` records, ascending by `cursor`, one per translation in the listed languages with a cursor above `since`:

| Field | Type | Value |
|---|---|---|
| `id` | `uuid` | Story id |
| `lang` | `lang` | The translation's language |
| `change` | `u8` | What happened last to that translation: 1 `published` (new or changed) or 2 `removed` |
| `sha256` | `sha256` | sha256 of the translation's `.tilla.gz`; all zero when `removed` |
| `cursor` | `u32` | The translation's cursor |

Each record is 61 bytes, so the body is `9 + 61 × count` bytes. When nothing is new the body is the 9-byte header with `count` 0. Removed translations are returned like any other, `since=0` included. What the app does with each record: [app-handoff.md](app-handoff.md#2-syncing).

### `DELETE /stories/<id>`

Removes a story: it tombstones every translation of the story at once, in one `BEGIN IMMEDIATE` transaction. Each `story` row is kept, its `change` set to `removed`, its `sha256` zeroed in the feed, and gets a new cursor, so a syncing app learns about it and deletes its copy. Nothing is deleted: the rows stay in `postilla.db`, and the `.tilla.gz`, `.opus` and `.flac` stay in R2. Removal is per story: a single translation can't be removed.

A removed id stays removed: `POST /drafts`, `POST /stories/<id>/edit` or `POST /stories/<id>/narrate` with it gets a 409 (`story removed`). Bringing a story back is on the [roadmap](roadmap.md#authoring-app).

No body. `<id>` is the story UUID in its written form.

| Case | Answer |
|---|---|
| Published story | 200 with no body, every translation tombstoned |
| Already removed | 200 with no body, nothing changes (no new cursor) |
| Story with a draft in progress | 409; discard the draft first, or it would republish the story |
| Unknown id | 404 |
| `<id>` not a UUID | 400 |
| Missing or wrong token | 401 |

### `GET /published`

Lists every story that has been published, removed ones included, so the authoring app can pick one to edit or remove. It reads each story's latest draft in state `published`, joined with its `story` rows; no titles are copied. The response is `200`, `application/octet-stream`:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `PUBL` |
| `version` | `u8` | `1` |
| `count` | `u32` | Number of stories that follow |

Then `count` stories, ascending by id:

| Field | Type | Value |
|---|---|---|
| `id` | `uuid` | Story id |
| `change` | `u8` | 1 `published` or 2 `removed` |
| `level` | `u8` | Level |
| `genre` | `str` | Genre id |
| `lang_count` | `u8` | Number of translations that follow |

Then `lang_count` translations, the original included, in `language` order, each a `lang` and a `title` (`str`).

## Drafts

A draft turns a story into a published one in steps. Each step except `review` and `listening` runs on a worker thread, and the draft's `state` records where it is:

```
moderating ──▶ rejected ──override──┐
    │                               │
    ▼                               ▼
translating ◀──retranslate── review ◀───────review──── listening
    │                          │  ▲                    ▲   │
    └─────────────────────────▶┘  │ (edit drafts      │   ├──renarrate──▶ narrating
                               approve  start here)    │   │
                                 │                     │   publish
                                 ├──▶ narrating ───────┘   ▼
                                 └───────────────────▶ publishing ──▶ published
```

- `approve` always goes to `narrating` for a `new` or `narrate` draft; for an `edit` draft, only when a narrated language's sentences changed, and straight to `publishing` otherwise, since there is nothing new to hear.
- On an `edit` draft whose Italian changed, `approve` goes through `moderating` first; a failing text goes back to `review` ([Moderation](#moderation)).
- Any step can also end in `failed`. The draft then stores the step that failed and its error, and `POST /drafts/<id>/resume` reruns that step.
- `POST /drafts/<id>/discard` drops a draft in `review`, `listening` or `failed` into `discarded`.
- `rejected` (unless overridden), `published` and `discarded` are final.

| Step | Service | What happens |
|---|---|---|
| `moderating` | Jev (`jev-1.13`, OpenCode key) | Decides whether the Italian text contains hate speech |
| `translating` | DeepSeek (`deepseek-v4.1-flash`, OpenCode key) | Translates the title, subtitle and every sentence into each language with `translate` 1 |
| `review` | You | Read the translations, then edit them, retranslate a language, or approve |
| `narrating` | Speechify (`simba-3.5`, Speechify key) | Narrates every translation in a language with `target` 1, with sentence times |
| `listening` | You | Listen to the narration, then publish, renarrate, or go back to review |
| `publishing` | R2 and the feed | Builds the files, uploads them, and takes the next cursors |

Only `review` and `listening` wait on you. Every other step starts as soon as the one before it ends, and the cursors increase only when `publishing` finishes.

Each draft has its own id, a `u32`. Its story id is a field of the draft. A story can have any number of drafts over time, such as its first version and later corrections, and finished drafts stay as history.

A story has at most one draft in progress, meaning in any state that isn't final. `POST /drafts`, `POST /stories/<id>/edit` and `POST /stories/<id>/narrate` get a 409 while the story has one (`draft in progress: 42`). Without this rule, two drafts would both publish and the later one would overwrite the earlier one's changes. To start over on a stuck draft, discard it first.

A draft has a `kind`, set when it is created:

| Value | Kind | Created by | Starts at |
|---|---|---|---|
| 1 | `new` | `POST /drafts` | `moderating` |
| 2 | `edit` | `POST /stories/<id>/edit` | `review` |
| 3 | `narrate` | `POST /stories/<id>/narrate` | `narrating` |

An `edit` or `narrate` copy that lacks a language with `translate` 1 starts at `translating` for just those languages instead, then goes to `review`; an approved `narrate` copy then narrates.

State values, as the `u8` the binary bodies carry:

| Value | State |
|---|---|
| 1 | `moderating` |
| 2 | `rejected` |
| 3 | `translating` |
| 4 | `review` |
| 5 | `narrating` |
| 6 | `listening` |
| 7 | `publishing` |
| 8 | `published` |
| 9 | `failed` |
| 10 | `discarded` |

### Concurrent edits

A draft has a `revision` (`u32`) that every change to it bumps, by a client or by the worker; `GET /drafts` and `GET /drafts/<id>` carry it. `PUT /drafts/<id>/translation` and `PUT /drafts/<id>/header` carry the revision they were based on; a mismatch gets a 409 (`draft changed: revision 7`), and the client reloads and reapplies. No edit is lost silently when two clients work on one draft.

### Retries

Each call to an outside service (OpenCode, Speechify, R2) is tried up to 3 times, waiting 5 s, 30 s, then 2 min between tries. A network error, a 429 or a 5xx counts as a failed try.

After the third failed try, the draft becomes `failed`. It stores the step that failed, the error, and the attempt count.

`POST /drafts/<id>/resume` reruns the failed step from scratch with a fresh try count. Work from earlier steps is kept: an approved translation is never redone, and a language that finished translating stays done.

### Moderation

The draft's Italian text (title, subtitle and sentences) goes to Jev in `state`, with one `choice` question. Its options are `none`, `homophobic`, `racist`, `sexist`, `religious` and `other_hate`, each described in the question's `criteria`.

- Jev returns a probability for each option and no explanation.
- The draft is `rejected` when `P(none)` is below the threshold: env `POSTILLA_MODERATION_THRESHOLD`, default `0.9`.
- The stored error names the option with the highest probability, so a rejection says what was flagged.
- Jev's docs don't say whether it reads Italian. A fixed test set of Italian texts, both clean and hateful, runs through Jev before this step is trusted, and stays as a regression check. If Jev handles Italian poorly, moderation moves to the Portuguese translation.

Request: `POST https://opencode.ai/inference/systemone/v1/systemone`, with `Authorization: Bearer $POSTILLA_OPENCODE_KEY`.

**Moderation of Italian edits.** When the Italian (title, subtitle or sentences) of an `edit` draft changed at `review`, `approve` answers at once and moves the draft to `moderating`, where the worker moderates the whole Italian text again, with the same request and threshold, so there's no new code path. If it fails, the draft goes back to `review` with the new scores and an error naming the change, instead of going on; if it passes, the draft continues as approve would have (`narrating` or `publishing`). An edit that leaves the Italian unchanged isn't moderated again. An `edit` draft starts at `review`, so it isn't moderated on creation: the editor is the reviewer.

**Override.** For a false positive, `POST /drafts/<id>/override` moves a `rejected` draft on to `translating`, or approves a draft held at `review` by re-moderation anyway. A `rejected` draft is final, so the story may have another draft in progress by then: override checks for one in the same `BEGIN IMMEDIATE` transaction as `POST /drafts`, and gets a 409 (`draft in progress: 42`) if there is. The scores stay stored, so an override is visible later in `GET /drafts/<id>`.

### Translation

The worker translates the draft into every language in `language` with `translate` 1 (today only `pt-BR`), one DeepSeek pass per language. It tracks each language separately: a language that finished stays done. After a failure, `resume` redoes only the languages without a finished translation, and the stored error names the language that failed (`pt-BR: paragraph 4: wrong sentence count`).

Each pass translates paragraph by paragraph, in reading order. It sends the title and subtitle first, as one extra two-sentence paragraph with the same request shape and length check, so every translation gets its own `title` and `subtitle` with no other code path. Each request carries one paragraph's Italian sentences, and the reply must be a JSON array of strings of the same length. That keeps the 1:1 sentence alignment the app needs (TRA-08).

- A reply that isn't a JSON array of strings, or has the wrong number of sentences, counts as a failed try (see [Retries](#retries)).
- After the third failed try the draft fails, and the error names the language and the paragraph.

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

### Review

At `review`, these endpoints are open:

- **Read:** `GET /drafts/<id>` returns the Italian and every translation.
- **Edit a language:** `PUT /drafts/<id>/translation` replaces one language's title, subtitle and sentences. The draft stays in `review`. On an `edit` draft the Italian can be edited too ([`PUT /drafts/<id>/translation`](#put-draftsidtranslation)).
- **Edit the header:** `PUT /drafts/<id>/header` replaces the story-level fields.
- **Retranslate:** `POST /drafts/<id>/retranslate?lang=<id>` discards that language only; the draft goes back to `translating`, and the worker redoes only that language.
- **Approve:** `POST /drafts/<id>/approve` freezes every translation at once, sends an edited Italian back through `moderating` first ([Moderation](#moderation)), and starts `narrating`, or `publishing` when nothing narrated changed. Narration and publishing run once per draft.

`GET /drafts?state=review` lists the drafts waiting for you.

### Narration

Only translations in a language with `target` 1 are narrated (today only the Italian original); learners listen in the language they are learning. When another language becomes a target, its translations are narrated too, with a Speechify voice per language.

An `edit` draft reruns narration only for a narrated language whose sentences changed; narration reads only the paragraphs, so a title, subtitle or header change doesn't count. Otherwise the published `.opus`, `.flac` and sentence times are reused, so a header fix or a Portuguese typo costs no Speechify credits.

One streamed call narrates one translation: `POST https://api.speechify.ai/v1/audio/stream/with-timestamps` (Server-Sent Events), with `Authorization: Bearer $POSTILLA_SPEECHIFY_KEY`. The request sets:

- `model` to `simba-3.5`
- `voice_id` to the language's voice: `daniele-agent` for `it`
- `language` to `it-IT` for `it`
- the highest-quality PCM that Speechify streams

That endpoint takes up to 20,000 spoken characters. `POST /drafts` already rejects a longer story.

The input is the translation's paragraphs joined in reading order. The worker reads the events:

- `speech.chunk` events carry the audio and word marks. Each mark has `start` and `end` (character offsets into the input) and `start_time` and `end_time` in ms.
- `speech.done` ends the stream.
- `speech.error`, or a dropped connection, counts as a failed try. The whole call is retried, since one stream can't resume halfway.

The stream yields three outputs:

- **Sentence times:** each sentence's `start_ms` and `end_ms` run from its first word's `start_time` to its last word's `end_time`. Words are matched to sentences by mapping the marks' character offsets onto the sentences.
- **App audio:** the PCM is encoded once with vendored libopus to the Ogg Opus `.opus` that tilla.md describes (16 kbps, mono). Its length is the translation's `audio_ms`.
- **Master:** the same PCM is also compressed to FLAC with vendored libFLAC. It is a lossless copy kept for re-encoding later. The app never downloads it.

When narration ends, the draft stores, per narrated language, the `.opus` and `.flac` as BLOBs with their sha256 and `audio_ms`, and each sentence's times, then stops at `listening`. So `listening` and publishing survive a restart.

### Listening

After `narrating`, a draft stops at `listening` instead of publishing. At `listening`:

- `GET /drafts/<id>/audio?lang=<id>` returns that language's `.opus` (`audio/ogg`). It answers in any state where the draft holds that audio (at `listening`, and at `review` or `failed` after it), not only here. `lang` must name a language with `target` 1, or the request gets a 400; a draft that holds no audio for it gets a 404 (`no audio: it`).
- `POST /drafts/<id>/publish` starts `publishing`.
- `POST /drafts/<id>/renarrate` discards the audio and goes back to `narrating`.
- `POST /drafts/<id>/review` takes the draft back to `review` with every edit, the audio and the sentence times kept. On the next approve, the edit rule applies: narration reruns only for a narrated language whose sentences changed (then `listening` again); otherwise the draft goes straight to `publishing`.
- `POST /drafts/<id>/discard` works as in `review`.

A draft whose narration didn't run (an edit with no sentence change) goes from `approve` straight to `publishing`, since there is nothing new to hear.

### Vocabulary coverage

`band_words` is four counts: how many of an Italian translation's `words` fall in each NVdB band, using `entry.band` from `dict.db` (0 outside · 1 fondamentale · 2 alto uso · 3 alta disponibilità). The four add up to `words`. Counts, not percentages, so they stay integers and the app computes the share.

A word takes the most common band among the lemmas its form leads to in `dict.db` (1 before 2 before 3 before 0): "porta" (*portare* 1, *porgere* 2) counts as band 1. A form with no lemma counts as band 0. The worker looks forms up the same way the app does on tap ([CONTRACT.md](CONTRACT.md)).

The worker gets `dict.db` the same way the app does. When a draft reaches `publishing`, it reads `dict/latest` from the public bucket, downloads that build into `POSTILLA_DICT_DIR` if it doesn't have it, and computes `band_words` from it. It keeps only the current build there and deletes older ones once it has switched. A new dictionary needs no restart. An R2 failure there is a failed try like any other R2 call. An older story's `band_words` reflect the bands at its publish time until it is republished.

A `.tilla` word is only a span, looked up by form; `dict.db` entry ids change between builds (ARQ-35) and nothing stores them, so a dictionary rebuild never touches a published story.

### Publishing

The worker writes one `.tilla` per translation ([tilla.md](tilla.md)): the story-level fields, the translation's title, subtitle and sentences, its word spans by the word rule in tilla.md, `words`, `band_words`, and, for a narrated translation, `audio_ms`, `opus_sha256`, `opus_size` and the sentence times. The gzip is deterministic, so an unchanged translation gives the same `.tilla.gz` and sha256.

It uploads every translation's `.tilla.gz`, and every new `.opus` and `.flac`, to R2 under the keys in [Files in R2](#files-in-r2). Audio reused from the published version is already there. Last, after every file is in R2, it upserts every translation's `story` row in one `BEGIN IMMEDIATE` transaction: a row whose sha256 changed, or that is new, gets `change` `published` and the next cursor; a row whose sha256 is the same keeps its cursor. So a syncing app sees all of a story's changed translations or none. Only then is the draft `published`, and its audio BLOBs are set to NULL, since R2 has the files; the sha256s, `audio_ms` and sentence times stay, because an edit draft copies them to reuse the audio. Discard sets the BLOBs to NULL too.

### `POST /drafts`

Starts a `new` draft from the story's header and its Italian sentences. Body:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `DNEW` |
| `version` | `u8` | `1` |
| `id` | `uuid` | Story id |
| `title` | `str` | Title |
| `subtitle` | `str` | Subtitle |
| `level` | `u8` | 1 A1 · 2 A2 · 3 B1 · 4 B2 · 5 C1 · 6 C2 |
| `genre` | `str` | A `genre.id` |
| `tag_count` | `u16` | Number of tags that follow |
| `tags` | `str` × `tag_count` | `tag.id`s |
| `work` | `str` | Work name; `''` outside a work |
| `part` | `u16` | Part of the work; 0 outside a work |
| `author` | `str` | An `author.id`; `''` for a story written for Postilla |
| `adapted` | `u8` | 1 when adapted from `author`'s work, 0 otherwise |
| `license` | `str` | SPDX id, `public-domain`, or `LicenseRef-Postilla` |
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
4. `title`, `subtitle`, `genre` and `license` are not empty; `license` is ASCII; `level` is 1 to 6; `adapted` is 0 or 1.
5. `work` is empty exactly when `part` is 0.
6. No tag is empty or repeated.
7. `adapted` is 1 only when `author` is not empty.
8. `paragraph_count` is at least 1, every `sentence_count` is at least 1, and no sentence is empty.
9. The story is at most 20,000 characters, the narration limit.

Past the parse, an unknown `genre`, tag or `author` gets a 400 (`genre: unknown id 'giallo'`), a removed story id a 409 (`story removed`), and a story with a draft in progress a 409 (`draft in progress: 42`).

The response is `202`, and its body is the new draft id as a `u32`. The worker starts `moderating`.

A draft for a story id that is already published counts as a republish: on publish, every changed translation gets a new cursor (see [Cursor](#cursor)). A rewrite that adds or removes paragraphs is a new `POST /drafts` with the same id, which runs the whole pipeline.

### `POST /stories/<id>/edit`

Copies the story's latest published draft (header, and every language's title, subtitle and sentences, with the audio's sha256s, `audio_ms` and sentence times) into a new `edit` draft that starts at `review`, and answers `202` with the draft id as a `u32`, like `POST /drafts`. No body. `<id>` is the story UUID in its written form.

The copy checks the header against the current lists: tags no longer in `tag` are dropped, since they're optional (authors are permanent, so the author always carries over). A genre no longer in `genre` is kept, and `approve` gets a 409 until `PUT /drafts/<id>/header` sets a listed one. So a republished story only ever carries listed ids.

At `review`, `PUT /drafts/<id>/translation` edits any language, the Italian included, and `PUT /drafts/<id>/header` replaces the header; `POST /drafts/<id>/approve` republishes, as for any draft. Moderation doesn't rerun unless the Italian changed ([Moderation](#moderation)).

A story id that isn't published gets a 404, a removed one a 409, and a story with a draft in progress a 409.

### `POST /stories/<id>/narrate`

Narrates a published story again, when its text hasn't changed. It copies the story's latest published draft like `/edit`, into a new `narrate` draft that starts at `narrating`: it narrates every translation in a language with `target` 1 (today only `it`), then stops at `listening`. The new audio replaces the old on publish. If the story lacks a language with `translate` 1, the copy goes through `translating` and `review` for it first, and approve then narrates.

No body. The response is `202` with the new draft id as a `u32`. A story id that isn't published gets a 404, a removed one a 409, and a story with a draft in progress a 409.

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
| `kind` | `u8` | 1 `new` · 2 `edit` · 3 `narrate` |
| `revision` | `u32` | Current revision |
| `title` | `str` | Italian title |

### `GET /drafts/<id>`

The response is `200`:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `DRFT` |
| `version` | `u8` | `1` |
| `draft_id` | `u32` | Draft id |
| `id` | `uuid` | Story id |
| `state` | `u8` | Current state |
| `kind` | `u8` | 1 `new` · 2 `edit` · 3 `narrate` |
| `failed_step` | `u8` | The state that failed, when `state` is `failed`; 0 otherwise |
| `attempts` | `u8` | Tries made by the current or failed step |
| `error` | `str` | Stored error; `''` when there is none |
| `moderation` | `u16` × 6 | Probabilities of `none`, `homophobic`, `racist`, `sexist`, `religious`, `other_hate`, in thousandths (0 to 1000); all 0 before moderation |
| `revision` | `u32` | Current revision |
| `title` | `str` | Italian title |
| `subtitle` | `str` | Italian subtitle |
| `level` | `u8` | Level |
| `genre` | `str` | Genre id |
| `tag_count` | `u16` | Number of tags that follow |
| `tags` | `str` × `tag_count` | Tag ids |
| `work` | `str` | Work name |
| `part` | `u16` | Part |
| `author` | `str` | Author id |
| `adapted` | `u8` | Adapted |
| `license` | `str` | License |
| `lang_count` | `u8` | Number of translated languages that follow |

Then `lang_count` translated languages, in `language` order:

| Field | Type | Value |
|---|---|---|
| `lang` | `lang` | Language |
| `title` | `str` | Title in that language; `''` before translation |
| `subtitle` | `str` | Subtitle in that language; `''` before translation |

Then the text:

| Field | Type | Value |
|---|---|---|
| `paragraph_count` | `u16` | Number of paragraphs that follow |

Each paragraph is a `sentence_count` (`u16`) followed by that many sentences. Each sentence is the Italian `str`, then one `str` per translated language, in the order listed above. Sentence counts follow the Italian: a language not yet translated for a sentence (a new draft, a retranslated language, or an edited Italian paragraph waiting for `translating`) carries `''`.

### `PUT /drafts/<id>/translation`

Replaces one language's title, subtitle and sentences. Body:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `TRNS` |
| `version` | `u8` | `1` |
| `lang` | `lang` | The language being replaced |
| `revision` | `u32` | The revision this edit is based on |
| `title` | `str` | Title, not empty |
| `subtitle` | `str` | Subtitle, not empty |
| `paragraph_count` | `u16` | Must equal the draft's |

Then each paragraph: a `sentence_count` (`u16`), followed by that many `str` sentences, none empty. No bytes may be left after the last paragraph.

- `lang` is the draft's original (`it`) or one of its translated languages; any other gets a 400.
- A translation must keep every paragraph's sentence count equal to the Italian's, or the request gets a 400.
- The Italian can be edited only on an `edit` draft (a 409 on others). It must keep `paragraph_count` (a 400 otherwise), but may change a paragraph's sentence count: the draft then goes to `translating` for just those paragraphs, in every other language (one DeepSeek request per paragraph, as above), keeping every edit elsewhere, and comes back to `review`.
- A `revision` that isn't the draft's gets a 409 (`draft changed: revision 7`).
- The draft must be at `review`; any other state gets a 409.

A body that fails the parse gets a 400. The response is `200` with no body, and the draft's revision goes up by one.

### `PUT /drafts/<id>/header`

Replaces the story-level fields. Body:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `HEDR` |
| `version` | `u8` | `1` |
| `revision` | `u32` | The revision this edit is based on |
| `level` | `u8` | 1 to 6 |
| `genre` | `str` | A `genre.id` |
| `tag_count` | `u16` | Number of tags that follow |
| `tags` | `str` × `tag_count` | `tag.id`s |
| `work` | `str` | Work name; `''` outside a work |
| `part` | `u16` | Part of the work; 0 outside a work |
| `author` | `str` | An `author.id` or `''` |
| `adapted` | `u8` | 0 or 1 |
| `license` | `str` | License |

The parse applies the header rules of `POST /drafts` (4 to 7, without `title` and `subtitle`, which `PUT /drafts/<id>/translation` edits), and no bytes may be left after `license`. An unknown `genre`, tag or `author` gets a 400; a `revision` that isn't the draft's, or a draft not at `review`, gets a 409. The response is `200` with no body, and the draft's revision goes up by one.

### Draft actions

No body. The response is `200` with no body.

| Endpoint | Needs | Does |
|---|---|---|
| `POST /drafts/<id>/retranslate?lang=<id>` | `review` | Discards that language and goes back to `translating`. `lang` is required and must name a language with `translate` 1 that the draft has; a missing `lang`, `it` or any other id gets a 400 |
| `POST /drafts/<id>/approve` | `review` | See [Review](#review); a genre no longer in `genre` gets a 409 |
| `POST /drafts/<id>/override` | `rejected` (and no other draft of the story in progress), or `review` held by re-moderation | Goes on to `translating`, or approves anyway |
| `POST /drafts/<id>/publish` | `listening` | Starts `publishing` |
| `POST /drafts/<id>/renarrate` | `listening` | Discards the audio and goes back to `narrating` |
| `POST /drafts/<id>/review` | `listening` | Back to `review`, keeping edits, audio and sentence times |
| `POST /drafts/<id>/resume` | `failed` | Reruns the failed step |
| `POST /drafts/<id>/discard` | `review`, `listening` or `failed` | Drops the draft into `discarded`. A draft that a worker is running can't be discarded until it stops |

Any other state gets a 409.

### Status codes

| Code | When |
|---|---|
| 200 | Success |
| 202 | Draft created |
| 400 | Bad `since`, `lang` or `state`; a story id that isn't a UUID; a body that fails the parse (including a translation edit that changes a sentence count it may not); an unknown genre, tag or author |
| 401 | Missing or wrong bearer token on an authoring endpoint |
| 404 | Any other path, an unknown or non-numeric draft id, audio a draft doesn't hold, or a story id that isn't published on `/edit`, `/narrate` or `DELETE` |
| 405 | Any other method on a known path |
| 409 | An action on a draft that isn't in the state it needs; a new draft for a story that already has one in progress or that was removed; a revision mismatch; `DELETE` of a story with a draft in progress; `approve` with a genre no longer listed |
| 500 | SQLite error |

## Database

```sql
CREATE TABLE story (
  id        BLOB NOT NULL,              -- 16 bytes
  lang      TEXT NOT NULL REFERENCES language(id),
  sha256    BLOB NOT NULL,              -- 32 bytes of the .tilla.gz; kept when removed
  has_opus  INTEGER NOT NULL,           -- 0 or 1
  change    INTEGER NOT NULL,           -- 1 published, 2 removed
  cursor    INTEGER NOT NULL UNIQUE,
  PRIMARY KEY (id, lang)
) WITHOUT ROWID;

CREATE TABLE genre (
  id       TEXT PRIMARY KEY,   -- classici
  it       TEXT NOT NULL,      -- Classici
  pt_br    TEXT NOT NULL,      -- Clássicos
  en       TEXT NOT NULL       -- Classics
) WITHOUT ROWID;
CREATE TABLE tag (
  id       TEXT PRIMARY KEY,   -- cibo
  it       TEXT NOT NULL,      -- Cibo
  pt_br    TEXT NOT NULL,      -- Comida
  en       TEXT NOT NULL       -- Food
) WITHOUT ROWID;
CREATE TABLE author (
  id       TEXT PRIMARY KEY,   -- collodi
  name     TEXT NOT NULL       -- Carlo Collodi
) WITHOUT ROWID;
CREATE TRIGGER author_keep BEFORE DELETE ON author
BEGIN SELECT RAISE(ABORT, 'author ids are permanent'); END;
CREATE TRIGGER author_id_fixed BEFORE UPDATE OF id ON author
BEGIN SELECT RAISE(ABORT, 'author ids are permanent'); END;
CREATE TABLE language (
  id       TEXT PRIMARY KEY CHECK (length(id) <= 8),   -- it
  name     TEXT NOT NULL,      -- Italiano
  target   INTEGER NOT NULL,   -- 0 or 1
  translate INTEGER NOT NULL   -- 0 or 1
) WITHOUT ROWID;
CREATE TRIGGER language_keep BEFORE DELETE ON language
BEGIN SELECT RAISE(ABORT, 'language ids are permanent'); END;
CREATE TRIGGER language_id_fixed BEFORE UPDATE OF id ON language
BEGIN SELECT RAISE(ABORT, 'language ids are permanent'); END;
```

`story` holds one row per translation: the feed. The story-level fields and the titles aren't copied there; they live in the drafts and in the `.tilla` files. The `UNIQUE` on `cursor` gives the index the GET query uses (`WHERE cursor > ? AND lang IN (…) ORDER BY cursor`). A removed row keeps its last `sha256`, and `FEED` sends zeros for it.

A publish runs in one `BEGIN IMMEDIATE` transaction: read the story's current rows, then, for each translation whose sha256 differs or whose row is new, read `coalesce(max(cursor), 0) + 1` and upsert. A removal runs the same way, setting `change` to 2 and a new cursor on every row of the story. The write lock keeps two concurrent publishes from taking the same cursor.

Startup creates the schema and inserts the initial rows with `INSERT OR IGNORE`, so a fresh `postilla.db` works with no manual step. Later rows are added by hand with SQL.

| Table | Initial rows |
|---|---|
| `language` | `it` Italiano (target 1, translate 0) · `pt-BR` Português brasileiro (0, 1) · `en` English (0, 0) |
| `genre` (`id`: `it` / `pt_br` / `en`) | `quotidiano`: Quotidiano / Cotidiano / Everyday · `famiglia`: Famiglia / Família / Family · `viaggio`: Viaggio / Viagem / Travel · `mistero`: Mistero / Mistério / Mystery · `lettere`: Lettere / Cartas / Letters · `racconto`: Racconto / Conto / Short story · `classici`: Classici / Clássicos / Classics |
| `author` | `collodi` Carlo Collodi |
| `tag` | none yet |

The drafts live in their own tables; the exact columns are left to the implementation. They hold:

- per draft: its id, story id, `kind`, `revision`, the header fields and tags, `state`, failed step, attempt count, error, moderation probabilities, and whether the held review comes from re-moderation;
- per draft and language: the title and subtitle, and whether that language's translation is done;
- per sentence, keyed by draft, paragraph, position and language: the text, and for a narrated language its `start_ms` and `end_ms`;
- per draft and narrated language (`draft_audio`): the `.opus` and `.flac` BLOBs (NULL once published or discarded), their sha256s and `audio_ms`. About 0.5 MB of `.opus` for a 4-minute story at 16 kbps.

Creating a draft checks for a draft in progress and for a removed story, and inserts the new one, in the same `BEGIN IMMEDIATE` transaction, so two requests at once can't both pass the check.

## Configuration

Everything comes from env, read and checked once at startup. A missing required value stops the server before it binds.

[`.env.example`](../.env.example) lists every variable with its default. Copy it to `.env`, which git ignores. The same file works as the systemd `EnvironmentFile`.

| Variable | Default | What it is |
|---|---|---|
| `POSTILLA_PORT` | `8080` | HTTP port |
| `POSTILLA_BIND` | `127.0.0.1` | Bind address; TLS is the reverse proxy's job |
| `POSTILLA_DB` | `./postilla.db` | SQLite path |
| `POSTILLA_DICT_DIR` | `./dict` | Where the worker caches the current `dict.db` build |
| `POSTILLA_AUTHOR_TOKEN` | required | Bearer token for every authoring endpoint |
| `POSTILLA_OPENCODE_KEY` | required | OpenCode key, for Jev and DeepSeek |
| `POSTILLA_SPEECHIFY_KEY` | required | Speechify key |
| `POSTILLA_R2_ACCOUNT_ID` | required | Cloudflare account id |
| `POSTILLA_R2_ACCESS_KEY_ID` | required | R2 S3 access key id |
| `POSTILLA_R2_SECRET_ACCESS_KEY` | required | R2 S3 secret key |
| `POSTILLA_R2_BUCKET` | required | The public bucket: stories and the dictionary |
| `POSTILLA_MODERATION_THRESHOLD` | `0.9` | Minimum `P(none)` to pass moderation |

## Process

- A self-contained Zig project in `backend/`, with its own `build.zig` and `build.zig.zon`. It vendors the same SQLite amalgamation as the pipeline.
- Thread per connection on `std.http.Server`. Each thread opens its own SQLite connection; the database runs in WAL mode with a busy timeout so reads never block on a publish.
- Draft steps run on worker threads, never on a request thread. A draft caught mid-step by a restart is resumed from its stored `state`.
- Vendored C libraries, besides SQLite: libopus and libFLAC. It also needs HTTPS client calls to OpenCode, Speechify and R2, and SigV4 signing for the R2 uploads and downloads.

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
