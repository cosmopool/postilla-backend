# Code map — r2

Base 93c1c2a (scaffold, server-read, server-write, words, tilla-writer). No outbound HTTP
code exists anywhere in the repo.

## Reuse

- `std.http.Client` (Zig 0.17, `Io`-based): requests, `initDefaultProxies` for env proxies.
- `std.crypto.auth.hmac.sha2.HmacSha256`, `std.crypto.hash.sha2.Sha256`: SigV4.
- `std.compress.flate` (gzip container): decompressing `dict/<sha256>.db.gz`.
- `std.Io.Dir`: the dict cache directory (`POSTILLA_DICT_DIR`).
- `test/harness.zig` pattern: the tests start real servers on free ports in-process; a fake
  R2 server can follow it (a small `std.http.Server` loop answering recorded responses and
  recording the requests it got).
- `src/cli.zig`: the CLI entry point is a usage stub; this slice doesn't wire commands (that's
  cli-publish), it adds the module the commands will call.

## Contract

- `docs/specification.md`, Files in R2: key layout, `Cache-Control: public, max-age=31536000,
  immutable`, nothing is ever deleted, `stories/` written only by the CLI.
- `docs/specification.md`, Vocabulary coverage: "reads `dict/latest` from the public bucket,
  downloads that build into `POSTILLA_DICT_DIR` if it doesn't have it … keeps only the current
  build there and deletes older ones once it has switched. An R2 failure there is a failed try
  like any other R2 call."
- `docs/CONTRACT.md`: `dict/latest` is one ASCII line: lowercase hex sha256 of the `.gz`, a
  space, the `.gz` size in bytes, `\n`; `dict/<sha256>.db.gz` is never overwritten.
- `docs/specification.md`, Retries; Configuration, CLI: `POSTILLA_R2_ACCOUNT_ID`,
  `POSTILLA_R2_ACCESS_KEY_ID`, `POSTILLA_R2_SECRET_ACCESS_KEY`, `POSTILLA_R2_BUCKET`,
  `POSTILLA_DICT_DIR`.

## Sandbox note

- Zig 0.17.1's HTTP client sends plain HTTP inside proxy CONNECT tunnels; real HTTPS calls
  from this sandbox go through `~/.local/zig-shim`. Tests use a plain-HTTP fake on 127.0.0.1,
  which `NO_PROXY` covers, so they're unaffected.

## I/O boundaries crossed

- Outbound HTTPS (R2, S3 API with SigV4).
- The filesystem (the dict cache directory).
