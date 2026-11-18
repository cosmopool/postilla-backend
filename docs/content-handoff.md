# Handoff to postilla-content

Changes from postilla-backend that postilla-content has to act on. Read [specification.md](specification.md) first: these follow from it. When an item is done, record it in `postilla-content/docs/` (CONTRACT.md, TILLA.md) and remove it here.

## 1. Stories no longer come from the pipeline

Every story is now made with the backend's `postilla` CLI, from a story folder: it moderates, translates and narrates it, builds its `.tilla` files, uploads them to R2 and publishes them through `POST /stories` (server-side drafts come in v1.2). The eight existing stories will be recreated that way. The pipeline stops building and publishing stories:

- No more story sources, `.tilla` writing or `POST /stories` calls from the build. `POST /stories` stays, with a new `STRY` body that carries every translation of a story, and only the backend's CLI calls it.
- `genres.txt` goes away. Genres, tags, authors and languages are closed lists in the backend's `postilla.db`, served by `GET /genres`, `GET /tags`, `GET /authors` and `GET /languages`.
- A story missing a translation is handled on the backend and app side: `postilla translate` translates a story into every language in `language` with `translate` 1, a language added later isn't backfilled until the story is published again, and the app shows such a story target-only.

## 2. The `.tilla` format changes

`.tilla` stays version 1 but changes in place (the app isn't published): one file per translation, a language-independent story header copied into each, and single-language paragraphs. The original TILLA.md was lost; the backend recreated it as `postilla-backend/docs/tilla.md` and `docs/formats/tilla.ksy`, and the backend's CLI is the only writer. Delete postilla-content's TILLA.md and `tilla.ksy` if a copy survives there (and compare it first: anything in it that the recreated spec lacks should be sent back). A `.tilla` word is only a span, as in the old `it_words`: the app looks words up by form, so `entry.id` may keep changing between builds (ARQ-35).

## 3. Splitting and normalizing with the shared `words` module

The word rule, the normalization and the lookup chain are now defined in [tilla.md, Words](tilla.md#words) and implemented once, in postilla-backend's `src/words.zig`. The build stops using its own `tokenize` and `normalize` (`src/stories.zig`, `src/main.zig`): it adds postilla-backend to its `build.zig.zon` (git URL, pinned hash), imports the `words` module, and computes `form_norm` and `word_norm` with it, so the backend's `band_words` and the app's taps see the same strings as the dictionary. Forms must follow the word rule, truncations included (*po'*), and elided combinations (*l'aria*) no longer need their own forms: the lookup falls back to the part after the apostrophe. Update CONTRACT.md's "Palavra" section to point at tilla.md.

## 4. Publishing `dict.db`

The build publishes each `dict.db` to the public R2 bucket: the gzipped file at `dict/<sha256>.db.gz` (sha256 of the `.gz`, never overwritten), then a `dict/latest` pointer naming that sha. Upload the file before the pointer, so a reader that sees a new pointer can always fetch the file. The learner app reads `dict/latest` and downloads the build when it differs from its copy; the backend's CLI uses the same build for `band_words`. The pointer's format (one ASCII line: lowercase hex sha256, a space, the `.gz` size in bytes, `\n`) is in the updated CONTRACT.md that comes with this handoff.

This replaces CONTRACT.md's GitHub Releases and `manifest.json` on Pages (ARQ-06, ARQ-20) for delivery: the app and the backend read only `dict/latest` in R2. Releases can stay as an archive, but nothing reads them, and the manifest and the `stories` package entry go away. The build needs R2 write credentials for the public bucket; R2 API tokens are scoped per bucket, not per prefix, so it can write anywhere in that bucket, and the backend's `stories/` keys rely on the build never touching them.

## 5. Also

- `stories.db` is dropped: nothing builds it anymore. Remove its writer and its description from CONTRACT.md.

## 6. Data

The eight existing stories are recreated as story folders and published with the `postilla` CLI in the new shape, with their tags, once the backend runs. Their genres are already seeded in `postilla.db` from `genres.txt` (see [Database](specification.md#database)), so `genres.txt` can go once that's done.
