# Code map — words

Base 3e75d29 (scaffold, server-read, server-write). Nothing word-related exists yet.

## Existing code to reuse or touch

- `build.zig` — builds `postilla-server` and `postilla` from `src/server.zig` and
  `src/cli.zig`, links the SQLite amalgamation into both (`module()` helper), scans `test/`
  for test roots and imports `server` and `harness` into each. No module is exported with
  `b.addModule`, so another package can't import anything yet. The SQLite dependency is
  eager (`b.dependency("sqlite")`), so a package importing this one would fetch SQLite even
  for `words` alone.
- `build.zig.zon` — `sqlite` dependency (not `.lazy`).
- `src/wire.zig` — the binary encoding. Unrelated to words, but shows the module style
  (types with methods, no allocator, caller-sized buffers).
- `AGENTS.md` — Fail early: callers size buffers up front, deep code takes slices and needs
  no allocator.
- `.agents/pipeline/config.json` (`.claude/pipeline` symlinks to it): `paths.generated` is
  empty; the generated normalization table must be listed there so the budget and
  minimize skip it.

## Contract text

- `docs/tilla.md`, section Words: characters (letter ranges, digits, apostrophes, hyphens),
  the word rule (runs, joiners between letters, the two closed edge lists, spans as byte
  ranges), normalization (lowercase base letter, ligatures, dropped combining accents,
  apostrophes to `'`, hyphens to `-`), the lookup chain.
- `docs/specification.md`, Process, `words` bullet: module export, SQLite lazy,
  `zig build dart` → `zig-out/dart/words_norm.dart`.
- `docs/app-handoff.md` §5 and `docs/content-handoff.md` §3: what the app and the content
  build expect.

## Not here yet

- The `.tilla` writer and `band_words` (slice `tilla-writer`) will call `words` to split
  sentences into spans and to build lookup keys.

## I/O boundaries crossed

None at run time: `words` is pure. The build step `zig build dart` writes one file under
`zig-out/` (the filesystem, build time only).
