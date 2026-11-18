# Stage 1 report: tilla-writer

## AC-to-test map

`scripts/pipeline/ac-map.sh --slug tilla-writer` found a test for every acceptance criterion. It reported no uncovered and no unknown ACs, and test/tilla.zig is the only test file.

- AC-1 and AC-2: test/tilla.zig:293. An Italian translation without narration reads back field by field.
- AC-3 and AC-4: test/tilla.zig:339. band_words counts each word in the best band of its lemmas, by form.
- AC-5: test/tilla.zig:361. A pt-BR translation lists its words, carries four zero band_words and never looks them up.
- AC-6 and AC-7: test/tilla.zig:389. A narrated translation carries its audio and sentence times.
- AC-8: test/tilla.zig:421. An input that breaks a rule is refused, and inputs exactly at the limits are accepted.
- AC-F1: test/tilla.zig:510. Building fails when dict.db can't be opened, isn't a database or has no form table.

## Candidates

Three candidates were built. They added 161, 155 and 153 lines.

Candidate 3 won with the fewest added lines (153). It puts Input and a two-pass build function in one file, src/tilla.zig. The first pass checks the input, splits the words, looks up band_words with one prepared statement and works out the file size. The second pass writes the file with wire.Writer. The function then hashes the result with sha256 and gzips it with flate.

## Minimality review

The reviewer accepted the diff. Their verdict, quoted:

> Accepted: I found no minimality violations in this diff. The budget script exited 0 with added 153 of 220, new files 1 of 1 and new public symbols 2 of 3, so nothing is over budget. src/tilla.zig reuses what code-map lists rather than rebuilding it: words.split, words.lookupKeys, words.Span, wire.Writer, wire.strSize, wire.Lang, wire.StoryId, db.open, Db.prepare and Stmt.step, plus std Sha256 and flate gzip. It adds no vtable, no interface with a single implementation and no wrapper that only forwards. It adds fewer symbols than the manifest allows: build returns an anonymous struct instead of a separate Built type. The validation it does is what the refusals in requirement.md and AC-8 require. Every touched file (build.zig, docs/tilla.md, docs/specification.md, src/tilla.zig, test/tilla.zig) is approved in manifest.md. The build.zig change copies wire.zig into its own module rather than exporting it from server. That change is the same size as the alternative and stays inside the approved file list, so it is not a violation. I don't think a competent engineer who had read the ACs would have written materially less.

## Flagged but not fixed

None. The reviewer left nothing open. They mentioned one choice: build.zig gives wire.zig its own module instead of exporting it from server. They judged that this is not a violation.
