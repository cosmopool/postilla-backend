# Stage 2, round 1: server-read

Hunted the whole feature diff (scope `f62dd56`..working tree). 4 findings raised, 4 survived
refutation, all 4 reproduced with a failing integration test, all 4 caused by this feature.
Decisions by the fix matrix: 1 fix, 3 report. No new critical bug.

| # | Finding | Where | Lens | Survived | Chance · criticality | Reproduced | Base check | Decision |
|---|---|---|---|---|---|---|---|---|
| 1 | Per-connection db.open runs PRAGMA journal_mode before busy_timeout, so it can fail with SQLITE_BUSY and the connection drops with no response | `src/server.zig:110` | correctness | yes | rare · minor | reproduced | feature | report |
| 2 | Path is cut at the first '&' as well as '?', so /genres&x answers 200 instead of 404 | `src/server.zig:148` | correctness | yes | rare · major | reproduced | feature | fix |
| 3 | An HTTP method std.http doesn't know (PROPFIND, lowercase get) gets 400 'bad request head' instead of 404 | `src/server.zig:131` | correctness | yes | rare · major | reproduced | feature | report |
| 4 | Per-connection db.open runs journal_mode before busy_timeout, so it can fail with SQLITE_BUSY and the socket closes with no response | `src/server.zig:110` | persistence | yes | rare · minor | reproduced | feature | report |

Findings 1 and 4 are the same defect, found by two hunters: `db.open` runs `PRAGMA
journal_mode = WAL` before `PRAGMA busy_timeout`, so a connection opening while the last
connection closes (and checkpoints the WAL) gets SQLITE_BUSY and its socket closes with no
response (Caddy would answer 502 instead of the spec's 500). Rare and self-recovering, so
reported; the fix is to set `busy_timeout` first.

Finding 3: `std.http` rejects a method it doesn't know (`PROPFIND`, lowercase `get`) while
parsing the head, so such a request gets `400 bad request head` instead of the spec's 404.
Rare but silent (major); reported because its fix is not a small one.

## Fix applied

Finding 2: `route` cut the path at the first `&` as well as `?` (`splitAny(target, "?&")`),
so `/genres&x` answered 200. It now cuts the path at the first `?` only and splits the rest
on `&`. Its reproduction, `test/server-read_repro_r1_2.zig`, failed before the fix and passes
after. The round also added AC-gap tests to `test/server_read.zig` (AC-F1: an oversized head
followed by a valid request, and a head that never ends; AC-F2).

## How this round was closed

The workflow's own fix step stopped on `hygiene.sh`: `dependency-change-not-in-manifest` at
`build.zig`, from 61fa368 (the configure-cache fix made between stage 1 and stage 2). With the
owner's OK, `build.zig` was added to the manifest, and the round was closed by hand instead of
rerun: lint, hygiene, `ac-map.sh --expect green`, analyze and the full suite all pass, then the
fix was committed and the round recorded with the same verify-loop record the workflow writes.
