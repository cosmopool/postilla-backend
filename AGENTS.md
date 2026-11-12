# Core Principles

> Philosophy based on "Codin' Dirty" by Carson Gross — important things should be big, unimportant things should be little. Minimize the total number of functions, structs, files, layers, and concepts in the system. Less code and fewer abstractions beat "purist" decomposition.

The backend is Zig (0.17, the `minimum_zig_version` in `build.zig.zon`) with vendored C libraries (SQLite, libopus, libFLAC). The design lives in [docs/specification.md](docs/specification.md).

## Data and performance
- Organize code around data and transformations.
- Flat structures, contiguous memory: slices of structs over slices of pointers; fixed-size arrays or stack buffers; when the length is known, size an `ArrayList` once (`ensureTotalCapacity`) or allocate the slice once.
- One arena per request or per draft step, freed in one go; no scattered `free`s.
- Avoid unnecessary allocations, copies, and dynamic dispatch: no vtables or `*const fn` calls in hot loops, no needless `*anyopaque` type erasure, no `anytype` where a concrete type works.
- Optimize hot paths (`GET /stories`); keep cold paths (drafts, startup) simple.

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
- After changing Zig code, run `zig build test` in `backend/` and fix every failure. Run `zig fmt` on changed files.
- After each change, update the docs in the same change. A change the docs don't describe isn't done.
  - `docs/specification.md`: anything about the backend's behavior, endpoints, formats, schema or config.
  - `docs/openapi.yaml`: any endpoint, parameter, status code, auth rule, or body layout table.
  - `docs/formats/*.ksy`: any binary body (magic, version, field, type, order, enum value). Add a `.ksy` for a new format.
  - `../docs/CONTRACT.md`, `../docs/TILLA.md` and `../docs/tilla.ksy`: when the change touches what they describe.
  - These files describe the same thing; when they disagree, the code and all of them get fixed together.
- Always follow `.agents/rules/testing.md` when writing/editing/reviewing tests.

## Naming conventions
Follow the Zig style guide, as the pipeline in `../src` does:
- Types and type-returning functions: PascalCase (`DraftNew`, `State`)
- Functions: camelCase (`parseDraftNew`, `publishStory`). The file is the namespace, so no module prefixes; `pub` marks what other files use.
- Variables, fields, constants and enum fields: snake_case (`draft_id`, `body_cap`, `.review`)
- The SQL schema and the binary wire formats (magics, field order, state values) are contracts: change them only with a migration or a version bump, documented in `docs/specification.md`.

## Testing
- Suites must be isolated: free port + temp SQLite file per run, no shared state.
- Fuzz tests only for hostile input (request bodies, the HTTP head): fixed seeds, bounded runtime.
- OpenCode, Speechify and R2 are faked with local servers that return recorded responses; tests never call them.

## Decisions are mine — interview, don't assume
- Facts: if it can be found in the environment (filesystem, tools, git), look it up — never ask me for it.
- Decisions (approach, design, scope, tradeoffs, anything ambiguous): mine. Put each one to me with your recommended answer before acting on it — never silently pick for me.
- One question at a time; wait for my answer before the next question or any dependent work.
- Trivial calls with one obvious answer don't need a question — when in doubt, it's a decision: ask.
