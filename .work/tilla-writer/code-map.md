# Code map — tilla-writer

Base f2367df (scaffold, server-read, server-write, words). No `.tilla` code exists.

## Reuse

- `src/words.zig:8` `Span` (`{ start: u16, end: u16 }`, the `.tilla` word), `:15`
  `split(text, out) []Span` (caller buffer, `out.len >= text.len` is enough), `:72`
  `lookupKeys(word, buf, keys) []const []const u8` (2–4 keys in chain order: as written,
  normalized, then both for the part after the last inner apostrophe; a key equal to the one
  before it is skipped).
- `src/wire.zig:66` `Writer` (`header`-style magic is 4 bytes there; `.tilla`'s magic is the
  5 bytes `TILLA`, so write it with `bytes`), `int`, `bytes`, `str`; `:61` `strSize` for
  sizing; `:40` `Lang` (8 zero-padded bytes for `lang` / `original`); `:10` `StoryId`.
- `src/db.zig:53` `open`, `:9` `Db.prepare`, `:31` `Stmt` (`step`, `bytes`; binds and column
  ints are raw `c.sqlite3_*` calls today, as in `src/server.zig`).
- `std.compress.flate.Compress` with the gzip container (Zig 0.17 std): no new dependency.
- `std.crypto.hash.sha2.Sha256`.

## Contract

- `docs/tilla.md`: header field order and types, paragraphs, sentence (`text`, `word_count`,
  words, `start_ms`, `end_ms`), the reader rules 1–8, sha256 of the `.tilla` before gzip.
- `docs/specification.md`, Vocabulary coverage: `band_words` counts per NVdB band, a word
  takes the most common band among its lemmas (1 before 2 before 3 before 0), no lemma = 0,
  only for Italian; other languages carry four zeros.
- `docs/CONTRACT.md`: `entry(id, word, word_norm, pos, band, data)`,
  `form(form, form_norm, entry_id)`.

## Not here yet

- `story.json` parsing, R2 upload, `POST /stories`: slice `cli-publish`, which calls this.
- The `dict.db` download (`dict/latest`, `POSTILLA_DICT_DIR`) is cli-publish's; this slice
  takes the path of a `dict.db` that is already on disk.

## I/O boundaries crossed

- SQLite: reading `dict.db`.
