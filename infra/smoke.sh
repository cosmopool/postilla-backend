#!/usr/bin/env bash
# Smoke test of a running postilla-server through its public URL, as the app talks to it: the
# version it runs, the four list bodies and the feed. Exits 1 naming the first check that fails.
# The deploy workflow runs it after each deploy with the commit it shipped; the smoke workflow
# runs it on a schedule without one (infra/README.md, GitHub Actions).
#
#   infra/smoke.sh <base URL> [expected commit]
#   infra/smoke.sh https://staging-api.postilla.kaiodelphino.com 0ea4bfc21459e68c5a0a2250c44a128ff38ec8b6
set -euo pipefail

base=${1:?usage: infra/smoke.sh <base URL> [expected commit]}
want=${2:-}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "smoke: $base: $*" >&2
  exit 1
}

# GET <path> into $tmp/body, retrying for 30 s: a just-restarted server may not be behind the
# proxy yet. Fails on anything but 200.
get() {
  local status
  for _ in $(seq 15); do
    status=$(curl -s -o "$tmp/body" -w '%{http_code}' --max-time 10 "$base$1" || true)
    [ "$status" = 200 ] && return 0
    sleep 2
  done
  fail "GET $1 answered $status"
}

size() { wc -c < "$tmp/body" | tr -d ' '; }
# Big-endian unsigned integer of <n> bytes at <offset> of the body.
uint() { od -An -tu1 -j "$1" -N "$2" "$tmp/body" | awk '{ for (i = 1; i <= NF; i++) v = v * 256 + $i } END { print v + 0 }'; }
magic() { head -c 5 "$tmp/body" | od -An -c | tr -d ' \n'; }

get /version
version=$(head -c 200 "$tmp/body" | tr -d '\n')
echo "smoke: $base runs $version"
# GET /version is "<tag> <commit>" (specification.md).
if [ -n "$want" ] && [ "${version#* }" != "$want" ]; then
  fail "runs commit ${version#* }, expected $want"
fi

# List bodies: magic, version 1, a u16 count (specification.md).
for list in languages:LANG genres:GNRS tags:TAGS authors:AUTH; do
  path=/${list%%:*}
  get "$path"
  [ "$(magic)" = "${list##*:}001" ] || fail "GET $path: not ${list##*:} version 1"
  count=$(uint 5 2)
  [ "$path" != /languages ] || [ "$count" -ge 1 ] || fail "GET /languages: no languages"
  echo "smoke: $path: $count records, $(size) bytes"
done

# The feed: FEED, version 1, a u32 count, 61 bytes per record.
get '/stories?since=0&lang=it,pt-BR'
[ "$(magic)" = FEED001 ] || fail "GET /stories: not FEED version 1"
count=$(uint 5 4)
[ "$(size)" = $((9 + 61 * count)) ] || fail "GET /stories: $(size) bytes for $count records"
echo "smoke: /stories: $count records"
echo "smoke: $base ok"
