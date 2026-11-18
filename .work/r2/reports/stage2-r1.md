# Stage 2, round 1: r2

Base ref: `93c1c2af1bd23806a4845df2964ba010d703e328`. Round 1 hunted the whole feature diff with the configured lenses. Three findings survived refutation. All three were reproduced with a failing integration test through the public `r2.Client`, against a local fake R2. None of the three compiles on the base, because `r2.Client` does not exist there (see `reports/base-check/*.log`). So the feature caused all three. Decisions come from `workflow.fix_matrix`; `small_fix_lines` is 5.

| # | Finding | Lens | Survived refutation | Chance | Criticality | Silent | Fix size (lines) | Repro | Base check | Decision |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | The 60 s timeout covers the whole transfer, not idle time (`src/outbound.zig:34`) | correctness | yes | rare | major | no | ~20 | reproduced (`test/r2_repro_r1_1.zig`) | fails to compile on base, so the feature caused it | **report** (fix-small, but over 5 lines) |
| 2 | SigV4 signature computed once per call, not once per try (`src/r2.zig:101`) | correctness | yes | rare | minor | no | ~12 | reproduced (`test/r2_repro_r1_2.zig`) | fails to compile on base, so the feature caused it | **report** |
| 3 | A failed try's HTTP connection is reused by every retry (`src/outbound.zig:51`) | memory | yes | occasional | major | no | 1 | reproduced (`test/r2_repro_r1_3.zig`) | fails to compile on base, so the feature caused it | **fix** |

## 1. The 60 s timeout covers the whole transfer

**Lens:** correctness. **Survived refutation:** yes. `events[1]` is set only by `send`'s `defer` when the whole try ends. Line 34 waits on it once for `idle_timeout_ms`, and nothing resets that wait while bytes move. The body goes out in one `sendBodyComplete` and comes back in one `allocRemaining`. So any try that runs longer than 60 s after connecting is canceled, even while bytes are still flowing. The owner's rule in requirement.md is "60 s with no byte received". The new line in docs/specification.md ("60 s after connecting without the whole answer") describes the code, not that rule. AC-F1 only tests a connection that stalls completely.

**Rating:** rare. Going past 60 s needs a link slower than about 0.5 to 1 Mbps for several MB of .flac or a dictionary .db.gz. Major: it breaks an owner rule, and on such a link the transfer can never finish. Not silent, because the call ends in an error.

**Reproduction:** reproduced. The fake answers 200 at once, then sends 46 bytes one every 50 ms. With `idle_timeout_ms` set to 500, every try is canceled about 500 ms after connecting. The call fails with `ReadFailed` after 4 tries (about 2041 ms). A canceled read reports as `ReadFailed`; the mechanism is the same. As a control, the same test passes with a 10 s timeout.

**Base check:** does not compile on base, so the feature caused it.

**Decision:** report. The matrix gives rare/major = fix-small, but the estimate (~20 lines) is over `small_fix_lines` (5). Suggested fix: count progress per chunk and restart the idle wait while the count moves, then restore the spec sentence to the owner's wording.

## 2. SigV4 signature computed once per call

**Lens:** correctness. **Survived refutation:** yes. `Client.call` (src/r2.zig:71-101) builds `x-amz-date` and the Authorization header once. `outbound.request` resends the same `headers` on all 4 tries. requirement.md, under Decided, says the signature is recomputed for every try. No test checks that the date is fresh or changes between tries. The refuter cut the worst-case gap to about 6 minutes (3 × 120 s of capped waits), so it takes a clock skew of about 9 minutes or more to hit R2's 15-minute window.

**Rating:** rare (needs a badly skewed clock plus a long run of retries). Minor: the 403 RequestTimeTooSkewed is visible, and running the command again recovers. Not silent.

**Reproduction:** reproduced. The fake answers try 1 with 503 and `Retry-After: 2`, then rejects any date more than 1 s off its clock. `put` fails with "expected .ok, found .forbidden" at `test/r2_repro_r1_2.zig:124`. A logging check showed the same date on both tries, with 0 s skew on try 1 and 2 s on try 2.

**Base check:** does not compile on base, so the feature caused it.

**Decision:** report (rare/minor). Options for later: sign inside each try, or change requirement.md and the spec to say one signature covers the whole call because the longest call fits SigV4's window.

## 3. A failed try's HTTP connection is reused by every retry

**Lens:** memory. **Survived refutation:** yes. `send` calls `sendBodyComplete` before `receiveHead`. When the body write fails or is canceled, `Request.deinit` sees `reader.state == .ready`. std/http/Client.zig:891 maps that to `closing = false`, so the socket goes back to the pool of the one client that lives across all tries (outbound.zig:22). Every retry then gets that socket from `findConnection`. A dead socket fails again at once. A live one gets try 2's bytes after try 1's partial body, and R2 answers a 400 for the hash mismatch, which outbound does not retry. Either way, the spec's "a network error or timeout is retried" does not hold for failures in the middle of the body. No test fails a try during the body write.

**Rating:** occasional (an outside service failing or slow, with a large body). Major: the specified retry breaks, and the publish fails or gets a 400. The payload hash is signed, so nothing is corrupted. Not silent.

**Reproduction:** reproduced, the same way on two runs. The fake never reads the first connection's 64 MiB body and serves later connections normally. Result: "put failed with WriteFailed after 1 accepted connection(s)". All 4 tries ran on one connection. With a fresh connection per try, the second try would succeed and the fake would count 2 accepts.

**Base check:** does not compile on base, so the feature caused it.

**Decision:** fix (occasional/major). The suggested 1-line fix, already checked against the repro (one accepted connection per try): in `send`, right after `defer req.deinit();`, add `errdefer req.connection.?.closing = true;`.

## Pre-existing bugs

None. Every reproduction fails to compile on the base.

## Outcome

One fix (#3), and two findings reported without code changes (#1, #2). None of them is critical. Both reported findings go into the final summary.
