# `.tilla` format

One `.tilla` holds one translation of one story: its header, then its paragraphs. The backend's worker is the only writer; the learner app is the reader. The file is stored gzipped as `stories/<id>/<lang>/<sha256>.tilla.gz` in the public R2 bucket, where `sha256` is the hash of the `.gz` (see [metadata.md](metadata.md#7-one-story-many-translations)). The gzip is deterministic: mtime 0, no file name, OS byte 255, and a fixed compression level and library, so the same `.tilla` always gives the same `.gz` and sha256. An edit that leaves a translation's content unchanged therefore leaves its key and cursor alone, and no app downloads it again. Machine-readable layout: [formats/tilla.ksy](formats/tilla.ksy).

Status: **draft**, recreated from what the backend docs recorded after the original TILLA.md was lost.

## Encoding

- Big-endian (network byte order) throughout, with no padding.
- `u8`, `u16`, `u32`: unsigned integers of 1, 2 and 4 bytes.
- `str`: a `u32` byte length, then that many bytes of UTF-8.
- `lang`: 8 bytes, a BCP 47 tag in ASCII, zero-padded (`it\0\0\0\0\0\0`, `pt-BR\0\0\0`).
- `sha256`: 32 bytes.

## Header

| Field | Type | Value |
|---|---|---|
| `magic` | 5 bytes | `TILLA` |
| `version` | `u8` | `1` |
| `id` | 16 bytes | Story id, the UUID's 32 hex digits as bytes in written order |
| `lang` | `lang` | This translation's language |
| `original` | `lang` | The language the story was written in (`story.lang`) |
| `title` | `str` | Title, in `lang` |
| `subtitle` | `str` | Subtitle, in `lang` |
| `level` | `u8` | 1 A1 · 2 A2 · 3 B1 · 4 B2 · 5 C1 · 6 C2 |
| `genre` | `str` | A `genre.id` |
| `tag_count` | `u16` | Number of tags that follow |
| `tags` | `str` × `tag_count` | `tag.id`s |
| `work` | `str` | Work name; `''` outside a work |
| `part` | `u16` | Part of the work; 0 outside a work |
| `author` | `str` | An `author.id`; `''` for a story written for Postilla |
| `adapted` | `u8` | 1 when adapted from `author`'s work, 0 otherwise |
| `license` | `str` | SPDX id, `public-domain`, or `LicenseRef-Postilla` |
| `words` | `u16` | Number of words in this translation |
| `band_words` | `u16` × 4 | Words in NVdB bands 0 (outside), 1, 2, 3 |
| `audio_ms` | `u32` | Length of the narration; 0 without narration |
| `opus_sha256` | `sha256` | sha256 of the `.opus`; all zero without narration |
| `opus_size` | `u32` | Bytes of the `.opus`; 0 without narration |
| `paragraph_count` | `u16` | Number of paragraphs that follow |

The story-level fields (`original`, `level`, `genre`, tags, `work`, `part`, `author`, `adapted`, `license`) are the same in every translation of a story; the worker writes them from the same draft.

## Paragraphs

`paragraph_count` paragraphs, in reading order. Each is a `sentence_count` (`u16`) followed by that many sentences:

| Field | Type | Value |
|---|---|---|
| `text` | `str` | The sentence |
| `word_count` | `u16` | Number of words that follow |
| `words` | word × `word_count` | The sentence's words, in order |
| `start_ms` | `u32` | Where the sentence starts in the `.opus`; 0 without narration |
| `end_ms` | `u32` | Where it ends; 0 without narration |

A word:

| Field | Type | Value |
|---|---|---|
| `start` | `u16` | Byte offset of the word's first byte in `text` |
| `end` | `u16` | Byte offset just past its last byte |

A word is only a span: the file never names a dictionary entry; the app looks words up by form ([app-handoff.md](app-handoff.md#5-word-lookup)). So `dict.db` entry ids are free to change between builds (ARQ-35), and a dictionary rebuild never touches a published story. Every word is listed, in every language, by the same word rule: letters and digits; an apostrophe or hyphen between letters joins (*l'aria*, *c'è*, *porta-finestra*); a final apostrophe stays in truncations (*po'*, *va'*); punctuation is never a word ([CONTRACT.md](CONTRACT.md)). Every translation carries its spans, so a language that is native today can become a target later without republishing; which spans the app makes tappable is in [app-handoff.md](app-handoff.md#5-word-lookup). Spans count UTF-8 bytes of `text`, the same unit as its `str` length, so the file has one unit and one byte order throughout; this replaces the old `stories.db` spans, which were little-endian UTF-16 units of the whole paragraph.

Paragraph *p*, sentence *s* is the same sentence in every translation of the story, so two translations line up by index.

## Reader rules

A reader rejects a file that breaks any of these, and keeps what it already had:

1. The file starts with the 6 bytes `TILLA` and `version` 1 (`54 49 4C 4C 41 01`). The reader never guesses at the layout of another version.
2. Every length fits in the file, and no bytes are left after the last paragraph.
3. Every `str` is valid UTF-8, and `lang` and `original` are non-empty ASCII followed only by zero bytes.
4. `level` is 1 to 6; `adapted` is 0 or 1; `work` is empty exactly when `part` is 0.
5. `paragraph_count` is at least 1, every `sentence_count` is at least 1, and no `text` is empty.
6. Words in a sentence are in order and don't overlap: `start < end`, `end <= len(text)`, each `start` at or after the previous `end`, and both on UTF-8 character boundaries.
7. The sum of all `word_count`s is `words`. When `lang` is `it`, the four `band_words` add up to `words`; when it isn't, they are all 0.
8. Narration: `audio_ms`, `opus_size` and `opus_sha256` are all zero exactly when every `start_ms` and `end_ms` is 0. With narration, every sentence has `start_ms <= end_ms <= audio_ms`, and each sentence starts at or after the previous one's `start_ms`.

## Audio

The `.opus` is Ogg Opus, 16 kbps, mono, encoded once from the narration's PCM; sentence times are in milliseconds from the start of the decoded audio. A reader checks a downloaded `.opus` against `opus_size` and `opus_sha256`.
