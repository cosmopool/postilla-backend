output "api_url" {
  value = "https://${var.api_hostname}"
}

output "server_ipv4" {
  value = vultr_instance.api.main_ip
}

output "server_ipv6" {
  value = vultr_instance.api.v6_main_ip
}

output "files_url" {
  description = "The story bucket's public base URL, when files_hostname is set."
  value       = var.files_hostname == "" ? null : "https://${var.files_hostname}"
}

# `terraform output -raw cli_env` prints the CLI's configuration for cli.env, apart from the
# OpenCode and Speechify keys, which aren't Terraform's.
output "cli_env" {
  sensitive = true
  value     = <<-EOT
    POSTILLA_SERVER_URL=https://${var.api_hostname}
    POSTILLA_AUTHOR_TOKEN=${random_password.author_token.result}
    POSTILLA_R2_ACCOUNT_ID=${var.cloudflare_account_id}
    POSTILLA_R2_ACCESS_KEY_ID=${cloudflare_account_token.cli.id}
    POSTILLA_R2_SECRET_ACCESS_KEY=${local.cli_secret}
    POSTILLA_R2_BUCKET=${cloudflare_r2_bucket.stories.name}
  EOT
}
