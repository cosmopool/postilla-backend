# `.tilla` format

One `.tilla` holds one translation of one story: its header, then its paragraphs. This repo's CLI (`postilla publish`) is the only writer, through `tilla.build` in `src/tilla.zig`; the learner app is the reader. The file is stored gzipped as `stories/<id>/<lang>/<sha256>.tilla.gz` in the public R2 bucket, where `sha256` is the hash of the `.tilla` before gzip (see [Files in R2](specification.md#files-in-r2)). The same `.tilla` always has the same sha256, whatever gzip library or level wrote the `.gz`, so an edit that leaves a translation's content unchanged leaves its key and cursor alone, and no app downloads it again. A reader checks the sha256 after gunzip. Machine-readable layout: [formats/tilla.ksy](formats/tilla.ksy).

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

The story-level fields (`original`, `level`, `genre`, tags, `work`, `part`, `author`, `adapted`, `license`) are the same in every translation of a story; `postilla publish` writes them from the same `story.json`.

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

A word is only a span: the file never names a dictionary entry; the app looks words up by form ([app-handoff.md](app-handoff.md#5-word-lookup)). So `dict.db` entry ids are free to change between builds (ARQ-35), and a dictionary rebuild never touches a published story. Every word is listed, in every language, by the word rule in [Words](#words). Every translation carries its spans, so a language that is native today can become a target later without republishing; which spans the app makes tappable is in [app-handoff.md](app-handoff.md#5-word-lookup). Spans count UTF-8 bytes of `text`, the same unit as its `str` length, so the file has one unit and one byte order throughout; this replaces the old `stories.db` spans, which were little-endian UTF-16 units of the whole paragraph.

Paragraph *p*, sentence *s* is the same sentence in every translation of the story, so two translations line up by index.

## Words

The word rule, the normalization and the lookup are one piece of Zig code, `src/words.zig` in postilla-backend, exported by its `build.zig` as the module `words`. The CLI uses it to write spans and compute `band_words`; the postilla-content dictionary build imports the same module (a `build.zig.zon` dependency on postilla-backend) to split and normalize its `form` and `form_norm` columns; the learner app gets the normalization as a Dart table generated from the same source (`zig build dart`). This section is what that code does. A change to any of it changes spans or lookups, so it ships as one change to the module, its generated Dart table and this section.

### Characters

- **Letter:** `A`–`Z`, `a`–`z`, and U+00C0–U+024F except `×` (U+00D7) and `÷` (U+00F7): Latin-1 Supplement and Latin Extended-A and B, which cover Italian, Portuguese and the Italian dialects. A combining accent (U+0300–U+036F) right after a letter counts as part of that letter. Any other script is not a letter until this range grows.
- **Digit:** `0`–`9`.
- **Apostrophe:** `'` (U+0027), `’` (U+2019), `ʼ` (U+02BC).
- **Hyphen:** `-` (U+002D), `‐` (U+2010), `‑` (U+2011).
- Everything else separates words and is never part of one.

### The word rule

1. A word is a run of letters and digits (`casa`, `1860`, `A1`).
2. An apostrophe or a hyphen with a **letter** right before it and a **letter** right after it joins the two runs into one word: *l'aria*, *c'è*, *dell’anno*, *porta-finestra*. Between digits, or between a letter and a digit, it separates: `3,5` and `3-5` are two words each, and `anni '80` is `anni` and `80`.
3. An apostrophe at the edge of a word belongs to it only for the words in two closed lists, matched on the word's normalized text:
   - **Final apostrophe** (truncations): *po, va, fa, da, di, sta, to, mo, be, ca, pie, vo, te*. So *po'* and *va’* are words; in *'casa'*, used as a quotation, both apostrophes are separators.
   - **Leading apostrophe** (colloquial clippings): *sto, sta, sti, ste, na, ndrangheta*. So *'sto* and *'na* are words.

   The final apostrophe must not be followed by a letter or digit, and the leading one must not be preceded by one; otherwise rule 2 or rule 1 applies.
4. A span is the word's byte range in the sentence text, `start` to `end`, including any joined or edge apostrophes and hyphens as they are written. Spans keep the original characters; only lookups normalize.

### Normalization

`form_norm`, `word_norm` and every lookup use the same function, character by character:

- A letter becomes its lowercase base letter with every mark removed: `À`, `à`, `á`, `â` → `a`; `Ç` → `c`; `Ñ` → `n`. Letters with no decomposition take their closest base: `ø` → `o`, `đ` → `d`, `ł` → `l`, `ħ` → `h`. The ligatures `æ`, `œ`, `ß` become `ae`, `oe`, `ss`.
- A combining accent is dropped.
- Every apostrophe becomes `'` and every hyphen `-`.
- Digits and every other character stay as they are.

The letter table covers the whole letter range above. It was generated once from Python's `unicodedata` (decompose, drop marks, lowercase) plus the hand-written entries for letters that don't decompose, and is committed as a literal table, `src/words_table.zig`, written by `tools/words_table.py` (run by hand, never at build time); nothing reads Unicode data at build or run time, so every program and platform gives the same bytes. The output is UTF-8.

### Looking a word up

The CLI (for `band_words`) and the app (on tap) look a word up in `dict.db` the same way, and stop at the first step that finds a form:

1. `form` = the word as written.
2. `form_norm` = the normalized word.
3. If the word has an apostrophe between two letters, steps 1 and 2 again on the part after the last such apostrophe: *l'aria* → *aria*, *dell'anno* → *anno*, *c'è* → *è*.

`words.lookupKeys` gives these keys in order, skipping a key equal to the one before it; the caller runs them against `form` and `form_norm`.

A word that finds nothing has no lemma: on tap the app says so, and in `band_words` it counts as band 0.

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

The writer makes rules 2, 5, 6 and 8 hold by construction: it refuses, before writing a byte, an empty title, subtitle, paragraph list, paragraph or sentence, a sentence over 65 535 bytes (a span's `u16` can't reach past it), more than 65 535 words in a translation, more than 65 535 tags, paragraphs or sentences in a paragraph (their counts are `u16`s), a narration without one time pair per sentence, and times that break rule 8.

## Audio

The `.opus` is Ogg Opus, 16 kbps, mono, encoded once from the narration's PCM; sentence times are in milliseconds from the start of the decoded audio. A reader checks a downloaded `.opus` against `opus_size` and `opus_sha256`.
