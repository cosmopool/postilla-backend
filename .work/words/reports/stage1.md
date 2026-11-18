# Stage 1 — build report: words

## AC-to-test map

`scripts/pipeline/ac-map.sh --slug words` exited 0. Its output, verbatim:

```json
{
  "map": {
    "AC-1": [
      "test/words.zig:47 AC-1: a sentence splits into its words, as byte ranges of the text"
    ],
    "AC-2": [
      "test/words.zig:62 AC-2: an apostrophe or hyphen between letters joins, between digits it separates"
    ],
    "AC-3": [
      "test/words.zig:73 AC-3: edge apostrophes belong only to the words in the two closed lists"
    ],
    "AC-4": [
      "test/words.zig:83 AC-4: letters and digits form one run, \u00d7 and \u00f7 separate"
    ],
    "AC-5": [
      "test/words.zig:90 AC-5, AC-6: a combining accent belongs to the letter before it, and normalizes a"
    ],
    "AC-6": [
      "test/words.zig:90 AC-5, AC-6: a combining accent belongs to the letter before it, and normalizes a",
      "test/words.zig:97 AC-6: normalize lowercases to the base letter and unifies apostrophes and hyphen",
      "test/words.zig:220 AC-10, AC-6, AC-7, AC-8: the generated Dart normalize and lookupKeys give the Zi"
    ],
    "AC-7": [
      "test/words.zig:111 AC-7: every letter in U+00C0\u2013U+024F normalizes to lowercase ASCII letters, once ",
      "test/words.zig:220 AC-10, AC-6, AC-7, AC-8: the generated Dart normalize and lookupKeys give the Zi"
    ],
    "AC-8": [
      "test/words.zig:127 AC-8: lookupKeys gives the keys to try in order, skipping one equal to the key b",
      "test/words.zig:220 AC-10, AC-6, AC-7, AC-8: the generated Dart normalize and lookupKeys give the Zi"
    ],
    "AC-9": [
      "test/words.zig:142 AC-9: a package that imports only `words` builds and runs without fetching SQLit"
    ],
    "AC-10": [
      "test/words.zig:220 AC-10, AC-6, AC-7, AC-8: the generated Dart normalize and lookupKeys give the Zi"
    ],
    "AC-F1": [
      "test/words.zig:134 AC-F1: bytes that aren't valid UTF-8 separate words and normalize unchanged"
    ],
    "AC-F2": [
      "test/words.zig:251 AC-F2: zig build dart fails with the filesystem error when its directory can't b"
    ]
  },
  "uncovered": [],
  "unknown": [],
  "testFiles": [
    "test/words.zig"
  ],
  "run": {
    "expect": null,
    "passed": null,
    "asExpected": true
  }
}
```

## Candidates

Three candidates passed the AC tests, at 134, 132 and 131 added lines.

## Winner

Candidate 3 won, at 131 added lines. One private char() decoder returns each character's normalization (from the generated dense table) plus its byte length, and split, normalize and lookupKeys all classify characters by that normalization. build.zig exports `words`, returns before the lazy SQLite dependency when it isn't the root package, and generates the Dart file at configure time by calling words.normalize.

## Minimality review

Accepted with no violations. budget.sh exited 0: added 131 of 220, new files 1 of 2, new public symbols 4 of 5, exceeded []. src/words.zig adds only the approved symbols: Span, split, normalize and lookupKeys, all public, plus the generated table. Its private helpers (char, at, isLetter, isAlnum, inList) each have several call sites or exist for the normalized-word edge-list match the requirement asks for. It decodes UTF-8 with std.unicode and does not rebuild anything listed as reusable. The repo has nothing word-related to duplicate: the only UTF-8 code is src/wire.zig:121, which validates and does not decode. build.zig needs both the isRoot early return and the lazy SQLite dependency for AC-9: the first stops a package that imports only words from asking for SQLite, the second stops the package fetch from pulling it eagerly. The one difference from the manifest makes the diff smaller. There is no tools/dart_gen.zig: build.zig writes the Dart file itself, and build.zig.zon does not add tools to .paths. That is one approved file not created, not an unapproved surface. The Dart normalize and lookupKeys are required by AC-10. lookupKeys takes an extra keys out-parameter, which follows from the decision that nothing allocates. A competent engineer who had read the ACs would not have written materially less.

## Flagged but not fixed

Nothing. The reviewer flagged no violation, so nothing was left unfixed.
