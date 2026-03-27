# terraform-nomad-openshift-flexible-compute

Terraform No Code module for [Nomad Enterprise](https://www.nomadproject.io/) deployment on OpenShift with client agents on arbitrary hosts, including an optional client-only mode.

- Optionally deploys the Nomad server control plane into OpenShift via the [nomad-enterprise Helm chart](https://github.com/benemon/nomad-server-helm)
- Creates an inventory in Ansible Automation Platform with the provided client hosts
- Triggers an AAP job template to install and configure Nomad client agents on create/update
- Triggers a separate AAP job template to remove Nomad client agents on destroy
- Clients automatically register against either the deployed server LoadBalancer address or an existing Nomad server address
- Optionally distributes a pre-generated client introduction token for clusters that enforce client introduction
- Includes Ansible roles for cross-platform client install and removal (RedHat, Debian, Linux direct-download, macOS `launchd`, and Windows service)

## Prerequisites

- HCP Terraform Standard or Premium
- Terraform >= 1.11 (required for Terraform Actions)
- An OpenShift 4.x cluster with MetalLB or equivalent LoadBalancer provider (required when `deploy_nomad_cluster = true`)
- A Nomad Enterprise license (required when `deploy_nomad_cluster = true`)
- An Ansible Automation Platform instance with job templates for Nomad client install and removal
- Project-scoped variable sets providing Kubernetes and AAP credentials (see below)

## Provider Credentials

This module requires credentials for two providers, provided as environment variables via [variable sets](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/variables/variable-sets).

### Kubernetes / OpenShift (Helm provider)

Required when `deploy_nomad_cluster = true`.

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
| `deploy_nomad_cluster` | bool | `true` | No | Deploy Nomad server control plane with Helm |
| `load_balancer_ip` | string | `""` | Conditional | Static LoadBalancer IP address; required when `deploy_nomad_cluster = true` |
| `existing_nomad_server_address` | string | `""` | Conditional | Existing Nomad server address for client bootstrap when `deploy_nomad_cluster = false` |
| `client_introduction_token` | string | `""` | Conditional | Pre-generated Nomad client introduction token for clusters that enforce client introduction; the module does not generate or rotate this token |
| `license` | string | `""` | Conditional | Nomad Enterprise license string; required when `deploy_nomad_cluster = true` |
| `replica_count` | number | `3` | No | Server replicas (1, 3, or 5) |
| `monitoring_enabled` | bool | `true` | No | Enable OpenShift ServiceMonitor |
| `prometheus_rule_enabled` | bool | `true` | No | Enable Prometheus alerting rules |
| `nomad_client_hosts` | string | — | Yes | Comma-separated list of IPs/FQDNs for Nomad client hosts |
| `aap_install_job_template_id` | number | — | Yes | AAP job template ID for installing the Nomad client agent |
| `aap_remove_job_template_id` | number | — | Yes | AAP job template ID for removing the Nomad client agent |
| `aap_organization` | number | `1` | No | AAP organization ID for the inventory |

> **Note:** When `deploy_nomad_cluster = true`, `load_balancer_ip` is applied to both `service.external.loadBalancerIP` and `advertise.address` in the Helm chart, as these values must match. The same value is passed to AAP as `nomad_server_address` so clients know where to connect.

> **Note:** When `deploy_nomad_cluster = false`, the module skips Helm deployment and uses `existing_nomad_server_address` for `nomad_server_address` in AAP extra vars.

> **Note:** `client_introduction_token` is optional. If the target cluster enforces client introduction tokens, [bootstrap ACLs](https://developer.hashicorp.com/nomad/docs/secure/acl/bootstrap) and follow the [client node introduction tokens guide](https://developer.hashicorp.com/nomad/docs/deploy/clusters/connect-nodes#use-client-node-introduction-tokens) before using this module. Store the token as a sensitive workspace variable. The module only distributes a supplied token to clients.

> **Note:** Both AAP job templates must have "Prompt on launch" enabled for inventory, so they accept the Terraform-created inventory.

## Ansible Roles

The `ansible/` directory contains playbooks and roles for Nomad client lifecycle management, intended to be used as AAP job templates.

### Drain and remove Nomad agent (`ansible/remove_nomad_client.yml`)

- Runs the cross-platform `nomad_client_remove` role
- Stops Nomad and removes client artifacts so workstations return to employee use during business hours
- Matches the same host and privilege handling model as the existing install/remove playbooks

### Nomad agent installation and bootstrapp (`ansible/install_nomad_client.yml`)

- Runs the cross-platform `nomad_client_install` role as a dedicated preparation playbook
- Installs or reconciles the Nomad client, refreshes configuration, and starts the service before overnight jobs
- Supports Linux, macOS, and Windows through the existing role conditionals

### Install (`ansible/install_nomad_client.yml`)

- Adds the HashiCorp package repository (yum for RedHat, apt for Debian)
- Installs the `nomad-enterprise` package on RedHat and Debian
- Uses direct-download install for Linux (non-package), macOS, and Windows hosts
- Templates client configuration pointing at the server address
- Optionally writes an `intro_token.jwt` file in the Nomad client state directory
- Optionally writes the Nomad Enterprise license file
- Enables and starts Nomad using systemd (Linux), `launchd` (macOS), or Windows services

Key variables (set via AAP extra vars or role defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `nomad_server_address` | `""` | Server address (passed automatically by Terraform) |
| `nomad_client_intro_token` | `""` | Pre-generated client introduction token written to `intro_token.jwt` in the client state directory |
| `nomad_datacenter` | `dc1` | Nomad datacenter name |
| `nomad_region` | `global` | Nomad region |
| `nomad_license` | `""` | Enterprise license string |

### Remove (`ansible/remove_nomad_client.yml`)

- Drains each node before uninstall by disabling eligibility and enabling drain; uninstall does not proceed if drain fails
- Stops Nomad using systemd (Linux), `launchd` (macOS), or Windows services
- Removes the `nomad-enterprise` package on RedHat and Debian
- Removes direct-download artifacts on Linux (non-package), macOS, and Windows
- Cleans up configuration and data directories

Key variables (set via AAP extra vars or role defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `nomad_client_remove_drain_before_uninstall` | `true` | Require a successful drain before uninstalling Nomad |
| `nomad_client_remove_drain_force` | `false` | Use forced drain (`-force`) |
| `nomad_client_remove_drain_deadline` | `30m` | Drain deadline passed to `nomad node drain -deadline` |
| `nomad_client_remove_nomad_addr` | `""` | Optional explicit Nomad API address (`NOMAD_ADDR`) |
| `nomad_client_remove_nomad_token` | `""` | Optional ACL token used for drain operations (`NOMAD_TOKEN`) |

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

When `deploy_nomad_cluster = false`, Helm-related outputs (`release_name`, `namespace`, `status`, `chart_version`, `app_version`) return `null`.
