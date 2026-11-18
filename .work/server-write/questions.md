# Open questions — server-write (test authoring)

Saved for later, per the user's instruction; none of them blocks the run. The test suite
takes the reading noted under each.

1. **AC ids collide across features in ac-map.** The manifest has `test/server_read.zig`
   publish through `POST /stories`, so that file now counts as a feature test file, and
   ac-map reads its server-read ids (AC-1 … AC-12, AC-F1 … AC-F4) as citations of
   server-write ACs (e.g. server-read's 404 test shows under server-write AC-10, and
   AC-F3/AC-F4 show as "unknown"). Every server-write AC is still cited by
   `test/server_write.zig` on its own. Options: prefix ids per feature, or have ac-map
   only read descriptions that changed. Current reading: left as is.
2. **`lang_count` 0 in a 22-byte body** breaks rule 2 (wrong length) and rule 4 (no `it`).
   The requirement doesn't say which reason wins. The test accepts either
   `body: wrong length` or `lang: no 'it'`.
3. **`DELETE /stories/<not a uuid>` without a token.** Read as a known write route, so
   401 before the id is parsed (Decided: route, then token, then body). The test
   asserts 401 for `DELETE /stories/nope` with no or a wrong token.
4. **Reason strings end with `\n`**, like every existing reason body (`not found\n`).
   The requirement lists them without the newline; the tests expect it.
5. **`DELETE /stories/` (empty id)** is left untested: it could be read as an unknown
   path (404) or a path id that isn't a UUID (400 after the token).
