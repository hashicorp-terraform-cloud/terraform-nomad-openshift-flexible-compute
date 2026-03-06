# terraform-nomad-openshift-flexible-compute

Terraform No Code module for end-to-end deployment of [Nomad Enterprise](https://www.nomadproject.io/) on OpenShift with client agents on arbitrary hosts.

- Deploys the Nomad server control plane into OpenShift via the [nomad-enterprise Helm chart](https://github.com/benemon/nomad-server-helm)
- Creates an inventory in Ansible Automation Platform with the provided client hosts
- Triggers an AAP job template to install and configure Nomad client agents on create/update
- Triggers a separate AAP job template to remove Nomad client agents on destroy
- Clients automatically register against the server on the LoadBalancer address
- Includes Ansible roles for OS-agnostic (RedHat + Debian) client install and removal

## Prerequisites

- HCP Terraform Standard or Premium
- Terraform >= 1.11 (required for Terraform Actions)
- An OpenShift 4.x cluster with MetalLB or equivalent LoadBalancer provider
- A Nomad Enterprise license
- An Ansible Automation Platform instance with job templates for Nomad client install and removal
- Project-scoped variable sets providing Kubernetes and AAP credentials (see below)

## Provider Credentials

This module requires credentials for two providers, provided as environment variables via [variable sets](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/variables/variable-sets).

### Kubernetes / OpenShift (Helm provider)

| Variable | Sensitive | Description |
|----------|-----------|-------------|
| `KUBE_HOST` | No | OpenShift API server URL |
| `KUBE_TOKEN` | Yes | Bearer token for the OpenShift API |
| `KUBE_CLUSTER_CA_CERT_DATA` | Yes | PEM-encoded CA certificate for the API server |

### Ansible Automation Platform (AAP provider)

| Variable | Sensitive | Description |
|----------|-----------|-------------|
| `AAP_HOSTNAME` | No | AAP server URL (e.g., `https://aap.example.com`) |
| `AAP_TOKEN` | Yes | AAP authentication token |

Attach these variable sets to the project where No Code workspaces will be created.

## Inputs

| Name | Type | Default | Required | Description |
|------|------|---------|----------|-------------|
| `chart_repository` | string | `https://benemon.github.io/nomad-server-helm` | No | Helm repository URL |
| `chart_version` | string | `1.0.0` | No | Chart version to deploy |
| `namespace` | string | `nomad-enterprise` | No | Target Kubernetes namespace |
| `load_balancer_ip` | string | `""` | No | Static LoadBalancer IP address |
| `license` | string | — | Yes | Nomad Enterprise license string |
| `replica_count` | number | `3` | No | Server replicas (1, 3, or 5) |
| `monitoring_enabled` | bool | `true` | No | Enable OpenShift ServiceMonitor |
| `prometheus_rule_enabled` | bool | `true` | No | Enable Prometheus alerting rules |
| `nomad_client_hosts` | string | — | Yes | Comma-separated list of IPs/FQDNs for Nomad client hosts |
| `aap_install_job_template_id` | number | — | Yes | AAP job template ID for installing the Nomad client agent |
| `aap_remove_job_template_id` | number | — | Yes | AAP job template ID for removing the Nomad client agent |
| `aap_organization` | number | `1` | No | AAP organization ID for the inventory |

> **Note:** `load_balancer_ip` is applied to both `service.external.loadBalancerIP` and `advertise.address` in the Helm chart, as these values must match. It is also passed to the AAP job as `nomad_server_address` so clients know where to connect.

> **Note:** Both AAP job templates must have "Prompt on launch" enabled for inventory, so they accept the Terraform-created inventory.

## Ansible Roles

The `ansible/` directory contains playbooks and roles for Nomad client lifecycle management, intended to be used as AAP job templates.

### Install (`ansible/install_nomad_client.yml`)

- Adds the HashiCorp package repository (yum for RedHat, apt for Debian)
- Installs the `nomad-enterprise` package
- Templates client configuration pointing at the server address
- Optionally writes the Nomad Enterprise license file
- Enables and starts the nomad systemd service

Key variables (set via AAP extra vars or role defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `nomad_server_address` | `""` | Server address (passed automatically by Terraform) |
| `nomad_datacenter` | `dc1` | Nomad datacenter name |
| `nomad_region` | `global` | Nomad region |
| `nomad_license` | `""` | Enterprise license string |

### Remove (`ansible/remove_nomad_client.yml`)

- Stops the nomad service
- Removes the `nomad-enterprise` package
- Cleans up configuration and data directories

## Outputs

| Name | Description |
|------|-------------|
| `release_name` | Name of the Helm release |
| `namespace` | Kubernetes namespace of the deployment |
| `status` | Status of the Helm release |
| `chart_version` | Deployed chart version |
| `app_version` | Nomad Enterprise application version |
| `inventory_id` | AAP inventory ID for the Nomad client hosts |
| `client_hosts` | List of Nomad client host addresses |
