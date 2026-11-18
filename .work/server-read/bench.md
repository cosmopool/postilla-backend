# Bench — server-read

Stage 3. Base `f62dd56c983ff2e0aaf4f647adfa779ff52e43f3`, work branch `work/server-read` at `a8f46e1`.

**Verdict: no measurable hotspot on the hot path. Nothing to optimise.** An incremental
`GET /stories` costs the same at 0, 1 000, 10 000 and 100 000 rows (about 110–125 µs
server round trip on loopback, with 1 heap allocation). Full sync grows linearly, as expected.
At a realistic size it is about 2 ms, paid once per install.

Measuring turned up one **correctness** problem, not a perf one: about 0.2–1.8 % of new
connections get no response, because `db.open` sets `busy_timeout` only after
`journal_mode = WAL`. See "Side finding". It goes to stage 2 / the summary. Bench does not fix it.

## Setup

- Machine: Linux 7.0.14 x86_64, 16 cores, loopback TCP; zig 0.17.1; vendored SQLite 3.53.2.
- The code under test is a copy of `src/`, `build.zig`, `build.zig.zon` and `test/harness.zig`, placed in a
  scratch tree. The only build change is an extra `c` import for the bench test module
  (`bench/build-c-import.patch`). The latency runs use unmodified `src/`.
- Bench sources and raw logs are in `.work/server-read/bench/`:
  `bench.zig` (latency + SQLite counters), `bench_prepare.zig`, `bench_alloc.zig`,
  `counting-allocator.patch`, `pragma-order.patch`, `run-releasefast.txt`, `run-releasesafe.txt`.
- Data: `n` rows in `story` = `n/2` stories × {`it`, `pt-BR`}, cursors 1..n, every 20th row
  `change = 2`. The rows are seeded through the harness's SQL hook, the same way the feature tests seed them.
- Realistic size: one author who publishes by hand, with 2 languages. That is a few hundred stories, so ≈ 1 000 rows.
  10 000 is a generous ceiling and 100 000 is a stress point.
- Requests: `lang=it,pt-BR`. "full sync" is `since=0`. "incremental" is `since=n-10`
  (10 new rows, the normal sync). The client is a raw TCP client that reads the whole body. Times
  are wall-clock per request, after 10 warm-up requests.

Commands, run from the scratch tree (the copy described above, with the bench files placed under `test/`):

```
zig build test -Dtest-file=test/bench.zig -Doptimize=ReleaseFast --summary all   # → run-releasefast.txt
zig build test -Dtest-file=test/bench.zig -Doptimize=ReleaseSafe --summary all   # → run-releasesafe.txt
zig build test -Dtest-file=test/bench_prepare.zig -Doptimize=ReleaseFast         # prepare cost
zig build test -Dtest-file=test/bench.zig -Doptimize=ReleaseFast                 # with bench_alloc.zig as test/bench.zig
                                                                                 # and counting-allocator.patch applied
```

## 1. `GET /stories` latency (end to end, keep-alive connection)

ReleaseFast (`run-releasefast.txt`):

| rows | request | iters | body B | median µs | p95 µs | max µs |
|---:|---|---:|---:|---:|---:|---:|
| 0 | full sync | 1000 | 9 | 121.2 | 203.4 | 353.0 |
| 0 | incremental | 1000 | 9 | 62.1 | 91.4 | 137.3 |
| 1 000 | full sync | 1000 | 61 009 | 2 228.3 | 3 140.3 | 5 402.8 |
| 1 000 | incremental | 1000 | 619 | 112.4 | 152.0 | 266.1 |
| 10 000 | full sync | 1000 | 610 009 | 23 586.6 | 30 446.9 | 57 468.9 |
| 10 000 | incremental | 1000 | 619 | 119.2 | 185.2 | 2 242.3 |
| 100 000 | full sync | 100 | 6 100 009 | 273 140.5 | 291 108.4 | 299 528.2 |
| 100 000 | incremental | 1000 | 619 | 117.9 | 308.5 | 2 466.9 |
| (ref) | `GET /languages` | 1000 | 82 | 32.7–59.9 | 61–223 | — |

ReleaseSafe (`run-releasesafe.txt`):

| rows | full sync median µs | incremental median µs |
|---:|---:|---:|
| 0 | 101.7 | 89.0 |
| 1 000 | 2 995.7 | 125.6 |
| 10 000 | 30 797.3 | 106.0 |
| 100 000 | 344 475.6 | 117.9 |

The incremental cost does not depend on table size, because the query is an index range scan on `cursor`.
Full sync costs ≈ 2.2–3 µs per returned row, and almost all of that is SQLite (next table).

New connection per request (`connection: close`, incremental, ReleaseFast): median 630–714 µs,
p95 ≈ 1.3 ms. The extra ≈ 550 µs over keep-alive is `db.open` plus the WAL open, paid once per TCP
connection. Caddy keeps upstream connections alive, so this cost is paid per Caddy connection, not
per request.

## 2. SQLite per request

Statements per feed request (from the code, `src/server.zig:208`, `:225`): 2 `prepare_v2`
(language check and feed). Then 1–4 language-PK lookups (one per `lang` id), then one feed query.

Prepare cost (`bench_prepare.zig`, ReleaseFast, 2000 runs):
language check: median 4.8 µs, p95 6.9 µs. Feed query: median 15.1 µs, p95 17.8 µs. Total ≈ 20 µs of
the ≈ 115 µs incremental request. Caching the statements per connection would save about that much.
Nobody waits on 20 µs behind a phone's network round trip, so this is not proposed.

Feed query plan (`EXPLAIN QUERY PLAN`, identical at every size):

