# Stage 1 — audio-codecs

Base ref: ed77e3cf559f507ef5398535638935ab4396c441. API settled.

## AC-to-test map

`scripts/pipeline/ac-map.sh --slug audio-codecs` exited 0. Output, verbatim:

```json
{
  "map": {
    "AC-1": ["test/audio.zig:256 AC-1, AC-2, AC-3: 2 s of a 440 Hz sine at 48 kHz encode to a 16 kbit/s mono Ogg "],
    "AC-2": ["test/audio.zig:256 AC-1, AC-2, AC-3: 2 s of a 440 Hz sine at 48 kHz encode to a 16 kbit/s mono Ogg "],
    "AC-3": ["test/audio.zig:256 AC-1, AC-2, AC-3: 2 s of a 440 Hz sine at 48 kHz encode to a 16 kbit/s mono Ogg "],
    "AC-4": ["test/audio.zig:295 AC-4: the same 2 s at 48 kHz compress to a FLAC that decodes to the input exactl"],
    "AC-5": ["test/audio.zig:314 AC-5, AC-7: 120,000 samples at 48 kHz encode to the same bytes twice and last 25"],
    "AC-6": ["test/audio.zig:328 AC-6: 24 kHz input keeps its rate in OpusHead and STREAMINFO, its length in audi"],
    "AC-7": ["test/audio.zig:314 AC-5, AC-7: 120,000 samples at 48 kHz encode to the same bytes twice and last 25"],
    "AC-F1": ["test/audio.zig:355 AC-F1, AC-F2: no samples, or a rate the codecs don't take, is an error that leak"],
    "AC-F2": ["test/audio.zig:355 AC-F1, AC-F2: no samples, or a rate the codecs don't take, is an error that leak"],
    "AC-F3": ["test/audio.zig:369 AC-F3: every allocation failure during an encode returns error.OutOfMemory with "]
  },
  "uncovered": [],
  "unknown": [],
  "testFiles": ["test/audio.zig"],
  "run": {"expect": null, "passed": null, "asExpected": true}
}
```

Every AC maps to at least one test. None is uncovered and no test cites an unknown ID.

## Candidate spread

This step did not run the candidates. The run resumed after the apply step, so there are no
spread numbers to report here. The patches are in `.work/audio-codecs/candidates/` (1.patch,
2.patch, 3.patch).

## Winner

There was no earlier stage 1 report, so no winner was recorded in one. The latest checkpoint
commit (424f0f5) says candidate 3 was applied and the codecs are built as a static library.

## Minimality review

Accepted on round 1: I found no minimality violations. budget.sh passed (exit 0): 63 lines added, 1 new file and 2 new public symbols, all within 300/2/2.

What I checked:

- **Manifest:** every touched file is approved (build.zig.zon, build.zig, docs/specification.md, docs/tilla.md, AGENTS.md, src/audio.zig, src/audio.h, test/audio.zig). The only public symbols added are the approved `audio.encode` and `audio.Encoded`.
- **Helpers:** `flacWrite` and `flacStreamInfo` in src/audio.zig are private libFLAC callbacks. Both are needed: FLAC writes to memory, and with no seek callback the MD5 has to be patched into STREAMINFO by hand, which AC-4 requires.
- **Error handling:** every `orelse` and `catch` sits on a C codec boundary.
- **Build:** the static `codecs` library in build.zig departs slightly from the manifest's wording ("compile into the audio module"). It is not a forwarding wrapper: the comment says it exists so the C sources compile once, because compiling them for every test root ran out of file descriptors. The existing `module()` helper in build.zig hard-codes SQLite's source and flags, so it couldn't be reused here.
- **Duplication:** I searched src/ and test/ for existing Ogg, CRC, MD5, tone-detection or sine-generation code and found none. The only Ogg-related hits are fake "OggS" strings used as test fixtures.
- **Tests:** test/audio.zig covers AC-1 to AC-7 and AC-F1 to AC-F3, mostly in combined tests, and its Ogg and FLAC readers are what those ACs need to check the outputs.

A competent engineer who had read the ACs would not have written materially less.

## Flagged but not fixed

None. The reviewer raised nothing it could not fix.
