Source: docs/specification.md at c32b62c (no separate PO paste; the spec is the requirement).
Scope given by the user: slice `server-write` = the bearer token, POST /stories and DELETE /stories/<id>.
The read path (lists, GET /stories, routing, error bodies) shipped in `server-read`.
Carried over from server-read (questions.md #2): move the hand-written response bodies onto wire.Writer / wire.Lang.

## Cursor

The cursor is a publish counter, a `u32`, kept per translation. Every change to a translation takes the next value (`max(cursor) + 1`, the first gets 1) from one sequence shared by every translation of every story, and stores it in the translation's row.

- A new translation gets a new cursor.
- A republished translation (same story and language, new sha256) gets a new cursor too, replacing its old one. Its old value is never reused, so the cursors in the table can have gaps.
- A republish of a translation with the same sha256 changes nothing and keeps its cursor. So a republish that leaves a translation unchanged (say, a Portuguese typo fix leaves the Italian alone) touches only the translations that changed.
- Removing a story gives every one of its translations a new cursor ([Removing a story](#delete-storiesid)).

So `cursor > X` is exactly "published, corrected or removed after the app's last sync". Which cursor the app stores is in [app-handoff.md](app-handoff.md#2-syncing).

Cursors are `max(cursor) + 1`, so a Litestream restore that loses the last seconds of publishes gives the next publishes the lost cursors again. A phone that synced in that window then misses translations until cursors pass its own. This is accepted: it takes a crash plus a sync in those seconds, and those phones catch up once new cursors pass the ones they had. The lost stories themselves have to be published again.

### Auth

`POST /stories` and `DELETE /stories/<id>` take `Authorization: Bearer <token>`, where the token is env `POSTILLA_AUTHOR_TOKEN`, compared in constant time. A missing or wrong token gets a 401 with an empty body, before the body is read. `GET /stories`, `GET /genres`, `GET /tags`, `GET /authors` and `GET /languages` are public.

The authoring client is the `postilla` CLI, so the backend sends no CORS headers.

### Error bodies

Every 4xx except 401 carries a one-line English reason as `text/plain`, naming the rule and the field: `lang: unknown id 'fr'`, `story removed`. A 409 for a published translation missing from a `POST /stories` body names the language (`pt-BR: published, missing from body`). The CLI prints the line as is. A 401 stays empty, so it reveals nothing before the token is checked. A 500 carries no body.

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

The body is `22 + 40 × lang_count` bytes. The boundary parse rejects with 400 when any of these fail:

1. The magic is `STRY` and the version is 1.
2. `lang_count` is at least 1, and the body is exactly `22 + 40 × lang_count` bytes.
3. Every `lang` is non-empty ASCII followed only by zero bytes, and no `lang` repeats.
4. One `lang` is `it`, the original.

Past the parse, a `lang` not in `language` gets a 400 (`lang: unknown id 'fr'`), and a removed story id gets a 409 (`story removed`). A story that already has a published translation in a language the body doesn't carry gets a 409 (`pt-BR: published, missing from body`), so a republish can't leave an old translation next to a new original with different paragraph counts. There is no override: a republish carries every language the story was published in.

Then, in one `BEGIN IMMEDIATE` transaction, every translation in the body is upserted: a row whose sha256 changed, or that is new, gets `change` `published` and the next cursor; a row whose sha256 is the same keeps its cursor ([Cursor](#cursor)). So a syncing app sees all of a story's changed translations or none.

The response is `200` with no body.

### `DELETE /stories/<id>`

Removes a story: it tombstones every translation of the story at once, in one `BEGIN IMMEDIATE` transaction. Each `story` row is kept, its `change` set to `removed`, its `sha256` zeroed in the feed, and gets a new cursor, so a syncing app learns about it and deletes its copy. Nothing is deleted: the rows stay in `postilla.db`, and the `.tilla.gz`, `.opus` and `.flac` stay in R2. Removal is per story: a single translation can't be removed.

A removed id stays removed: `POST /stories` with it gets a 409 (`story removed`). Bringing a story back is on the [roadmap](roadmap.md#authoring-app).

No body. `<id>` is the story UUID in its written form.

| Case | Answer |
|---|---|
| Published story | 200 with no body, every translation tombstoned |
| Already removed | 200 with no body, nothing changes (no new cursor) |
| Unknown id | 404 |
| `<id>` not a UUID | 400 |
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

A `POST /stories` runs in one `BEGIN IMMEDIATE` transaction: read the story's current rows (a removed story or a missing published translation stops it here), then, for each translation whose sha256 differs or whose row is new, read `coalesce(max(cursor), 0) + 1` and upsert. A removal runs the same way, setting `change` to 2 and a new cursor on every row of the story. The write lock keeps two concurrent publishes from taking the same cursor.

Startup creates the schema and inserts the initial rows with `INSERT OR IGNORE`, so a fresh `postilla.db` works with no manual step, and a row edited by hand keeps its edit across restarts. Later rows are added by hand with SQL. Startup sets `PRAGMA user_version = 1`, the schema version, and refuses to start (logged, exit 1) on a database whose `user_version` is above 1.

| Table | Initial rows |
|---|---|
| `language` | `it` Italiano (target 1, translate 0) · `pt-BR` Português brasileiro (0, 1) · `en` English (0, 0) |
| `genre` (`id`: `it` / `pt_br` / `en`) | `quotidiano`: Quotidiano / Cotidiano / Everyday · `famiglia`: Famiglia / Família / Family · `viaggio`: Viaggio / Viagem / Travel · `mistero`: Mistero / Mistério / Mystery · `lettere`: Lettere / Cartas / Letters · `racconto`: Racconto / Conto / Short story · `classici`: Classici / Clássicos / Classics |
| `author` | `collodi` Carlo Collodi |
| `tag` | none yet |
