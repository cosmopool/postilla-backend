#!/usr/bin/env bash
# Builds postilla-server and installs it on the VPS: the binary goes over SSH to
# postilla-update (infra/postilla-update), which restarts the server and rolls back when the
# new binary doesn't come up. The same script makes the first deploy and every update.
#
#   infra/deploy.sh [user@host]      default: root@api.postilla.kaiodelphino.com
#
# POSTILLA_DEPLOY_KEY, when set, is the SSH private key to log in with.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

target=${1:-root@api.postilla.kaiodelphino.com}
ssh_opts=(-o BatchMode=yes)
if [ -n "${POSTILLA_DEPLOY_KEY:-}" ]; then
  ssh_opts+=(-i "$POSTILLA_DEPLOY_KEY" -o IdentitiesOnly=yes)
fi

zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
ssh "${ssh_opts[@]}" "$target" sudo /usr/local/sbin/postilla-update < zig-out/bin/postilla-server
