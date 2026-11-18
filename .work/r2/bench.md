# r2 — stage 3 bench

Result: **no measurable hotspot.** No optimisation proposed.

## Signals checked

Command: `bash scripts/pipeline/perf-signals.sh --slug r2` (exit 0, `"run": true`)

| Signal | Line | Finding |
|---|---|---|
| http-client | src/outbound.zig:22 | `std.http.Client` built once per `request` call. That covers all 4 tries, so a retry reuses the client's connection pool. The CLI's R2 calls (cli-publish, not wired yet) pay one fresh connection per call. Nothing in this sandbox can measure that: the fake R2 is plain HTTP on loopback, and a real R2 call costs money and is out of scope. |
| http-client | src/outbound.zig:48 | `send`, one try. Reads the body with `allocRemaining(.unlimited)` into the caller's arena: one buffer per try, no copy loop. |
| allocation | src/r2.zig:88 | False positive: `HmacSha256.create` is the HMAC one-shot (it writes into `k` on the stack), not an allocator `create`. The `allocPrint("AWS4{s}")` on that line is one small arena allocation per call. |
| allocation | src/r2.zig:89 | False positive: same `HmacSha256.create`, 4 unrolled iterations on a stack buffer, no allocation. |

## What can be measured here, and the numbers

1. **`GET /stories` latency, SQLite statements and rows, allocations per request:** this
   feature leaves all of them unchanged. Neither module is reachable from the server.
   - `grep -rn 'import("r2")\|r2.zig\|outbound.zig' src build.zig test | grep -v '^src/r2.zig:\|^test/r2'`
     returns only `build.zig:63` (the test-only `r2` module). No `src/` file imports it.
   - `git diff 93c1c2af HEAD -- src/server.zig | wc -l` returns `0`.
   - The feature adds no SQL statements, so no SQLite statements or rows were counted.
2. **Paid outside-service calls (R2 operations).** The fake R2 in `test/r2.zig` records
   every request, and the suite asserts the counts:
   - `put`: 1 PUT per object when the first try succeeds (AC-1: `f.seen.items.len == i + 1` over 3 uploads)
   - `get`: 1 GET (AC-3: `f.seen.items.len == 1`)
   - `dict`, cold cache: 1 GET `dict/latest` + 1 GET `dict/<sha>.db.gz` (AC-8: `f.count(gz_key) == 1`)
   - `dict`, warm cache: 1 GET `dict/latest`, 0 `.db.gz` downloads (AC-8, second call: `f.count(gz_key)` stays 1)
   - worst case for one call: 4 requests (AC-7, AC-F2: "no fifth try")
   - nothing repeats a paid call outside the owner's retry schedule
   - Command: `bash -l -c 'zig build test -Dtest-file=test/r2.zig --summary all'`, which printed
     `Build Summary: 4/4 steps succeeded`, `test success`, `real 0m0.121s` (the run was cached).
3. **Loops over realistic data:** the only loop over data is `dict`'s directory sweep,
   which runs over the `*.db` files in `POSTILLA_DICT_DIR`. The cache keeps one build, so
   the loop sees 1 or 2 entries. Gunzipping streams through a 4 KiB buffer and a 32 KiB
   window. Its cost is bound by the dict's size, and it runs once per new dict build, never
   per request. Benchmarking it would benchmark `std.compress.flate`, which is the framework.

## Not measured, and why

- Connection reuse across the CLI's R2 calls: there is no TLS endpoint to time against
  here, and no caller exists until cli-publish.
- Allocations per SigV4 signature: about 8 small arena allocations, once per call, in a
  CLI that makes a handful of calls per publish. Nobody waits on this.
