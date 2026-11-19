# Everything docs/specification.md, Deployment, needs: the two R2 buckets, one token per
# bucket, the VPS with its firewall, and the DNS record Caddy serves.

locals {
  # R2's S3 host, as Litestream takes it.
  r2_host = "${var.cloudflare_account_id}.r2.cloudflarestorage.com"
  # An R2 S3 key pair comes from an API token: the token's id is the access key id and the
  # sha256 of its value is the secret.
  cli_secret        = sha256(cloudflare_account_token.cli.value)
  litestream_secret = sha256(cloudflare_account_token.litestream.value)
}

# --- R2 ----------------------------------------------------------------------

resource "cloudflare_r2_bucket" "stories" {
  account_id = var.cloudflare_account_id
  name       = var.story_bucket
  location   = var.r2_location
}

resource "cloudflare_r2_bucket" "backup" {
  account_id = var.cloudflare_account_id
  name       = var.backup_bucket
  location   = var.r2_location
}

# The public base URL the app downloads from, when files_hostname is set.
resource "cloudflare_r2_custom_domain" "stories" {
  count       = var.files_hostname == "" ? 0 : 1
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.stories.name
  domain      = var.files_hostname
  zone_id     = var.zone_id
  enabled     = true
  min_tls     = "1.2"
}

# --- Tokens: one per bucket, each limited to that bucket's objects -------------

data "cloudflare_account_api_token_permission_groups_list" "r2_write" {
  account_id = var.cloudflare_account_id
  name       = "Workers R2 Storage Bucket Item Write"
}

locals {
  r2_write_group = data.cloudflare_account_api_token_permission_groups_list.r2_write.result[0].id
}

# The CLI's: `postilla publish` uploads stories/ and reads dict/ in the story bucket.
resource "cloudflare_account_token" "cli" {
  account_id = var.cloudflare_account_id
  name       = "postilla-cli (${var.story_bucket})"
  policies = [{
    effect            = "allow"
    permission_groups = [{ id = local.r2_write_group }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.stories.name}" = "*"
    })
  }]
}

# Litestream's: the backup bucket only. It sits on the VPS, which holds no other R2 key.
resource "cloudflare_account_token" "litestream" {
  account_id = var.cloudflare_account_id
  name       = "postilla-litestream (${var.backup_bucket})"
  policies = [{
    effect            = "allow"
    permission_groups = [{ id = local.r2_write_group }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.backup.name}" = "*"
    })
  }]
}

# The bearer token for POST /stories and DELETE /stories/<id>: on the VPS and in cli.env.
resource "random_password" "author_token" {
  length  = 64
  special = false
}

# --- VPS ---------------------------------------------------------------------

resource "hcloud_ssh_key" "admin" {
  name       = "postilla-admin"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "server" {
  name = "postilla-server"

  rule {
    description = "SSH"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.ssh_allowed_cidrs
  }
  rule {
    description = "HTTP (ACME challenge, redirect to HTTPS)"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
  rule {
    description = "HTTPS"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
  rule {
    description = "HTTP/3"
    direction   = "in"
    protocol    = "udp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
  rule {
    description = "Ping"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "api" {
  name         = "postilla-api"
  server_type  = var.server_type
  location     = var.server_location
  image        = var.server_image
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.server.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    api_hostname       = var.api_hostname
    author_token       = random_password.author_token.result
    binary_url         = var.server_binary_url
    litestream_version = var.litestream_version
    r2_host            = local.r2_host
    backup_bucket      = cloudflare_r2_bucket.backup.name
    litestream_key_id  = cloudflare_account_token.litestream.id
    litestream_secret  = local.litestream_secret
  })

  # postilla.db lives on this disk: never replace or wipe the server by accident. A changed
  # cloud-init only matters for a new server, so it doesn't force one either.
  delete_protection  = true
  rebuild_protection = true
  lifecycle {
    ignore_changes = [user_data, image]
  }
}

# --- DNS ---------------------------------------------------------------------

# Not proxied: Caddy terminates TLS itself, with its own certificate for api_hostname.
resource "cloudflare_dns_record" "api_a" {
  zone_id = var.zone_id
  name    = var.api_hostname
  type    = "A"
  content = hcloud_server.api.ipv4_address
  ttl     = 300
  proxied = false
}

resource "cloudflare_dns_record" "api_aaaa" {
  zone_id = var.zone_id
  name    = var.api_hostname
  type    = "AAAA"
  content = hcloud_server.api.ipv6_address
  ttl     = 300
  proxied = false
}
