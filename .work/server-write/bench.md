# server-write — stage 3 measurements

Verdict: **no measurable hotspot.** Nothing to propose.

## Setup

- Base `c32b62c` and head `f700cb3` checked out as detached worktrees under the session
  scratchpad (`$S/base`, `$S/head`, where
  `S=/tmp/claude-1000/-home-arrow-Development-postilla-backend/945d538b-48e1-4b97-9e7b-965747cfa7f8/scratchpad`).
- Two throwaway test files, never added to the repo: `$S/bench_feed.zig` (runs unchanged
  on base and head) and `$S/bench_write.zig` (head only). Both start the real server via
  `test/harness.zig`, seed `story` by SQL with N stories × 2 translations (`it`, `pt-BR`,
  cursors 1..2N), and time requests over real HTTP on loopback (one TCP connection per
  request, as the harness does; that means one SQLite open per request too).
- Realistic size: 8 stories exist today (docs/content-handoff.md). Measured at N = 8,
  1 000 and 10 000 (20 000 rows) to cover growth.
- Build: `-Doptimize=ReleaseFast`, 16 cores, Linux 7.0.14. Zig's build runner marks a test
  that writes to stderr as failed, so each binary was built once and then run directly.

Commands:

```
cp $S/bench_feed.zig $S/<base|head>/test/zz_bench_feed.zig
cd $S/<base|head> && zig build test -Doptimize=ReleaseFast -Dtest-file=test/zz_bench_feed.zig
# then, 3 rounds interleaved base/head, 500 requests per case:
for i in 1 2 3; do for t in base head; do (cd $S/$t && ./$(cat ../bin_$t.txt) 2>&1 | grep -o "N=.*" | sed "s/^/$t run$i /") >> $S/reads2.txt; done; done

cp $S/bench_write.zig $S/head/test/zz_bench_write.zig
cd $S/head && zig build test -Doptimize=ReleaseFast -Dtest-file=test/zz_bench_write.zig
cd $S/head && ./.zig-cache/o/50a15c82e8a2c0c7f639900578284a74/test   # 300 requests per case
```

Loopback latency on this machine is bimodal (about 0.5 ms or about 1.2 ms per request,
even for the 3-row `/languages`, on base and head alike), so medians move in steps that
the code didn't cause. Min is the figure to compare base and head with.

## 1. `GET /stories` and the lists, base vs head (feed encoding moved onto `wire.Writer`, lists got window columns)

Per-round values, 3 rounds × 500 requests (µs):

| N (rows) | request | body | base min | head min | base median | head median |
|---|---|---|---|---|---|---|
| 8 (16) | `since=0&lang=it,pt-BR` | 985 B | 524, 524, 588 | 528, 579, 576 | 602–625 | 618–631 |
| 8 | `/genres` | 335 B | 446, 515, 435 | 556, 462, 469 | 542–550 | 525–605 |
| 8 | `/languages` | 82 B | 502, 506, 448 | 475, 707, 533 | 543–556 | 1148–1320 * |
| 1 000 (2 000) | `since=0` (full sync) | 122 009 B | 3981, 4387, 4256 | 4718, 4580, 4678 | 4765–4839 | 5721–6554 * |
| 1 000 | `since=1980` (incremental) | 1 229 B | 642, 598, 457 | 664, 603, 622 | 552–808 | 907–1433 * |
| 10 000 (20 000) | `since=0` (full sync) | 1 220 009 B | 42231, 41805, 40981 | 41474, 43307, 42291 | 47099–51578 | 50781–53329 |
| 10 000 | `since=19980` (incremental) | 1 229 B | 604, 549, 455 | 646, 589, 514 | 1214–1465 | 1247–1451 |
| 10 000 | `/genres` | 335 B | 614, 529, 914 | 607, 642, 468 | 1027–1229 | 1221–1326 |

\* An earlier 3-round run (200 requests per case, `$S/reads.txt`) gave the opposite: head
N=1000 full sync medians 4816, 4758, 4832 µs against base 4822, 9836, 5927 µs; head
`since=1980` 635, 591, 648 against base 638, 1426, 740. The gaps follow the loopback
mode, not the build.

Read: the 20 000-row full sync is 41–43 ms min on both builds, and the incremental sync
and lists sit at the loopback floor on both. No difference shows above noise.

SQLite cost of the list query (`$S/bench_write.zig`, 7 genre rows): the head query with
`count(*) OVER ()` and `sum(...) OVER ()` takes **430 VM steps, 1 sort**; the base query
took **49 VM steps, 0 sorts**. That is microseconds on a 7-row table and doesn't show in the
latencies above.

## 2. `POST /stories` and `DELETE /stories/<id>` (head only, new endpoints)

Run of `$S/head/.zig-cache/o/50a15c82e8a2c0c7f639900578284a74/test`, 300 requests per case (µs):

