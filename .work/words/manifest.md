# Manifest — words

## Files to touch
- `build.zig` — export `src/words.zig` as the module `words` (`b.addModule`); fetch SQLite
  with `b.lazyDependency` so a package importing only `words` doesn't fetch it; import
  `words` into the test roots; add the step `zig build dart`, which builds and runs
  `tools/dart_gen.zig` (importing `words`) and installs `zig-out/dart/words_norm.dart`; make
  `zig build test` also run `dart run test/words_check.dart` against that file (AC-10).
- `build.zig.zon` — mark the `sqlite` dependency `.lazy = true`; add `tools` to `.paths`.
- `.agents/pipeline/config.json` (untracked tooling) — `paths.generated` gains
  `src/words_table.zig`, so the budget and minimize skip the generated table.
- `docs/specification.md` — Process, `words` bullet: the exported functions (`split`,
  `normalize`, `lookupKeys`), the caller-sized buffers, where the table comes from, and that
  `zig build test` needs `dart` on the PATH.
- `docs/tilla.md` — Words: name `src/words_table.zig` and `tools/words_table.py` as the
  table's source, and `lookupKeys` as the chain's keys.

## New files
- `src/words.zig` — `Span`, `split`, `normalize`, `lookupKeys` and the two edge lists.
- `src/words_table.zig` — generated: the letter → replacement table for U+00C0–U+024F
  (minus × and ÷). Not counted against the `added` budget.
- `test/words.zig` — the Zig tests for AC-1 … AC-9 and AC-F1.
- `test/words_check.dart` — runs the generated Dart `normalize` and `lookupKeys` on the
  AC-6, AC-7 and AC-8 inputs and checks them against expected outputs (AC-10).
- `tools/words_table.py` (generator of `src/words_table.zig`: Python `unicodedata` plus the
  hand entries; run by hand, never at build time) and `tools/dart_gen.zig` (writes the Dart
  file from `words`). Outside `src/`, so outside the production budget.

## Public symbols to add
- `words.Span` — a word's byte range, `{ start: u16, end: u16 }`, the `.tilla` word.
- `words.split` — the word rule.
- `words.normalize` — the normalization.
- `words.lookupKeys` — the ordered lookup keys.
- `words_table.table` (in the generated file) — the replacement table `words` and the Dart
  generator both read.

## Reused, not rebuilt
- `build.zig` `module()` and the `test/` scan; the SQLite dependency, made lazy.
- `std.unicode` for UTF-8 decoding (no hand-written decoder).

## Budget
added 220 · new files 2 · new public symbols 5

`src/words.zig` is about 150 lines; the generated table is excluded from `added` but still
counts as a new file.

## API
settled
