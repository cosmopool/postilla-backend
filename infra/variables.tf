variable "cloudflare_account_id" {
  description = "Cloudflare account id: the R2 buckets and their tokens live in it."
  type        = string
}

variable "zone_id" {
  description = "Cloudflare zone id of the domain that holds api_hostname (kaiodelphino.com)."
  type        = string
}

variable "api_hostname" {
  description = "Where postilla-server answers; Caddy gets its TLS certificate for this name."
  type        = string
  default     = "api.postilla.kaiodelphino.com"
}

variable "staging_api_hostname" {
  description = "Where the staging postilla-server answers, on the same VPS; Caddy gets its own certificate for it."
  type        = string
  default     = "staging-api.postilla.kaiodelphino.com"
}

variable "files_hostname" {
  description = "Custom domain of the public story bucket: the base URL the app downloads stories from (built into the app, ARQ-06). Empty: no custom domain."
  type        = string
  default     = "content.postilla.kaiodelphino.com"
}

variable "staging_files_hostname" {
  description = "Custom domain of staging's story bucket: the base URL the app's dev flavor downloads from. Empty: no custom domain."
  type        = string
  default     = "staging-content.postilla.kaiodelphino.com"
}

variable "story_bucket" {
  description = "Public bucket: stories/ (written by `postilla publish`) and dict/ (written by the postilla-content build)."
  type        = string
  default     = "postilla-stories"
}

variable "staging_story_bucket" {
  description = "Staging's story bucket: what `postilla publish` writes against the staging server."
  type        = string
  default     = "postilla-stories-staging"
}

variable "backup_bucket" {
  description = "Private bucket Litestream streams postilla.db to."
  type        = string
  default     = "postilla-backup"
}

variable "r2_location" {
  description = "R2 location hint for both buckets: apac, eeur, enam, weur, wnam or oc."
  type        = string
  default     = "weur"
}

variable "server_type" {
  description = "Vultr plan. vc2-1c-1gb: 1 vCPU, 1 GB, 25 GB, x86_64, plenty for one SQLite writer."
  type        = string
  default     = "vc2-1c-1gb"
}

variable "server_location" {
  description = "Vultr region. sao: São Paulo, near the Brazilian learners."
  type        = string
  default     = "sao"
}

variable "server_image" {
  description = "OS image for the VPS, by its Vultr name."
  type        = string
  default     = "Ubuntu 24.04 LTS x64"
}

variable "ssh_public_key" {
  description = "Public key allowed to log in as root (and as the admin user)."
  type        = string
}

variable "deploy_ssh_public_key" {
  description = "Public key CI logs in with as deploy; it can only run postilla-update (infra/README.md, GitHub Actions)."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "Source ranges allowed to reach port 22. Narrow this to your own address."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "server_binary_url" {
  description = "Optional URL of a static postilla-server binary (x86_64-linux-musl) for cloud-init to download. Empty: copy it with `scp` after the first apply (README.md, Deploying)."
  type        = string
  default     = ""
}

variable "litestream_version" {
  description = "Litestream release installed by cloud-init."
  type        = string
  default     = "0.5.18"
}

variable "egress_limit_gb" {
  description = "Outbound traffic per calendar month (UTC), in GB of 10^9 bytes, at which the VPS stops Caddy until the next month. Below Vultr's allowance (2 TB free per account plus the plan's 1 TB), so an attack can't run up an overage bill."
  type        = number
  default     = 2900

  validation {
    condition     = var.egress_limit_gb > 0 && var.egress_limit_gb == floor(var.egress_limit_gb)
    error_message = "egress_limit_gb must be a whole number of GB above 0."
  }
}
