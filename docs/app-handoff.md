# Handoff to the learner app

What the Postilla learner app has to do with what the backend and postilla-content serve: its rules and business logic. The backend docs describe only what they guarantee and link here for the app side. Read [metadata.md](metadata.md) for the data model, [tilla.md](tilla.md) for the story file and [CONTRACT.md](CONTRACT.md) for `dict.db`. When an item is built in the app, record it in the app's own docs and remove it here.

## 1. Languages

- The learner picks a **target** language (what they learn) and a **native** language (what they read translations in) from `GET /languages`.
- Offer as target only languages with `target` 1 (today only `it`), and as native only languages with `translate` 1 (today only `pt-BR`); a language with `translate` 0 (like `en`, which exists for genre and tag names) has no story translations to read.
- Send both ids on every sync: `GET /stories?since=<cursor>&lang=<target>,<native>`. Ids are exact, case-sensitive BCP 47 tags as `GET /languages` lists them; the `<lang>` segment of an R2 key is the id verbatim, with the 8-byte zero padding of the binary field stripped.
- Language ids are permanent on the backend, so a stored choice never becomes invalid. A language whose `target` turns 0 stays usable for a learner who already chose it.
- When the learner switches target or native language, sync again from `since=0` with the new list, to get the new language's files for stories already on the device.

## 2. Syncing

- **Records.** Each `FEED` record is one translation: `id`, `lang`, `change`, `sha256`, `cursor`. `change` 1 `published` means download `sha256`; `change` 2 `removed` means delete the local copy of that story. A new story and an updated one look the same; tell them apart by whether the id is already on the device. Ignore a `removed` record for an id the device doesn't have (they come in every sync, `since=0` included). Any other `change` value is an error.
- **Atomic per story.** Group a sync's records by story `id`. Download that story's `.tilla.gz` files into a temporary directory and check each against its `sha256`. Only when every one of them is there and verified, move them into place in one step, replacing the old ones together. Until then the learner keeps the previous version. A story therefore never shows a new translation next to an old one.
- **Cursor.** Store a cursor only up to the highest cursor at or below which every record has been applied. A story that keeps failing holds the cursor back but doesn't block stories already applied, and after a crash the next sync returns the unapplied records again. (This replaces specification.md's "the app stores the largest cursor it received".)
- **No 404s.** The backend never deletes an R2 object, so a file the feed or a `.tilla` named is always there.
- **Restores.** After a rare database restore the backend may reuse a few cursors; the app does nothing special, and catches up once new cursors pass its own.

## 3. Cards and opening a story

- There is no catalog. Draw each story's card (title, subtitle, level, genre, tags, author, reading time, audio length, vocabulary coverage) from the header of its `.tilla` files, so a card appears once its story is applied.
- Tapping a story that is still downloading shows a "Downloading…" dialog until its files are applied.
- **Pairing.** Paragraph *p*, sentence *s* is the same sentence in every translation, so pair the target and native files by index. Show a paragraph by joining its sentences with a space.
- **Missing native translation.** Stories published before a language was added don't have it. Show such a story target-only, marked as having no translation in the learner's language: it opens with the target text alone, and word lookup and audio still work.
- **Reading position.** A republished story can change its sentence counts (an edit can split a sentence); clamp or reset a saved position that no longer exists.

## 4. Reading time, audio length, coverage

- **Reading time:** `words` ÷ the level's reading speed, rounded up: A1 60, A2 80, B1 100, B2 120, C1 140, C2 160 words per minute. The speeds live in the app.
- **Audio length:** show `audio_ms` ("4:12") when it isn't 0; 0 means no narration.
- **Vocabulary coverage:** `band_words` are counts per NVdB band (0 outside, 1 fondamentale, 2 alto uso, 3 alta disponibilità) that add up to `words` in Italian; the app computes the shares. In other languages they are all 0: show nothing.

## 5. Word lookup

- Offer word lookup only in the target language (restating TRA-04). Every translation carries word spans, but only the target's are tappable.
- On tap, take the text under the span and look it up in the device's `dict.db`: `form`, then `form_norm` if nothing matches. Show every lemma the form leads to ("porta" → *porta*, *portare*, *porgere*). Never store `entry.id`: it changes with every dictionary build (ARQ-35).
- **Span units.** Spans count UTF-8 bytes of the sentence text. Dart indexes a `String` in UTF-16 units, so map byte offsets to `String` indices once per sentence with a byte → index table (count one unit per UTF-8 lead byte, two for a 4-byte sequence). A benchmark put this at about 0.1 ms for a 5,000-word story on a desktop CPU. Don't decode each word separately: it's about 3× slower and gives no indices for highlighting.

## 6. Audio

- The `.opus` isn't part of a sync. Fetch it the first time the learner plays the story, check it against `opus_size` and `opus_sha256` from the `.tilla`, and cache it. A new `opus_sha256` after an update means fetching it again on the next play.
- Sentence times are milliseconds from the start of the decoded audio; highlight sentence *s* between its `start_ms` and `end_ms`.

## 7. Genres, tags and authors

- Cache `GET /genres`, `GET /tags` and `GET /authors`, and refetch all three whenever a sync returns at least one record, so a new entry arrives with the first story that uses it. A rename alone produces no feed record, so it shows up at the next sync that returns one.
- Names: genres and tags carry one column per language (`it`, `pt_br`, `en`): the column is the language id lowercased with `-` turned into `_`. Show the learner's native language's column.
- A list never hides a story. A genre the app doesn't know puts the story on an "Other" shelf; a tag it doesn't know isn't shown. Authors are permanent on the backend, so an unknown author only happens before the refetch; show it once it arrives.
- **Attribution.** Show the author and the license of every story whose `license` isn't `LicenseRef-Postilla` (`CC-BY-SA-4.0` requires credit). Map SPDX ids to a display name and URL in the app.

## 8. The dictionary

- Keep one `dict.db`, the latest. Read `dict/latest` from the public bucket (one line: lowercase hex sha256, a space, the `.gz` size), and download `dict/<sha256>.db.gz` when the sha differs from the device's copy, checking size and sha256. A new build replaces the old one; published stories keep working, since words are looked up by form.
- Show `dict.db`'s `meta.license` and `meta.attribution` (Wiktionary data) somewhere in the app.

## 9. Format versions and errors

- Every body and `.tilla` starts with a version. A reader that meets a version it doesn't know (`FEED`, a list body, `.tilla`) stops, keeps what it has, and asks the learner to update the app; it never guesses at the layout. The backend bumps a version only together with an app release that reads it.
- 4xx responses carry a one-line English reason as `text/plain`; the learner app ignores it.
- Rate limiting is on the backend's [roadmap](roadmap.md#rate-limit-on-public-endpoints): once it ships, a 429 carries `Retry-After`, and the app waits that long before retrying.

## Open on the app side

- The public bucket's base URL (specification.md, Open): the app needs it to build every download URL.
