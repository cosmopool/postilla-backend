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

variable "files_hostname" {
  description = "Optional custom domain for the public story bucket (e.g. files.postilla.kaiodelphino.com), the base URL the app downloads stories from. Empty: no custom domain."
  type        = string
  default     = ""
}

variable "story_bucket" {
  description = "Public bucket: stories/ (written by `postilla publish`) and dict/ (written by the postilla-content build)."
  type        = string
  default     = "postilla-stories"
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
  description = "Hetzner Cloud server type. cx22: 2 vCPU, 4 GB, plenty for one SQLite writer."
  type        = string
  default     = "cx22"
}

variable "server_location" {
  description = "Hetzner location: fsn1, nbg1, hel1 (EU), ash, hil (US), sin."
  type        = string
  default     = "fsn1"
}

variable "server_image" {
  description = "OS image for the VPS."
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_public_key" {
  description = "Public key allowed to log in as root (and as the admin user)."
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
