# `.tilla` writer (tilla-writer)

## Summary

`src/tilla.zig`: turns one translation of a story (the story-level fields, the translation's
title, subtitle and sentences, and its narration when there is one) into the `.tilla` bytes
`docs/tilla.md` defines, with word spans from `words.split`, `words`, and `band_words` looked
up in a `dict.db`; then gzips it and hashes the uncompressed bytes. `postilla publish`
(slice `cli-publish`) will call it for every translation and upload the results.

## Specified

- The header and paragraph layout of `docs/tilla.md`, field by field, big-endian; every
  reader rule (1–8) holds for every file written.
- "Every word is listed, in every language, by the word rule in Words"; spans count UTF-8
  bytes of `text`.
- `band_words`: "how many of an Italian translation's `words` fall in each NVdB band, using
  `entry.band` … The four add up to `words`." "A word takes the most common band among the
  lemmas its form leads to … (1 before 2 before 3 before 0) … A word with no lemma counts as
  band 0." Other languages: four zeros.
- "The sha256 is taken of the `.tilla` before gzip"; the file is stored gzipped.
- Narration fields: `audio_ms`, `opus_sha256`, `opus_size` and each sentence's `start_ms` /
  `end_ms`; all zero without narration.

## Decided

- **One function, one value in, bytes out.** `tilla.build(arena, input, dict) !Built`, where
  `input` holds the story-level fields, the translation and its optional narration, and
  `Built` holds the `.tilla` bytes, the `.gz` bytes and the sha256 of the `.tilla`. An arena
  allocator is fine here: this is the CLI's cold path, once per translation.
- **The input type lives in `tilla.zig`** (`tilla.Input`, with the story header, `lang`,
  `original`, title, subtitle, paragraphs as `[]const []const []const u8`, and an optional
  narration: `audio_ms`, the `.opus` bytes' sha256 and size, and per-sentence times). The
  `story.json` parser in cli-publish fills it.
- **Lookup per key:** each key from `words.lookupKeys` is tried against `form`, then against
  `form_norm`; the first key that finds any row decides the word's band. The band is the
  lowest non-zero `entry.band` among the matched rows, or 0 if all are 0 or nothing matched.
  One prepared statement, reset per key.
- **`band_words` only when `lang == original == it`;** otherwise the dict isn't queried and
  the four counts are zero.
- **Refusals, as errors before any byte is written:** a sentence over 65 535 bytes (a span
  can't hold it), more than 65 535 words in the translation or in one sentence, an empty
  title, subtitle, paragraph list, paragraph or sentence, a narration whose sentence count
  differs from the text's, or times that break reader rule 8. These are the caller's input
  errors; cli-publish reports them as `story.json` problems.
- **gzip:** `std.compress.flate` with the gzip container at its default level; no fixed
  header bytes are promised (C5: the hash is of the uncompressed file).
- **Tests read the written file back** with a small reader in the test file that applies
  tilla.md's reader rules 1–8, and decompress the `.gz` with `std.compress.flate` to compare.

## Assumed

- **`dict.db` is the build CONTRACT.md describes** (`form`, `form_norm`, `entry.band`).
  Blast radius: a schema change there breaks the query. Confirm: postilla-content.
- **Only Italian has word data** for now. Blast radius: a second target language needs its
  own dictionary and this check generalised. Confirm: owner (roadmap).

## Non-goals

- Parsing `story.json`, downloading `dict.db`, uploading to R2, `POST /stories`.
- Reading `.tilla` in production code (the app is the reader).
- Choosing or verifying the `.opus` itself (cli-narrate makes it; this takes its sha256,
  size and length).

## Acceptance criteria

AC-1: Given an Italian translation of 2 paragraphs (2 and 1 sentences) without narration,
      when built, then the `.tilla` starts with `TILLA` 1, carries every header field in
      tilla.md's order with `lang` and `original` `it`, the four narration fields zero, and
      passes reader rules 1–8.
AC-2: Given that translation, then each sentence's words are the spans `words.split` gives,
      `words` is their total, and every `start_ms` / `end_ms` is 0.
AC-3: Given a `dict.db` where *porta* leads to entries of band 1 and 2, *casa* to band 1,
      *gatto* to band 2, *xyz* to nothing, and *l'aria* has no form but *aria* has band 3,
      then a sentence "porta casa gatto xyz l'aria" counts 2 in band 1, 1 in band 2, 1 in
      band 3 and 1 in band 0, adding up to `words`.
AC-4: Given a word whose `form` doesn't match but whose `form_norm` does ("Perché" →
      `perche`), then it takes that entry's band.
AC-5: Given a `pt-BR` translation, then `original` is `it`, `lang` is `pt-BR`, the four
      `band_words` are 0 and the dict isn't queried.
AC-6: Given a translation with narration (audio length, opus sha256 and size, one time pair
      per sentence), then those fields and every sentence's times are written, and reader
      rule 8 holds.
AC-7: Given the same input twice, then the `.tilla` bytes and the sha256 are identical, and
      the sha256 is the hash of the uncompressed `.tilla`, which the `.gz` decompresses to.
AC-8: Given an input that breaks a rule (an empty sentence, a sentence over 65 535 bytes, a
      narration with the wrong number of times, or times out of order), then `build` returns
      an error and writes nothing.
AC-F1: Given a `dict.db` path that can't be opened, or one missing the `form` table, then
       `build` for Italian returns `error.Sqlite` and writes nothing.

## Touched boundaries

- SQLite (`dict.db`): AC-F1.
