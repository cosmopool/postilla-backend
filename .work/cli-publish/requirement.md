# `postilla publish` (cli-publish)

## Summary

The first real CLI command. `postilla publish <folder>` reads the story folder's `story.json`,
checks it (the 8 `story.json` rules, then the server's lists, the translations and the audio),
downloads the current `dict.db`, builds every translation's `.tilla` with `tilla.build`,
uploads every `.tilla.gz`, `.opus` and `.flac` to R2, and last sends `POST /stories`. It also
loads `cli.env`, and fixes the two r2 defects it is the first real caller of.

## Specified

- Command and folder: "`postilla <command> <folder>` works on one story folder … A command that
  fails prints one line naming the step and the reason and exits non-zero"; the folder holds
  `story.json`, `<lang>.opus` and `<lang>.flac`.
- `story.json`: the JSON layout and field table, and rules 1–8 ("valid JSON with the fields
  above and no others", empty fields, ASCII license, level 1–6, adapted 0/1, `work`/`part`, tags,
  `adapted` needs an author, `it` present with ≥ 1 paragraph and sentence, matching counts,
  20 000 characters).
- Publish checks: genre, tags, author listed by the server and every language in `language`;
  every `translate` 1 language present; every `target` 1 language with `audio` whose
  `text_sha256` matches its current text, and its `.opus` and `.flac` in the folder.
- Building and uploading: `tilla.build` per translation; upload every `.tilla.gz`, `.opus`
  and `.flac` under `stories/<id>/<lang>/<sha256>.…`; last, `POST /stories` with every
  translation's `lang` and `sha256`; a 409 for a missing published translation means "add it
  back".
- Configuration: `cli.env` in the current directory is loaded when present, "a variable already
  set in the environment wins over the file", and a missing required value stops the command.
- Owner (2026-11-18): optional `POSTILLA_R2_ENDPOINT` replaces
  `https://<account>.r2.cloudflarestorage.com`; fix questions.md #25 and #18; 450-line budget.

## Decided

- **The command runs in-process for tests:** `src/cli.zig` gets `run(io, arena, env, cwd, args)
  → exit code`, which `main` calls with the process's env and cwd; the tests call it with an env
  map and a temp directory, against the real server (harness) and a fake R2 on free ports.
- **`cli.env` format:** `KEY=value` lines; blank lines and lines starting with `#` are skipped;
  no quotes or escapes (the same form as `.env` for systemd). A line without `=` is an error
  naming the line number.
- **`story.json` parsing:** `std.json` into a struct with `ignore_unknown_fields = false`
  (rule 1); `translations` is a map keyed by language id; errors print as `story.json: <rule>`.
  The 20 000-character limit (rule 8) counts Unicode code points of the Italian sentences, the
  unit Speechify counts in.
- **"Text" for `text_sha256`:** the sha256 of the translation's sentences joined with one space
  between sentences and one newline between paragraphs (the narration input; cli-narrate must
  write the same). Defined here because publish checks it first.
- **The lists come from the server's public GETs** (`/genres`, `/tags`, `/authors`,
  `/languages`) through `outbound.request`, parsed with `wire.Reader`.
- **Uploads before POST, in order `.tilla.gz` then audio;** any failed upload stops the command
  before `POST /stories`, so the feed never names a missing file. Already-present keys are just
  uploaded again (same bytes).
- **Exit codes:** 0 success, 1 any failure, 2 usage error.
- **#25 fix:** each try sends its own copy of the body, so a cut send can't change the bytes the
  next try sends or the caller's buffer. **#18 fix:** `dict.db` is opened read-only with no
  pragmas (`SQLITE_OPEN_READONLY`).
- **Output:** one line per uploaded object and one final line with the story id and the cursors
  it got (from a `GET /stories` after the POST is not needed: the line says "published").

## Assumed

- **`text_sha256` input format** (joined sentences) is what cli-narrate will hash. Blast radius:
  a mismatch would make every publish refuse its audio. Confirm: cli-narrate's requirement.
- **Code points are Speechify's unit** for the 20 000 limit. Confirm: the first real
  narration (D4).

## Non-goals

- `translate` and `narrate` (later slices); moderation; writing `story.json`.
- Removing stories from the CLI (`DELETE` exists on the server; no CLI command yet).
- Parallel uploads, resumable uploads, progress bars.

## Acceptance criteria

AC-1: Given a story folder with `it` (narrated: `audio` with matching `text_sha256`, `it.opus`,
      `it.flac`) and `pt-BR`, a running server and a fake R2, when `postilla publish <folder>`
      runs, then it exits 0, the fake holds both `.tilla.gz` under
      `stories/<id>/<lang>/<sha256>.tilla.gz` plus `it.opus` and `it.flac` under their sha256
      keys, and `GET /stories?lang=it,pt-BR` lists both translations with those sha256s.
AC-2: Given the same folder published twice, then the second run exits 0 and no feed cursor
      moves.
AC-3: Given a `story.json` breaking any of rules 1–8, then the command exits 1 with
      `story.json: <reason>`, uploads nothing and sends no POST.
AC-4: Given a genre, tag or author the server doesn't list, or a language not in `language`,
      then it exits 1 naming the field and the id, before any upload.
AC-5: Given a missing `translate` 1 language (`pt-BR`), then it exits 1 telling to run
      `translate`.
AC-6: Given the `it` audio missing, its `text_sha256` not matching the current text, or
      `it.opus` / `it.flac` absent, then it exits 1 telling to run `narrate`.
AC-7: Given a story already published with `pt-BR` and a folder without it (and the checks
      otherwise satisfied by a server whose `translate` list was changed), then the server's 409
      reason is printed and it exits 1.
AC-8: Given a `cli.env` in the current directory, then its values are used; given the same
      variable in the environment, the environment's wins.
AC-9: Given an empty dict cache, then the first publish downloads the dictionary through R2 and
      the Italian `.tilla` carries `band_words` from it; a second publish downloads nothing.
AC-10: Given a PUT whose first try is cut mid-body, then the retry uploads exactly the original
       bytes with a valid signature, and the caller's buffer is unchanged (#25).
AC-11: Given a publish, then no `-wal` or `-shm` file appears next to the cached `dict.db`, and
       a read-only `dict.db` file works (#18).
AC-F1: Given R2 failing every try for one upload, then the command exits 1 naming the key,
       and no `POST /stories` reaches the server.
AC-F2: Given a server that doesn't answer, then the list GETs fail after the retries and the
       command exits 1 before any upload.
AC-F3: Given a folder that doesn't exist or has no `story.json`, then it exits 1 naming the
       path.
AC-F4: Given a required variable missing from both `cli.env` and the environment, then it exits
       1 naming the variable; given a `cli.env` line without `=`, it exits 1 naming the line.
AC-F5: Given a cached `dict.db` that isn't a SQLite database (or lacks the `form` table), then
       it exits 1 naming the dictionary, before any upload.

## Touched boundaries

- The filesystem (folder, `cli.env`, dict cache): AC-3, AC-8, AC-11, AC-F3.
- Env at startup: AC-8, AC-F4.
- Outbound HTTPS (R2, server): AC-7, AC-10, AC-F1, AC-F2.
- SQLite (`dict.db`): AC-9, AC-11, AC-F5.
