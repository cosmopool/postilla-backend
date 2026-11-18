# `postilla narrate` (cli-narrate)

## Summary

The last CLI command. `postilla narrate <folder>` checks `story.json` with the shared rules,
reads the server's lists, and for every translation in a language with `target` 1 (today
only `it`) streams its text from Speechify with word marks. It turns the marks into one
`[start_ms, end_ms]` per sentence, encodes the PCM with `audio.encode`, writes `<lang>.opus`
and `<lang>.flac`, and writes `audio` (`audio_ms`, `text_sha256`, `times`) into `story.json`.
It also makes `outbound.request`'s idle timeout a true idle timer, so a long stream that
keeps sending isn't cut off.

## Specified

- "Narrates every translation in a language with `target` 1 (today only the Italian
  original) … A rerun narrates again and replaces the audio; narration reads only the
  paragraphs".
- "One streamed call narrates one translation: `POST
  https://api.speechify.ai/v1/audio/stream/with-timestamps` (Server-Sent Events), with
  `Authorization: Bearer $POSTILLA_SPEECHIFY_KEY`", `model` `simba-3.5`, `voice_id`
  `daniele-agent` for `it`, `language` `it-IT` for `it`, the highest-quality PCM.
- "The input is the translation's paragraphs joined in reading order"; `speech.chunk`
  carries audio and word marks; `speech.done` ends the stream; "`speech.error`, or a dropped
  connection, counts as a failed try. The whole call is retried".
- Sentence times "run from its first word's `start_time` to its last word's `end_time`.
  Words are matched to sentences by mapping the marks' character offsets onto the
  sentences."
- `.opus` and `.flac` from the PCM (`audio.encode`), `audio_ms` from the PCM's length; "The
  times, `audio_ms` and the sha256 of the input text go to the translation's `audio`".
- `text_sha256`: "sha256 of the text it narrated: the sentences joined by one space within a
  paragraph and the paragraphs by one newline".
- Owner (2026-11-18): true idle timer; `[end, end]` for a sentence without marks;
  `options.loudness_normalization` on; `daniele-agent` stays.

## Decided

- **The input** is exactly the hashed text: sentences joined by one space within a
  paragraph, paragraphs by one newline. So `text_sha256` is the sha256 of `input`, and each
  sentence's code-point range in `input` is known from the join.
- **Request body:** `input`, `voice_id`, `model` `simba-3.5`, `language`, `output_format`
  `pcm_48000`, `options` `{"loudness_normalization": true}` (text_normalization left at its
  default, off). The PCM is then 16-bit little-endian mono at 48,000 Hz (fixture), passed to
  `audio.encode` with rate 48000.
- **Voices** are a table fixed in code by language id, like `prompt_names`: `it` →
  `daniele-agent`, `it-IT`. A `target` 1 language without one stops the command before any
  Speechify call (`<lang>: no voice`).
- **Base URL:** optional `POSTILLA_SPEECHIFY_URL`, default `https://api.speechify.ai`; the CLI
  appends `/v1/audio/stream/with-timestamps`; a value without `://` stops the command
  naming the variable (as `POSTILLA_OPENCODE_URL`). Needed for the fake.
- **Matching marks to sentences:** a mark belongs to the sentence whose code-point range in
  `input` contains its `start`; a sentence's time is its first mark's `start_time` to its
  last mark's `end_time`, both rounded down to whole ms. A sentence with no mark gets
  `[e, e]`, `e` the previous sentence's `end_ms` (0 for the first). Every `end_ms` is
  capped at `audio_ms`, so tilla.md rule 8 holds.
- **Bad stream = failed try**, like DeepSeek's bad reply: a 200 whose events include
  `speech.error`, that ends without `speech.done`, whose audio isn't valid base64 or has an
  odd byte count, or whose events aren't JSON. Up to 3 tries, each one full
  `outbound.request`, the next one at once. After the third, the command stops with
  `<lang>: narration: <reason>` (the `speech.error` message when there is one).
- **True idle timer (owner):** in `outbound.request`, `idle_timeout_ms` counts from the last
  byte received, not from connect: a try fails after that long with nothing received, and
  a response that keeps arriving runs as long as it takes. The default stays 60 s. The
  connect timeout stays 10 s. The spec's Retries section and #20 are updated.
- **Writes:** per language, `<lang>.opus` and `<lang>.flac` are written (temp file, then
  rename) after its audio is encoded, then `story.json` (temp, rename) with that language's
  `audio`. A language is written only once all of it is done.

## Assumed

- **Bad-stream tries cost credits:** each retry of a broken stream re-bills its characters
  (up to 3 × 20,000). Confirm: owner.
- **A failure after the audio files are written but before `story.json`** leaves new `.opus`
  and `.flac` with the old `audio`; `publish` still refuses only a stale `text_sha256`, so
  rerun narrate after such a failure. Blast radius: one rerun. Confirm: owner.
