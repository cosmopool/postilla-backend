#!/usr/bin/env bash
# Builds postilla-server and installs it on the VPS: the binary goes over SSH to
# postilla-update (infra/postilla-update), which restarts the server and rolls back when the
# new binary doesn't come up. The same script makes the first deploy and every update.
#
#   infra/deploy.sh <production|staging> [user@host]
#
# Both servers run on one VPS; user@host defaults to root@api.postilla.kaiodelphino.com.
# POSTILLA_DEPLOY_KEY, when set, is the SSH private key to log in with.
# POSTILLA_SERVER_BIN, when set, is the path to a binary already built (CI's build job, which
# passes it absolute; a relative one is from the repo root), so nothing is built here.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

case ${1:-} in
  production | staging) server=$1 ;;
  *) echo "usage: infra/deploy.sh <production|staging> [user@host]" >&2; exit 2 ;;
esac
target=${2:-root@api.postilla.kaiodelphino.com}
ssh_opts=(-o BatchMode=yes)
if [ -n "${POSTILLA_DEPLOY_KEY:-}" ]; then
  ssh_opts+=(-i "$POSTILLA_DEPLOY_KEY" -o IdentitiesOnly=yes)
fi

bin=${POSTILLA_SERVER_BIN:-}
if [ -z "$bin" ]; then
  zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
  bin=zig-out/bin/postilla-server
fi
ssh "${ssh_opts[@]}" "$target" sudo /usr/local/sbin/postilla-update "$server" < "$bin"
