# Handoff to postilla-content

Changes from postilla-backend that postilla-content has to act on. Read [metadata.md](metadata.md) first: it is the proposal these come from. When an item is done, record it in `postilla-content/docs/` (CONTRACT.md, TILLA.md) and remove it here.

## 1. Stories no longer come from the pipeline

Every story is now created as a draft in the backend (`POST /drafts`): moderated, translated, reviewed, narrated and published by the backend's worker. The eight existing stories will be recreated that way. The pipeline stops building and publishing stories:

- No more story sources, `.tilla` writing or `POST /stories` calls from the build; the backend removes `POST /stories`.
- `genres.txt` goes away. Genres, tags, authors and languages are closed lists in the backend's `postilla.db`, served by `GET /genres`, `GET /tags`, `GET /authors` and `GET /languages`.
- A story missing a translation is handled on the backend and app side: a draft is translated into every language in `language` with `translate` 1 when it's made, a language added later isn't backfilled, and the app shows such a story target-only.

## 2. The `.tilla` format changes

`.tilla` stays version 1 but changes in place (the app isn't published): one file per translation, a language-independent story header copied into each, and single-language paragraphs. The original TILLA.md was lost; the backend recreated it as `postilla-backend/docs/tilla.md` and `docs/formats/tilla.ksy`, and the backend is the only writer. Delete postilla-content's TILLA.md and `tilla.ksy` if a copy survives there (and compare it first: anything in it that the recreated spec lacks should be sent back). A `.tilla` word is only a span, as in the old `it_words`: the app looks words up by form, so `entry.id` may keep changing between builds (ARQ-35).

## 3. Publishing `dict.db`

The build publishes each `dict.db` to the public R2 bucket: the gzipped file at `dict/<sha256>.db.gz` (sha256 of the `.gz`, never overwritten), then a `dict/latest` pointer naming that sha. Upload the file before the pointer, so a reader that sees a new pointer can always fetch the file. The learner app reads `dict/latest` and downloads the build when it differs from its copy; the backend's worker uses the same build. The pointer's format (one ASCII line: lowercase hex sha256, a space, the `.gz` size in bytes, `\n`) is in the updated CONTRACT.md that comes with this handoff.

This replaces CONTRACT.md's GitHub Releases and `manifest.json` on Pages (ARQ-06, ARQ-20) for delivery: the app and the backend read only `dict/latest` in R2. Releases can stay as an archive, but nothing reads them, and the manifest and the `stories` package entry go away. The build needs R2 write credentials for the public bucket; R2 API tokens are scoped per bucket, not per prefix, so it can write anywhere in that bucket, and the backend's `stories/` keys rely on the build never touching them.

## 4. Also

- `stories.db` is dropped: nothing builds it anymore. Remove its writer and its description from CONTRACT.md.
