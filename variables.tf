variable "chart_repository" {
  type        = string
  description = "Helm repository URL for the Nomad Enterprise chart."
  default     = "https://benemon.github.io/nomad-server-helm"
}

variable "chart_version" {
  type        = string
  description = "Version of the nomad-enterprise Helm chart to deploy."
  default     = "1.0.0"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for the Nomad Enterprise deployment."
  default     = "nomad-enterprise"
}

variable "load_balancer_ip" {
  type        = string
  description = "Static IP address for the LoadBalancer service. Also used as the Nomad advertise address."
}

variable "license" {
  type        = string
  description = "Nomad Enterprise license string."
}

variable "replica_count" {
  type        = number
  description = "Number of Nomad server replicas."
  default     = 3

  validation {
    condition     = contains([1, 3, 5], var.replica_count)
    error_message = "replica_count must be 1, 3, or 5 for Raft consensus."
  }
}

variable "monitoring_enabled" {
  type        = bool
  description = "Enable OpenShift monitoring integration (ServiceMonitor)."
  default     = true
}

variable "prometheus_rule_enabled" {
  type        = bool
  description = "Enable Prometheus alerting rules for Nomad server health."
  default     = true
}

# --- Nomad Client Deployment (AAP) ---

variable "nomad_client_hosts" {
  type        = string
  description = "Comma-separated list of IPs or FQDNs for Nomad client hosts."
}

variable "aap_install_job_template_id" {
  type        = number
  description = "AAP job template ID for installing the Nomad client agent."
}

variable "aap_remove_job_template_id" {
  type        = number
  description = "AAP job template ID for removing the Nomad client agent."
}

variable "aap_organization" {
  type        = number
  description = "AAP organization ID for the Nomad client inventory."
  default     = 1
}
