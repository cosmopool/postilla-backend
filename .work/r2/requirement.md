# R2 client and dictionary download (r2)

## Summary

Two modules the CLI commands will use. `src/outbound.zig` makes one outbound HTTP request with
the owner's retry and timeout rules, for every outside service (R2 now; OpenCode and
Speechify later). `src/r2.zig` signs requests to R2's S3 API with SigV4, uploads an object
with the right headers, downloads one, and keeps the current `dict.db` in
`POSTILLA_DICT_DIR` from `dict/latest`. No CLI command is wired here; cli-publish does that.

## Specified

- Retries (owner, 2026-11-18): "4 tries in all (1 + 3 retries), waiting 5 s, 30 s, then
  2 min"; retried: "network errors, timeouts, 429 and 5xx; a Retry-After on 429/503 replaces
  the scheduled wait (capped at 2 min); any other 4xx fails at once".
- Timeouts (owner): "10 s to connect, 60 s with no byte received".
- R2 keys and objects: `stories/<id>/<lang>/<sha256>.tilla.gz`, `.opus`, `.flac`; "Every
  object can be served with `Cache-Control: public, max-age=31536000, immutable`"; "Nothing is
  ever deleted from R2".
- Dictionary: read `dict/latest` (one ASCII line: lowercase hex sha256 of the `.gz`, a space,
  the size in bytes, `\n`), download `dict/<sha256>.db.gz` "if it doesn't have it", "keeps only
  the current build there and deletes older ones once it has switched", "An R2 failure there
  is a failed try like any other R2 call".

## Decided

- **`outbound.request`** takes the method, URL, headers and body, and the retry schedule
  (`[3]u32` waits in ms, default `.{ 5_000, 30_000, 120_000 }`) and timeouts as parameters,
  so tests pass short waits and the CLI passes the defaults. It returns the final status and
  body (in a caller arena) or an error naming the last failure. Anything not retried returns
  at once with its status.
- **SigV4 for R2:** region `auto`, service `s3`, path-style URLs `<endpoint>/<bucket>/<key>`,
  `x-amz-content-sha256` set to the body's hex sha256 (no unsigned payloads, no chunked or
  multipart uploads: every object fits in one request), `x-amz-date`, signed headers
  `host;x-amz-content-sha256;x-amz-date`. The signature is recomputed for every try, since
  `x-amz-date` changes.
- **The endpoint is a parameter** of `r2.Client` (default
  `https://<account>.r2.cloudflarestorage.com` built by the caller), so tests point it at a
  plain-HTTP fake. No new env variable in this slice; cli-publish decides how its own tests
  override it.
- **Upload headers:** `Content-Type` by extension (`.tilla.gz` → `application/gzip`, `.opus`
  → `audio/ogg`, `.flac` → `audio/flac`), `Cache-Control: public, max-age=31536000,
  immutable`, and never `Content-Encoding` (a client would otherwise gunzip the `.tilla.gz` and
  its sha256 check would fail).
- **The dict cache:** the file is `<POSTILLA_DICT_DIR>/<sha256>.db`, the sha256 being the
  `.gz`'s. If it exists, nothing is downloaded. Otherwise the `.gz` is downloaded, checked
  against the pointer's size and sha256 (a mismatch is a failed try), gunzipped into a temp
  file in the same directory and renamed into place; then every other `*.db` in the
  directory is deleted. `r2.dict(...)` returns the path. A `dict/latest` line that doesn't
  parse is an error, not a retry.
- **The tests use a fake R2:** a small HTTP server in the test file that records requests,
  checks the SigV4 signature with the same algorithm against a fixed secret, and answers
  scripted statuses (200, 429 with Retry-After, 500, 403, a stalled connection) and bodies.

## Assumed

- **R2 accepts path-style requests on the account endpoint** with region `auto`. Blast
  radius: every upload; one real call settles it. Confirm: the first real `postilla publish`.
- **Zig's HTTP client can enforce an idle read timeout.** If 0.17's client can't, the timeout
  is applied around the request (a cancelable task with an `Io` timeout). Blast radius: a
  dead connection would hang the CLI. Confirm: implementation.

## Non-goals

- Any CLI command, `cli.env` loading, `story.json`, `POST /stories` (cli-publish).
- Deleting objects, listing, multipart uploads, presigned URLs, writing `dict/`.
- OpenCode and Speechify requests (they reuse `outbound.request` in their slices).

## Acceptance criteria

AC-1: Given a fake R2, when an object is uploaded under `stories/<id>/it/<sha>.tilla.gz`,
      then the fake receives one PUT to `/<bucket>/<key>` with the exact body,
      `Content-Type: application/gzip`, the immutable `Cache-Control`, no `Content-Encoding`,
      and a SigV4 `Authorization` header the fake verifies with the secret.
AC-2: Given `.opus` and `.flac` keys, then their `Content-Type` is `audio/ogg` and
      `audio/flac`.
AC-3: Given an object in the fake, when it is downloaded with GET, then the body comes back
      exactly and the request is signed.
AC-4: Given the fake answers 500 twice then 200, then the call succeeds after 3 tries with
      the scheduled waits between them (short waits in the test).
AC-5: Given a 429 with `Retry-After: 1`, then the next try waits that long instead of the
      scheduled wait; a `Retry-After` above 2 min is capped at 2 min.
AC-6: Given a 403 (or 400, 404), then it fails after one try with that status.
AC-7: Given four failing tries, then the call fails with the last status or error after
      exactly 4 tries.
AC-8: Given an empty dict dir and `dict/latest` naming a build, then `r2.dict` downloads it,
      checks size and sha256, writes `<sha>.db` with the gunzipped content and returns its
      path; called again, it downloads nothing.
AC-9: Given a cached older `<old>.db` and a new `dict/latest`, then the new build is
      downloaded and `<old>.db` is deleted.
AC-F1: Given a fake that accepts the connection and then sends nothing, then the try fails
       after the idle timeout (short in the test) and is retried.
AC-F2: Given an endpoint where nothing listens, then each try fails to connect and the call
       fails after 4 tries.
AC-F3: Given a `.db.gz` whose size or sha256 doesn't match `dict/latest`, then no `.db` is
       written and the attempt counts as a failed try; given a malformed `dict/latest`, then
       `r2.dict` fails at once.
AC-F4: Given a dict dir that can't be written, then `r2.dict` fails with the filesystem error
       and leaves no temp file.

## Touched boundaries

- Outbound HTTPS (R2): AC-4, AC-5, AC-6, AC-7, AC-F1, AC-F2, AC-F3.
- The filesystem (dict cache): AC-F3, AC-F4.
