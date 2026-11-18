Source: the docs at 2be5999 plus the owner's decisions of 2026-11-18 (in this session):
- Narrate's second slice: Speechify, the sentence times, story.json; `audio.encode`
  (merged in audio-codecs) makes the .opus and .flac.
- "True idle timer": 60 s without receiving any byte fails the try; a stream that keeps
  sending runs as long as it needs (questions.md #20: today's 60 s runs from connect to the
  end of the response, which every long narration would exceed).
- A sentence with no word marks gets a zero-length time at the gap: `[end, end]`, `end` the
  previous sentence's end time (0 for the first).
- `options.loudness_normalization` on.
- Voice `daniele-agent` stays for `it` (owner: available for simba-3.5).
- Real Speechify calls (2026-11-18, .work/fixtures/speechify_request.json and
  speechify_stream.txt): the format field is `output_format` (`audio_format` is ignored and
  gives MP3); `pcm_48000` answers `speechify-audio-content-type: audio/L16;rate=48000;
  channels=1`, base64 headerless 16-bit LE mono PCM in `speech.chunk` `audio`; word marks in
  `speech_marks` with `start`/`end` as code-point offsets into `input` (checked with `…`, `«»`,
  `é`), `start_time`/`end_time` in ms from the start; `speech.done` carries
  `audio_duration_ms` and `billable_characters_count`. Docs: `speech.error` carries
  `error.code`/`error.message`; unknown event types are ignored. A 102-character text
  streamed in ~1 s for 5.6 s of audio.

From docs/specification.md:

### `postilla narrate`

Narrates every translation in a language with `target` 1 (today only the Italian original); learners listen in the language they are learning. When another language becomes a target, its translations are narrated too, with a Speechify voice per language. A rerun narrates again and replaces the audio; narration reads only the paragraphs, so a title, subtitle or header change doesn't need it.

One streamed call narrates one translation: `POST https://api.speechify.ai/v1/audio/stream/with-timestamps` (Server-Sent Events), with `Authorization: Bearer $POSTILLA_SPEECHIFY_KEY`. The request sets:

- `model` to `simba-3.5`
- `voice_id` to the language's voice: `daniele-agent` for `it`
- `language` to `it-IT` for `it`
- `output_format` to `pcm_48000`, the highest-quality PCM that Speechify streams: headerless 16-bit little-endian mono at 48 kHz (`audio/L16;rate=48000;channels=1`)

That endpoint takes up to 20,000 spoken characters, which is why `story.json` rule 8 limits the Italian.

The input is the translation's paragraphs joined in reading order. The CLI reads the events:

- `speech.chunk` events carry the audio and word marks. Each mark has `start` and `end` (character offsets into the input) and `start_time` and `end_time` in ms.
- `speech.done` ends the stream.
- `speech.error`, or a dropped connection, counts as a failed try. The whole call is retried, since one stream can't resume halfway.

The stream yields three outputs:

- **Sentence times:** each sentence's `start_ms` and `end_ms` run from its first word's `start_time` to its last word's `end_time`. Words are matched to sentences by mapping the marks' character offsets onto the sentences.
- **App audio:** the PCM is encoded once to the Ogg Opus `.opus` that tilla.md describes (16 kbps, mono), written as `<lang>.opus`, with vendored libopusenc over vendored libopus. libopusenc writes the Ogg container (headers, pages, pre-skip, end trimming) and resamples to a rate Opus takes, so the CLI writes no container code. The settings are fixed: 16,000 bit/s, `OPUS_SIGNAL_VOICE`, complexity 10, VBR, and Ogg serial number 1 (libopusenc picks a random one otherwise), so the same PCM always gives the same `.opus` bytes and an unchanged narration keeps its `opus_sha256`. OpusHead's input rate is the PCM's rate, and `OpusTags` holds only libopusenc's vendor string. `audio_ms` is the PCM's length: its sample count ÷ its sample rate × 1000, rounded down.
- **Master:** the same PCM is also compressed to FLAC with vendored libFLAC, written as `<lang>.flac`. It is a lossless copy kept for re-encoding later: compression level 8, 16 bits, mono, the PCM's rate, the MD5 signature on, and the sample count in STREAMINFO. The app never downloads it.

`audio.encode` (`src/audio.zig`) makes both files in memory from the samples and their rate, and narrate writes them. It refuses no samples (`error.NoAudio`) and a rate outside 8,000–96,000 Hz (`error.UnsupportedRate`) before any C call; a codec call that fails returns `error.OpusEncode` or `error.FlacEncode`.

The times, `audio_ms` and the sha256 of the input text go to the translation's `audio` in `story.json`. Listen to the `.opus` before publishing.


### Retries

Each call to an outside service (OpenCode, Speechify, R2) and to the server goes through `outbound.request` (`src/outbound.zig`) and gets 4 tries in all (1 + 3 retries), waiting 5 s, 30 s, then 2 min between them. A network error, a timeout, a 429 or a 5xx counts as a failed try; a `Retry-After` in seconds on a 429 or a 503 replaces the scheduled wait, capped at 2 min. Any other status ends the call at once with that status.

Every call sends `user-agent: postilla/1.0` (the HTTP client's own `zig/…` is replaced), which OpenCode Go asks of its clients, and `accept-encoding: identity`, since the client asks for gzip by default and OpenCode answers gzipped when asked. Each try sends its own copy of the body, so a try cut mid-send can't change what the next one sends. A try times out after 10 s without a connection, or 60 s after connecting without the whole answer. The HTTP client has no timeouts of its own, so the try runs as a task that is canceled when either time runs out.

After the fourth failed try, the command stops with the step that failed and the error. Rerunning it starts that step over, keeping what `story.json` already holds.


47:- **Translation fields** depend on it: `title`, `subtitle`, the sentences, `words`, `band_words`, `audio_ms` and the narration. The original is the translation whose language is `original`.
64:| `audio_ms` | ms | Length of the translation's `.opus`; 0 without narration |
148:- A republish whose audio didn't change gives the same `.opus` and `.flac` keys, so no app downloads them again. The `.tilla` names its `.opus` by `opus_sha256`.