```
CO-ROUTINE (subquery-2)
SEARCH story USING INDEX sqlite_autoindex_story_1 (cursor>?)
SCAN (subquery-2)
USE TEMP B-TREE FOR ORDER BY
```

The `UNIQUE(cursor)` index is used: there is no full scan and no autoindex (`fullscan_steps=0`, `autoindex=0` at all sizes).
`count(*) OVER ()`, which sizes the body once, makes SQLite run the
query as a co-routine and sort its output again (`sorts=1` per execution).

SQL-only time (statement prepared once; median of 50 runs, 10 at 100k; ReleaseFast), current
query against variants:

| rows | since | current (window count) | no window | count(*) only | window `ORDER BY cursor` frame |
|---:|---:|---:|---:|---:|---:|
| 1 000 | 0 | 1 970.9 µs | 686.1 µs | 567.4 µs | 2 428.3 µs |
| 1 000 | 990 | 44.0 µs | 10.3 µs | 9.2 µs | 43.0 µs |
| 10 000 | 0 | 22 102.8 µs | 9 124.4 µs | 7 667.0 µs | 21 362.0 µs |
| 10 000 | 9 990 | 23.9 µs | 10.5 µs | 9.2 µs | 22.4 µs |
| 100 000 | 0 | 255 655.4 µs | 99 676.9 µs | 90 677.5 µs | 236 645.9 µs |
| 100 000 | 99 990 | 26.2 µs | 10.9 µs | 12.0 µs | 23.1 µs |

VM steps per execution (cumulative `SQLITE_STMTSTATUS_VM_STEP` / runs, ReleaseSafe log):
1 000 rows full sync ≈ 53 044 (window) vs 16 025 (no window); incremental ≈ 574 vs 185.

Reading: the window count is the most expensive part of the feed query. It costs ≈ 2.9× the SQL time of
the same query without it. In absolute terms, at a realistic 1 000 rows that is ≈ 1.3 ms once per
install (full sync), and ≈ 15–34 µs per incremental sync. A separate covered `count(*)` followed by
the plain query would save ≈ 0.7 ms per full sync at 1 000 rows and nothing anyone notices on an
incremental. Dropping the count and letting the buffer grow would save ≈ 1.3 ms, but it would undo the requirement's
"body sized once" decision. Neither gain justifies a change: no user waits on it, so neither is proposed.

## 3. Allocations per request

Counting wrapper around `gpa` in `src/server.zig` (`counting-allocator.patch`), 1 000 rows,
100 requests each on one keep-alive connection, ReleaseFast:

| request | allocs/req | resizes/req | bytes/req |
|---|---:|---:|---:|
| `/stories?since=0&lang=it,pt-BR` | 1.00 | 0.00 | 61 009 |
| `/stories?since=990&lang=it,pt-BR` | 1.00 | 0.00 | 619 |
| `/stories?since=1000&lang=it,pt-BR` | 1.00 | 0.00 | 9 |
| `/stories?since=x&lang=it` (400) | 0.00 | 0.00 | 0 |
| `/languages` | 1.00 | 0.00 | 140 |
| `/genres` | 2.00 | 1.00 | 488 |

The feed makes exactly one allocation, sized `9 + 61 × count` exactly, with no growth. This matches the
requirement. SQLite's internal allocations are not counted (`SQLITE_DEFAULT_MEMSTATUS=0`).

## 4. Other flagged lines

- `src/server.zig:32,33,36,37` (sqlite-transaction): these are `CREATE TRIGGER` DDL in the schema string.
  They run once at startup in `listen` and cost nothing per request.
- `src/server.zig:172,174` (list loop): 0–7 rows × 2–4 columns, closed lists. The loop is trivial.
  `GET /languages` takes a 33–60 µs median round trip.
- `src/server.zig:193,213,216` (param and lang loops): at most 4 ids and a handful of params, bounded by
  the 8 KiB head.
- `src/server.zig:238` (feed record loop): 61 bytes per row into a presized buffer. Its cost is
  inside the SQL-dominated full-sync numbers above (end-to-end 2 228 µs against 1 971 µs of SQL at 1 000 rows).
- Paid outside-service calls: none. The read path calls no outside service.

## Side finding (correctness, not perf): new connections dropped under churn

`connection()` (`src/server.zig:110`, added by this feature) opens SQLite per TCP connection with
`db.open(...) catch return`. `db.open` (`src/db.zig`, base code) runs `PRAGMA journal_mode = WAL`
**before** `PRAGMA busy_timeout = 5000`. When the previous connection closes, it is the last
connection on the file, so it checkpoints and removes the WAL. A new connection that opens during that
window gets `SQLITE_BUSY` ("database is locked") with no busy handler set yet. The server then closes the
socket without a response, and Caddy would answer 502.

Measured with 1 000 sequential new-connection requests per size (`bench.zig`, `perConnection`):

| build | 0 rows | 1 000 | 10 000 | 100 000 |
|---|---:|---:|---:|---:|
| ReleaseFast, current `db.open` | 6 dropped | 5 | 2 | 4 |
| ReleaseSafe, current `db.open` | 16 | 10 | 18 | 2 |
| ReleaseFast, `busy_timeout` first (`pragma-order.patch`), 2 runs | 0, 0 | 0, 0 | 0, 0 | — |

Each drop logs `[db] (warn): database is locked` (17 in the ReleaseFast log, 46 in the ReleaseSafe log). The
fix is a 1-line reorder in `db.open`: set `busy_timeout` first. Before this feature, base never
opened SQLite per connection, so this feature exposes the bug. It belongs in the stage 2 findings / final summary.