| N (rows) | request | min | median | p90 |
|---|---|---|---|---|
| 1 000 (2 000) | POST new story (it, pt-BR) | 2104 | 4045 | 4767 |
| 1 000 | POST republish unchanged | 2389 | 4070 | 4515 |
| 1 000 | POST republish, both changed | 2456 | 4094 | 4968 |
| 1 000 | DELETE (2 translations) | 2182 | 2754 | 3886 |
| 1 000 | DELETE already removed | 526 | 570 | 653 |
| 10 000 (20 000) | POST new story (it, pt-BR) | 2123 | 3103 | 4107 |
| 10 000 | POST republish unchanged | 2224 | 3414 | 4115 |
| 10 000 | POST republish, both changed | 2016 | 3725 | 4353 |
| 10 000 | DELETE (2 translations) | 1949 | 2626 | 4406 |
| 10 000 | DELETE already removed | 530 | 567 | 648 |

Write latency doesn't grow with table size (about 2 ms min at 2 000 and 20 000 rows). It is
the WAL commit; a DELETE that writes nothing is at the 0.5 ms loopback floor.

## 3. SQLite statements per write request (plans and step counts at N = 1 000 and 10 000: identical)

Each statement was copied from `src/server.zig` with literal values, run in its own
connection inside `BEGIN IMMEDIATE … ROLLBACK`, and counted with `sqlite3_stmt_status`.

| statement (src/server.zig) | plan | VM steps | full-scan steps | runs per request |
|---|---|---|---|---|
| publish: `SELECT lang, change … WHERE id = ?1` (:285) | SEARCH story USING PRIMARY KEY (id=?) | 17 (2 rows) | 0 | 1 |
| publish: upsert, new translation (:295) | SEARCH language PK; scalar `max(cursor)` via COVERING INDEX on `cursor` | 90 | 0 | lang_count |
| publish: upsert, changed translation (:295) | same | 111 | 0 | lang_count |
| remove: `SELECT 1 … WHERE id = ?1` (:321) | SEARCH story USING PRIMARY KEY (id=?) | 15 | 0 | 1 |
| remove: tombstone `UPDATE … RETURNING 1` (:325) | PK (id, lang) + PK (id) + `max(cursor)` via COVERING INDEX | 82 | 0 | translations + 1 |

Every write statement is an index lookup: no full scan, and step counts don't change from
2 000 to 20 000 rows. A two-translation publish runs 2 prepares, `BEGIN IMMEDIATE`,
1 select, 2 upserts and `COMMIT`. A two-translation delete runs 2 prepares, `BEGIN
IMMEDIATE`, 1 select, 3 update steps and `COMMIT`.

For scale (pre-existing, unchanged by this feature): the feed's full-sync query is
1 091 842 VM steps and 1 sort for 20 600 rows.

## 4. Allocations per request (read from the code, not counted)

`gpa` is the hard-coded `std.heap.smp_allocator`, so a counting allocator can't be
dropped in without changing production code. Counted by reading the added lines instead:

- `feed` (:244): 1 `gpa.alloc` of exactly `9 + 61 × count`. Base also made 1 allocation of
  that size (`Allocating.initCapacity`). No change.
- `list` (:185): 1 `gpa.alloc` of exactly the body size from the window column. Base
  started an `Allocating` writer empty and let it grow, so base made 1 or more. Same or
  fewer.
- `publish` / `remove`: 0 heap allocations. The body goes into a 10 222-byte stack buffer
  (:264) and reasons into a 128-byte stack buffer.

## 5. Loops over request data (flagged lines :166, :190, :192, :274–:303, :331)

- :166: the header scan, once per write request over the request's headers.
- :190–:192: rows × columns of a list table (3–7 rows today).
- :274–:290: `lang_count` (2–3 real, 255 max). The repeat check is O(n²) over 8-byte
  compares, at most 32 385 compares for a 255-language body, and only on the author's
  write path.
- :303 and :331: one SQLite step per translation, costed in §3.

## 6. Paid outside-service calls

None. `src/server.zig` makes no R2, OpenCode or Speechify call (grep for
`r2|http.Client|fetch|opencode|speechify` finds nothing), and this feature has no drafts.

## Conclusion

- Read path: the move to `wire.Writer` and the list window columns make no difference
  above loopback noise, up to a 20 000-row feed.
- Write path: one author publishes rarely. Each request is a few indexed statements plus
  one WAL commit, about 2 ms, flat in table size.
- No optimisation has a number behind it, so none is proposed.

Observation only, no proposal: an unchanged republish still commits (min 2.2 ms against
0.5 ms for a no-op DELETE), because the upsert rewrites the row with the same values.
Nobody waits on this, and avoiding it would add code.
