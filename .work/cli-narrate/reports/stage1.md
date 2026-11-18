# Stage 1 — cli-narrate

## AC-to-test map

From `scripts/pipeline/ac-map.sh --slug cli-narrate`. Every AC is cited by a test in `test/cli_narrate.zig`. Nothing is uncovered and no citation is unknown.

| AC | Test (test/cli_narrate.zig) |
|---|---|
| AC-1, AC-2 | :494 a story whose Italian has 2 paragraphs is narrated in one Speechify request |
| AC-3 | :542 a sentence without marks gets [e, e] at the previous sentence's end |
| AC-4 | :566 narrating a narrated folder again replaces it.opus, it.flac and audio |
| AC-5, AC-6 | :589 with it and pt-BR in the story, only it (target 1) is narrated |
| AC-7 | :622 a stream with speech.error is tried again at once and the good one is kept |
| AC-8 | :650 a stream closed before speech.done three times stops the command |
| AC-9 | :664 narrate without a folder, or with an extra argument, exits 2 |
| AC-10 | :817 an answer that keeps arriving runs past idle_timeout_ms on its first try |
| AC-F1, AC-F2 | :681 Speechify answering 401 stops the command after one request |
| AC-F3 | :702 a POSTILLA_SPEECHIFY_URL without :// exits 1 naming the variable |
| AC-F4 | :717 a read-only story folder exits 1 naming the audio file it couldn't write |

## Candidate spread

Not run here. This stage resumed after apply, so the candidates' sizes and test results were not measured again. The three patches are still in `candidates/1.patch`, `candidates/2.patch` and `candidates/3.patch`.

## Winner

No earlier stage 1 report existed. The checkpoint commit 23339cc ("cli-narrate candidate 3 applied") and state.json (stage build, step apply, commit 859b481) record candidate 3 as the winner.

## Review verdict

Accepted with no violations. budget.sh exited 0 (added 109, removed 16, new_files 0, new_public_symbols 0, within_budget true), so there is no over-budget finding. Every touched file is in manifest.md: src/cli.zig, src/outbound.zig, build.zig, cli.env.example, docs/specification.md and the approved new test/cli_narrate.zig. The diff adds no public symbols. The only new declaration is the private `voices` table, which the manifest approves. The narrate block sits beside translate's inside `command`, as code-map.md asks, and reuses `outbound.request`, `audio.encode`, `fail`, `Sha256` and the shared story/lists start.

I found no duplication with a citable symbol. Publish's sha join (src/cli.zig:380) and translate's story.json temp-and-rename (src/cli.zig:262-263) are inline code, not reusable functions. Narrate also needs each sentence's code-point start from the join, so it can't reuse publish's hashing loop as is.

The parts no AC reaches are the "no voice" pre-check and the non-JSON, non-base64 and odd-byte-count bad-stream branches. They are not unused surface: requirement.md's Decided section asks for each of them. They guard data from the network or the server, and without them `voices.get(lang).?` or `bytesAsSlice` on an odd length would crash. Whether they stay is a stage-4 defensive or boundary question, not a minimality one.

The outbound.zig idle-timer change is the smallest change that gets a true idle timer: it reuses the two existing events and adds a stream loop that sets the event on each part of the answer. A competent engineer who had read the ACs would not have written materially less.

## Flagged but not fixed

The reviewer flagged nothing it could not fix. One item is passed on to stage 4: the "no voice" pre-check and the bad-stream branches (non-JSON, non-base64, odd byte count) have no AC test, so stage 4 decides whether they stay as defensive or boundary code. One note on the environment: the ac-map run did not run the tests (`run.passed` is null). `reports/apply.log` ends with a `zig build` that failed with `ProcessFdQuotaExceeded`, which is the sandbox's file-descriptor limit, not a code error.
