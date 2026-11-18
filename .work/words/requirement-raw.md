Source: the docs at 3e75d29 (no separate PO paste; the docs are the requirement).
Scope given by the user: slice `words` = src/words.zig (word rule, normalization, lookup chain),
exported as a module, with `zig build dart` generating the app's normalization table.

From docs/tilla.md:

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

The letter table covers the whole letter range above. It was generated once from Python's `unicodedata` (decompose, drop marks, lowercase) plus the hand-written entries for letters that don't decompose, and is committed as a literal table in `words.zig`; nothing reads Unicode data at build or run time, so every program and platform gives the same bytes. The output is UTF-8.

### Looking a word up

The CLI (for `band_words`) and the app (on tap) look a word up in `dict.db` the same way, and stop at the first step that finds a form:

1. `form` = the word as written.
2. `form_norm` = the normalized word.
3. If the word has an apostrophe between two letters, steps 1 and 2 again on the part after the last such apostrophe: *l'aria* → *aria*, *dell'anno* → *anno*, *c'è* → *è*.

A word that finds nothing has no lemma: on tap the app says so, and in `band_words` it counts as band 0.

From docs/specification.md, Process:

- **`words`:** `src/words.zig`, the word rule, the normalization and the lookup chain ([tilla.md, Words](tilla.md#words)), with no dependencies. `build.zig` exports it as a module, so postilla-content imports the same code through a `build.zig.zon` dependency on this repo; SQLite is a lazy dependency, so importing `words` doesn't fetch it. `zig build dart` writes the app's normalization table (`zig-out/dart/words_norm.dart`) from the same source.

From docs/content-handoff.md:

## 3. Splitting and normalizing with the shared `words` module

The word rule, the normalization and the lookup chain are now defined in [tilla.md, Words](tilla.md#words) and implemented once, in postilla-backend's `src/words.zig`. The build stops using its own `tokenize` and `normalize` (`src/stories.zig`, `src/main.zig`): it adds postilla-backend to its `build.zig.zon` (git URL, pinned hash), imports the `words` module, and computes `form_norm` and `word_norm` with it, so the backend's `band_words` and the app's taps see the same strings as the dictionary. Forms must follow the word rule, truncations included (*po'*), and elided combinations (*l'aria*) no longer need their own forms: the lookup falls back to the part after the apostrophe. Update CONTRACT.md's "Palavra" section to point at tilla.md.

From docs/app-handoff.md, Word lookup:

- On tap, take the text under the span and look it up in the device's `dict.db` by the lookup chain in [tilla.md, Words](tilla.md#words): `form`, then `form_norm`, then, for an elided word (*l'aria*), the part after the apostrophe. Normalize with the Dart table that postilla-backend generates (`zig build dart`), never with `toLowerCase()` or Unicode decomposition, whose results differ between platforms; the table gives the same bytes as the dictionary build's `form_norm`. The app never splits words itself: spans come from the `.tilla`. Show every lemma the form leads to ("porta" → *porta*, *portare*, *porgere*). Never store `entry.id`: it changes with every dictionary build (ARQ-35).
