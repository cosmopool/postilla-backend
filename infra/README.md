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
| `vultr_instance.api` | The VPS (Vultr `vc2-1c-1gb` in São Paulo, Ubuntu 24.04), set up by `cloud-init.yaml.tftpl` |
| `vultr_firewall_group.server`, `vultr_firewall_rule.server` | 22 from `ssh_allowed_cidrs`; 80 and 443 from anywhere |
| `cloudflare_dns_record.api_a`, `api_aaaa` | `api.postilla.kaiodelphino.com` → the VPS, not proxied (Caddy does TLS) |
| `cloudflare_r2_bucket.staging_stories` | Staging's story bucket, `postilla-stories-staging` |
| `cloudflare_account_token.cli_staging` | The CLI's R2 key against staging: objects in the staging story bucket only |
| `random_password.staging_author_token` | Staging's bearer token, never valid on production |
| `cloudflare_dns_record.staging_a`, `staging_aaaa` | `staging-api.postilla.kaiodelphino.com` → the same VPS |

cloud-init installs Caddy, Litestream and the `postilla-server` systemd unit on first boot,
writes `/etc/postilla/env` (root-only, the author token), and restores `postilla.db` from
the backup bucket when the bucket already holds one. It also installs the egress guard
(see Notes) and staging (below). Terraform doesn't deploy the binary after that, and
changing cloud-init doesn't touch a running server.

## Staging

Staging is a second `postilla-server` on the same VPS, with nothing shared but the machine:

| | Production | Staging |
|---|---|---|
| URL | `https://api.postilla.kaiodelphino.com` | `https://staging-api.postilla.kaiodelphino.com` |
| systemd unit, binary | `postilla-server` | `postilla-server-staging` |
| User, data | `postilla`, `/var/lib/postilla` | `postilla-staging`, `/var/lib/postilla-staging` |
| Port, env | 8080, `/etc/postilla/env` | 8081, `/etc/postilla/staging.env` |
| Story bucket | `postilla-stories` | `postilla-stories-staging` |
| Backup | Litestream to `postilla-backup` | none: staging data is disposable |

They share the CPU, memory and the egress guard's monthly count: load on staging slows
production, and the guard stops Caddy for both. `dict/` isn't in the staging bucket until
it's copied there.

## You need

- OpenTofu ≥ 1.10. The lock file names OpenTofu's registry; Terraform ≥ 1.10 works too after `terraform init -upgrade`.
- The domain's DNS on Cloudflare (the `kaiodelphino.com` zone), and its zone id.
- A Cloudflare API token for Terraform, with:
  - Account → Workers R2 Storage: Edit
  - Account → Account API Tokens: Edit
  - Zone → DNS: Edit, on `kaiodelphino.com`
  - Zone → Zone: Read, on `kaiodelphino.com` (for `files_hostname`)
