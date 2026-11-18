# Stage 1 report: r2

## AC-to-test map

`scripts/pipeline/ac-map.sh --slug r2` exited 0. Every AC maps to at least one test in test/r2.zig. The uncovered and unknown lists are empty, and the run reports asExpected true.

- AC-1 and AC-2: test/r2.zig:281. An upload is one signed PUT to /<bucket>/<key> with the exact body.
- AC-3: test/r2.zig:311. A download is a signed GET that brings the object's body back byte for byte.
- AC-4: test/r2.zig:330. Two 500s then a 200 succeed on the third try.
- AC-5: test/r2.zig:348. A Retry-After on a 429 or a 503 replaces the scheduled wait, capped at the maximum.
- AC-6: test/r2.zig:374. A 403, a 400 or a 404 fails after one try with that status.
- AC-7: test/r2.zig:405. Four failing tries end the call with the last status, and no fifth try is made.
- AC-8: test/r2.zig:467. An empty dict dir gets the build named by dict/latest, checked and gunzipped.
- AC-9: test/r2.zig:494. A new dict/latest replaces the cached build, and the older .db is deleted.
- AC-F1: test/r2.zig:425. A connection that answers nothing fails the try after the idle timeout.
- AC-F2: test/r2.zig:444. An endpoint where nothing listens fails every connect try.
- AC-F3: test/r2.zig:518 checks a .db.gz whose size or sha256 doesn't match dict/latest. test/r2.zig:549 checks a dict/latest line that doesn't parse.
- AC-F4: test/r2.zig:579. A dict dir that can't be written fails r2.dict with the filesystem error.

## Candidate spread

Not run here. This stage resumed after apply, so no competing candidates were produced or compared in this run.

## Winner

No earlier stage 1 report exists, so no winner was recorded. The applied implementation is commit 9f0ff39 ("feat(r2): add R2 client, retries and dict cache"). Per checkpoint f4d3e81, it was applied by hand after a transient fd error.

## Review verdict

Accepted with no violations. budget.sh exited 0 with 172 lines added, 2 new files and 6 new public symbols, all within the declared budget, so there is nothing to report under over-budget.

Every file and public symbol in the diff is one manifest.md approves. The files are build.zig, docs/specification.md, docs/roadmap.md, src/outbound.zig, src/r2.zig and test/r2.zig. The public symbols are outbound.request, outbound.Retry, r2.Client, and Client.put, get and dict. The build.zig change is smaller than the manifest allows: it adds only the r2 test import, because r2 imports outbound by relative path.

Duplication: nothing in the base repo hashes to hex SHA-256 or picks a content type by extension. The only SHA-256 uses outside the diff are src/tilla.zig:148, src/server.zig:169 and src/wire.zig:33, and none is a reusable helper. So no pre-existing symbol can be cited.

Unused surface: the tests set every Retry field except connect_timeout_ms (waits_ms, max_wait_ms in the AC-5 cap test, idle_timeout_ms in AC-F1). connect_timeout_ms is the owner's 10 s rule, so it stays.

One borderline item, not reported: the `digest` parameter of outbound.request has only one caller that fills it (r2.dict). AC-F3 makes a size or sha256 mismatch a failed try, so the check has to run inside the retry loop. Doing it any other way would need a callback or a second retry loop, which is more code, not less.

Response is a private alias taken from request's return type instead of a new named type, and call() is the single private SigV4 path that put, get and dict share. Neither adds a forwarding layer or an abstraction no AC asks for. Read against the ACs, a competent engineer would not have written meaningfully less.

## Flagged but not fixed

None. The reviewer flagged nothing it could not fix.
