terraform {
  required_version = ">= 1.10"

  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.29" }
    hcloud     = { source = "hetznercloud/hcloud", version = "~> 1.70" }
    random     = { source = "hashicorp/random", version = "~> 3.7" }
  }

  # The state holds every token below in plain text, so it lives in its own private R2
  # bucket, never the public story bucket. The bucket and its credentials are made by hand
  # once (README.md, "Before the first apply"); `terraform init -backend-config=backend.hcl`
  # fills in the rest.
  backend "s3" {
    key                         = "postilla/terraform.tfstate"
    region                      = "auto"
    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

# Both read their token from the environment: CLOUDFLARE_API_TOKEN and HCLOUD_TOKEN.
provider "cloudflare" {}
provider "hcloud" {}
