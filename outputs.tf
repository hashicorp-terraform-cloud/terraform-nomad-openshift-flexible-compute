output "release_name" {
  description = "Name of the Helm release."
  value       = helm_release.nomad_enterprise.name
}

output "namespace" {
  description = "Kubernetes namespace where Nomad Enterprise is deployed."
  value       = helm_release.nomad_enterprise.namespace
}

output "status" {
  description = "Status of the Helm release."
  value       = helm_release.nomad_enterprise.status
}

output "chart_version" {
  description = "Version of the deployed Helm chart."
  value       = helm_release.nomad_enterprise.metadata.version
}

output "app_version" {
  description = "Application version of Nomad Enterprise."
  value       = helm_release.nomad_enterprise.metadata.app_version
}

# --- AAP ---

output "inventory_id" {
  description = "AAP inventory ID for the Nomad client hosts."
  value       = aap_inventory.nomad_clients.id
}

output "client_hosts" {
  description = "List of Nomad client host addresses."
  value       = keys(aap_host.nomad_client)
}
