output "release_name" {
  description = "Name of the Helm release."
  value       = try(helm_release.nomad_enterprise[0].name, null)
}

output "namespace" {
  description = "Kubernetes namespace where Nomad Enterprise is deployed."
  value       = try(helm_release.nomad_enterprise[0].namespace, null)
}

output "status" {
  description = "Status of the Helm release."
  value       = try(helm_release.nomad_enterprise[0].status, null)
}

output "chart_version" {
  description = "Version of the deployed Helm chart."
  value       = try(helm_release.nomad_enterprise[0].metadata.version, null)
}

output "app_version" {
  description = "Application version of Nomad Enterprise."
  value       = try(helm_release.nomad_enterprise[0].metadata.app_version, null)
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
