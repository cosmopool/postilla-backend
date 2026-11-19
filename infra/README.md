# infra

Terraform for everything [Deployment](../docs/specification.md#deployment) needs:

| Resource | What it is |
|---|---|
| `cloudflare_r2_bucket.stories` | The public story bucket (`stories/` from `postilla publish`, `dict/` from postilla-content) |
| `cloudflare_r2_bucket.backup` | The private bucket Litestream streams `postilla.db` to |
| `cloudflare_r2_custom_domain.stories` | Optional public domain for the story bucket (`files_hostname`) |
| `cloudflare_account_token.cli` | The CLI's R2 key: objects in the story bucket only |
| `cloudflare_account_token.litestream` | Litestream's R2 key: objects in the backup bucket only |
| `random_password.author_token` | The bearer token for `POST /stories` and `DELETE /stories/<id>` |
| `hcloud_server.api` | The VPS (Hetzner Cloud, Ubuntu 24.04), set up by `cloud-init.yaml.tftpl` |
| `hcloud_firewall.server` | 22 from `ssh_allowed_cidrs`; 80 and 443 from anywhere |
| `cloudflare_dns_record.api_a`, `api_aaaa` | `api.postilla.kaiodelphino.com` → the VPS, not proxied (Caddy does TLS) |

cloud-init installs Caddy, Litestream and the `postilla-server` systemd unit on first boot,
writes `/etc/postilla/env` (root-only, the author token), and restores `postilla.db` from
the backup bucket when the bucket already holds one. Terraform doesn't deploy the binary
after that, and changing cloud-init doesn't touch a running server.

## You need

- Terraform ≥ 1.10 (or OpenTofu ≥ 1.10).
- The domain's DNS on Cloudflare (the `kaiodelphino.com` zone), and its zone id.
- A Cloudflare API token for Terraform, with:
  - Account → Workers R2 Storage: Edit
  - Account → Account API Tokens: Edit
  - Zone → DNS: Edit, on `kaiodelphino.com`
  - Zone → Zone: Read, on `kaiodelphino.com` (for `files_hostname`)
- A Hetzner Cloud project and an API token for it (read & write).
- An SSH key pair.

## Before the first apply

The state holds every R2 key in plain text, so it lives in its own private bucket, made by
hand once (Terraform can't create the bucket that holds its own state):

1. Cloudflare dashboard → R2 → Create bucket `postilla-tfstate`.
2. R2 → Manage API tokens → Create an **Account** token with *Object Read & Write* on
   `postilla-tfstate` only. Keep its Access Key ID and Secret Access Key.
3. In `infra/`:
   ```bash
   cp backend.hcl.example backend.hcl            # set your account id in the endpoint
   cp terraform.tfvars.example terraform.tfvars  # account id, zone id, SSH key
   ```
   Both are git-ignored.

## Apply

```bash
export CLOUDFLARE_API_TOKEN=…           # the Terraform token above
export HCLOUD_TOKEN=…
export AWS_ACCESS_KEY_ID=…              # the postilla-tfstate key pair
export AWS_SECRET_ACCESS_KEY=…

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Then the CLI's configuration: every value but the OpenCode and Speechify keys. Copy these
lines into `cli.env` over the old ones (don't redirect into it: that would drop the two keys
it already holds):

```bash
terraform output -raw cli_env
```

## Deploying the server

The binary is static, so one build runs on any x86_64 Linux:

```bash
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
scp zig-out/bin/postilla-server root@$(terraform -chdir=infra output -raw server_ipv4):/usr/local/bin/
ssh root@… 'chmod 0755 /usr/local/bin/postilla-server && systemctl restart postilla-server'
```

On first boot without `server_binary_url` the unit waits for the binary (its
`ConditionPathExists` fails until then), so the first deploy is the same `scp` and
`systemctl restart`. Once a release URL exists, set `server_binary_url` and new servers
fetch it themselves.

Check it:

```bash
curl -sS https://api.postilla.kaiodelphino.com/languages | head -c 4   # LANG
ssh root@… journalctl -u postilla-server -u litestream -u caddy -n 50
```

## Restoring

`postilla.db` is replicated to the backup bucket within a second of each write. To rebuild
the server, remove its protection and replace it:

```bash
terraform apply -replace=hcloud_server.api   # after turning delete_protection off in the console
```

The new server's cloud-init restores the database from the backup before the server starts.
Cursors lost in the last second follow the rule in specification.md, Cursor.

## Notes

- `delete_protection` and `rebuild_protection` are on: the disk holds `postilla.db`.
- An R2 key pair is derived from its token: the access key id is the token's id and the
  secret is the sha256 of its value (`main.tf`, `locals`).
- The VPS's user data holds the author token and Litestream's key; Hetzner's metadata
  service shows it only to the server itself.
- `server_type` `cx22` is x86_64 (2 vCPU, 4 GB, about €4/month). An Arm `cax` type needs an
  `aarch64-linux-musl` build and the Litestream `arm64` package.
