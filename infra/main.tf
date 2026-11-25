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

resource "vultr_ssh_key" "admin" {
  name    = "postilla-admin"
  ssh_key = var.ssh_public_key
}

resource "vultr_firewall_group" "server" {
  description = "postilla-server"
}

locals {
  anywhere = ["0.0.0.0/0", "::/0"]
  # Vultr takes one rule per protocol, port and source range.
  firewall_rules = merge(
    { for c in var.ssh_allowed_cidrs : "ssh ${c}" => { notes = "SSH", protocol = "tcp", port = "22", cidr = c } },
    { for c in local.anywhere : "http ${c}" => { notes = "HTTP (ACME challenge, redirect to HTTPS)", protocol = "tcp", port = "80", cidr = c } },
    { for c in local.anywhere : "https ${c}" => { notes = "HTTPS", protocol = "tcp", port = "443", cidr = c } },
    { for c in local.anywhere : "http3 ${c}" => { notes = "HTTP/3", protocol = "udp", port = "443", cidr = c } },
    { for c in local.anywhere : "ping ${c}" => { notes = "Ping", protocol = "icmp", port = null, cidr = c } },
  )
}

resource "vultr_firewall_rule" "server" {
  for_each          = local.firewall_rules
  firewall_group_id = vultr_firewall_group.server.id
  notes             = each.value.notes
  protocol          = each.value.protocol
  port              = each.value.port
  ip_type           = strcontains(each.value.cidr, ":") ? "v6" : "v4"
  subnet            = split("/", each.value.cidr)[0]
  subnet_size       = tonumber(split("/", each.value.cidr)[1])
}

data "vultr_os" "server" {
  filter {
    name   = "name"
    values = [var.server_image]
  }
}

resource "vultr_instance" "api" {
  label             = "postilla-api"
  hostname          = "postilla-api"
  plan              = var.server_type
  region            = var.server_location
  os_id             = data.vultr_os.server.id
  enable_ipv6       = true
  ssh_key_ids       = [vultr_ssh_key.admin.id]
  firewall_group_id = vultr_firewall_group.server.id
  # Litestream to R2 is the backup; Vultr's snapshots would add 20% to the bill.
  backups          = "disabled"
  activation_email = false

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    api_hostname       = var.api_hostname
    author_token       = random_password.author_token.result
    binary_url         = var.server_binary_url
    litestream_version = var.litestream_version
    r2_host            = local.r2_host
    backup_bucket      = cloudflare_r2_bucket.backup.name
    litestream_key_id  = cloudflare_account_token.litestream.id
    litestream_secret  = local.litestream_secret
    egress_limit_gb    = var.egress_limit_gb
    postilla_update    = file("${path.module}/postilla-update")
  })

  # postilla.db lives on this disk: never replace or wipe the server by accident. A changed
  # cloud-init only matters for a new server, so it doesn't force one either.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [user_data, os_id]
  }
}

# --- DNS ---------------------------------------------------------------------

# Not proxied: Caddy terminates TLS itself, with its own certificate for api_hostname.
resource "cloudflare_dns_record" "api_a" {
  zone_id = var.zone_id
  name    = var.api_hostname
  type    = "A"
  content = vultr_instance.api.main_ip
  ttl     = 300
  proxied = false
}

resource "cloudflare_dns_record" "api_aaaa" {
  zone_id = var.zone_id
  name    = var.api_hostname
  type    = "AAAA"
  content = vultr_instance.api.v6_main_ip
  ttl     = 300
  proxied = false
}
