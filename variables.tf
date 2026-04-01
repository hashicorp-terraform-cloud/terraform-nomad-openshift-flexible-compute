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

variable "deploy_nomad_cluster" {
  type        = bool
  description = "Whether to deploy the Nomad Enterprise server control plane via Helm."
  default     = true
}

variable "load_balancer_ip" {
  type        = string
  description = "Static IP address for the LoadBalancer service. Also used as the Nomad advertise address."
  default     = ""

  validation {
    condition     = var.deploy_nomad_cluster ? length(trimspace(var.load_balancer_ip)) > 0 : true
    error_message = "load_balancer_ip must be set when deploy_nomad_cluster is true."
  }
}

variable "existing_nomad_server_address" {
  type        = string
  description = "Existing Nomad server address used for client bootstrap when deploy_nomad_cluster is false."
  default     = ""

  validation {
    condition     = var.deploy_nomad_cluster ? true : length(trimspace(var.existing_nomad_server_address)) > 0
    error_message = "existing_nomad_server_address must be set when deploy_nomad_cluster is false."
  }
}

variable "client_introduction_token" {
  type        = string
  description = "Pre-generated Nomad client introduction token used when the target cluster enforces client introduction tokens."
  default     = ""
  sensitive   = true
}

variable "nomad_client_edition" {
  type        = string
  description = "Nomad client edition to install via Ansible (community or enterprise)."
  default     = "community"

  validation {
    condition     = contains(["community", "enterprise"], lower(trimspace(var.nomad_client_edition)))
    error_message = "nomad_client_edition must be either 'community' or 'enterprise'."
  }
  validation {
    condition = (
      lower(trimspace(var.nomad_client_edition)) != "enterprise"
      || length(trimspace(var.license)) > 0
    )
    error_message = "license must be set when nomad_client_edition is enterprise."
  }
}

variable "license" {
  type        = string
  description = "Nomad Enterprise license string."
  default     = ""

  validation {
    condition     = var.deploy_nomad_cluster ? length(trimspace(var.license)) > 0 : true
    error_message = "license must be set when deploy_nomad_cluster is true."
  }
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

variable "nomad_client_remove_delete_state" {
  type        = bool
  description = "Whether remove workflow deletes Nomad client state/data directories (including the client node ID)."
  default     = true
}

variable "nomad_client_remove_purge_node" {
  type        = bool
  description = "Whether remove workflow purges the node from Nomad after uninstall. Recommended when nomad_client_remove_delete_state is true."
  default     = false
}
