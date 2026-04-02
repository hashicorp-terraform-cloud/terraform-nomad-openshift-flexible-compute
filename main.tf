provider "helm" {
  kubernetes = {}
}

provider "aap" {}

locals {
  nomad_server_address      = var.deploy_nomad_cluster ? var.load_balancer_ip : var.existing_nomad_server_address
  client_introduction_token = trimspace(var.client_introduction_token)
  nomad_client_edition      = lower(trimspace(var.nomad_client_edition))
  nomad_client_version      = local.nomad_client_edition == "enterprise" ? "1.11.3+ent" : "1.11.3"
  install_nomad_client_extra_vars = merge(
    {
      nomad_server_address                = local.nomad_server_address
      nomad_datacenter                    = var.namespace
      nomad_edition                       = local.nomad_client_edition
      nomad_version                       = local.nomad_client_version
      nomad_client_install_server_address = local.nomad_server_address
      nomad_client_install_datacenter     = var.namespace
    },
    length(local.client_introduction_token) > 0 ? {
      nomad_client_intro_token         = local.client_introduction_token
      nomad_client_install_intro_token = local.client_introduction_token
    } : {},
    length(trimspace(var.license)) > 0 ? {
      nomad_license = var.license
    } : {},
  )
  remove_nomad_client_extra_vars = {
    nomad_remove_delete_state = var.nomad_client_remove_delete_state
    nomad_remove_purge_node   = var.nomad_client_remove_purge_node
    nomad_edition             = local.nomad_client_edition
    nomad_server_address      = local.nomad_server_address
  }
}

resource "helm_release" "nomad_enterprise" {
  count            = var.deploy_nomad_cluster ? 1 : 0
  name             = "nomad-enterprise"
  repository       = var.chart_repository
  chart            = "nomad-enterprise"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
  wait             = true
  timeout          = 600

  set_sensitive = [
    {
      name  = "license"
      value = var.license
    },
  ]

  set = [
    {
      name  = "replicaCount"
      value = tostring(var.replica_count)
    },
    {
      name  = "service.external.loadBalancerIP"
      value = var.load_balancer_ip
    },
    {
      name  = "advertise.address"
      value = var.load_balancer_ip
    },
    {
      name  = "openshift.monitoring.enabled"
      value = tostring(var.monitoring_enabled)
    },
    {
      name  = "openshift.monitoring.prometheusRule.enabled"
      value = tostring(var.prometheus_rule_enabled)
    },
  ]
}

# --- Nomad Client Deployment via AAP ---

resource "aap_inventory" "nomad_clients" {
  name         = "nomad-clients-${var.namespace}"
  description  = "Nomad client hosts managed by Terraform"
  organization = var.aap_organization
}

resource "aap_host" "nomad_client" {
  for_each     = toset([for h in split(",", var.nomad_client_hosts) : trimspace(h)])
  inventory_id = aap_inventory.nomad_clients.id
  name         = each.value
}

action "aap_job_launch" "install_nomad_clients" {
  config {
    job_template_id                     = var.aap_install_job_template_id
    inventory_id                        = aap_inventory.nomad_clients.id
    extra_vars                          = jsonencode(local.install_nomad_client_extra_vars)
    wait_for_completion                 = true
    wait_for_completion_timeout_seconds = 600
  }
}

action "aap_job_launch" "remove_nomad_clients" {
  config {
    job_template_id                     = var.aap_remove_job_template_id
    inventory_id                        = aap_inventory.nomad_clients.id
    extra_vars                          = jsonencode(local.remove_nomad_client_extra_vars)
    wait_for_completion                 = true
    wait_for_completion_timeout_seconds = 600
  }
}

resource "terraform_data" "nomad_client_lifecycle" {
  input = {
    nomad_client_hosts               = var.nomad_client_hosts
    nomad_client_edition             = local.nomad_client_edition
    nomad_client_version             = local.nomad_client_version
    nomad_license_sha256             = nonsensitive(sha256(trimspace(var.license)))
    nomad_server_address             = local.nomad_server_address
    client_introduction_token_sha256 = nonsensitive(sha256(local.client_introduction_token))
  }

  depends_on = [
    helm_release.nomad_enterprise,
    aap_host.nomad_client,
  ]

  lifecycle {
    action_trigger {
      events  = [after_create, after_update]
      actions = [action.aap_job_launch.install_nomad_clients]
    }
  }
}
