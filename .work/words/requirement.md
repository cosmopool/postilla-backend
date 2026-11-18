# Shared word module (words)

## Summary

`src/words.zig`: the word rule (split a sentence into word spans), the normalization
(`form_norm`) and the lookup keys, exactly as `docs/tilla.md` (Words) defines them, with no
dependencies. `build.zig` exports it as the module `words` so postilla-content can import the
same code, makes SQLite a lazy dependency so importing `words` doesn't fetch it, and adds
`zig build dart`, which writes the learner app's normalization table plus `normalize()` and
`lookupKeys()` in Dart from the same source.

## Specified

- Characters: "Letter: `A`–`Z`, `a`–`z`, and U+00C0–U+024F except `×` (U+00D7) and `÷`
  (U+00F7) … A combining accent (U+0300–U+036F) right after a letter counts as part of that
  letter." "Digit: `0`–`9`." Apostrophes `'` `’` `ʼ`, hyphens `-` `‐` `‑`; "Everything else
  separates words".
- Word rule 1–4 (runs of letters and digits; a joiner with a letter on both sides joins; the
  final-apostrophe list *po, va, fa, da, di, sta, to, mo, be, ca, pie, vo, te* and the
  leading-apostrophe list *sto, sta, sti, ste, na, ndrangheta*, matched on the normalized
  word; spans are byte ranges keeping the original characters).
- Normalization: lowercase base letter, marks removed; `ø`→`o`, `đ`→`d`, `ł`→`l`, `ħ`→`h`;
  `æ`, `œ`, `ß` → `ae`, `oe`, `ss`; combining accents dropped; apostrophes → `'`, hyphens →
  `-`; digits and everything else unchanged; "generated once from Python's `unicodedata` …
  committed as a literal table in `words.zig`; nothing reads Unicode data at build or run
  time".
- Lookup: "`form` = the word as written", "`form_norm` = the normalized word", then for a
  word with an apostrophe between two letters, the same two on "the part after the last such
  apostrophe".
- Process: "`build.zig` exports it as a module … SQLite is a lazy dependency, so importing
  `words` doesn't fetch it. `zig build dart` writes the app's normalization table
  (`zig-out/dart/words_norm.dart`) from the same source."

## Decided

- **Lookup API returns keys, not results:** `words.lookupKeys(word, buf)` gives the 2–4
  strings to try, in order (as written, normalized, then the same two for the part after the
  last inner apostrophe), skipping a key equal to the one before it. Callers run them against
  `form` / `form_norm` with their own SQLite. Rejected: a function that queries dict.db
  (would make `words` depend on SQLite).
- **`zig build dart` generates the table and the logic:** one Dart file with the
  code-point → replacement const map, `normalize(String)` and `lookupKeys(String)`, written
  by a generator that reads the same Zig table and lists. Rejected: the table alone (the app
  would reimplement the logic).
- **No allocation:** `split(text, out: []Span) []Span` fills a caller buffer (a sentence of
  n bytes has at most n words, so `out.len >= text.len` is always enough);
  `normalize(text, out: []u8) []u8` writes into a caller buffer, and normalized text is never
  longer than its input (every replacement is no longer than the bytes it replaces), so
  `out.len >= text.len` is enough. `Span` is `{ start: u16, end: u16 }`, the `.tilla` word.
- **Bytes that aren't valid UTF-8** count as separators; callers pass validated text (the CLI
  validates `story.json`), so this only keeps the functions total.
- **The table lives in its own generated file** `src/words_table.zig`, listed under
  `paths.generated` in the pipeline config, written by `tools/words_table.py` (Python
  `unicodedata` plus the hand entries) and committed; the Python script runs only when the
  table is regenerated, never at build time.
- **The Dart generator** is a Zig program in `tools/` that imports `words`; `zig build dart`
  builds and runs it.
- Edge-list matching uses the normalized word (case- and accent-insensitive), as specified.

