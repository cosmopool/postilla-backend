# cli-publish — stage 2, round 2

Base ref: `aacef22ecee1528252e039b27342be19877fcdc7`. One finding came out of the hunt. It survived refutation and was reproduced with a failing test. The feature caused it, and it will be fixed.

## Findings

1. **Publish fails with `dict: NotDir` when the dict cache directory is a symlink.** Lens: correctness. AC-9. `src/cli.zig:190`
   - **Why it survived refutation:** the round 1 fix (75e2288) added `cwd.createDirPath(io, dict_dir)` before `client.dict`. In Zig 0.17.1's std, `dirCreateDirPath` handles `PathAlreadyExists` with a `filePathKind` check (`lib/std/Io/Threaded.zig:3582-3587`). That check uses statx with `AT_SYMLINK_NOFOLLOW` and returns `error.NotDir` for anything that is not `.directory`. So when the last component of `POSTILLA_DICT_DIR` (or `./dict`) is a symlink to a real directory, publish prints `dict: NotDir` and exits 1 before any upload. `openDir` in `src/r2.zig:45` follows the symlink, so this setup worked before 75e2288. No test or requirement rejects it.
   - **Rating:** rare (only authors who symlink their dict cache hit it), major (blocks publishing). Not silent: it exits 1 with an error, and pointing the variable at the real directory works around it.
   - **Reproduction:** reproduced in `test/cli-publish_repro_r2_1.zig`. It runs `cli.run(..., {"postilla","publish",<folder>})` against the harness server and a fake R2, with `dict` a symlink to `shared-dict`, and gets `dict: NotDir`, exit 1. The control run with `shared-dict` as the dict dir directly passes. Production code was not touched.
   - **Base check:** the test does not compile on the base (`no module named 'cli'`), because the publish command did not exist there. The feature caused it.
   - **Decision:** fix, about 1 line. Let `error.NotDir` from `createDirPath` fall through so `r2.dict`'s `openDir` decides: `cwd.createDirPath(io, dict_dir) catch |err| if (err != error.NotDir) return fail(w, "dict: {t}", .{err});`. A path that really is a file is still rejected by `openDir`.

The base-check log is `.work/cli-publish/reports/base-check/cli-publish_repro_r2_1.zig.log`. It ends with `compile test debug native 1 errors`. Under RULES.md, a test that does not compile on the base counts as caused by the feature.

There are no follow-ups for bugs that already existed before this feature.

## Table

| # | Finding | Lens | AC | Survived refutation | Chance | Criticality | Reproduction | Base check | Decision |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Symlinked dict cache dir makes `createDirPath` return NotDir | correctness | AC-9 | yes, std's NOFOLLOW kind check rejects the symlink, and `openDir` alone accepted it | rare | major | reproduced (`repro_r2_1`) | feature (no compile on base) | fix (~1 line) |

No critical finding was confirmed in this round.
