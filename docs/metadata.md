# Story metadata — proposal

Status: **draft**, not implemented. Nothing here is in the backend or `.tilla` yet. When it is accepted, it moves into [specification.md](specification.md), [tilla.md](tilla.md) and [formats/](formats/) here; then this file goes away.

## Today

| Field | Type | Where it comes from |
|---|---|---|
| `id` | UUID | source `uuid:` |
| `title`, `subtitle` | text (Italian) | source |
| `level` | 1 A1 · 2 A2 · 3 B1 · 4 B2 | source |
| `genre` | one `genre.id` | source |
| `work`, `part` | text, int; `''` and 0 outside a work | source |
| `words` | Italian words | computed |
| `minutes` | words ÷ level reading speed, rounded up | computed |

## What changes

### 1. Level up to C2

`level`: 1 A1 · 2 A2 · 3 B1 · 4 B2 · **5 C1 · 6 C2**. Still a `u8`. Reader rule 5 becomes "`level` is 1 to 6".

### 2. More than one genre: `genre` + `tags`

`genre` stays: exactly one, it decides where the story sits in the app's shelves. New `tags`: zero or more.

Both are closed lists that the backend owns: a `genre` and a `tag` table in `postilla.db`, each with a mandatory Italian, Portuguese and English name (`it`, `pt_br`, `en`), served by `GET /genres` and `GET /tags`. `genres.txt` goes away. `POST /drafts` checks against the tables, and an unknown genre or tag gets a 400.

The name columns follow `language`: each column is a language id lowercased with `-` turned into `_` (`pt-BR` → `pt_br`), and every language in `language` has one, so `en` is a `language` row too (`target` 0, `translate` 0). Adding a language adds a column to `genre` and `tag`, which is a schema migration and a `GNRS`/`TAGS` version bump.

Genres and tags are added, renamed or removed by hand with SQL on `postilla.db`; there is no endpoint for it. Removing one that published stories still carry is allowed: their `.tilla` keeps the id.

How the app caches the lists and handles an id it doesn't know: [app-handoff.md](app-handoff.md#7-genres-tags-and-authors).

Tags are for what genre can't say: topic (`cibo`, `lavoro`), place (`sicilia`, `roma`), form (`dialogo`).

`POST /drafts` (`DNEW`) carries the tags: zero or more ids.

### 3. Source and license

| Field | Type | Meaning |
|---|---|---|
| `author` | text | Original author, an `author.id` (`collodi`); `''` for a story written for Postilla |
| `adapted` | 0/1 | 1 when the text is adapted from `author`'s work (Pinocchio), 0 when written for Postilla or used as-is |
| `license` | text | SPDX id (`CC-BY-SA-4.0`), `public-domain`, or `LicenseRef-Postilla` (all rights reserved) |

`POST /drafts` (`DNEW`) carries all three. A story written for Postilla sends `author` `''`, `adapted` 0 and `license` `LicenseRef-Postilla`.

Authors are a closed list like genres and tags: an `author` table in `postilla.db` (`id`, `name`), served by `GET /authors`, with the same rules as section 2 (filled by hand with SQL, an unknown id gets a 400 in `POST /drafts`), except that authors are permanent: a row is never deleted and its id never changes (triggers refuse both), and only `name` can be corrected. Some licences (`CC-BY-SA-4.0`) require the author to be credited, so an author's name must always be available to the app. One `name` and no PT/IT pair, because author names aren't translated.

### 4. Vocabulary coverage (computed)

`band_words`: four counts, how many of the story's `words` fall in each NVdB band, using `entry.band` from `dict` (0 outside · 1 fondamentale · 2 alto uso · 3 alta disponibilità). The four add up to `words`. Counts, not percentages, so they stay integers and the app computes the share.

A word takes the most common band among the lemmas its form leads to in `dict.db` (1 before 2 before 3 before 0): "porta" (*portare* 1, *porgere* 2) counts as band 1. A form with no lemma counts as band 0. The worker looks forms up the same way the app does on tap.

This makes the worker depend on `dict.db`.

