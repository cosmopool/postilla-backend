# Stage 1 report: server-read

Base ref: f62dd56c983ff2e0aaf4f647adfa779ff52e43f3. The API is settled.

## AC-to-test map

Output of `scripts/pipeline/ac-map.sh --slug server-read`. Uncovered: none. Unknown: none. Run as expected.

| AC | Tests |
|---|---|
| AC-1 | test/server_read.zig:116 |
| AC-2 | test/server_read.zig:116 |
| AC-3 | test/server_read.zig:116, test/server_read.zig:148 |
| AC-4 | test/server_read.zig:116 |
| AC-5 | test/server_read.zig:191 |
| AC-6 | test/server_read.zig:191 |
| AC-7 | test/server_read.zig:191 |
| AC-8 | test/server_read.zig:220 |
| AC-9 | test/server_read.zig:244 |
| AC-10 | test/server_read.zig:272 |
| AC-11 | test/server_read.zig:116, test/server_read.zig:127, test/server_read.zig:148 |
| AC-12 | test/server_read.zig:174 |
| AC-F1 | test/server_read.zig:302 |
| AC-F2 | test/server_read.zig:333 |
| AC-F3 | test/server_read.zig:348 |
| AC-F4 | test/server_read.zig:366 |

Test files: test/harness.zig, test/server_read.zig.

## Candidates

The candidate spread was not run in this pass, because the run resumed after apply. The existing report recorded three passing candidates, with 252, 190 and 205 added lines. Candidate 2 won as the smallest diff, at 190 added lines. Its read-path code is all in src/server.zig.

## Review verdict

> I'm rejecting this round over two violations. budget.sh exited 0 (added 190, removed 15, new_files 0, new_public_symbols 2, within_budget true), so there is no over-budget finding. Everything else is about as small as the ACs allow: the single generic list() for the four lists, the temp-table CHECK used for the user_version refusal, the count(*) OVER () query that sizes the feed body once, the peek-with-timeout that gives the idle close, and the reason/bytes helpers.
>
> 1) Duplication. feed() writes the FEED body with its own code using std.Io.Writer.Allocating, even though manifest.md lists wire.zig as "every response body" reuse. server.zig never imports wire.zig, which is used nowhere in the diff. The feed buffer is already sized up front, so wire.Writer fits unchanged.
>
> 2) Out-of-manifest. manifest.md approves db.Stmt and Db.prepare/step/column* inside src/db.zig. The diff instead adds private prepare/step/bytes in src/server.zig on raw `c` calls and makes db.fail public, which is a public symbol the manifest does not approve. It also changes the existing log level in fail from err to warn, which no AC asks for.
>
> The list() string encoding (writeInt u32 plus writeAll) could also be done with wire.Writer.str, but that needs a second sizing pass over the rows and would be longer, so I did not flag it.

## Flagged but not fixed

The reviewer named nothing as unfixable. Both violations can be fixed inside the manifest: build the feed body with wire.Writer, and move the statement helpers into src/db.zig as db.Stmt so that db.fail stays private and keeps its err log level. The reviewer chose not to flag the list() string encoding, because changing it would make the code longer. Both violations stay open until a fix is applied and committed.
