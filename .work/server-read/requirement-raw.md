Source: docs/specification.md at f62dd56 (no separate PO paste; the spec is the requirement).
Scope given by the user: slice `server-read` = schema and seed, GET /genres, /tags, /authors, /languages,
GET /stories (the hot path), routing and error bodies. POST /stories, DELETE /stories/<id> and auth are `server-write`.

## Languages, genres, tags and authors

Four closed lists in `postilla.db`, edited by hand with SQL; there is no endpoint that changes them. Startup creates them with their initial rows ([Database](#database)).

- **`language`**: `id` (a BCP 47 tag of at most 8 ASCII bytes: `it`, `pt-BR`, later variants like `pt-PT` or dialects like `scn`), `name` (the language's own name, as language pickers show it, naming the variant where there is one: `Italiano`, `Português brasileiro`), `target` (1 when the language can be learned: it has a dictionary and a narration voice; today only `it`) and `translate` (1 when stories are translated into it; today only `pt-BR`). `en` is a row too (`target` 0, `translate` 0), there for genre and tag names. Language ids are permanent: a row is never deleted and its `id` never changes, because every installed app sends its ids on each sync and an unknown one gets a 400. Triggers refuse both. `name` and `target` can change; `target` 0 only stops the app offering the language as something to learn, and learners already using it keep syncing.
- **`genre`** and **`tag`**: an `id` and a mandatory name in every language of `language`, one column per language, named by its id lowercased with `-` turned into `_` (`it`, `pt_br`, `en`). Adding a language adds a column to both tables, which is a schema migration and a `GNRS`/`TAGS` version bump. Removing a genre or tag that published stories still carry is allowed: their `.tilla` keeps the id.
- **`author`**: `id` and `name`. One name, because author names aren't translated. Authors are permanent: a row is never deleted and its id never changes (triggers refuse both), and only `name` can be corrected. Some licences (`CC-BY-SA-4.0`) require the author to be credited, so an author's name must always be available to the app.

Wherever a list of a story's languages is "in `language` order", that means the story's original first, then the other languages ascending by `id` (`it`, then `en`, `pt-BR`…).

`postilla publish` checks a story's `genre`, `tags` and `author` against `GET /genres`, `GET /tags` and `GET /authors`, and its languages against `GET /languages`, and stops on an unknown id. The server checks only the languages, the one list `POST /stories` carries. How the app caches the lists and handles an id it doesn't know: [app-handoff.md](app-handoff.md#7-genres-tags-and-authors).

Adding a language to `language` doesn't backfill: stories published before it keep the languages they had, so a story can lack the learner's native language (the app shows it target-only). The gap is filled the next time the story is published: `postilla translate` fills in every missing language with `translate` 1, and `postilla publish` requires them.

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

### Error bodies

Every 4xx except 401 carries a one-line English reason as `text/plain`, naming the rule and the field: `lang: unknown id 'fr'`, `story removed`. A 409 for a published translation missing from a `POST /stories` body names the language (`pt-BR: published, missing from body`). The CLI prints the line as is. A 401 stays empty, so it reveals nothing before the token is checked. A 500 carries no body.

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
| `sha256` | `sha256` | sha256 of the translation's `.tilla`, before gzip; all zero when `removed` |
| `cursor` | `u32` | The translation's cursor |

Each record is 61 bytes, so the body is `9 + 61 × count` bytes. When nothing is new the body is the 9-byte header with `count` 0. Removed translations are returned like any other, `since=0` included. What the app does with each record: [app-handoff.md](app-handoff.md#2-syncing).

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

Startup creates the schema and inserts the initial rows with `INSERT OR IGNORE`, so a fresh `postilla.db` works with no manual step. Later rows are added by hand with SQL.

| Table | Initial rows |
|---|---|
| `language` | `it` Italiano (target 1, translate 0) · `pt-BR` Português brasileiro (0, 1) · `en` English (0, 0) |
| `genre` (`id`: `it` / `pt_br` / `en`) | `quotidiano`: Quotidiano / Cotidiano / Everyday · `famiglia`: Famiglia / Família / Family · `viaggio`: Viaggio / Viagem / Travel · `mistero`: Mistero / Mistério / Mystery · `lettere`: Lettere / Cartas / Letters · `racconto`: Racconto / Conto / Short story · `classici`: Classici / Clássicos / Classics |
| `author` | `collodi` Carlo Collodi |
| `tag` | none yet |

### Server

[`.env.example`](../.env.example) lists every variable with its default. Copy it to `.env`, which git ignores. The same file works as the systemd `EnvironmentFile`.

| Variable | Default | What it is |
|---|---|---|
| `POSTILLA_PORT` | `8080` | HTTP port |
| `POSTILLA_BIND` | `127.0.0.1` | Bind address; TLS is the reverse proxy's job |
| `POSTILLA_DB` | `./postilla.db` | SQLite path |
| `POSTILLA_AUTHOR_TOKEN` | required | Bearer token for `POST /stories` and `DELETE /stories/<id>` |
