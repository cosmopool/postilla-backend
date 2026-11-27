# Core Principles

> Philosophy based on "Codin' Dirty" by Carson Gross — important things should be big, unimportant things should be little. Minimize the total number of functions, structs, files, layers, and concepts in the system. Less code and fewer abstractions beat "purist" decomposition.

The backend is Zig (0.17, the `minimum_zig_version` in `build.zig.zon`) with vendored C libraries (SQLite, libopus 1.6.1, libopusenc 0.3, libFLAC 1.5.0). The design lives in [docs/specification.md](docs/specification.md).

## Data and performance
- Organize code around data and transformations.
- Flat structures, contiguous memory: slices of structs over slices of pointers; fixed-size arrays or stack buffers; when the length is known, size an `ArrayList` once (`ensureTotalCapacity`) or allocate the slice once.
- One arena per request or per CLI step, freed in one go; no scattered `free`s.
- Avoid unnecessary allocations, copies, and dynamic dispatch: no vtables or `*const fn` calls in hot loops, no needless `*anyopaque` type erasure, no `anytype` where a concrete type works.
- Optimize hot paths (`GET /stories`); keep cold paths (the CLI, startup) simple.

## Debuggability
- Code should step cleanly in a debugger: explicit control flow, no clever constructs.
- `comptime` only where it removes real code; no metaprogramming for its own sake.

## Correctness by construction
- Distinct types for ids, enums and units: `enum` for closed sets (`const State = enum(u8) { moderating = 1, … }`), non-exhaustive enums for ids (`const DraftId = enum(u32) { _ };`). A bare `u32` doesn't stop mixing a draft id with a cursor.
- Parse, don't validate: the boundary parse fn (`parseDraftNew(body) !DraftNew`) is the only code that fills the struct, and the one place allowed to return an error for bad input; the handler answers 400. Past the boundary, values are trusted. Keep structs by value; no opaque heap handles.

## Fewer codepaths
Every branch a caller must handle multiplies codepaths; give callers one.
- Zero is initialization: every struct has default field values, and `.{}` is a valid empty value. Failed work leaves the zero value, and consumers just work.
- No optional from lookups: instead of `?T`, return a read-only nil sentinel (`const nil_draft: Draft = .{}`) or take a default.
- AND over OR: return the result plus its errors (`struct { events: Events, msgs: Msgs }`), not an error union that drops the partial result.
- Fail early: acquire buffers and resources up front in a shallow frame, so deep code takes slices, needs no allocator, and can't fail.
- Errors go to a log side channel (`std.log.scoped(.config)`), not error-payload slots.

# Rules
- English only, everywhere: code, comments, logs, tests, docs, specs, commit messages. Exception: story content (Italian and Portuguese text in stories, translations, test fixtures and the moderation test set).
- After changing Zig code, run `zig build test` and fix every failure. Run `zig fmt` on changed files.
- After each change, update the docs in the same change. A change the docs don't describe isn't done.
  - `docs/specification.md`: anything about the backend's behavior, endpoints, formats, schema or config.
  - `docs/openapi.yaml`: any endpoint, parameter, status code, auth rule, or body layout table.
  - `docs/formats/*.ksy`: any binary body (magic, version, field, type, order, enum value). Add a `.ksy` for a new format.
  - `docs/tilla.md` and `docs/formats/tilla.ksy`: any change to the `.tilla` format or its reader rules. The backend is the only writer.
  - `../docs/CONTRACT.md`: when the change touches what it describes (`dict.db`).
  - These files describe the same thing; when they disagree, the code and all of them get fixed together.
- Always follow `.agents/rules/testing.md` when writing/editing/reviewing tests.
- Track every feature in `docs/roadmap.md`, "Progress" and "Next slices":
  - Before starting work, mark it `in progress` in "Progress" and name the slice in "Next slices".
  - In the same commit as the code, move it to `done`, or to `partial` with what's missing, and name the commit or slice.
  - Anything left out, deferred or found along the way goes into "Next slices" (or a later version's section), never only into chat or a commit message.
- Use /caveman-commit skill to generate every commit message

## Naming conventions
Follow the Zig style guide, as the pipeline in `../src` does:
- Types and type-returning functions: PascalCase (`DraftNew`, `State`)
- Functions: camelCase (`parseDraftNew`, `publishStory`). The file is the namespace, so no module prefixes; `pub` marks what other files use.
- Variables, fields, constants and enum fields: snake_case (`draft_id`, `body_cap`, `.review`)
- The SQL schema and the binary wire formats (magics, field order, state values) are contracts: change them only with a migration or a version bump, documented in `docs/specification.md`.
- Migrations stay compatible with the binary before them, so a rollback always starts (`docs/specification.md`, Database): add a table or a column with a default; never drop, rename or repurpose one in the same release. Every SQL statement names its columns: no positional `INSERT … VALUES`, no `SELECT *`.

## Testing
- Suites must be isolated: free port + temp SQLite file per run, no shared state.
- OpenCode, Speechify and R2 are faked with local servers that return recorded responses; tests never call them.
- Fuzz tests (`test/fuzz.zig`, `std.testing.fuzz`) only for hostile input: the boundary parsers and the HTTP layer. Each has a corpus of real and broken inputs, which `zig build test` replays, and checks properties (no panic, only declared errors, a round trip through the writer). A parser function is the public API for bytes, the stated exception to testing rule 1. A failure the fuzzer finds goes into the corpus with its fix.

## Decisions are mine — interview, don't assume
- Facts: if it can be found in the environment (filesystem, tools, git), look it up — never ask me for it.
- Decisions (approach, design, scope, tradeoffs, anything ambiguous): mine. Put each one to me with your recommended answer before acting on it — never silently pick for me.
- One question at a time; wait for my answer before the next question or any dependent work.
- Trivial calls with one obvious answer don't need a question — when in doubt, it's a decision: ask.
