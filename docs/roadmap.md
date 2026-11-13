# Roadmap

Planned work that isn't in [specification.md](specification.md) yet. When an item is built, it moves into the spec and leaves this file.

## Rate limit on public endpoints

`GET /stories`, `GET /genres`, `GET /tags`, `GET /authors` and `GET /languages` are the only endpoints anyone can call; the rest need `POSTILLA_AUTHOR_TOKEN`. Nothing limits them today.

Decided so far:

- **Where:** in the backend, not in Caddy or Cloudflare. Behind Caddy every request comes from `127.0.0.1`, so the client IP is the last hop of `X-Forwarded-For`, trusted because the server binds to `127.0.0.1`.
- **Policy:** one token bucket per client, shared by the five endpoints: a burst of 30, refilling 1 per second. An empty bucket gets a 429 with `Retry-After` set to the seconds until one token is back. Env `POSTILLA_RATE_BURST` (30) and `POSTILLA_RATE_PER_SEC` (1).
- **Storage:** in memory only, so a restart refills every bucket. A fixed table of 2²⁰ (1,048,576) entries, allocated once at startup and guarded by one mutex. Each entry is 32 bytes (`ip` `[16]u8`, `tokens` `f32`, `last_ns` `u64`, padding), 33,554,432 bytes (32 MiB) in all.
- **Lookup:** open addressing. Hash the key and look at up to 8 consecutive slots: a match is the client's bucket, otherwise take an empty slot, or replace the least recently seen of the 8. Constant work per request; an entry idle long enough to have refilled counts as empty.

Still open:

1. The IPv6 key. Proposed: IPv4 by full address (stored IPv4-mapped), IPv6 by its /64 (first 8 bytes), so a client rotating addresses inside its /64 doesn't get a fresh bucket each time. The alternatives are the full address (bypassable by anyone with a /64) or the /56 (stricter, more unrelated users share a bucket).

When built: a 429 row in the spec's status codes, the env vars in Configuration and `.env.example`, 429 responses in openapi.yaml, and integration tests that drain a bucket and check `Retry-After`.

## Authoring app

An app to create, edit, approve and remove stories. What it needs now is specified in [metadata.md](metadata.md#8-authoring): removal, listing, edit drafts, the `listening` state and `/narrate`. Later:

- **Restore a removed story:** removal (`DELETE /stories/<id>`, see [metadata.md](metadata.md#8-authoring)) keeps the rows and the R2 files, so a story can come back. Proposed: `POST /stories/<id>/restore` (bearer token) sets every translation's `change` back to `published` with new cursors and the old `sha256`, in one transaction; apps download the files again. Alternatives: only through a new draft with the same id, or never.
- **Web authoring app:** the first authoring clients are native, desktop and CLI, so the backend has no CORS. A web version later needs CORS on the token endpoints for one origin set in env (e.g. `POSTILLA_AUTHOR_ORIGIN`): answer the `OPTIONS` preflight with `204`, allow `Authorization` and `Content-Type` and the methods in use; other origins get no CORS headers. Serving it from the API's own domain through Caddy avoids CORS instead.
- **Auth:** one bearer token (`POSTILLA_AUTHOR_TOKEN`) works for a single editor; more editors need per-user tokens.

## Card data in the feed

Today the learner app draws story cards from the `.tilla` headers it downloads during sync ([metadata.md](metadata.md#7-one-story-many-translations)). An alternative: each `FEED` record carries the card fields after its fixed part (title, subtitle, level, genre, tags, author, work, part, `words`, `audio_ms`, `band_words`; empty when removed), stored on the `story` rows by the worker at publish from the same draft that writes the `.tilla`. Cards would draw right after a sync, and `.tilla` files could download when a story is opened, behind a "Downloading…" dialog, making the first sync tiny. The costs: variable-length `FEED` records on the hot path, the header written in two places, and stories not readable offline until opened once.

## Picking the right lemma for each word

Today a `.tilla` word is only a span ([tilla.md](tilla.md)): on tap, the app looks the form up in `dict.db` and shows every lemma it leads to, so *porta* opens *porta*, *portare* and *porgere*, and *siede* in *si siede* opens *sedere*, not *sedersi*. `band_words` uses the most common band among the candidates. Most forms lead to one lemma, so this only matters for the ambiguous minority, which are often very common words.

The feature: the worker picks the lemma each ambiguous word has in its sentence, and the `.tilla` stores the pick so the app opens exactly that entry.

- **Multi-word forms first:** match the longest run of words that `dict.db`'s `form` table knows ("si siede" → *sedersi*, fixed expressions), and emit one span for it. Deterministic, no model.
- **Ambiguous single words:** pick one lemma from the candidates `dict.db` gives. To choose between:
  - **An LLM** (DeepSeek, already called per paragraph during translation): send the sentence and the candidate lemmas, get the choice back. No new service, and picks are reviewed at `review` like translations; the costs are a larger prompt or an extra call, and one more thing to review.
  - **An Italian POS tagger and lemmatizer:** a dedicated model, deterministic for a given version and usually very accurate on standard prose, but a Python/ML stack the Zig backend would run as a sidecar service.
- **Storing the pick:** as the lemma's text, `word` and `pos` (*portare* + `verbo`), not `entry.id`, because ids change with every `dict.db` build (ARQ-35, [CONTRACT.md](CONTRACT.md)) and `(word, pos)` names an entry across builds. Only ambiguous words carry one; the app falls back to the form lookup when the pair isn't found.
- **Then:** `band_words` takes the picked lemma's band instead of the most common band, and the authoring app shows the picks at `review` so they can be corrected.
