Source: the docs at 93c1c2a plus the owner's decisions of 2026-11-18 (in this session):
- retries: 4 tries in all (1 + 3 retries), waiting 5 s, 30 s, then 2 min;
- retried: network errors, timeouts, 429 and 5xx; a Retry-After on 429/503 replaces the scheduled
  wait (capped at 2 min); any other 4xx fails at once;
- timeouts: 10 s to connect, 60 s with no byte received;
- cli-publish is split: slice `r2` first (the SigV4 client, the retry and timeout rules, the dict.db
  download into POSTILLA_DICT_DIR, tested against a fake R2 server), then `cli-publish`.

From docs/specification.md:

## Files in R2

All files are in one public bucket, keyed by story id, language and a sha256 of the content:

```
stories/<id>/<lang>/<sha256>.tilla.gz       one translation (tilla.md); sha256 of the .tilla before gzip
stories/<id>/<lang>/<opus_sha256>.opus      its narration for the app: Ogg Opus, 16 kbps, mono
stories/<id>/<lang>/<flac_sha256>.flac      narration master: lossless, never downloaded by the app
dict/latest                                 pointer to the current dictionary (CONTRACT.md)
dict/<sha256>.db.gz                         a dictionary build
```

`<id>` is the UUID in its written form (`d0159518-99cc-46f0-bef2-b5b6f6f9a76d`), `<lang>` is the language id verbatim (`pt-BR`), and every `<sha256>` is 64 lowercase hex digits.

- A new version writes new keys, so no cache can serve a stale file. Every object can be served with `Cache-Control: public, max-age=31536000, immutable`.
- Nothing is ever deleted from R2. A republish leaves the previous `.tilla.gz`, `.opus` and `.flac` in place, and a removal leaves every file, so a phone never gets a 404 for a file the feed or a `.tilla` named.
- A republish whose audio didn't change gives the same `.opus` and `.flac` keys, so no app downloads them again. The `.tilla` names its `.opus` by `opus_sha256`.
- The app builds each `.tilla.gz` URL from a feed record's `id`, `lang` and `sha256`, and the `.opus` URL from the `.tilla`.
- A translation without narration has no `.opus` or `.flac`; its `.tilla` has `audio_ms` 0.
- `stories/` is written only by `postilla publish`; the server never touches R2. The `dict/` keys belong to the postilla-content build ([content-handoff.md](content-handoff.md#4-publishing-dictdb)); the CLI only reads them, and the build never touches `stories/`.

#### Vocabulary coverage

`band_words` is four counts: how many of an Italian translation's `words` fall in each NVdB band, using `entry.band` from `dict.db` (0 outside · 1 fondamentale · 2 alto uso · 3 alta disponibilità). The four add up to `words`. Counts, not percentages, so they stay integers and the app computes the share.

A word takes the most common band among the lemmas its form leads to in `dict.db` (1 before 2 before 3 before 0): "porta" (*portare* 1, *porgere* 2) counts as band 1. A word with no lemma counts as band 0. Words are split, normalized and looked up by the shared `words` module, the same way the app looks them up on tap ([tilla.md, Words](tilla.md#words)).

The CLI gets `dict.db` the same way the app does: it reads `dict/latest` from the public bucket, downloads that build into `POSTILLA_DICT_DIR` if it doesn't have it, and computes `band_words` from it. It keeps only the current build there and deletes older ones once it has switched. An R2 failure there is a failed try like any other R2 call. An older story's `band_words` reflect the bands at its publish time until it is republished.

A `.tilla` word is only a span, looked up by form; `dict.db` entry ids change between builds (ARQ-35) and nothing stores them, so a dictionary rebuild never touches a published story.

### Retries

Each call to an outside service (OpenCode, Speechify, R2) is tried up to 3 times, waiting 5 s, 30 s, then 2 min between tries. A network error, a 429 or a 5xx counts as a failed try.

After the third failed try, the command stops with the step that failed and the error. Rerunning it starts that step over, keeping what `story.json` already holds.

### CLI

[`cli.env.example`](../cli.env.example) lists every variable with its default. Copy it to `cli.env`, which git ignores. The CLI loads `cli.env` from the current directory when it is there; a variable already set in the environment wins over the file.

| Variable | Default | What it is |
|---|---|---|
| `POSTILLA_SERVER_URL` | required | Base URL of `postilla-server` (`https://api.example.com`) |
| `POSTILLA_AUTHOR_TOKEN` | required | The server's bearer token, for `POST /stories` |
| `POSTILLA_OPENCODE_KEY` | required | OpenCode key, for Jev and DeepSeek |
| `POSTILLA_SPEECHIFY_KEY` | required | Speechify key |
| `POSTILLA_R2_ACCOUNT_ID` | required | Cloudflare account id |
| `POSTILLA_R2_ACCESS_KEY_ID` | required | R2 S3 access key id |
| `POSTILLA_R2_SECRET_ACCESS_KEY` | required | R2 S3 secret key |
| `POSTILLA_R2_BUCKET` | required | The public bucket: stories and the dictionary |
| `POSTILLA_DICT_DIR` | `./dict` | Where the CLI caches the current `dict.db` build |
| `POSTILLA_MODERATION_THRESHOLD` | `0.9` | Minimum `P(none)` to pass moderation |

From docs/CONTRACT.md (dict/latest):

## Publicação no R2

O pacote vai para o bucket público do R2, o mesmo das histórias, e substitui as Releases do GitHub e o `manifest.json` no Pages (ARQ-06, ARQ-20) como meio de entrega: o app e o backend só leem o R2. As Releases podem continuar como arquivo, mas nada as lê.

1. Envia `dict/<sha256>.db.gz`, onde `sha256` é o do `.db.gz`. Uma chave nunca é sobrescrita.
2. Só depois, sobrescreve `dict/latest`, um texto ASCII de uma linha: o sha256 em hexadecimal minúsculo, um espaço, o tamanho do `.db.gz` em bytes e `\n`.

```
3f2a…c9e1 22829235
```

Enviar o arquivo antes do ponteiro garante que quem lê um `dict/latest` novo sempre encontra o arquivo. Como o app usa o ponteiro está em `postilla-backend/docs/app-handoff.md`; o CLI do backend (`postilla publish`) o lê ao publicar uma história.

O build precisa de credenciais de escrita do bucket. Tokens do R2 valem para o bucket inteiro, não por prefixo: o build só escreve sob `dict/` e nunca toca em `stories/`, que é do backend.

From docs/app-handoff.md:

- Keep one `dict.db`, the latest. Read `dict/latest` from the public bucket (one line: lowercase hex sha256, a space, the `.gz` size), and download `dict/<sha256>.db.gz` when the sha differs from the device's copy, checking size and sha256. A new build replaces the old one; published stories keep working, since words are looked up by form.
