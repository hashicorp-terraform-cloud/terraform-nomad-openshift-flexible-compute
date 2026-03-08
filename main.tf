provider "helm" {}

provider "aap" {}

resource "helm_release" "nomad_enterprise" {
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
    job_template_id                    = var.aap_install_job_template_id
    inventory_id                       = aap_inventory.nomad_clients.id
    extra_vars                         = jsonencode({ nomad_server_address = var.load_balancer_ip })
    wait_for_completion                = true
    wait_for_completion_timeout_seconds = 600
  }
}

action "aap_job_launch" "remove_nomad_clients" {
  config {
    job_template_id                    = var.aap_remove_job_template_id
    inventory_id                       = aap_inventory.nomad_clients.id
    wait_for_completion                = true
    wait_for_completion_timeout_seconds = 600
  }
}

resource "terraform_data" "nomad_client_lifecycle" {
  input = var.nomad_client_hosts

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
