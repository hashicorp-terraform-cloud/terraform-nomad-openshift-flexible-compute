output "linux_public_ip" {
  description = "Public IP of the Linux E2E test host."
  value       = aws_instance.linux.public_ip
}

output "redhat_public_ip" {
  description = "Public IP of the optional Red Hat E2E test host; null when deploy_redhat_client is false."
  value       = try(aws_instance.redhat[0].public_ip, null)
}

output "windows_public_ip" {
  description = "Public IP of the Windows E2E test host."
  value       = aws_instance.windows.public_ip
}

output "linux_ssh_user" {
  description = "SSH username for Linux host access."
  value       = var.linux_ssh_user
}

output "redhat_ssh_user" {
  description = "SSH username for optional Red Hat host access."
  value       = var.redhat_ssh_user
}

output "windows_admin_username" {
  description = "Windows administrator username."
  value       = var.windows_admin_username
}

output "deploy_local_macos_client" {
  description = "Whether the optional local macOS client target is enabled in generated inventory."
  value       = var.deploy_local_macos_client
}

output "local_macos_connection" {
  description = "Connection mode for the optional local macOS client target."
  value       = lower(trimspace(var.local_macos_connection))
}

output "local_macos_host_alias" {
  description = "Inventory host alias for the optional local macOS client target."
  value       = var.local_macos_host_alias
}

output "generated_ssh_private_key_pem" {
  description = "Generated private key PEM used by the E2E EC2 key pair for Linux SSH access and Windows password-data decryption."
  value       = tls_private_key.e2e.private_key_pem
  sensitive   = true
}

output "windows_admin_password" {
  description = "Decrypted Windows administrator password from EC2 password_data using the generated E2E private key; may be empty until AWS returns password_data."
  value       = local.windows_admin_password
  sensitive   = true
}

output "inventory_ini" {
  description = "Rendered Ansible inventory content for local E2E artifact generation."
  value       = trimspace(local.inventory_content)
  sensitive   = true
}

output "extra_vars_yaml" {
  description = "Rendered Ansible extra vars YAML content for local E2E artifact generation."
  value       = trimspace(local.rendered_extra_vars)
  sensitive   = true
}

output "windows_password_data" {
  description = "Encrypted Windows administrator password data returned by EC2; decrypt locally with generated_ssh_private_key_pem."
  value       = aws_instance.windows.password_data
  sensitive   = true
}

output "deploy_nomad_server" {
  description = "Whether the E2E harness deployed a single-node Nomad server."
  value       = var.deploy_nomad_server
}

output "nomad_server_address" {
  description = "Nomad server address consumed by the Ansible install playbook; uses the EC2 private DNS hostname for self-contained E2E runs."
  value       = local.effective_nomad_server_address
}

output "nomad_server_private_ip" {
  description = "Private IP of the E2E Nomad server when deploy_nomad_server is true; null otherwise."
  value       = local.nomad_server_private_ip
}

output "nomad_server_private_dns" {
  description = "Private DNS hostname of the E2E Nomad server when deploy_nomad_server is true; null otherwise."
  value       = try(aws_instance.nomad_server[0].private_dns, null)
}

output "nomad_server_public_ip" {
  description = "Public IP of the E2E Nomad server when deploy_nomad_server is true; null otherwise."
  value       = try(aws_eip.nomad_server[0].public_ip, null)
}

output "nomad_datacenter" {
  description = "Nomad datacenter value used by Ansible install playbook."
  value       = var.nomad_datacenter
}

output "nomad_region" {
  description = "Nomad region value used by Ansible install playbook."
  value       = var.nomad_region
}

output "nomad_acl_enabled" {
  description = "Whether Nomad ACLs are enabled in the self-hosted E2E Nomad server configuration."
  value       = var.nomad_acl_enabled
}

output "nomad_edition" {
  description = "Nomad client edition value used by E2E install workflow."
  value       = var.nomad_edition
}

output "nomad_version" {
  description = "Optional Nomad version override value used by E2E install workflow."
  value       = var.nomad_version
}

output "nomad_license" {
  description = "Optional single-line Nomad Enterprise license value used by E2E install workflow."
  value       = var.nomad_license
  sensitive   = true
}

output "client_introduction_token" {
  description = "Optional Nomad client introduction token used during install tests."
  value       = var.client_introduction_token
  sensitive   = true
}

output "nomad_tls_enabled" {
  description = "Whether Nomad TLS is enabled in the E2E harness."
  value       = var.nomad_tls_enabled
}

output "nomad_addr" {
  description = "Nomad API address used by E2E scripts and remove workflow."
  value       = "${var.nomad_tls_enabled ? "https" : "http"}://${local.effective_nomad_server_address}:4646"
}

output "nomad_tls_ca_pem" {
  description = "PEM-encoded Nomad TLS CA certificate used by E2E workflows."
  value       = local.nomad_tls_ca_pem_e2e
  sensitive   = true
}

output "nomad_tls_client_cert_pem" {
  description = "PEM-encoded Nomad TLS client certificate used by E2E workflows."
  value       = local.nomad_tls_cli_cert_pem_e2e
  sensitive   = true
}

output "nomad_tls_client_key_pem" {
  description = "PEM-encoded Nomad TLS client private key used by E2E workflows."
  value       = local.nomad_tls_cli_key_pem_e2e
  sensitive   = true
}
