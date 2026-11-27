#!/usr/bin/env bash
# Installs the CI deploy key (~/.ssh/postilla-deploy.pub) on a running VPS, with the same
# restricted line cloud-init writes (cloud-init.yaml.tftpl). Terraform ignores user_data on an
# existing server, so a new deploy_ssh_public_key reaches it only through this script.
#
#   infra/install-deploy-key.sh [root@host] [public key file]
set -euo pipefail

target=${1:-root@api.postilla.kaiodelphino.com}
pub=${2:-$HOME/.ssh/postilla-deploy.pub}
key=$(cut -d' ' -f1,2 "$pub")
line='restrict,command="sudo /usr/local/sbin/postilla-update \"${SSH_ORIGINAL_COMMAND##* }\"" '"$key"

echo "new:     $(ssh-keygen -lf "$pub")"
printf '%s\n' "$line" | ssh "$target" '
  f=/home/deploy/.ssh/authorized_keys
  echo "current: $(ssh-keygen -lf "$f" 2>&1)"
  install -d -o root -g root -m 0755 /home/deploy/.ssh
  cat > "$f.new" && chown root:root "$f.new" && chmod 0644 "$f.new" && mv "$f.new" "$f"
  echo "now:     $(ssh-keygen -lf "$f")"
'
