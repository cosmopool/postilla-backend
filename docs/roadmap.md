# Roadmap

Planned work that isn't in [specification.md](specification.md) yet, and the progress of v1.0. When an item is built, it moves into the spec and leaves this file; its row in "Progress" says so.

## Progress

What v1.0 has today, by spec section. Status: `done` · `partial` (what's missing) · `in progress` (slice) · `not started`. Every slice updates its rows in the commit that delivers them (AGENTS.md). As of 2026-11-27 the spec describes only what is built, so every section starts as `done`; the rows below record what the live deployment still lacks.

| Spec section | Status | Notes |
|---|---|---|
| Encoding, Stories and translations, Cursor | done | |
| Languages, genres, tags and authors | in progress (first stories) | Production has 0 tags; the learner app's catalogue needs 15. |
| Files in R2 | in progress (first stories) | Both public domains live; `dict/latest` in both buckets. No story files yet. |
| Endpoints (`GET /stories`, lists, `POST /stories`, `DELETE /stories/<id>`) | done | Production's feed is empty: no story is published yet. |
| The CLI (`translate`, `narrate`, `publish`) | done | Never run against production. |
| Database, Configuration, Process, Deployment, Tests | done | |

## Next slices

In order. A slice moves its rows to `in progress` when it starts.

1. **First stories, for the learner app's sync slice** (its roadmap, 2026-11-27):
   - the 15 catalogue tags in the startup rows (done, `284d940`; not deployed yet);
   - `dict/latest` and its `dict/<sha256>.db.gz` in both buckets (done 2026-11-27 by a one-off upload of `dict-1.0.0.db.gz`, sha `dfae4ada…`, the build the app bundles);
   - the 8 real stories as `story.json` folders in `stories/` (done; pt-BR titles written by hand), narrated and listened to (done 2026-11-27), published to staging, then to production after the app's end-to-end check;
   - both public domains in `infra/`, defaulting to the real names (done and applied 2026-11-27, `a47f02f`);
   - rotate both CLI R2 tokens (`tofu apply -replace=cloudflare_account_token.cli -replace=cloudflare_account_token.cli_staging`): their secrets were printed in a working session on 2026-11-27. Deferred by the owner. Until then, the local `cli.env` points its R2 lines at a `postilla-content` bucket with another key instead of Terraform's `postilla-stories`, so production `publish` must wait for this step.

2. **postilla-content: publish `dict.db` from the build** ([content-handoff.md](content-handoff.md) §4). The 2026-11-27 upload was by hand; nothing publishes the next build yet.
3. **postilla-content: `form_norm` and `word_norm` from the shared `words` module** (content-handoff.md §3). Changes the dictionary build, so `band_words` of stories published before it may differ from a later build's.

## v1.2: Drafts

v1.0 has no story authoring on the server: the `postilla` CLI moderates, translates, narrates and builds each story on your machine and publishes it with `POST /stories` ([The CLI](specification.md#the-cli)). v1.2 moves that work into the server as drafts, so stories can be created, reviewed and edited from an authoring app. Its endpoints: everything under `/drafts`, `POST /stories/<id>/edit`, `POST /stories/<id>/narrate` and `GET /published`.

The design below is the one written for the backend before it was moved here on 2026-11-17, kept word for word. Where it repeats what the spec now says for the CLI (the Jev, DeepSeek and Speechify requests, vocabulary coverage, the `.tilla` build), the spec wins. The binary layouts it names (`DNEW`, `DLST`, `DRFT`, `TRNS`, `HEDR`, `PUBL`, the bare `u32` draft id) and their `.ksy` files are in git history, at commit `76a8a45` ("docs: drafts design, before moving it to v1.2"). When v1.2 is built, this section moves back into the spec, openapi.yaml and `formats/`, and the CLI's `translate`, `narrate` and `publish` become worker steps.

Every story comes from a draft. The backend moderates it, translates it, waits for your review, narrates it, lets you listen, builds the files and publishes them ([Drafts](#drafts)):

- `POST /drafts` starts a draft from Italian text.
- `POST /stories/<id>/edit` starts a draft from a published story, at `review` ([Editing a published story](#post-storiesidedit)).
- `POST /stories/<id>/narrate` starts a draft from a published story, at `narrating` ([Narrating a published story again](#post-storiesidnarrate)).
- `DELETE /stories/<id>` removes a story ([Removing a story](specification.md#delete-storiesid)).

#### `GET /published`

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

### Drafts

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

#### Concurrent edits

A draft has a `revision` (`u32`) that every change to it bumps, by a client or by the worker; `GET /drafts` and `GET /drafts/<id>` carry it. `PUT /drafts/<id>/translation` and `PUT /drafts/<id>/header` carry the revision they were based on; a mismatch gets a 409 (`draft changed: revision 7`), and the client reloads and reapplies. No edit is lost silently when two clients work on one draft.

#### Retries

Each call to an outside service (OpenCode, Speechify, R2) is tried and retried as the spec's [Retries](specification.md#retries) says.

After the last failed try, the draft becomes `failed`. It stores the step that failed, the error, and the attempt count.

`POST /drafts/<id>/resume` reruns the failed step from scratch with a fresh try count. Work from earlier steps is kept: an approved translation is never redone, and a language that finished translating stays done.

#### Moderation

The draft's Italian text (title, subtitle and sentences) goes to Jev in `state`, with one `choice` question. Its options are `none`, `homophobic`, `racist`, `sexist`, `religious` and `other_hate`, each described in the question's `criteria`.

- Jev returns a probability for each option and no explanation.
- The draft is `rejected` when `P(none)` is below the threshold: env `POSTILLA_MODERATION_THRESHOLD`, default `0.9`.
- The stored error names the option with the highest probability, so a rejection says what was flagged.
- Jev's docs don't say whether it reads Italian. A fixed test set of Italian texts, both clean and hateful, runs through Jev before this step is trusted, and stays as a regression check. If Jev handles Italian poorly, moderation moves to the Portuguese translation.

Request: `POST https://opencode.ai/inference/systemone/v1/systemone`, with `Authorization: Bearer $POSTILLA_OPENCODE_KEY`.

**Moderation of Italian edits.** When the Italian (title, subtitle or sentences) of an `edit` draft changed at `review`, `approve` answers at once and moves the draft to `moderating`, where the worker moderates the whole Italian text again, with the same request and threshold, so there's no new code path. If it fails, the draft goes back to `review` with the new scores and an error naming the change, instead of going on; if it passes, the draft continues as approve would have (`narrating` or `publishing`). An edit that leaves the Italian unchanged isn't moderated again. An `edit` draft starts at `review`, so it isn't moderated on creation: the editor is the reviewer.

**Override.** For a false positive, `POST /drafts/<id>/override` moves a `rejected` draft on to `translating`, or approves a draft held at `review` by re-moderation anyway. A `rejected` draft is final, so the story may have another draft in progress by then: override checks for one in the same `BEGIN IMMEDIATE` transaction as `POST /drafts`, and gets a 409 (`draft in progress: 42`) if there is. The scores stay stored, so an override is visible later in `GET /drafts/<id>`.

#### Translation

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

#### Review

At `review`, these endpoints are open:

- **Read:** `GET /drafts/<id>` returns the Italian and every translation.
- **Edit a language:** `PUT /drafts/<id>/translation` replaces one language's title, subtitle and sentences. The draft stays in `review`. On an `edit` draft the Italian can be edited too ([`PUT /drafts/<id>/translation`](#put-draftsidtranslation)).
- **Edit the header:** `PUT /drafts/<id>/header` replaces the story-level fields.
- **Retranslate:** `POST /drafts/<id>/retranslate?lang=<id>` discards that language only; the draft goes back to `translating`, and the worker redoes only that language.
- **Approve:** `POST /drafts/<id>/approve` freezes every translation at once, sends an edited Italian back through `moderating` first ([Moderation](#moderation)), and starts `narrating`, or `publishing` when nothing narrated changed. Narration and publishing run once per draft.

`GET /drafts?state=review` lists the drafts waiting for you.

#### Narration

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
- **App audio:** the PCM is encoded once with vendored libopusenc over libopus to the Ogg Opus `.opus` that tilla.md describes (16 kbps, mono). Its length is the translation's `audio_ms`.
- **Master:** the same PCM is also compressed to FLAC with vendored libFLAC. It is a lossless copy kept for re-encoding later. The app never downloads it.

When narration ends, the worker writes, per narrated language, the `.opus` and `.flac` as files in the draft's folder (`<POSTILLA_DRAFTS_DIR>/<draft_id>/<lang>.opus` and `.flac`, the same names as in a CLI story folder), and the draft stores their sha256s, `audio_ms` and each sentence's times, then stops at `listening`. So `listening` and publishing survive a restart. The folder isn't in `postilla.db`, so Litestream doesn't back it up: a lost VPS loses unpublished narration, which is narrated again.

#### Listening

After `narrating`, a draft stops at `listening` instead of publishing. At `listening`:

- `GET /drafts/<id>/audio?lang=<id>` returns that language's `.opus` (`audio/ogg`). It answers in any state where the draft holds that audio (at `listening`, and at `review` or `failed` after it), not only here. `lang` must name a language with `target` 1, or the request gets a 400; a draft that holds no audio for it gets a 404 (`no audio: it`).
- `POST /drafts/<id>/publish` starts `publishing`.
- `POST /drafts/<id>/renarrate` discards the audio and goes back to `narrating`.
- `POST /drafts/<id>/review` takes the draft back to `review` with every edit, the audio and the sentence times kept. On the next approve, the edit rule applies: narration reruns only for a narrated language whose sentences changed (then `listening` again); otherwise the draft goes straight to `publishing`.
- `POST /drafts/<id>/discard` works as in `review`.

A draft whose narration didn't run (an edit with no sentence change) goes from `approve` straight to `publishing`, since there is nothing new to hear.

#### Vocabulary coverage

`band_words` is four counts: how many of an Italian translation's `words` fall in each NVdB band, using `entry.band` from `dict.db` (0 outside · 1 fondamentale · 2 alto uso · 3 alta disponibilità). The four add up to `words`. Counts, not percentages, so they stay integers and the app computes the share.

A word takes the most common band among the lemmas its form leads to in `dict.db` (1 before 2 before 3 before 0): "porta" (*portare* 1, *porgere* 2) counts as band 1. A form with no lemma counts as band 0. The worker looks forms up the same way the app does on tap ([CONTRACT.md](CONTRACT.md)).

The worker gets `dict.db` the same way the app does. When a draft reaches `publishing`, it reads `dict/latest` from the public bucket, downloads that build into `POSTILLA_DICT_DIR` if it doesn't have it, and computes `band_words` from it. It keeps only the current build there and deletes older ones once it has switched. A new dictionary needs no restart. An R2 failure there is a failed try like any other R2 call. An older story's `band_words` reflect the bands at its publish time until it is republished.

A `.tilla` word is only a span, looked up by form; `dict.db` entry ids change between builds (ARQ-35) and nothing stores them, so a dictionary rebuild never touches a published story.

#### Publishing

The worker writes one `.tilla` per translation ([tilla.md](tilla.md)): the story-level fields, the translation's title, subtitle and sentences, its word spans by the word rule in tilla.md, `words`, `band_words`, and, for a narrated translation, `audio_ms`, `opus_sha256`, `opus_size` and the sentence times. The gzip is deterministic, so an unchanged translation gives the same `.tilla.gz` and sha256.

It uploads every translation's `.tilla.gz`, and every new `.opus` and `.flac`, to R2 under the keys in [Files in R2](specification.md#files-in-r2). Audio reused from the published version is already there. Last, after every file is in R2, it upserts every translation's `story` row in one `BEGIN IMMEDIATE` transaction: a row whose sha256 changed, or that is new, gets `change` `published` and the next cursor; a row whose sha256 is the same keeps its cursor. So a syncing app sees all of a story's changed translations or none. Only then is the draft `published`, and its folder is deleted, since R2 has the files; the sha256s, `audio_ms` and sentence times stay, because an edit draft copies them to reuse the audio. Discard deletes the folder too.

#### `POST /drafts`

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

A draft for a story id that is already published counts as a republish: on publish, every changed translation gets a new cursor (see [Cursor](specification.md#cursor)). A rewrite that adds or removes paragraphs is a new `POST /drafts` with the same id, which runs the whole pipeline.

#### `POST /stories/<id>/edit`

Copies the story's latest published draft (header, and every language's title, subtitle and sentences, with the audio's sha256s, `audio_ms` and sentence times) into a new `edit` draft that starts at `review`, and answers `202` with the draft id as a `u32`, like `POST /drafts`. No body. `<id>` is the story UUID in its written form.

The copy checks the header against the current lists: tags no longer in `tag` are dropped, since they're optional (authors are permanent, so the author always carries over). A genre no longer in `genre` is kept, and `approve` gets a 409 until `PUT /drafts/<id>/header` sets a listed one. So a republished story only ever carries listed ids.

At `review`, `PUT /drafts/<id>/translation` edits any language, the Italian included, and `PUT /drafts/<id>/header` replaces the header; `POST /drafts/<id>/approve` republishes, as for any draft. Moderation doesn't rerun unless the Italian changed ([Moderation](#moderation)).

A story id that isn't published gets a 404, a removed one a 409, and a story with a draft in progress a 409.

#### `POST /stories/<id>/narrate`

Narrates a published story again, when its text hasn't changed. It copies the story's latest published draft like `/edit`, into a new `narrate` draft that starts at `narrating`: it narrates every translation in a language with `target` 1 (today only `it`), then stops at `listening`. The new audio replaces the old on publish. If the story lacks a language with `translate` 1, the copy goes through `translating` and `review` for it first, and approve then narrates.

No body. The response is `202` with the new draft id as a `u32`. A story id that isn't published gets a 404, a removed one a 409, and a story with a draft in progress a 409.

#### `GET /drafts?state=<state>`

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

#### `GET /drafts/<id>`

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

#### `PUT /drafts/<id>/translation`

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

#### `PUT /drafts/<id>/header`

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

#### Draft actions

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

#### Status codes

| Code | When |
|---|---|
| 200 | Success |
| 202 | Draft created |
| 400 | Bad `since`, `lang` or `state`; a story id that isn't a UUID; a body that fails the parse (including a translation edit that changes a sentence count it may not); an unknown genre, tag or author |
| 401 | Missing or wrong bearer token on an authoring endpoint |
| 404 | Any other path or method, an unknown or non-numeric draft id, audio a draft doesn't hold, or a story id that isn't published on `/edit`, `/narrate` or `DELETE` |
| 409 | An action on a draft that isn't in the state it needs; a new draft for a story that already has one in progress or that was removed; a revision mismatch; `DELETE` of a story with a draft in progress; `approve` with a genre no longer listed |
| 500 | SQLite error |

#### Draft tables

The drafts live in their own tables; the exact columns are left to the implementation. They hold:

- per draft: its id, story id, `kind`, `revision`, the header fields and tags, `state`, failed step, attempt count, error, moderation probabilities, and whether the held review comes from re-moderation;
- per draft and language: the title and subtitle, and whether that language's translation is done;
- per sentence, keyed by draft, paragraph, position and language: the text, and for a narrated language its `start_ms` and `end_ms`;
- per draft and narrated language (`draft_audio`): the sha256s of the `.opus` and `.flac` and `audio_ms`. The files themselves are in the draft's folder until it is published or discarded: about 0.5 MB of `.opus` for a 4-minute story at 16 kbps, and several MB of `.flac`.

Creating a draft checks for a draft in progress and for a removed story, and inserts the new one, in the same `BEGIN IMMEDIATE` transaction, so two requests at once can't both pass the check.

## Later

Not assigned to a version yet.

### Authoring app

An app to create, edit, approve and remove stories. What it needs first is [v1.2](#v12-drafts): drafts, listing, edit drafts, the `listening` state and `/narrate`. After that:

- **Restore a removed story:** removal (see [`DELETE /stories/<id>`](specification.md#delete-storiesid)) keeps the rows and the R2 files, so a story can come back. Proposed: `POST /stories/<id>/restore` (bearer token) sets every translation's `change` back to `published` with new cursors and the old `sha256`, in one transaction; apps download the files again. Alternatives: only through a new draft with the same id, or never.
- **Web authoring app:** the first authoring clients are native, desktop and CLI, so the backend has no CORS. A web version later needs CORS on the token endpoints for one origin set in env (e.g. `POSTILLA_AUTHOR_ORIGIN`): answer the `OPTIONS` preflight with `204`, allow `Authorization` and `Content-Type` and the methods in use; other origins get no CORS headers. Serving it from the API's own domain through Caddy avoids CORS instead.
- **Auth:** one bearer token (`POSTILLA_AUTHOR_TOKEN`) works for a single editor; more editors need per-user tokens.

### Card data in the feed

Today the learner app draws story cards from the `.tilla` headers it downloads during sync ([Stories and translations](specification.md#stories-and-translations)). An alternative: each `FEED` record carries the card fields after its fixed part (title, subtitle, level, genre, tags, author, work, part, `words`, `audio_ms`, `band_words`; empty when removed), stored on the `story` rows by the worker at publish from the same draft that writes the `.tilla`. Cards would draw right after a sync, and `.tilla` files could download when a story is opened, behind a "Downloading…" dialog, making the first sync tiny. The costs: variable-length `FEED` records on the hot path, the header written in two places, and stories not readable offline until opened once.

### Picking the right lemma for each word

Today a `.tilla` word is only a span ([tilla.md](tilla.md)): on tap, the app looks the form up in `dict.db` and shows every lemma it leads to, so *porta* opens *porta*, *portare* and *porgere*, and *siede* in *si siede* opens *sedere*, not *sedersi*. `band_words` uses the most common band among the candidates. Most forms lead to one lemma, so this only matters for the ambiguous minority, which are often very common words.

The feature: the worker picks the lemma each ambiguous word has in its sentence, and the `.tilla` stores the pick so the app opens exactly that entry.

- **Multi-word forms first:** match the longest run of words that `dict.db`'s `form` table knows ("si siede" → *sedersi*, fixed expressions), and emit one span for it. Deterministic, no model.
- **Ambiguous single words:** pick one lemma from the candidates `dict.db` gives. To choose between:
  - **An LLM** (DeepSeek, already called per paragraph during translation): send the sentence and the candidate lemmas, get the choice back. No new service, and picks are reviewed at `review` like translations; the costs are a larger prompt or an extra call, and one more thing to review.
  - **An Italian POS tagger and lemmatizer:** a dedicated model, deterministic for a given version and usually very accurate on standard prose, but a Python/ML stack the Zig backend would run as a sidecar service.
- **Storing the pick:** as the lemma's text, `word` and `pos` (*portare* + `verbo`), not `entry.id`, because ids change with every `dict.db` build (ARQ-35, [CONTRACT.md](CONTRACT.md)) and `(word, pos)` names an entry across builds. Only ambiguous words carry one; the app falls back to the form lookup when the pair isn't found.
- **Then:** `band_words` takes the picked lemma's band instead of the most common band, and the authoring app shows the picks at `review` so they can be corrected.

### Infrastructure as code

Done: [`infra/`](../infra/README.md) (OpenTofu, Cloudflare and Vultr providers, state in a private R2 bucket). Still open: whether the postilla-content build's R2 token is managed there too.
