# Manifest — tilla-writer

## Files to touch
- `build.zig` — import `words` and the new `tilla.zig` where the tests need them (the test
  roots already import `server`; tests reach `tilla` through a module the same way).
- `docs/tilla.md` — name `src/tilla.zig` as the writer and state the refusals (sentence and
  word limits) that make reader rules 2, 6 and 8 hold by construction.
- `docs/specification.md` — Building and uploading: `tilla.build` and how `band_words` tries
  each lookup key against `form`, then `form_norm`.

## New files
- `src/tilla.zig` — `Input`, `Built`, `build`.
- `test/tilla.zig` — the tests for AC-1 … AC-8 and AC-F1, with a small reader applying
  tilla.md's reader rules and a fixture `dict.db` created with CONTRACT.md's schema.

## Public symbols to add
- `tilla.Input` — what one translation needs: the story header, the translation, the
  optional narration.
- `tilla.Built` — the `.tilla` bytes, the `.gz` bytes and the sha256.
- `tilla.build` — the writer.

## Reused, not rebuilt
- `src/words.zig:15` `split`, `:72` `lookupKeys`, `:8` `Span`.
- `src/wire.zig:66` `Writer`, `:61` `strSize`, `:40` `Lang`, `:10` `StoryId`.
- `src/db.zig:53` `open`, `Db.prepare`, `Stmt.step`.
- `std.compress.flate.Compress` (gzip), `std.crypto.hash.sha2.Sha256`.

## Budget
added 220 · new files 1 · new public symbols 3

## API
settled