- **The whole stream is held in memory** (about 160 MB of base64 for 20 min, plus the
  decoded PCM), as `outbound.request` returns whole bodies. Fine on the author's machine.
- **The rate is trusted as requested** (48,000); the response's
  `speechify-audio-content-type` isn't read.
- **Unknown event types are ignored**, as Speechify's docs say.
- **Usage:** `narrate` takes exactly one folder; anything else is exit 2.

## Non-goals

- Narrating languages with `target` 0, the title or the subtitle; SSML, pronunciations,
  text normalization.
- Resuming a stream, streaming the encode, or writing PCM to disk.
- Checking that the `.opus` sounds right (the spec says listen before publishing).
- Changing `publish` or `translate`.
- Reading the response's audio content type, or picking a rate other than 48 kHz.
- A per-command required-variable list.

## Acceptance criteria

AC-1: Given a valid story whose `it` has 2 paragraphs (2 sentences, then 1) and the server
listing `it` with `target` 1, when `postilla narrate <folder>` runs against a fake
Speechify that streams PCM and one word mark per word of the request's `input`, then it
exits 0, writes `it.opus` (Ogg Opus) and `it.flac` (decoding to exactly the fake's PCM), and
`story.json`'s `translations.it.audio` holds `audio_ms` = samples ÷ 48, `text_sha256` = the
sha256 of the input, and one `[start_ms, end_ms]` per sentence from its first word's
`start_time` to its last word's `end_time`, in the shape of `paragraphs`.

AC-2: Given AC-1's run, then the request is `POST <base>/v1/audio/stream/with-timestamps`
with `Authorization: Bearer <key>` and a JSON body with `input` (sentences joined by a
space, paragraphs by a newline), `voice_id` `daniele-agent`, `model` `simba-3.5`, `language`
`it-IT`, `output_format` `pcm_48000` and `options.loudness_normalization` true.

AC-3: Given the fake sends no mark for the second sentence, then that sentence's time is
`[e, e]` with `e` the first sentence's `end_ms`; given it sends none for the first sentence,
it is `[0, 0]`. Given the last mark's `end_time` is above `audio_ms`, the last `end_ms` is
`audio_ms`.

AC-4: Given AC-1's folder narrated once, when `narrate` runs again with the fake sending
different audio, then `it.opus`, `it.flac` and `audio` are replaced by the new ones.

AC-5: Given a story with `it` and `pt-BR`, where only `it` has `target` 1, when `narrate`
runs, then only `it` is narrated (one Speechify request) and `pt-BR` gets no `audio`.

AC-6: Given AC-1's output, when `postilla publish` checks it, then the narration is current:
the `text_sha256` narrate wrote equals the one publish computes (same join), so publish
doesn't say "run narrate".

AC-7: Given the fake answers the first request with a stream holding `speech.error`, then a
good one, when `narrate` runs, then it exits 0 with the good stream's audio. Given it sends
`speech.error` three times, then it exits 1 naming `it: narration` and the error's message,
and neither `story.json` nor any `.opus`/`.flac` is written.

AC-8: Given the fake closes the stream before `speech.done` three times, when `narrate`
runs, then it exits 1 naming `it: narration`, and nothing is written.

AC-9: Given wrong arguments (no folder, an extra argument), when `narrate` runs, then it
exits 2 and prints the usage.

AC-10: Given a server that sends its response a few bytes at a time, each gap shorter than
`idle_timeout_ms` but the whole taking several times longer, when `outbound.request` runs
with a short `Retry`, then it succeeds on the first try with the whole body. Given a server
that sends the head and then nothing for longer than `idle_timeout_ms`, then that try fails
and the call retries.

AC-F1: Given Speechify answers 401, when `narrate` runs, then it exits 1 after one request
naming `it` and the status, and nothing is written.

AC-F2: Given Speechify answers 503 with `Retry-After: 0` on every try, when `narrate` runs,
then it exits 1 after 4 tries, and nothing is written.

AC-F3: Given `POSTILLA_SPEECHIFY_URL=api.speechify.ai`, when `narrate` runs, then it exits 1
naming the variable and sends no request.

AC-F4: Given the story folder is read-only, when `narrate` runs, then it exits 1 naming the
file it couldn't write, and `story.json` is unchanged.

## Touched boundaries

| Boundary | Failure covered by |
|---|---|
| outbound HTTPS: Speechify | AC-F1 (4xx), AC-F2 (5xx, retries), AC-7 (`speech.error`), AC-8 (dropped stream), AC-10 (idle) |
| outbound HTTPS: server lists | covered by cli-publish AC-F2 (shared code) |
| filesystem: writing `.opus`, `.flac`, `story.json` | AC-F4 |
| libopus/libFLAC via `audio.encode` | covered by audio-codecs AC-F1–F3 |
| env: `POSTILLA_SPEECHIFY_URL` | AC-F3 |
