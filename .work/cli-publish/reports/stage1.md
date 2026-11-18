# Stage 1 — cli-publish

## AC-to-test map

Output of `scripts/pipeline/ac-map.sh --slug cli-publish`, verbatim:

```json
{
  "map": {
    "AC-1": ["test/cli_publish.zig:548 AC-1, AC-2, AC-9, AC-11: a narrated story uploads both .tilla.gz and its audio a"],
    "AC-2": ["test/cli_publish.zig:548 AC-1, AC-2, AC-9, AC-11: a narrated story uploads both .tilla.gz and its audio a"],
    "AC-3": [
      "test/cli_publish.zig:609 AC-3: a story.json that breaks any of rules 1 to 8 exits 1 with `story.json: <re",
      "test/cli_publish.zig:664 AC-3: the 20 000-character limit counts code points, so an Italian of exactly 20"
    ],
    "AC-4": ["test/cli_publish.zig:680 AC-4, AC-5, AC-6: an id the server doesn't list, a missing translate language, o"],
    "AC-5": ["test/cli_publish.zig:680 AC-4, AC-5, AC-6: an id the server doesn't list, a missing translate language, o"],
    "AC-6": ["test/cli_publish.zig:680 AC-4, AC-5, AC-6: an id the server doesn't list, a missing translate language, o"],
    "AC-7": ["test/cli_publish.zig:710 AC-7: a republish without a published translation, once the server no longer ask"],
    "AC-8": ["test/cli_publish.zig:725 AC-8, AC-F4: cli.env in the current directory fills what the environment lacks a"],
    "AC-9": ["test/cli_publish.zig:548 AC-1, AC-2, AC-9, AC-11: a narrated story uploads both .tilla.gz and its audio a"],
    "AC-10": ["test/cli_publish.zig:861 AC-10: an upload whose first try is cut mid-body is retried with exactly the ori"],
    "AC-11": ["test/cli_publish.zig:548 AC-1, AC-2, AC-9, AC-11: a narrated story uploads both .tilla.gz and its audio a"],
    "AC-F1": ["test/cli_publish.zig:830 AC-F1: an upload R2 fails on every try stops the command naming its key, and no "],
    "AC-F2": ["test/cli_publish.zig:845 AC-F2: a server that answers no list request fails after the retries and exits 1"],
    "AC-F3": ["test/cli_publish.zig:784 AC-F3: a folder that doesn't exist, or has no story.json, exits 1 naming the pat"],
    "AC-F4": ["test/cli_publish.zig:725 AC-8, AC-F4: cli.env in the current directory fills what the environment lacks a"],
    "AC-F5": ["test/cli_publish.zig:803 AC-F5: a cached dict.db that isn't a SQLite database, or has no form table, exit"]
  },
  "uncovered": [],
  "unknown": [],
  "testFiles": ["test/cli_publish.zig"],
  "run": {"expect": null, "passed": null, "asExpected": true}
}
```

## Candidate spread

Three candidates passed, at 216, 220 and 212 added lines.

## Winner

Candidate 3 won with 212 added lines. It is one long `cli.publish` function behind `cli.run`. The function loads the config and parses story.json with std.json into an inline anonymous struct. It then checks the rules, fetches the four server lists in one loop, collects the inputs and audio, calls `r2.dict` and `tilla.build`, uploads the .tilla.gz and then the audio, and finishes with POST /stories. `db.openReadOnly` opens dict.db. In outbound, the body is copied into one scratch buffer before every try.

## Review verdict

Accepted, with no minimality violations. budget.sh exited 0: 212 lines added against a budget of 450, 0 new files, and 2 new public symbols against a budget of 2. Nothing exceeded, so there is no over-budget output to report.

The production diff stays inside manifest.md. It touches src/cli.zig, src/outbound.zig, src/db.zig, src/tilla.zig, build.zig, cli.env.example and docs/specification.md, and the only new public symbols are `cli.run` and `db.openReadOnly`.

- **Reuse:** it uses `tilla.build`/`Input`, `r2.Client` (`put` and `dict`), `outbound.request`, and wire's `Reader`, `Writer`, `StoryId` and `Lang`. I searched src/ and test/ and found no existing helper for parsing env or `cli.env`, joining text for the `text_sha256`, counting code points, or building the `stories/` keys, so none of the new code duplicates something already there.
- **Abstraction:** there are no new types, no vtables and no forwarding wrappers. `fail` is a small private formatter used at every failure exit. The new `outbound` module in build.zig is needed because a Zig file can belong to only one module, and both cli and r2 import outbound.zig.
- **Interface:** every `run` parameter is passed by both `main` and the tests. `POSTILLA_R2_ENDPOINT` is owner-approved, and `POSTILLA_DICT_DIR` was already in the spec.
- **Fixes:** the #25 fix is one copy buffer refreshed before each try. The #18 fix is one `sqlite3_open_v2` call that reuses `db.fail`.
- **Tests:** test/cli_publish.zig copies `FakeR2`, `signedBy` and `gzip` from test/r2.zig. code-map.md allows this ("copy or import it"), and the build makes every test/*.zig except harness.zig its own test root, so importing it is not a clean option. I did not count it as a violation.

A competent engineer who had read the ACs would not have written materially less.

## Flagged but not fixed

Nothing. The reviewer flagged no issue it was unable to fix.
