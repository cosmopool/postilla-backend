# Story feed backend

Tells the app which story translations were published or removed since it last asked. The app sends the newest cursor it has and the languages it reads; the backend answers with one record per changed translation. The app then downloads each published translation (`.tilla.gz`, and its `.opus` when it has narration; format in [tilla.md](tilla.md)) from the R2 bucket.

The backend never serves story files. They live in Cloudflare R2; the backend only holds their metadata in a local SQLite (`postilla.db`), and every R2 key follows from it.

v1.0 is two executables built from this repo:

- **`postilla-server`**, on the VPS: the feed and the lists, `POST /stories` to publish a story and `DELETE /stories/<id>` to remove one ([Endpoints](#endpoints)).
- **`postilla`**, a CLI on your machine: it moderates, translates and narrates a story from a story folder, builds its files, uploads them to R2 and publishes them with `POST /stories` ([The CLI](#the-cli)).

Server-side drafts, edits of published stories and an authoring app are v1.2 ([roadmap.md](roadmap.md#v12-drafts)).

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
| `STRY` | `POST /stories` request |

The same layouts are in machine-readable form: [openapi.yaml](openapi.yaml) for the endpoints, and one Kaitai Struct file per body in [formats/](formats/) (`feed.ksy`, `gnrs.ksy`, `tags.ksy`, `auth.ksy`, `lang.ksy`, `stry.ksy`; shared types in `postilla_str.ksy` and `postilla_enums.ksy`).

The app isn't published yet, so these formats changed in place and kept version 1. After launch, a format changes only with a version bump, and the backend bumps a version only together with an app release that reads it ([app-handoff.md](app-handoff.md#9-format-versions-and-errors)).

## Stories and translations

A story is split by language, so that any two of its languages can be the learner's target and native language (Italian for a Brazilian today, Portuguese for an Italian later).

- **Story-level fields** don't depend on language: `id`, `original` (the language it was written in, always `it` today), `level`, `genre`, `tags`, `author`, `adapted`, `license`, `work`, `part`. `level` is the original's; translations are written to the same level.
- **Translation fields** depend on it: `title`, `subtitle`, the sentences, `words`, `band_words`, `audio_ms` and the narration. The original is the translation whose language is `original`.

Every translation of a story has the same paragraph count and, paragraph by paragraph, the same sentence count, so paragraph *p*, sentence *s* means the same thing in every language and any two translations line up by index. `postilla translate` and `postilla publish` check it.

Each translation is its own `.tilla` file ([tilla.md](tilla.md)), which also carries the story-level fields so it stands alone. `postilla publish` writes every translation from the same `story.json`, so the copies can't disagree; a change to a story-level field republishes every translation of the story.

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

- **`language`**: `id` (a BCP 47 tag of at most 8 ASCII bytes: `it`, `pt-BR`, later variants like `pt-PT` or dialects like `scn`), `name` (the language's own name, as language pickers show it, naming the variant where there is one: `Italiano`, `Português brasileiro`), `target` (1 when the language can be learned: it has a dictionary and a narration voice; today only `it`) and `translate` (1 when stories are translated into it; today only `pt-BR`). `en` is a row too (`target` 0, `translate` 0), there for genre and tag names. Language ids are permanent: a row is never deleted and its `id` never changes, because every installed app sends its ids on each sync and an unknown one gets a 400. Triggers refuse both. `name` and `target` can change; `target` 0 only stops the app offering the language as something to learn, and learners already using it keep syncing.
- **`genre`** and **`tag`**: an `id` and a mandatory name in every language of `language`, one column per language, named by its id lowercased with `-` turned into `_` (`it`, `pt_br`, `en`). Adding a language adds a column to both tables, which is a schema migration and a `GNRS`/`TAGS` version bump. Removing a genre or tag that published stories still carry is allowed: their `.tilla` keeps the id.
- **`author`**: `id` and `name`. One name, because author names aren't translated. Authors are permanent: a row is never deleted and its id never changes (triggers refuse both), and only `name` can be corrected. Some licences (`CC-BY-SA-4.0`) require the author to be credited, so an author's name must always be available to the app.

Wherever a list of a story's languages is "in `language` order", that means the story's original first, then the other languages ascending by `id` (`it`, then `en`, `pt-BR`…).

`postilla publish` checks a story's `genre`, `tags` and `author` against `GET /genres`, `GET /tags` and `GET /authors`, and its languages against `GET /languages`, and stops on an unknown id. The server checks only the languages, the one list `POST /stories` carries. How the app caches the lists and handles an id it doesn't know: [app-handoff.md](app-handoff.md#7-genres-tags-and-authors).

Adding a language to `language` doesn't backfill: stories published before it keep the languages they had, so a story can lack the learner's native language (the app shows it target-only). The gap is filled the next time the story is published: `postilla translate` fills in every missing language with `translate` 1, and `postilla publish` requires them.

### `GET /version`

Public, with no parameters. The answer is `200`, `Content-Type: text/plain`: the latest tag reachable from the commit the binary was built from, a space, the commit's 40 hex digits (with `-dirty` after them when the tree had uncommitted changes), and a newline, the same text `postilla-server --version` prints after its name: `v0.2.4 0ea4bfc21459e68c5a0a2250c44a128ff38ec8b6`. It says what a server runs; the deploy's smoke test compares it with the tag it deployed (`infra/smoke.sh`).

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
- A republish of a translation with the same sha256 changes nothing and keeps its cursor. So a republish that leaves a translation unchanged (say, a Portuguese typo fix leaves the Italian alone) touches only the translations that changed.
- Removing a story gives every one of its translations a new cursor ([Removing a story](#delete-storiesid)).

So `cursor > X` is exactly "published, corrected or removed after the app's last sync". Which cursor the app stores is in [app-handoff.md](app-handoff.md#2-syncing).

Cursors are `max(cursor) + 1`, so a Litestream restore that loses the last seconds of publishes gives the next publishes the lost cursors again. A phone that synced in that window then misses translations until cursors pass its own. This is accepted: it takes a crash plus a sync in those seconds, and those phones catch up once new cursors pass the ones they had. The lost stories themselves have to be published again.

## Files in R2

All files are in one public bucket, keyed by story id, language and a sha256 of the content:

```
stories/<id>/<lang>/<sha256>.tilla.gz       one translation (tilla.md); sha256 of the .tilla before gzip
stories/<id>/<lang>/<opus_sha256>.opus      its narration for the app: Ogg Opus, 16 kbps, mono
stories/<id>/<lang>/<flac_sha256>.flac      narration master: lossless, never downloaded by the app
dict/latest                                 pointer to the current dictionary (CONTRACT.md)
dict/<sha256>.db.gz                         a dictionary build
```

`<id>` is the UUID in its written form (`d0159518-99cc-46f0-bef2-b5b6f6f9a76d`), `<lang>` is the language id verbatim (`pt-BR`), and every `<sha256>` is 64 lowercase hex digits.

- A new version writes new keys, so no cache can serve a stale file. Every object can be served with `Cache-Control: public, max-age=31536000, immutable`.
- Nothing is ever deleted from R2. A republish leaves the previous `.tilla.gz`, `.opus` and `.flac` in place, and a removal leaves every file, so a phone never gets a 404 for a file the feed or a `.tilla` named.
- A republish whose audio didn't change gives the same `.opus` and `.flac` keys, so no app downloads them again. The `.tilla` names its `.opus` by `opus_sha256`.
- The app builds each `.tilla.gz` URL from a feed record's `id`, `lang` and `sha256`, and the `.opus` URL from the `.tilla`.
- A translation without narration has no `.opus` or `.flac`; its `.tilla` has `audio_ms` 0.
- The CLI talks to R2's S3 API (`src/r2.zig`) at `https://<account>.r2.cloudflarestorage.com` (or `POSTILLA_R2_ENDPOINT` when set), path-style (`/<bucket>/<key>`), signing every request with SigV4: region `auto`, service `s3`, signed headers `host;x-amz-content-sha256;x-amz-date`, and `x-amz-content-sha256` set to the body's hex sha256. Every object goes up in one PUT, with `Content-Type` by extension (`.tilla.gz` `application/gzip`, `.opus` `audio/ogg`, `.flac` `audio/flac`), the immutable `Cache-Control` above, and never a `Content-Encoding`: a client would gunzip the `.tilla.gz` and its sha256 check would fail.
- `stories/` is written only by `postilla publish`; the server never touches R2. The `dict/` keys belong to the postilla-content build ([content-handoff.md](content-handoff.md#4-publishing-dictdb)); the CLI only reads them, and the build never touches `stories/`.

## Endpoints

### Auth

`POST /stories` and `DELETE /stories/<id>` take `Authorization: Bearer <token>`, where the token is env `POSTILLA_AUTHOR_TOKEN`, compared in constant time (both sides hashed with SHA-256, the digests compared with `std.crypto.timing_safe.eql`). The scheme is matched case-insensitively and followed by one space. A missing or wrong token, or another scheme, gets a 401 with an empty body, before the body is read. The route (path and method) is matched first, so an unknown path or method is a 404 with no token check; then the token; then the body. A write's connection closes after its answer, so a body that went unread is never taken for the next request. `GET /stories`, `GET /genres`, `GET /tags`, `GET /authors` and `GET /languages` are public.

The authoring client is the `postilla` CLI, so the backend sends no CORS headers.

### Error bodies

Every 4xx except 401 carries a one-line English reason as `text/plain`, naming the rule and the field: `lang: unknown id 'fr'`, `story removed`. A 409 for a published translation missing from a `POST /stories` body names the language (`pt-BR: published, missing from body`). The CLI prints the line as is. A 401 stays empty, so it reveals nothing before the token is checked. A 500 carries no body.

### `GET /stories?since=<cursor>&lang=<ids>`

`since` is a decimal `u32`: 1 to 10 ASCII digits, leading zeros allowed. When it is missing it counts as 0, which returns every translation in the listed languages. Any other value (empty, signed, a space or any other byte) gets a 400 `since: not a u32`.

`lang` is required: 1 to 4 comma-separated language ids (`it,pt-BR`), each in `language` (compared byte for byte), with no duplicates and no empty items. The 400 reasons are `lang: missing`, `lang: empty id`, `lang: more than 4 ids`, `lang: duplicate id 'it'` and `lang: unknown id 'fr'`. Unknown parameters are ignored; a repeated `since` or `lang` gets a 400 `since: repeated` or `lang: repeated`.

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
| `sha256` | `sha256` | sha256 of the translation's `.tilla`, before gzip; all zero when `removed` |
| `cursor` | `u32` | The translation's cursor |

Each record is 61 bytes, so the body is `9 + 61 × count` bytes. When nothing is new the body is the 9-byte header with `count` 0. Removed translations are returned like any other, `since=0` included. What the app does with each record: [app-handoff.md](app-handoff.md#2-syncing).

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

### `DELETE /stories/<id>`

Removes a story: it tombstones every translation of the story at once, in one `BEGIN IMMEDIATE` transaction. Each `story` row is kept, its `change` set to `removed`, its `sha256` zeroed in the feed, and gets a new cursor, so a syncing app learns about it and deletes its copy. Nothing is deleted: the rows stay in `postilla.db`, and the `.tilla.gz`, `.opus` and `.flac` stay in R2. Removal is per story: a single translation can't be removed.

A removed id stays removed: `POST /stories` with it gets a 409 (`story removed`). Bringing a story back is on the [roadmap](roadmap.md#authoring-app).

No body; any body sent is ignored. `<id>` is the story UUID in its written form, hex in either case; a trailing slash or another segment after it is an unknown path (404).

| Case | Answer |
|---|---|
| Published story | 200 with no body, every translation tombstoned |
| Already removed | 200 with no body, nothing changes (no new cursor) |
| Unknown id | 404 `not found` |
| `<id>` not a UUID | 400 `id: not a UUID` |
| Missing or wrong token | 401 |

### Status codes

| Code | When |
|---|---|
| 200 | Success |
| 400 | Bad `since` or `lang`; a story id that isn't a UUID; a body that fails the parse; a `lang` not in `language` |
| 401 | Missing or wrong bearer token on `POST /stories` or `DELETE /stories/<id>` |
| 404 | Any other path or method, or an unknown story id on `DELETE` |
| 409 | `POST /stories` for a removed story, or without one of the story's published translations |
| 500 | SQLite error |

## The CLI

`postilla <command> <folder>` works on one story folder. Each command reads `story.json` in the folder and writes its results back there, so the folder is the state between commands: any command can be rerun on its own, and you read and edit the files between them. Keep the story folders in git.

```
postilla translate <folder> [--force] [--redo <lang>]   moderate the Italian, translate the missing languages
postilla narrate   <folder>                             narrate every language with target 1
postilla publish   <folder>                             build the .tilla files, upload to R2, POST /stories
```

The CLI reads the lists from the server's public endpoints (`GET /languages`, `GET /genres`, `GET /tags`, `GET /authors` at `POSTILLA_SERVER_URL`), so it never needs `postilla.db`. A command that fails prints one line naming the step and the reason and exits non-zero, leaving `story.json` as it was before that step. The exit code is 0 on success, 1 on any failure and 2 for a usage error (an unknown command, a missing folder, an unknown or repeated flag, or `--redo` without a language). `postilla --help` (or `-h`, or `help`) prints what each command does, the story folder, the configuration and the exit codes to stdout and exits 0; a usage error prints the short usage to stderr and points to `--help`. `postilla --version` prints `postilla <version>` to stdout and exits 0 ([Process](#process)).

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

Translates the story into every language with `translate` 1 (today only `pt-BR`) that `translations` lacks. A rerun never overwrites a translation already there, so hand edits survive it. `--redo <lang>` first drops that language, which must be one with `translate` 1 (any other, `it` included, stops the command before any request), then translates it again; the new translation goes after the other languages. When there is nothing to translate, the command does nothing, not even moderation, and `story.json` stays byte for byte as it was.

`story.json` is written once after moderation (the scores, also on a rejection), then once after each finished language, as `story.json.tmp` renamed over `story.json`, so a crash never leaves half a file. It is written with `std.json` at two-space indent, in the field order it was read in: a hand layout is reformatted on the first write.

**Moderation** runs first, every time the command translates something. The Italian text goes to Jev (`jev-1.13`, OpenCode key) in `state`: the title, the subtitle, then each paragraph's sentences joined by one space, each on its own line. It carries one `choice` question, `hate`, with `instructions` `Does this Italian text contain hate speech? Pick the kind, or none.` Its options are `none`, `homophobic`, `racist`, `sexist`, `religious` and `other_hate`, each described in the question's `criteria`:

| Option | Criterion |
|---|---|
| `none` | No hate speech: the text attacks no group for who they are |
| `homophobic` | Attacks or demeans people for their sexual orientation or gender identity |
| `racist` | Attacks or demeans people for their race, ethnicity or nationality |
| `sexist` | Attacks or demeans people for their sex or gender |
| `religious` | Attacks or demeans people for their religion |
| `other_hate` | Attacks or demeans another protected group, such as disabled people |

- Jev returns a probability for each option and no explanation.
- The text is rejected when `P(none)` is below the threshold: env `POSTILLA_MODERATION_THRESHOLD`, default `0.9`. A threshold that isn't a number from 0 to 1 stops the command, naming the variable, before any request.
- The scores are written to `moderation` either way. On a rejection the command prints the six scores and the option other than `none` with the highest probability, so a rejection says what was flagged, and exits non-zero without translating.
- `--force` is the override for a false positive: the command moderates again, writes the scores with `forced` true, and translates anyway. A text that passes writes `forced` false, with or without `--force`.
- A reply that isn't Jev's JSON with the `hate` answer and all six probabilities stops the command (`moderation: <reason>`), as does a failed call (see [Retries](#retries)).
- Jev's docs don't say whether it reads Italian. A fixed test set of Italian texts, both clean and hateful, runs through Jev before this step is trusted, and stays as a regression check. If Jev handles Italian poorly, moderation moves to the Portuguese translation.

Request: `POST $POSTILLA_OPENCODE_URL/systemone/v1/systemone`, with `Authorization: Bearer $POSTILLA_OPENCODE_KEY` and `user-agent: postilla/1.0`.

**Translation** uses DeepSeek (`deepseek-v4.1-flash`, OpenCode key), one pass per language. A language is written into `story.json` only once all of it is done, so after a failure a rerun redoes only the languages without a finished translation, and the error names the language that failed (`pt-BR: paragraph 4: wrong sentence count`).

Each pass translates paragraph by paragraph, in reading order. It sends the title and subtitle first, as one extra two-sentence paragraph with the same request shape and length check, so every translation gets its own `title` and `subtitle` with no other code path. Each request carries one paragraph's Italian sentences, and the reply must be a JSON array of strings of the same length. That keeps the 1:1 sentence alignment the app needs (TRA-08).

- A paragraph gets 3 tries. Each is one full call (with its own retries, see [Retries](#retries)); a reply whose `choices[0].message.content` isn't a JSON array of strings (code fences included), or has the wrong number of sentences, starts the next try at once.
- After the third failed try the command stops with `<lang>: paragraph <n>: <reason>`, `n` counting from 1 and the title paragraph 0. A call that fails (any status but 200 once its retries are spent) stops it at once, naming the language and the status.

OpenCode Zen documents no JSON mode for this model, so the length check above is the only guarantee.

Request: `POST $POSTILLA_OPENCODE_URL/go/v1/chat/completions` (OpenCode Go, OpenAI-compatible), with `Authorization: Bearer $POSTILLA_OPENCODE_KEY`, `user-agent: postilla/1.0` and `x-opencode-session`, one random UUID per command run, the same on every DeepSeek request. The request sets `model` to `deepseek-v4.1-flash` and `temperature` to `0.3`, and has two messages.

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

### `postilla narrate`

Narrates every translation in a language with `target` 1 (today only the Italian original); learners listen in the language they are learning. When another language becomes a target, its translations are narrated too, with a Speechify voice per language. A rerun narrates again and replaces the audio; narration reads only the paragraphs, so a title, subtitle or header change doesn't need it.

One streamed call narrates one translation: `POST https://api.speechify.ai/v1/audio/stream/with-timestamps` (Server-Sent Events; the base URL is `POSTILLA_SPEECHIFY_URL`), with `Authorization: Bearer $POSTILLA_SPEECHIFY_KEY`. The request's JSON body sets:

- `input` to the text to narrate (below)
- `model` to `simba-3.5`
- `voice_id` to the language's voice: `daniele-agent` for `it`
- `language` to `it-IT` for `it`
- `output_format` to `pcm_48000`, the highest-quality PCM that Speechify streams: headerless 16-bit little-endian mono at 48 kHz (`audio/L16;rate=48000;channels=1`)
- `options` to `{"loudness_normalization": true}`; text normalization stays at its default, off

The voice and language come from a table fixed in the CLI by language id (today only `it`); a language with `target` 1 that isn't in it stops the command (`<lang>: no voice`) before any call to Speechify.

That endpoint takes up to 20,000 spoken characters, which is why `story.json` rule 8 limits the Italian.

The input is the translation's paragraphs joined in reading order: the sentences joined by one space within a paragraph and the paragraphs by one newline, the same text whose sha256 is `text_sha256`. The CLI reads the events:

- `speech.chunk` events carry the audio (base64) and word marks. Each mark has `start` and `end` (code-point offsets into the input) and `start_time` and `end_time` in ms.
- `speech.done` ends the stream.
- Other event types are ignored.
- `speech.error`, or a dropped connection, counts as a failed try. The whole call is retried, since one stream can't resume halfway.

A 200 whose events include `speech.error`, that ends without `speech.done`, whose audio isn't valid base64 or has an odd byte count, whose events aren't JSON, or with a mark whose `start_time` or `end_time` isn't a number of ms from 0 to 4,294,967,295 is a bad stream. Each of up to 3 tries is a whole `outbound.request` ([Retries](#retries)), the next one sent at once; after the third the command stops with `<lang>: narration: <reason>`, the `speech.error` message when there is one. A non-200 answer stops it at once with the status.

The stream yields three outputs:

- **Sentence times:** each sentence's `start_ms` and `end_ms` run from its first word's `start_time` to its last word's `end_time`, both rounded down to whole ms. Words are matched to sentences by mapping the marks' character offsets onto the sentences: a mark belongs to the sentence whose code-point range in the input holds its `start`. A sentence with no mark gets `[e, e]`, `e` the previous sentence's `end_ms` (0 for the first). Every `end_ms` is capped at `audio_ms`, so tilla.md's reader rules hold.
- **App audio:** the PCM is encoded once to the Ogg Opus `.opus` that tilla.md describes (16 kbps, mono), written as `<lang>.opus`, with vendored libopusenc over vendored libopus. libopusenc writes the Ogg container (headers, pages, pre-skip, end trimming) and resamples to a rate Opus takes, so the CLI writes no container code. The settings are fixed: 16,000 bit/s, `OPUS_SIGNAL_VOICE`, complexity 10, VBR, and Ogg serial number 1 (libopusenc picks a random one otherwise), so the same PCM always gives the same `.opus` bytes and an unchanged narration keeps its `opus_sha256`. OpusHead's input rate is the PCM's rate, and `OpusTags` holds only libopusenc's vendor string. `audio_ms` is the PCM's length: its sample count ÷ its sample rate × 1000, rounded down.
- **Master:** the same PCM is also compressed to FLAC with vendored libFLAC, written as `<lang>.flac`. It is a lossless copy kept for re-encoding later: compression level 8, 16 bits, mono, the PCM's rate, the MD5 signature on, and the sample count in STREAMINFO. The app never downloads it.

`audio.encode` (`src/audio.zig`) makes both files in memory from the samples and their rate, and narrate writes them. It refuses no samples (`error.NoAudio`) and a rate outside 8,000–96,000 Hz (`error.UnsupportedRate`) before any C call; a codec call that fails returns `error.OpusEncode` or `error.FlacEncode`.

The times, `audio_ms` and the sha256 of the input text go to the translation's `audio` in `story.json`. Per language, once all of its audio is encoded, `<lang>.opus`, `<lang>.flac` and then `story.json` are written, each to a temp file renamed into place; a file that can't be written stops the command naming it. Listen to the `.opus` before publishing.

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

The CLI writes one `.tilla` per translation ([tilla.md](tilla.md)): the story-level fields, the translation's title, subtitle and sentences, its word spans by the word rule in tilla.md, `words`, `band_words`, and, for a narrated translation, `audio_ms`, `opus_sha256`, `opus_size` and the sentence times. `tilla.build` (`src/tilla.zig`) writes it, with its gzip and sha256, and refuses the inputs tilla.md lists under Reader rules. For `band_words` it tries each of `words.lookupKeys`'s keys against `form`, then `form_norm`; the first key that finds a row decides the word's band. `dict.db` is opened only for the Italian original, read-only and with no pragmas, so the cached build is never written (no `-wal` or `-shm`, and a read-only file works); a `dict.db` that can't be opened or read fails the build, naming the dictionary, before any upload. The sha256 is taken of the `.tilla` before gzip, so an unchanged translation keeps its sha256, its key and its cursor whatever the gzip library or level does; the gzip needs no fixed settings.

It uploads every translation's `.tilla.gz`, `.opus` and `.flac` to R2 under the keys in [Files in R2](#files-in-r2). Keys are content-addressed, so uploading a file that is already there writes the same bytes again. They go up one at a time, every `.tilla.gz` first, then the audio, each printed as `uploaded <key>` once R2 has it; an upload that fails after its retries stops the command naming the key, before `POST /stories`. Last, after every file is in R2, it sends `POST /stories` with every translation's `lang` and `sha256`, and the server takes the cursors, then prints `published <id>`. A non-200 answer is printed with the server's reason line and the command exits 1. A 409 for a missing published translation means the folder lacks a language the story was published in: add it back.

### Retries

Each call to an outside service (OpenCode, Speechify, R2) and to the server goes through `outbound.request` (`src/outbound.zig`) and gets 4 tries in all (1 + 3 retries), waiting 5 s, 30 s, then 2 min between them. A network error, a timeout, a 429 or a 5xx counts as a failed try; a `Retry-After` in seconds on a 429 or a 503 replaces the scheduled wait, capped at 2 min. Any other status ends the call at once with that status.

Every call sends `user-agent: postilla/1.0` (the HTTP client's own `zig/…` is replaced), which OpenCode Go asks of its clients, and `accept-encoding: identity`, since the client asks for gzip by default and OpenCode answers gzipped when asked. Each try sends its own copy of the body, so a try cut mid-send can't change what the next one sends. A try times out after 10 s without a connection, or after 60 s with nothing received: the idle timer restarts with every part of the answer that arrives, so a long stream that keeps sending (a narration) runs as long as it takes. The HTTP client has no timeouts of its own, so the try runs as a task that is canceled when either time runs out.

After the fourth failed try, the command stops with the step that failed and the error. Rerunning it starts that step over, keeping what `story.json` already holds.

## Database

```sql
CREATE TABLE story (
  id        BLOB NOT NULL,              -- 16 bytes
  lang      TEXT NOT NULL REFERENCES language(id),
  sha256    BLOB NOT NULL,              -- 32 bytes, of the .tilla before gzip; kept when removed
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

`story` holds one row per translation: the feed. The story-level fields and the titles aren't copied there; they live in the story folders and in the `.tilla` files. The `UNIQUE` on `cursor` gives the index the GET query uses (`WHERE cursor > ? AND lang IN (…) ORDER BY cursor`). A removed row keeps its last `sha256`, and `FEED` sends zeros for it.

A `POST /stories` runs in one `BEGIN IMMEDIATE` transaction: read the story's current rows (a removed story or a missing published translation stops it here), then, for each translation whose sha256 differs or whose row is new, read `coalesce(max(cursor), 0) + 1` and upsert. A removal runs the same way, setting `change` to 2 and a new cursor on every row of the story. The write lock keeps two concurrent publishes from taking the same cursor. A 4xx or any SQLite error rolls the transaction back, so a refused or failed write changes no row; the body is read and parsed before the transaction starts, so a slow client never holds the write lock.

Startup creates the schema and inserts the initial rows with `INSERT OR IGNORE`, so a fresh `postilla.db` works with no manual step, and a row edited by hand keeps its edit across restarts. Later rows are added by hand with SQL. Startup sets `PRAGMA user_version = 1`, the schema version, and refuses to start (logged, exit 1) on a database whose `user_version` is above 1.

Migrations are compatible with the binary before them, so a rollback (`postilla-update` restoring the previous binary, or deploying an older tag) never meets a database it can't read:

- A migration may add a table, or a column with a default. It never drops, renames or changes the meaning of a table or column in the same release that stops using it.
- `user_version` is the oldest schema a binary must know to read the database, not the newest one applied. A compatible migration leaves it as it is, so an older binary still starts.
- Removing what an earlier release stopped using is a contract step: it raises `user_version` to the binary's own schema, ships in a release of its own after the one that stopped using it, and is the point a rollback can't go back past.
- Every statement names its columns (no positional `INSERT … VALUES`, no `SELECT *`), so a binary works on a table a later one extended. `test/server_read.zig` checks this on a database with a column added to every table and a new table.

| Table | Initial rows |
|---|---|
| `language` | `it` Italiano (target 1, translate 0) · `pt-BR` Português brasileiro (0, 1) · `en` English (0, 0) |
| `genre` (`id`: `it` / `pt_br` / `en`) | `quotidiano`: Quotidiano / Cotidiano / Everyday · `famiglia`: Famiglia / Família / Family · `viaggio`: Viaggio / Viagem / Travel · `mistero`: Mistero / Mistério / Mystery · `lettere`: Lettere / Cartas / Letters · `racconto`: Racconto / Conto / Short story · `classici`: Classici / Clássicos / Classics |
| `author` | `collodi` Carlo Collodi |
| `tag` (`id`: `it` / `pt_br` / `en`) | `caffe`: Caffè / Café / Coffee · `casa`: Casa / Casa / Home · `cibo`: Cibo / Comida / Food · `citta`: Città / Cidade / City · `cucina`: Cucina / Cozinha / Cooking · `emilia-romagna`: Emilia-Romagna / Emília-Romanha / Emilia-Romagna · `famiglia`: Famiglia / Família / Family · `mercato`: Mercato / Mercado / Market · `nonna`: Nonna / Nonna / Grandma · `notte`: Notte / Noite / Night · `segreto`: Segreto / Segredo / Secret · `sicilia`: Sicilia / Sicília / Sicily · `treno`: Treno / Trem / Train · `trieste`: Trieste / Trieste / Trieste · `vicini`: Vicini / Vizinhos / Neighbours |

## Configuration

Everything comes from env, read and checked once at startup. A missing required value stops the program before it does anything else.

### Server

[`.env.example`](../.env.example) lists every variable with its default. Copy it to `.env`, which git ignores. The same file works as the systemd `EnvironmentFile`.

| Variable | Default | What it is |
|---|---|---|
| `POSTILLA_PORT` | `8080` | HTTP port |
| `POSTILLA_BIND` | `127.0.0.1` | Bind address; TLS is the reverse proxy's job |
| `POSTILLA_DB` | `./postilla.db` | SQLite path |
| `POSTILLA_AUTHOR_TOKEN` | required | Bearer token for `POST /stories` and `DELETE /stories/<id>` |

### CLI

[`cli.env.example`](../cli.env.example) lists every variable with its default. Copy it to `cli.env`, which git ignores. The CLI loads `cli.env` from the current directory when it is there; a variable already set in the environment wins over the file. Its lines are `KEY=value`, with no quotes or escapes (the same form as `.env`); blank lines and lines starting with `#` are skipped, and a line without `=` stops the command naming its line number. An empty value counts as missing.

| Variable | Default | What it is |
|---|---|---|
| `POSTILLA_SERVER_URL` | required | Base URL of `postilla-server` (`https://api.example.com`) |
| `POSTILLA_AUTHOR_TOKEN` | required | The server's bearer token, for `POST /stories` |
| `POSTILLA_OPENCODE_KEY` | required | OpenCode key, for Jev and DeepSeek |
| `POSTILLA_OPENCODE_URL` | `https://opencode.ai/inference` | OpenCode's base URL; `translate` stops naming it when it has no `://` |
| `POSTILLA_SPEECHIFY_KEY` | required | Speechify key |
| `POSTILLA_SPEECHIFY_URL` | `https://api.speechify.ai` | Speechify's base URL; `narrate` stops naming it when it has no `://` |
| `POSTILLA_R2_ACCOUNT_ID` | required | Cloudflare account id |
| `POSTILLA_R2_ENDPOINT` | `https://<account>.r2.cloudflarestorage.com` | R2's S3 API base URL, when it isn't the account's |
| `POSTILLA_R2_ACCESS_KEY_ID` | required | R2 S3 access key id |
| `POSTILLA_R2_SECRET_ACCESS_KEY` | required | R2 S3 secret key |
| `POSTILLA_R2_BUCKET` | required | The public bucket: stories and the dictionary |
| `POSTILLA_DICT_DIR` | `./dict` | Where the CLI caches the current `dict.db` build |
| `POSTILLA_MODERATION_THRESHOLD` | `0.9` | Minimum `P(none)` to pass moderation |

## Process

- A self-contained Zig project (Zig 0.17), with its own `build.zig` and `build.zig.zon`. `zig build` makes both executables into `zig-out/bin/`, and they share source files in `src/`: `server.zig` and `cli.zig` are the two entry points, `wire.zig` the binary encoding every body shares, `db.zig` the SQLite wrapper.
- **Version:** every build embeds `<tag> <commit>` in both executables: the latest git tag reachable from HEAD (`untagged` when there is none), then the full 40-character HEAD hash (`unknown` outside a git checkout) with `-dirty` appended when tracked files have uncommitted changes. A build step runs `git` on every build, so the string is never stale. `postilla-server --version` prints `postilla-server <version>` and `postilla --version` prints `postilla <version>`, to stdout, exiting 0; the server reads no configuration for it. CI checks out the full history so the tag is found.
- SQLite is the amalgamation (3.53.2), a `build.zig.zon` dependency by URL and hash, compiled in multi-thread mode (`SQLITE_THREADSAFE=2`): every thread opens its own connection, and no connection is shared. Both executables link it: the server for `postilla.db`, the CLI to read `dict.db`.
- libopus 1.6.1 (the float build, no SIMD intrinsics), libopusenc 0.3 and libFLAC 1.5.0 (without Ogg) are `build.zig.zon` dependencies by URL and hash, compiled from their release tarballs into the `audio` module (`src/audio.zig`) with their config as `-D` flags. Both encoders link their decoders: libopus's repacketizer needs its packet parser, libFLAC's verify mode its decoder.
- **`postilla-server`:** every connection runs as its own concurrent task on `std.Io.Threaded`, so one OS thread per connection, on `std.http.Server`. It closes a connection after a response when the request isn't keep-alive, and after 30 s with no request. A malformed request head, or one over the 8 KiB head buffer, gets a 400 `bad request head` and the connection closes. Each connection opens its own SQLite connection; the database runs in WAL mode (`synchronous = NORMAL`) with a 5 s busy timeout, so readers never wait on a publish and a second writer waits for the first instead of failing. It makes no outbound calls.
- **`words`:** `src/words.zig`, the word rule, the normalization and the lookup chain ([tilla.md, Words](tilla.md#words)), with no dependencies. `build.zig` exports it as a module, so postilla-content imports the same code through a `build.zig.zon` dependency on this repo; SQLite is a lazy dependency, so importing `words` doesn't fetch it. It exports `split(text, out)` (the word spans), `normalize(text, out)` and `lookupKeys(word, buf, keys)`; callers size the buffers (`out.len >= text.len`, `buf.len >= 2 * word.len`), and nothing allocates. `zig build dart` writes the app's normalization table, `normalize` and `lookupKeys` (`zig-out/dart/words_norm.dart`) from the same source; `zig build test-dart` (`test/dart/words.zig`, never part of `zig build test`) checks that file with `dart`, so only it needs the Dart SDK on the PATH; CI runs it with `zig build test` on every push and pull request (`test.yml`), and the deploy waits for the same run.
- **`postilla`:** one process per command, single-threaded. It vendors libopus, libopusenc and libFLAC, makes HTTPS client calls to OpenCode, Speechify, R2 and the server, and signs its R2 uploads and downloads with SigV4.

## Deployment

- One small Linux VPS runs the static `postilla-server` binary under systemd, with the env from a root-only file. The VPS holds only the author token: the OpenCode, Speechify and R2 keys stay on the machine that runs the CLI.
- Caddy in front terminates TLS and proxies to `127.0.0.1:8080`.
- Litestream streams the SQLite WAL to R2 continuously, so a lost VPS restores to within seconds. The backup goes to a separate **private** bucket, never the public story bucket.
- An egress guard bounds the hosting bill: a cron job stops Caddy once the month's outbound traffic, counted by vnstat, reaches 2,900 GB (below Vultr's allowance of 2 TB free per account plus the plan's 1 TB, past which Vultr bills per GB with no cap), and starts it again when the UTC month turns over. Until then the API is down.
- Staging is a second `postilla-server` on the same VPS at `staging-api.postilla.kaiodelphino.com`: its own user, port (8081), database, author token and story bucket, and no backup. Each story bucket has its public domain: `content.postilla.kaiodelphino.com` for production, `staging-content.postilla.kaiodelphino.com` for staging (`files_hostname` and `staging_files_hostname` in `infra/`).
- [`infra/`](../infra/README.md) is the Terraform for all of it: the R2 buckets (story, staging story, backup), one R2 token per bucket (the CLI's for each story bucket, Litestream's for the backup bucket), the Vultr VPS in São Paulo with its firewall, and the DNS records for both hostnames. Its cloud-init installs Caddy, Litestream, both systemd units and the egress guard, and restores `postilla.db` from the backup bucket on a new server. Its state is in a third, private R2 bucket. The binary is a static `x86_64-linux-musl` build; `infra/deploy.sh` pipes it over SSH to `postilla-update` on the server, which swaps it in, restarts the service, and rolls back to the previous binary when the new one doesn't answer `GET /languages` within 10 s. When the new one comes up, `postilla-update` prints its `--version` and logs it to syslog (`journalctl -t postilla-update` shows what each server runs). GitHub Actions runs the tests on every push and pull request; for a pushed `vMAJOR.MINOR.PATCH` tag it builds the binary once they pass, deploys that artifact to staging and smoke-tests it through the public URL (`infra/smoke.sh`, which also runs every 6 hours against both servers); production is a manual run on a tag that ships the same artifact, kept 90 days. It logs in as `deploy`, whose key can only run `postilla-update`.

## Tests

Integration tests through the public entry points only (see `.agents/rules/testing.md`): HTTP for the server, and for the CLI its commands run on a temp story folder against a real server. Each suite gets a free port and a temp SQLite file.

`zig build test` runs every `test/*.zig` (each its own test binary) except `test/harness.zig`, which starts the real server in-process on a free port with a temp SQLite file under `.zig-cache/tmp/`, and sends raw HTTP over TCP so a test can send any bytes. `-Dtest-file=test/<name>.zig` runs one file; `-Dcoverage` runs them under `kcov` into `coverage/kcov`. Malformed `since`, `lang` and `STRY` bodies are integration cases like any other.

`test/golden/` holds golden files: three `.tilla` (narrated Italian, its Portuguese, a standalone story with the word rule's edge cases) and one body of each wire format, produced from fixed inputs. `test/tilla.zig`, `server_read.zig` and `server_write.zig` compare fresh output with them byte for byte; on a difference they write `<name>.candidate` next to the reference and fail, and the reference changes only by renaming a reviewed candidate over it. `zig build test-formats` (`tools/check_formats.py`, CI's `formats` job) parses every golden file with its `docs/formats/*.ksy` and requires the parse to end at the file's last byte, so the specs and the writer can't drift apart. The learner app's reader tests read the same `.tilla` files.

`test/fuzz.zig` fuzzes the boundary parsers (`wire.parseStory`, `wire.StoryId.parse`, `wire.Reader.lang`) and the HTTP layer through the harness. `zig build test` replays each fuzz test's corpus; `zig build test -Dtest-file=test/fuzz.zig --fuzz=<runs>` fuzzes (the `fuzz` workflow runs 5M every Monday). SQLite and the audio codecs are static libraries, so the fuzzer's instrumentation stays out of their C code.

OpenCode, Speechify and R2 are system boundaries. Tests point their base URLs at local fake servers that return recorded responses, so no test spends credits or needs network access. The Italian moderation test set is the exception: it calls Jev for real and runs only on demand, with `zig build test-moderation` (`test/live/moderation.zig`, never part of `zig build test`). It reads `POSTILLA_OPENCODE_KEY` and `POSTILLA_OPENCODE_URL` from the environment or `cli.env`; every clean text must pass the default threshold, `0.9`, and every hateful one, one per option other than `none`, must be rejected.

## Open

Nothing open. The app builds in both base URLs, the API's and the bucket's public domain, with no manifest (the app's ARQ-06).
