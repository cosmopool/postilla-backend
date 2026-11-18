# Manifest — r2

## Files to touch
- `build.zig` — expose `outbound` and `r2` to the test roots (as `tilla` is) and to the CLI
  module.
- `docs/specification.md` — Retries: replace the old text with the owner's rules (4 tries,
  5 s / 30 s / 2 min, what is retried, Retry-After, the timeouts); Files in R2: the upload
  headers and SigV4 details; Vocabulary coverage: the dict cache file name, temp-and-rename,
  and the deletion of older builds.
- `docs/roadmap.md` — the v1.2 Retries paragraph points to the spec's Retries section.

## New files
- `src/outbound.zig` — `request`: one outbound HTTP call with the retry schedule, the
  Retry-After rule and the timeouts.
- `src/r2.zig` — `Client` (endpoint, bucket, key id, secret, retry schedule) with `put` and
  `get`, SigV4 signing, and `dict` (the dictionary cache).
- `test/r2.zig` — the tests for AC-1 … AC-9 and AC-F1 … AC-F4, with the fake R2 server.

## Public symbols to add
- `outbound.request` — the one outbound call every service uses.
- `outbound.Retry` — the schedule and timeouts (defaults: 5 s / 30 s / 2 min, 10 s connect,
  60 s idle), so tests can shorten them.
- `r2.Client` — R2 access with `put`, `get` and `dict` as methods.

## Reused, not rebuilt
- `std.http.Client`, `std.crypto` HMAC-SHA256 and SHA-256, `std.compress.flate`, `std.Io.Dir`.
- `test/harness.zig`'s free-port, in-process server pattern for the fake.

## Budget
added 300 · new files 2 · new public symbols 6

Raised from 3 after stage 1: `budget.sh` counts methods, so `Client.put`, `Client.get` and
`Client.dict` count on top of `request`, `Retry` and `Client`. All six are needed (the tests
and the CLI call them across modules). Logged in questions.md.

## API
settled