A `.tilla` word is only a span, looked up by form ([CONTRACT.md](CONTRACT.md), [app-handoff.md](app-handoff.md#5-word-lookup)). `dict.db` entry ids change between builds (ARQ-35) and nothing stores them, so a rebuild is an ordinary file update for the worker and the app. postilla-content publishes it, replacing its GitHub Releases and `manifest.json` (ARQ-06, ARQ-20) for delivery: its build uploads `dict/<sha256>.db.gz` (immutable) and a `dict/latest` pointer naming that sha; the app reads the pointer ([app-handoff.md](app-handoff.md#8-the-dictionary)). The backend picks it up the same way, when a draft reaches publishing: the worker reads `dict/latest`, downloads that build into a local cache directory if it doesn't have it, and writes the word links and `band_words` from it. A new dictionary needs no restart. An R2 failure there is a failed try like any other R2 call. An older story's `band_words` reflect the bands at its publish time until it is republished.

### 5. Audio duration (computed)

`audio_ms`: length of the story's `.opus` in milliseconds; 0 when the story has no narration. Lets the app show "4:12" without opening the audio.

### 6. `minutes` goes away

`minutes` is dropped from `.tilla`: the app computes reading time from `words` ([app-handoff.md](app-handoff.md#4-reading-time-audio-length-coverage)).

### 7. One story, many translations

Every story comes from a draft; none come from the content pipeline anymore. The eight existing stories are recreated through `POST /drafts`. So `POST /stories` (`STRY`, `stry.ksy`) is removed: the worker's last step runs the publish transaction itself, upserting every translation's `story` row in one `BEGIN IMMEDIATE` transaction after all files are in R2, so a syncing app sees all of a story's translations or none.

A story is split by language so that any two of its languages can be the learner's target and native language (Italian for a Brazilian today, Portuguese for an Italian later).

- `language`: the closed list of languages in `postilla.db`, `id` (a BCP 47 tag of at most 8 ASCII bytes: `it`, `pt-BR` for Brazilian Portuguese, and later variants like `pt-PT` or dialects like `scn`), `name`, the language's own name (`Italiano`, `Português`), as language pickers show it, `target`, 1 when the language can be learned (it has a dictionary and a narration voice; today only `it`), and `translate`, 1 when drafts are translated into it (today `pt-BR`; `en` is a row with `translate` 0, there for genre and tag names). Edited by hand with SQL like genres, tags and authors, and served by `GET /languages`. Language ids are permanent: a row is never deleted and its `id` never changes, because every installed app sends its ids on each sync and an unknown one gets a 400. Triggers refuse both. `name` and `target` can change; `target` 0 only stops the app offering the language as something to learn, and learners already using it keep syncing.
- `story`: what doesn't depend on language: `id`, `lang` (the language it was written in), `level`, `genre`, tags, `author`, `adapted`, `license`, `work`, `part`. `level` is the original's; translations are written to the same level.
- `translation`: one row per story and language, keyed by `(story_id, lang)`: what does depend on language: `title`, `subtitle`, `words`, `audio_ms` (its own `.opus`), and the word data. The original is the translation whose `lang` is `story.lang`.

Every translation of a story has the same paragraph count and, paragraph by paragraph, the same sentence count, so paragraph *p*, sentence *s* means the same thing in every language and any two translations line up by index. It's the check the translation step and `PUT /drafts/<id>/translation` already make.

Each translation is its own file: `stories/<id>/<lang>/<sha256>.tilla.gz`. Its narration, when it has one, is keyed by the audio's own sha256: `stories/<id>/<lang>/<opus_sha256>.opus` for the app and `stories/<id>/<lang>/<flac_sha256>.flac` for the master, whose sha the backend keeps in `postilla.db`. An edit that reuses the audio keeps its keys, so nothing is copied and no app downloads it again. Nothing is ever deleted from R2: a republish leaves the previous `.tilla.gz`, `.opus` and `.flac` in place (replacing specification.md's "the previous version's three objects are deleted"), so a phone never gets a 404 for a file the feed or a `.tilla` named. The app downloads only its target and native languages and pairs them by index, and republishing one translation leaves the others alone. The feed goes per translation. The app isn't published yet, so every format below changes in place and keeps version 1:

- `postilla.db`'s `story` table is keyed by `(id, lang)`, so every translation has its own `sha256`, `has_opus`, `change` and cursor.
- `GET /stories?since=<cursor>&lang=it,pt-BR` returns only the listed languages (`FEED`). `lang` is required: 1 to 4 comma-separated ids, each in `language`, with no duplicates and no empty items. A missing, empty or malformed `lang`, or an id not in `language`, gets a 400, like a bad `since`. A record is 61 bytes: `id` (`uuid`), `lang` (8 bytes), `change` (`u8`), `sha256` (32 bytes), `cursor` (`u32`). `change` says what happened last to that translation: `published` (1, new or changed) or `removed` (2; `sha256` is all zero). Removed rows are returned like any other, `since=0` included. What the app does with each record: [app-handoff.md](app-handoff.md#2-syncing).

How the app applies a sync (atomic per story, the cursor rule, cards, audio on first play): [app-handoff.md](app-handoff.md#2-syncing).

Cursors are `max(cursor) + 1`, so a Litestream restore that loses the last seconds of publishes gives the next publishes the lost cursors again. A phone that synced in that window then misses stories until cursors pass its own. This is accepted: it takes a crash plus a sync in those seconds, and those phones catch up once new cursors pass the ones they had. The lost stories themselves have to be published again.

Cursors come from one sequence shared by every translation.

After launch, formats change only with a version bump. The backend bumps a version only together with an app release that reads it; how the app treats a version it doesn't know is in [app-handoff.md](app-handoff.md#9-format-versions-and-errors).

Wherever a binary body carries a language id (`FEED`, `.tilla`, the draft bodies), it's 8 bytes: the tag in ASCII, zero-padded, so every record keeps a fixed size.

Every translation's `.tilla` also carries the story-level fields (`lang` of the original, `level`, `genre`, tags, `author`, `adapted`, `license`, `work`, `part`), so each file stands alone. The worker writes them from the same draft, so the copies can't disagree; a change to one of them republishes every translation of the story.

Word data (dictionary lookups and `band_words`) exists only for Italian. A translation in any other language still lists its word spans, but its four `band_words` are 0, and a reader rule says so. A language can be a target (`language.target` 1) only once it has a dictionary, so for now Italian is the only target; Portuguese works as a native language from the start.

A draft's original is always Italian. The worker translates it into every language in `language` with `translate` 1, one DeepSeek pass per language, with the system message naming the target language; today that is only `pt-BR`. Each pass sends the title and subtitle first, as one extra two-sentence paragraph with the same request shape and length check, so every translation gets its own `title` and `subtitle` with no new code path. Each translation is reviewed, and publishing writes one `.tilla` per language.

Adding a language to `language` doesn't backfill: stories published before it keep the languages they had, so a story can lack the learner's native language (the app shows it target-only, [app-handoff.md](app-handoff.md#3-cards-and-opening-a-story)). The gap is filled the next time the story is edited or renarrated: an `/edit` or `/narrate` copy that lacks a language with `translate` 1 first goes through `translating` for just those languages, then to `review`.

Review works per language, approval per draft:

- `GET /drafts/<id>` (`DRFT`) carries every language: per sentence, the Italian, then one `str` per translated language, in `language` order, after a header listing those languages.
- `PUT /drafts/<id>/translation` (`TRNS`) gains a `lang` and replaces only that language's title, subtitle and sentences; `DRFT` carries each language's title and subtitle too.
- `POST /drafts/<id>/retranslate?lang=pt-BR` discards only that language; the draft goes back to `translating`, and the worker redoes only that language. `lang` is required and must name a language with `translate` 1 that the draft has; a missing `lang`, `it` or any other id gets a 400. It works on any draft at `review`, and gets a 409 in any other state.
- The translation step tracks each language separately: a language that finished stays done. After a failure, `resume` redoes only the languages without a finished translation, and the stored error names the language that failed (`pt-BR: paragraph 4: wrong sentence count`).
- `POST /drafts/<id>/approve` freezes every translation at once and starts `narrating`, because narration and publishing run once per draft.

Only translations in a language with `target` 1 are narrated (today only the Italian original); learners listen in the language they are learning. When another language becomes a target, its translations are narrated too, with a Speechify voice per language.

### 8. Authoring

What an authoring app (create, edit, approve, remove stories) needs from the backend, beyond the `/drafts` endpoints.

**Removing a story.** `DELETE /stories/<id>` (bearer token) tombstones every translation of the story at once, in one `BEGIN IMMEDIATE` transaction: each `story` row is kept, its `change` set to `removed`, and gets a new cursor, so a syncing app learns about it and deletes its copy. Nothing is deleted: the rows stay in `postilla.db`, and the `.tilla.gz`, `.opus` and `.flac` stay in R2. Removal is per story: a single translation can't be removed. A removed id stays removed: `POST /drafts` or `POST /stories/<id>/narrate` with it gets a 409. Bringing a story back is on the [roadmap](roadmap.md#authoring-app).

| Case | Answer |
|---|---|
| Published story | 200, every translation tombstoned |
| Already removed | 200, nothing changes (no new cursor) |
| Story with a draft in progress | 409; discard the draft first, or it would republish the story |
| Unknown id | 404 |
| `<id>` not a UUID | 400 |
| Missing or wrong token | 401 |

**Listing published stories.** `GET /published` (bearer token) lists every story that has been published, removed ones included, so the app can pick one to edit or remove. It reads each story's latest draft in state `published`, joined with its `story` rows; no titles are copied. The response is `200`, `application/octet-stream`:

| Field | Type | Value |
|---|---|---|
| `magic` | 4 bytes | `PUBL` |
| `version` | `u8` | `1` |
| `count` | `u32` | Number of stories that follow |

Then `count` stories, ascending by id:

| Field | Type | Value |
|---|---|---|
| `id` | `uuid` | Story id |
| `change` | `u8` | `published` or `removed` |
| `level` | `u8` | Level |
| `genre` | `str` | Genre id |
| `lang_count` | `u8` | Number of translations that follow |

Then `lang_count` translations, in `language` order, each a `lang` (8 bytes) and a `title` (`str`).

**Editing a published story.** `POST /stories/<id>/edit` (bearer token) copies the story's latest published draft (header, and every language's title, subtitle and sentences) into a new draft that starts at `review`, and answers `202` with the draft id, like `POST /drafts`. At `review`:

- `PUT /drafts/<id>/translation` edits any language, the Italian original included. Other languages keep every sentence count. The Italian may change a paragraph's sentence count but not the number of paragraphs: the draft then goes to `translating` for just those paragraphs, in every other language (one DeepSeek request per paragraph, as now), keeping every edit elsewhere, and comes back to `review`. A different paragraph count gets a 400.
- `PUT /drafts/<id>/header` (new) replaces the header: `level`, `genre`, tags, `author`, `adapted`, `license`, `work`, `part`.
- `POST /drafts/<id>/approve` republishes, as for any draft.

The copy checks the header against the current lists: tags no longer in `tag` are dropped, since they're optional (authors are permanent, so the author always carries over). A genre no longer in `genre` is kept, and `approve` gets a 409 until `PUT /drafts/<id>/header` sets a listed one. So a republished story only ever carries listed ids.

The same rules as other drafts apply: one draft in progress per story (409 otherwise), and a removed story gets a 409. After approve, narration reruns only for a narrated language (`target` 1) whose sentences changed; narration reads only the paragraphs, so a title, subtitle or header change doesn't count. Otherwise the published `.opus`, `.flac` and sentence times are reused, so a header fix or a Portuguese typo costs no Speechify credits. Moderation doesn't rerun: an edit starts at `review`, and the editor is the reviewer.

A rewrite that adds or removes paragraphs is a new `POST /drafts` with the same id, which runs the whole pipeline.

**Moderation of Italian edits.** When the Italian (title, subtitle or sentences) changed at `review`, in a new draft or an edit draft, `approve` first moderates the whole Italian text again, with the same request and threshold as `moderating`, so there's no new code path. If it fails, the draft stays at `review` with the new scores and an error naming the change, instead of going on; if it passes, approve continues as usual. An edit that leaves the Italian unchanged isn't moderated again. For a false positive, `POST /drafts/<id>/override` (bearer token) moves a `rejected` draft on to `translating`, or approves a draft held at `review` by re-moderation anyway. The scores stay stored, so an override is visible later in `GET /drafts/<id>`.

**Listening before publishing.** After `narrating`, a draft stops at a new state, `listening`, instead of publishing. When narration ends, the draft stores, per narrated language, the `.opus` and `.flac` as BLOBs with their sha256 and `audio_ms` (a `draft_audio` table keyed by `(draft_id, lang)`; about 0.5 MB of `.opus` for a 4-minute story at 16 kbps), and each sentence's times in `draft_sentence`. So `listening` and publishing survive a restart. After publishing, the BLOBs are set to NULL, since R2 has the files; the shas, `audio_ms` and sentence times stay, because an edit draft copies them to reuse the audio. Discard sets the BLOBs to NULL too. At `listening` (bearer token):

- `GET /drafts/<id>/audio?lang=it` returns that language's `.opus` (`audio/ogg`).
- `POST /drafts/<id>/publish` starts publishing.
- `POST /drafts/<id>/renarrate` discards the audio and goes back to `narrating`.
- `POST /drafts/<id>/discard` works as in any other state.
- `POST /drafts/<id>/review` takes the draft back to `review` with every edit, the audio and the sentence times kept. On the next approve, the edit rule applies: narration reruns only for a narrated language whose sentences changed (then `listening` again); otherwise the draft goes straight to publishing.

A draft whose narration didn't run (an edit with no sentence change) goes from `approve` straight to publishing, since there is nothing new to hear.

**Narrating a published story again.** `POST /stories/<id>/narrate` copies the story's latest published draft, like `/edit`, but starts at `narrating`: it narrates every translation in a language with `target` 1 (today only `it`), then stops at `listening`. It is how to redo the audio when the text hasn't changed. If the story lacks a language with `translate` 1, the copy goes through `translating` and `review` for it first, and approve then narrates.

**Clients.** The authoring clients are native, desktop and CLI apps, so the backend sends no CORS headers. A web version is on the [roadmap](roadmap.md#authoring-app).

**Concurrent edits.** A draft has a `revision` (`u32`) that every change to it bumps, by a client or by the worker, and `GET /drafts/<id>` carries it. `PUT /drafts/<id>/translation` and `PUT /drafts/<id>/header` carry the revision they were based on; a mismatch gets a 409 (`draft changed: revision 7`), and the client reloads and reapplies. No edit is lost silently when two clients work on one draft.

**Error bodies.** Every 4xx except 401 carries a one-line English reason as `text/plain`, naming the rule and the field: `tags: unknown id 'rom'`, `story removed`. A 409 for a story with a draft in progress names that draft (`draft in progress: 42`), so a client whose `POST /drafts` or `/edit` response was lost can find the draft it created. The authoring app shows the line as is. This replaces openapi.yaml's "error responses carry no body". A 401 stays empty, so it reveals nothing before the token is checked.

**Auth.** One bearer token covers every authoring endpoint (`/drafts`, `/stories/<id>/edit`, `/narrate`, `DELETE /stories/<id>`, `GET /published`), compared in constant time as today. With `POST /stories` gone, env `POSTILLA_PUBLISH_TOKEN` is renamed `POSTILLA_AUTHOR_TOKEN`.

## `postilla.db`, `GET /genres`, `GET /tags`, `GET /authors` and `GET /languages`

```sql
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

All four endpoints are public, like `GET /stories`, and take no parameters. Every response is `200`, `Content-Type: application/octet-stream`, and starts with the same header:

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

## `stories.db`

Dropped. The content build wrote it, and no story comes from the build anymore. There is no catalog file either.

## `.tilla`

The full format, recreated after the original TILLA.md was lost, is in [tilla.md](tilla.md) and [formats/tilla.ksy](formats/tilla.ksy). The app isn't published yet, so the format changes in place and stays version 1; the eight stories are recreated through drafts in the new shape, and no reader keeps the old one.

## To do when accepted

- postilla-content: stop building and publishing stories and delete `genres.txt`; delete its TILLA.md and `tilla.ksy`, which now live here as [tilla.md](tilla.md) and [formats/tilla.ksy](formats/tilla.ksy) (see [content-handoff.md](content-handoff.md)).
- postilla-backend, lists: the `language`, `genre`, `tag` and `author` tables (in the schema), `GET /languages`, `GET /genres`, `GET /tags` and `GET /authors`, with their `.ksy` files, the magic table and openapi.yaml; `POST /drafts` checks `genre`, `tags` and `author` against the tables. Drop the genre question from the Open section of specification.md.
- postilla-backend, feed: `story` keyed by `(id, lang)`, `FEED` with `lang` and `?lang=`; remove `POST /stories`, `STRY` and `stry.ksy`, and publish from the worker's last step; R2 keys `stories/<id>/<lang>/<sha256>.tilla.gz`, and `.opus` and `.flac` keyed by their own sha256.
- postilla-backend, authoring: `DELETE /stories/<id>` (tombstones, `change` in `story` and `FEED`), `GET /published` (`PUBL`), `POST /stories/<id>/edit`, `PUT /drafts/<id>/header`, the `listening` state with `GET /drafts/<id>/audio`, `publish` and `renarrate`, `/narrate` per target language, 409 for removed ids, and `POSTILLA_PUBLISH_TOKEN` renamed `POSTILLA_AUTHOR_TOKEN` (spec, `.env.example`, openapi.yaml), each with its `.ksy` and status codes.
- postilla-backend, drafts: the same new `.tilla` writer, one file per translation. `DNEW` carries the hand-written fields (`tags`, `author`, `adapted`, `license`); `DRFT` with every language, `TRNS` with `lang`, and `retranslate?lang=`; one DeepSeek pass per non-Italian language, with the target language in the system message and `{level}` up to `C2`; narration only for languages with `target` 1. `postilla_enums.ksy` gains `c1`, `c2`; rule 4 of `POST /drafts` becomes `level` 1 to 6. `band_words` means the worker reads `dict/latest` and caches builds in a local directory (a new config path, e.g. `POSTILLA_DICT_DIR`).
- Data: fill `language` (`it` target 1 translate 0, `pt-BR` target 0 translate 1, `en` target 0 translate 0), `genre` from today's `genres.txt` (adding `en` names), `tag`, and `author` (`collodi` for Pinocchio); recreate the eight stories through `POST /drafts`, with their tags.
- postilla-app: everything in [app-handoff.md](app-handoff.md).
- `zig build test`, with cases for each new reader rule.