- A Vultr account and its API key (Account → API → Enable API), with your address allowed
  under the key's Access Control.
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
   cp .env.example .env                          # the four keys below
   ```
   All three are git-ignored.

## Apply

`.env` holds the keys OpenTofu reads from the environment: `CLOUDFLARE_API_TOKEN` (the
Terraform token above), `VULTR_API_KEY`, and `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` (the postilla-tfstate key pair). Load it into the shell that runs
`tofu`, from `infra/`. In bash:

```bash
set -a; . ./.env; set +a
```

In fish:

```fish
for l in (string match -rv '^\s*(#|$)' < .env); set -gx (string split -m1 = -- $l); end
```

Then:

```bash
tofu init -backend-config=backend.hcl
tofu plan
tofu apply
```

Then the CLI's configuration: every value but the OpenCode and Speechify keys. Copy these
lines into `cli.env` over the old ones (don't redirect into it: that would drop the two keys
it already holds):

```bash
tofu output -raw cli_env
```

Staging's go in `cli.staging.env` (git-ignored), with the OpenCode and Speechify lines
copied from `cli.env`. The CLI reads `./cli.env`, and the environment wins over it, so
loading `cli.staging.env` into the environment points one command at staging:

```bash
tofu output -raw cli_env_staging
env $(grep -v '^#' cli.staging.env) postilla publish …   # bash; in fish: env (grep -v '^#' cli.staging.env) …
```

## Deploying the server

`deploy.sh` makes the first deploy and every update, to production or staging. It builds
the static `x86_64-linux-musl` binary and pipes it over SSH to `postilla-update` on the
server, which:

1. keeps the running binary as `.prev` (`/usr/local/bin/postilla-server.prev`, or
   `postilla-server-staging.prev`),
2. swaps the new one in with one rename and restarts the unit,
3. waits up to 10 s for `GET /languages` on its port (8080 or 8081), and when it doesn't
   answer, puts `.prev` back, restarts, and exits 1.

```bash
POSTILLA_DEPLOY_KEY=~/.ssh/tumbler infra/deploy.sh staging      # root@api.postilla.kaiodelphino.com
POSTILLA_DEPLOY_KEY=~/.ssh/tumbler infra/deploy.sh production
```

`POSTILLA_DEPLOY_KEY` is optional (without it, ssh picks the key), and a second argument
overrides the target, e.g. `infra/deploy.sh staging root@216.238.123.227`. One update runs
at a time. cloud-init installs `postilla-update` (from `infra/postilla-update`) on a new
server; on the running one, an edit to it is installed by hand:

```bash
ssh root@… 'install -m 0755 /dev/stdin /usr/local/sbin/postilla-update' < infra/postilla-update
```

On first boot without `server_binary_url` the unit waits for the binary (its
`ConditionPathExists` fails until then), so the first deploy is `deploy.sh` too. Once a
release URL exists, set `server_binary_url` and new servers fetch it themselves.

Check it:

```bash
curl -sS https://api.postilla.kaiodelphino.com/languages | head -c 4   # LANG
ssh root@… journalctl -u postilla-server -u litestream -u caddy -n 50
```

## GitHub Actions

`.github/workflows/deploy.yml` runs `zig build test-dart` in a `dart` job (the only one with the
Dart SDK), then, once it passes, `zig build test` and `deploy.sh` in the `deploy` job:

- Pushing a version tag (`git tag v1.2.0 && git push origin v1.2.0`) deploys it to staging.
- Production is manual: Actions → deploy → Run workflow, pick the tag under "Use workflow
  from" and `production`. A run on a branch fails before it deploys.

The job logs in as `deploy@api.postilla.kaiodelphino.com` with the repository secret
`DEPLOY_SSH_KEY`, the private half of `deploy_ssh_public_key` (`~/.ssh/postilla-deploy`).
That key can do one thing: cloud-init writes it to `/home/deploy/.ssh/authorized_keys` as
`restrict,command="sudo /usr/local/sbin/postilla-update …"`, which runs `postilla-update`
with the last word of the requested command, and `/etc/sudoers.d/postilla-deploy` allows
only `postilla-update production` and `postilla-update staging`. Root owns both files, so
the deploy user can't lift the limit; any other command fails at sudo. A leaked key can
install a binary, which still has to answer `GET /languages`, and nothing else.

The server's host key is pinned in `infra/known_hosts`, so the job refuses any other
server. It runs in the GitHub environment named after the server (`staging`,
`production`); required reviewers on `production` add an approval step.

## Restoring

`postilla.db` is replicated to the backup bucket within a second of each write. To rebuild
the server, remove its protection and replace it:

```bash
tofu apply -replace=vultr_instance.api   # after deleting prevent_destroy in main.tf
```

The new server's cloud-init restores the database from the backup before the server starts.
Cursors lost in the last second follow the rule in specification.md, Cursor. Staging starts
empty. The new server has a new SSH host key: replace the line in `infra/known_hosts`
(`ssh root@… cat /etc/ssh/ssh_host_ed25519_key.pub`), or the deploy workflow refuses it.

## Notes

- SSH takes keys only: `/etc/ssh/sshd_config.d/00-postilla.conf` turns password and
  keyboard-interactive logins off. Port 22 is open to `ssh_allowed_cidrs`, the whole internet
  by default; narrowing it changes firewall rules only, not the server.
- `prevent_destroy` is on: the disk holds `postilla.db`, and Vultr has no delete protection
  of its own.
- An R2 key pair is derived from its token: the access key id is the token's id and the
  secret is the sha256 of its value (`main.tf`, `locals`).
- The VPS's user data holds the author token and Litestream's key; Vultr's metadata
  service shows it only to the server itself.
- The egress guard caps the bill. Vultr charges $0.01/GB for outbound traffic past the
  account's allowance and has no cap of its own, so a flood of requests could run one up.
  `/usr/local/sbin/postilla-egress-guard` runs from cron every minute. It reads this
  month's outbound bytes from vnstat, and at `egress_limit_gb` (2,900 GB of 10^9 bytes,
  under the allowance: 2 TB free per account plus the plan's 1 TB, accrued hourly) it stops
  Caddy: both APIs are down, SSH and Litestream keep working. At the next month (UTC, like
  Vultr's billing) it starts Caddy again. vnstat counts all the interface sends, which
  is at least what Vultr bills. See it with `vnstat -m` and
  `journalctl -t postilla-egress-guard`. To serve again before the month ends, raise the
  `limit=` line in the script (`egress_limit_gb` in Terraform only reaches new servers).
- `server_type` `vc2-1c-1gb` is x86_64 (1 vCPU, 1 GB, 25 GB, 1 TB of traffic, $5/month).
  São Paulo (`sao`) is about 10 ms from Brazil; the app downloads stories from R2, so only
  API calls pay the distance from Italy.