## Assumed

- **Spans fit in u16:** no sentence is longer than 65 535 bytes. Blast radius: a longer
  sentence would need a `.tilla` format change; `split` returns no span past 65 535.
  Confirm: owner (the CLI could refuse such a sentence).
- **postilla-content can depend on postilla-backend by git URL and pinned hash.** Blast
  radius: none here; the content build changes. Confirm: owner (content-handoff §3).

- **The Dart SDK is on the machine that runs `zig build test`.** The Dart check needs
  `dart` on the PATH (3.14.1 in this sandbox). Blast radius: on a machine without it, the
  test step fails rather than skipping. Confirm: owner (CI image).

## Non-goals

- Looking anything up in dict.db (the caller's job), computing `band_words` (tilla-writer).
- Any script other than the Latin ranges; Unicode category tables.
- Publishing the Dart file anywhere: it's written to `zig-out/dart/`.
- Changing the server or the CLI.

## Acceptance criteria

AC-1: Given "C'era una volta un re.", when split, then the spans are `C'era`, `una`, `volta`,
      `un`, `re`, as byte ranges of the text.
AC-2: Given *l'aria*, *dell’anno* (U+2019), *porta-finestra* and *porta‐finestra* (U+2010),
      then each is one word; given `3,5`, `3-5` and `anni '80`, then the digits separate
      (`3` and `5`; `anni` and `80`).
AC-3: Given `po'`, `Va’` and `di'` at a word edge followed by a space or the end, then the
      final apostrophe is part of the span; given `'sto`, `'Na` after a space, then the
      leading apostrophe is part of the span; given `'casa'`, then the span is `casa` alone.
AC-4: Given `1860`, `A1` and `B2`, then each is one word; given `×` and `÷` between letters,
      then they separate.
AC-5: Given a letter followed by combining accents (`e` + U+0301), then the accent is inside
      the span; given a combining accent after a space, then it separates.
AC-6: Given "È GIÀ così", `perché`, `Straße`, `Œuvre`, `Ærø`, `Łódź`, `Đorđe`, `Ħal`, then
      normalize gives "e gia cosi", `perche`, `strasse`, `oeuvre`, `aero`, `lodz`, `dorde`,
      `hal`; given `l’aria`, `c‑è`, then `l'aria`, `c-e`; digits and punctuation are unchanged.
AC-7: Given every letter in U+00C0–U+024F except × and ÷, then normalize maps it to
      lowercase ASCII letters only, matching the committed table; given normalize applied
      twice, then the second pass changes nothing.
AC-8: Given *l'aria*, then lookupKeys gives `l'aria`, then `aria` (the normalized forms
      equal the ones before them and are skipped); given `Dell’Anno`, then `Dell’Anno`,
      `dell'anno`, `Anno`, `anno`; given `casa`, then `casa` only; given `po'`, then `po'`
      only (no apostrophe between two letters).
AC-9: Given a package that imports postilla-backend's `words` module, then it builds without
      fetching SQLite (the dependency is lazy).
AC-10: Given `zig build dart`, then `zig-out/dart/words_norm.dart` exists, its table has
       exactly one entry per entry of `src/words_table.zig` with the same replacement, and,
       run with the Dart SDK (`dart`, installed in the sandbox), its `normalize` and
       `lookupKeys` give the same results as the Zig functions on the AC-6, AC-7 and AC-8
       inputs. `zig build test` runs this check.
AC-F1: Given text containing bytes that aren't valid UTF-8, then split treats them as
       separators and normalize copies them unchanged, with no crash.
AC-F2: Given `zig build dart` when `zig-out/dart/` can't be created, then the build step fails
       with the filesystem error (the filesystem boundary, build time).

## Touched boundaries

- The filesystem, at build time only (`zig build dart` writes one file): AC-F2.
- Text from callers (not an I/O boundary, but hostile-shaped): AC-F1.
