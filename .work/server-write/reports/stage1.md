# Stage 1 report: server-write

Base ref: `c32b62c41cae86e171e2d6315951797f9e4e596b`. The API is settled.

## AC-to-test map

This comes from `scripts/pipeline/ac-map.sh --slug server-write`. No AC is left uncovered, and the run was as expected.

| AC | Tests |
|---|---|
| AC-1 | test/server_read.zig:140, test/server_write.zig:147 |
| AC-2 | test/server_read.zig:140, test/server_write.zig:169 |
| AC-3 | test/server_read.zig:140, :172; test/server_write.zig:169 |
| AC-4 | test/server_read.zig:140, test/server_write.zig:202 |
| AC-5 | test/server_read.zig:215, test/server_write.zig:202 |
| AC-6 | test/server_read.zig:215, test/server_write.zig:225 |
| AC-7 | test/server_read.zig:215, test/server_write.zig:225 |
| AC-8 | test/server_read.zig:245, test/server_write.zig:269 |
| AC-9 | test/server_read.zig:269, test/server_write.zig:303 |
| AC-10 | test/server_read.zig:297, test/server_write.zig:325 |
| AC-11 | test/server_read.zig:140, :151, :172; test/server_write.zig:393 |
| AC-12 | test/server_read.zig:198; test/server_write.zig:147, :169, :269 |
| AC-F1 | test/server_read.zig:327, test/server_write.zig:437 |
| AC-F2 | test/server_read.zig:376, test/server_write.zig:484 |

ac-map lists AC-F3 and AC-F4 as unknown ids. They come from server-read's own ACs in `test/server_read.zig`, and that file is now counted as a feature test file. Because of this, the server_read.zig rows above are server-read citations. Each server-write AC is still cited by `test/server_write.zig` alone. This is open question 1 in `questions.md`.

## Candidates

There were 3 candidates. They added 121, 140 and 146 lines.

**Candidate 1 won**, with 121 lines added. Every change is in `src/server.zig`:

- `route` matches `POST /stories` and `DELETE /stories/<id>`, and it closes the connection after every write.
- It checks the bearer token by comparing SHA-256 digests with `timing_safe.eql`.
- `publish` reads the body. Content-Length is required and capped at 10 222. It parses the body with `wire.Reader`.
- Inside one `BEGIN IMMEDIATE`, `publish` checks for removed or missing rows. It then runs an `INSERT ... SELECT FROM language` upsert with `RETURNING`, which also catches unknown languages.
- `remove` tombstones one row at a time with an `UPDATE ... RETURNING` loop.
- `feed` and `list` now write through `wire.Writer`/`wire.Lang`. Each list query also returns its row count and body size from SQL window columns.

## Minimality review

The reviewer accepted the diff: a competent engineer who had read the ACs would not have written materially less.

- **Budget:** `budget.sh` exited 0. The diff added 121 lines, removed 36, and has 0 new files and 0 new public symbols, so it is within budget.
- **Duplication:** none. The code reuses what code-map.md lists. One small overlap was not counted: `publish` repeats `std.mem.sliceTo(body[22+40*i..][0..8], 0)`, which `wire.Lang.text` (src/wire.zig:55) already does. Keeping a Lang array would need a new declaration and would not make the code shorter.
- **Over-abstraction:** none. There are no new types, interfaces or wrappers.
- **Unused surface:** none. `publish` and `remove` stay private, and `route` gets only the token. The window-function columns follow from the decided move onto `wire.Writer`, which needs its buffer size up front.
- **Out of manifest:** none. Every touched file is approved. The approved `Stmt.bindBlob` was not added: the code calls `sqlite3_bind_blob` directly, which means less surface. Some doc edits reach slightly past the listed sections: the Database paragraph in the spec and the bearer scheme text in openapi. They are in approved files and add no symbols.

The reviewer did not judge the test files for size, because they are the acceptance oracle.

## Flagged but not fixed

The reviewer raised no findings, so none are left unfixed. Only the `wire.Lang.text` overlap above is noted, and it was deliberately left alone.

The questions from test authoring are saved in `.work/server-write/questions.md` for a later decision, and none of them blocks the run: the ac-map id collision, the reason precedence for a 22-byte body, 401 before the id parse, reason strings ending in `\n`, and the untested `DELETE /stories/`.
