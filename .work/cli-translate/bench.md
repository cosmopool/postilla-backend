# cli-translate: stage 3 bench

Verdict: no measurable hotspot. Nothing to propose.

## What applies here

The feature is a CLI command (`postilla translate`). It adds no server route, no SQLite
statement and nothing on `GET /stories`, so request latency and rows per request don't apply.
What can be measured: paid outside calls per draft, allocations per run, and the loops over
paragraphs at the largest story rule 8 allows.

## Setup

- Story: 63 paragraphs of 5 sentences, about 63 code points each, so 315 sentences and about
  19,800 code points. That is close to rule 8's 20,000 limit: 64 paragraphs was refused with
  `it: 20110 characters, above 20 000`. `story.json` is 21,502 B going in and 53,163 B coming out.
- Harness: the `World` / `FakeOpenCode` from `test/cli_translate.zig` (lines 1-501: the real
  server for the lists, plus a fake OpenCode on loopback). `cli.run` gets a counting allocator
  wrapped around its own `ArenaAllocator`. The test lives in `.work/cli-translate/bench_test.zig`.
- Command (it builds a temporary test file, runs it and then deletes it):

```
head -n 501 test/cli_translate.zig > test/zz_bench_translate.zig \
  && cat .work/cli-translate/bench_test.zig >> test/zz_bench_translate.zig \
  && zig build test -Dtest-file=test/zz_bench_translate.zig --summary none 2>&1 | grep BENCH; \
  rm -f test/zz_bench_translate.zig
```

For the 1-paragraph and 16-paragraph rows, change `const P = 63;` in the test. Between runs
I appended a comment line to the file so the Zig build cache could not skip the run step.

## Raw numbers

| paragraphs | sentences | Jev calls | DeepSeek calls | arena allocs | bytes requested | arena capacity | DeepSeek body bytes | wall ms |
|---|---|---|---|---|---|---|---|---|
| 1  | 5   | 1 | 2  | 54  | 88,905    | 137,200   | 2,480   | 45 |
| 16 | 80  | 1 | 17 | 206 | 390,079   | 413,654   | 28,305  | 48 |
| 63 | 315 | 1 | 64 | 682 | 1,336,488 | 1,574,174 | 109,521 | 111, 124, 130, 137, 140, 145, 146 (7 runs) |

The alloc and byte counts were identical in every run of the same size. Wall time is against
the loopback fake and includes fetching the server's lists.

## Reading

- **Paid calls per draft:** 1 Jev call plus (paragraphs + 1) DeepSeek calls per language. At
  the rule 8 maximum that is 65 calls. The spec sets this count ("paragraph by paragraph",
  "title and subtitle first", AC-2). A rerun with nothing missing makes 0 calls (AC-3). Bad
  replies can raise the count to at most 3 tries per paragraph (AC-8). No call is made twice
  without a reason.
- **Flagged lines:** `src/cli.zig:196` `todo` gets one append per language with `translate` 1,
  which is 1 today. `src/cli.zig:227` `done` gets one append per paragraph plus one, 64 at the
  maximum. Both use the run's arena. They are a small part of the 682 allocations and well
  under 1 KB of the 1.34 MB requested.
- **Slope:** (682 - 54) / 62 is about 10 allocations and (1,336,488 - 88,905) / 62 is about
  20 KB per DeepSeek call. Almost all of it comes from `outbound.request`, which builds a new
  `std.http.Client` (connection buffers) per call and copies the body. That is existing code
  from before this feature, so it is out of scope. 1.5 MB of arena for a one-shot CLI run is
  not a cost anyone waits on.
- **Wall time:** about 130 ms for 65 calls on loopback, so about 2 ms of client-side work per
  call. Against the real OpenCode, each DeepSeek reply takes seconds and is the whole run time.
  The spec rules out parallel paragraphs (non-goal). The latency of the real service can't be
  measured here: it is paid, and the sandbox firewall blocks it.
- **`story.json` writes:** 1 + the number of languages (the assumption "once after moderation,
  then once after each finished language"), so 2 writes of at most 53 KB at the maximum.

No optimisation has numbers behind it, so stage 3 proposes and implements nothing.
