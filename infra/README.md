# infra

Terraform for everything [Deployment](../docs/specification.md#deployment) needs:

| Resource | What it is |
|---|---|
| `cloudflare_r2_bucket.stories` | The public story bucket (`stories/` from `postilla publish`, `dict/` from postilla-content) |
| `cloudflare_r2_bucket.backup` | The private bucket Litestream streams `postilla.db` to |
| `cloudflare_r2_custom_domain.stories` | Public domain of the story bucket (`files_hostname`, default `content.postilla.kaiodelphino.com`) |
| `cloudflare_r2_custom_domain.staging_stories` | Public domain of staging's story bucket (`staging_files_hostname`, default `staging-content.postilla.kaiodelphino.com`) |
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
| Public domain | `files_hostname` (`content.postilla.kaiodelphino.com`) | `staging_files_hostname` (`staging-content.postilla.kaiodelphino.com`) |
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
  - Zone → Zone: Read, on `kaiodelphino.com` (for `files_hostname` and `staging_files_hostname`)
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
   answer, puts `.prev` back, restarts, and exits 1,
4. when it answers, prints the new binary's `--version` (the latest git tag and the full
   commit hash it was built from) and logs it to syslog.

To see what a server runs: `ssh root@… /usr/local/bin/postilla-server --version` (or
`postilla-server-staging`), or `journalctl -t postilla-update` for every install.

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

`.github/workflows/test.yml` runs on every branch push and pull request: `zig build test`,
`zig build test-dart` (the only job with the Dart SDK) and `zig fmt --check`; a newer push to the
same branch cancels the run it replaces. `.github/workflows/deploy.yml` runs four jobs, each once
the one before passes: `ref` refuses a tag that isn't `vMAJOR.MINOR.PATCH` (its name reaches shell
commands and `--version`) and a production run on a branch; `tests` calls `test.yml`; `build`
builds the release binary and uploads it as the `postilla-server` artifact; `deploy` downloads it,
runs `deploy.sh` with `POSTILLA_SERVER_BIN`, so it ships the exact file `build` made and has no
Zig, then runs `infra/smoke.sh` against that server's public URL with the commit it shipped: a
server that runs another commit, or whose lists or feed don't parse, fails the run.
`tests` and `build` run `zig build --fetch=all` first: on a cold cache the build fetches the lazy C
dependencies concurrently, and Zig 0.17's HTTP client fails the second download from
xiph.org with `HttpConnectionClosing`.

- Pushing a version tag (`git tag v1.2.0 && git push origin v1.2.0`) deploys it to staging.
- Production is manual: Actions → deploy → Run workflow, pick the tag under "Use workflow
  from" and `production`. A run on a branch fails before it deploys. It skips `tests` and
  `build` and ships the artifact of the tag's successful push run, the binary staging runs.
  Artifacts are kept 90 days; a tag with none (expired, or tagged before the `build` job,
  v0.2.3 and older) fails, and the fix is a new tag.
- `.github/workflows/smoke.yml` runs the same smoke test against both servers every 6 hours and
  on demand (Actions → smoke → Run workflow). A failed run is GitHub's email to the watchers.
  Servers older than `GET /version` (v0.2.3 and older) fail it until their next deploy.
- `infra/smoke.sh <base URL> [commit]` runs it by hand, against either server or a local one.
- Every action is pinned by commit SHA, with its version in a comment. To update one, take the
  commit of its new tag (`git ls-remote https://github.com/actions/checkout 'refs/tags/v7.0.2^{}'`,
  or the tag itself when it isn't annotated) and change both.

The job logs in as `deploy@api.postilla.kaiodelphino.com` with the repository secret
`DEPLOY_SSH_KEY`, the private half of `deploy_ssh_public_key` (`~/.ssh/postilla-deploy`).
That key can do one thing: cloud-init writes it to `/home/deploy/.ssh/authorized_keys` as
`restrict,command="sudo /usr/local/sbin/postilla-update …"`, which runs `postilla-update`
with the last word of the requested command, and `/etc/sudoers.d/postilla-deploy` allows
only `postilla-update production` and `postilla-update staging`. Root owns both files, so
the deploy user can't lift the limit; any other command fails at sudo. A leaked key can
install a binary, which still has to answer `GET /languages`, and nothing else.

Terraform ignores `user_data` on a running server, so a changed `infra/postilla-update` reaches it
only by hand, over root SSH:

```
ssh root@api.postilla.kaiodelphino.com 'cat > /usr/local/sbin/postilla-update.new && chmod 0755 /usr/local/sbin/postilla-update.new && mv /usr/local/sbin/postilla-update.new /usr/local/sbin/postilla-update' < infra/postilla-update
```

Nor does a new `deploy_ssh_public_key`: `infra/install-deploy-key.sh [root@host] [public key]` writes the same line over root
SSH and prints the key fingerprint before and after.

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
