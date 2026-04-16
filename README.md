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
| `nomad_client_edition` | string | `community` | No | Nomad client edition installed by the Ansible role (`community` or `enterprise`) |
| `license` | string | `""` | Conditional | Nomad Enterprise license string used for Helm server deployment and enterprise client installation; required when `deploy_nomad_cluster = true` or `nomad_client_edition = enterprise` |
| `replica_count` | number | `3` | No | Server replicas (1, 3, or 5) |
| `monitoring_enabled` | bool | `true` | No | Enable OpenShift ServiceMonitor |
| `prometheus_rule_enabled` | bool | `true` | No | Enable Prometheus alerting rules |
| `nomad_client_hosts` | string | — | Yes | Comma-separated list of IPs/FQDNs for Nomad client hosts |
| `aap_install_job_template_id` | number | — | Yes | AAP job template ID for installing the Nomad client agent |
| `aap_remove_job_template_id` | number | — | Yes | AAP job template ID for removing the Nomad client agent |
| `aap_organization` | number | `1` | No | AAP organization ID for the inventory |
| `nomad_client_remove_delete_state` | bool | `true` | No | Delete Nomad client state/data directories during remove; this deletes the client node identity (node ID) |
| `nomad_client_remove_purge_node` | bool | `false` | No | Attempt to purge the node from the Nomad server client list during remove; recommended when `nomad_client_remove_delete_state = true` |

> **Note:** When `deploy_nomad_cluster = true`, `load_balancer_ip` is applied to both `service.external.loadBalancerIP` and `advertise.address` in the Helm chart, as these values must match. The same value is passed to AAP as `nomad_server_address` so clients know where to connect.

> **Note:** When `deploy_nomad_cluster = false`, the module skips Helm deployment and uses `existing_nomad_server_address` for `nomad_server_address` in AAP extra vars.

> **Note:** `client_introduction_token` is optional. If the target cluster enforces client introduction tokens, [bootstrap ACLs](https://developer.hashicorp.com/nomad/docs/secure/acl/bootstrap) and follow the [client node introduction tokens guide](https://developer.hashicorp.com/nomad/docs/deploy/clusters/connect-nodes#use-client-node-introduction-tokens) before using this module. Store the token as a sensitive workspace variable. The module only distributes a supplied token to clients.

> **Note:** If you set `nomad_client_remove_delete_state = true`, Nomad client identity state is deleted and a reinstall will register as a new node ID. Set `nomad_client_remove_purge_node = true` to remove stale client entries from the Nomad server list during remove.

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
- Installs the `nomad` package by default, or `nomad-enterprise` when `nomad_client_edition = enterprise`
- Uses direct-download install for Linux (non-package), macOS, and Windows hosts
- Templates client configuration pointing at the server address
- Uses managed Nomad client allocation directories under the configured data directory (defaults to `<data_dir>/alloc` and `<data_dir>/alloc_mounts`)
- Optionally writes an `intro_token.jwt` file in the Nomad client state directory
- Optionally writes the Nomad Enterprise license file when `nomad_client_edition = enterprise`
- Enables and starts Nomad using systemd (Linux), `launchd` (macOS), or Windows services

Key variables (set via AAP extra vars or role defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `nomad_server_address` | `""` | Server address (passed automatically by Terraform) |
| `nomad_client_intro_token` | `""` | Pre-generated client introduction token written to `intro_token.jwt` in the client state directory |
| `nomad_edition` | `community` | Client edition (`community` or `enterprise`) used to derive package/version defaults |
| `nomad_version` | derived from `nomad_edition` | Override Nomad version for direct-download installs |
| `nomad_datacenter` | `dc1` | Nomad datacenter name |
| `nomad_region` | `global` | Nomad region |
| `nomad_license` | `""` | Enterprise license string (used when `nomad_edition = enterprise`) |

### Remove (`ansible/remove_nomad_client.yml`)

- Drains each node before uninstall by disabling eligibility and enabling drain; uninstall does not proceed if drain fails
- Stops Nomad using systemd (Linux), `launchd` (macOS), or Windows services
- Removes Nomad package variants (`nomad` and `nomad-enterprise`) on RedHat and Debian
- Removes direct-download artifacts on Linux (non-package), macOS, and Windows
- Cleans up configuration and data directories

Key variables (set via AAP extra vars or role defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `nomad_client_remove_drain_before_uninstall` | `true` | Require a successful drain before uninstalling Nomad |
| `nomad_client_remove_drain_force` | `true` | Use forced drain (`-force`) |
| `nomad_client_remove_drain_deadline` | `30m` | Drain deadline passed to `nomad node drain -deadline` |
| `nomad_edition` | `community` | Client edition (`community` or `enterprise`) used to derive package removal behavior |
| `nomad_client_remove_allocations_wait_retries` | `12` | Number of post-drain allocation polling attempts before failing |
| `nomad_client_remove_allocations_wait_delay_seconds` | `10` | Delay in seconds between post-drain allocation polling attempts |
| `nomad_client_remove_nomad_addr` | `""` | Optional explicit Nomad API address (`NOMAD_ADDR`) |
| `nomad_client_remove_nomad_token` | `""` | Optional ACL token used for drain operations (`NOMAD_TOKEN`) |
| `nomad_client_remove_delete_state` | `true` | Delete Nomad client state/data directories during remove (deletes node identity state) |
| `nomad_client_remove_purge_node` | `true` | Purge node from Nomad server list during remove; recommended when deleting state |

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

## Ansible E2E tests (AWS)

This repository includes an Ansible-focused end-to-end harness under `e2e_tests/`.

- Provisions Linux and Windows EC2 hosts.
- Provisions Amazon Linux and Windows EC2 hosts, with optional additional Red Hat Enterprise Linux coverage.
- Optionally includes a local macOS host as an additional Nomad client E2E target when enabled in `e2e_tests/terraform.auto.tfvars` or `e2e_tests/terraform.tfvars`.
- Generates dynamic inventory and extra vars.
- Runs `ansible/install_nomad_client.yml` and `ansible/remove_nomad_client.yml` directly with OSS Ansible.
- Verifies install and remove behavior with assertion playbooks.
- Waits for self-hosted Nomad server API, SSH, and WinRM readiness before running install/assert/remove workflows.

By default, local macOS targeting is disabled. Enable it with `deploy_local_macos_client = true` in `e2e_tests/terraform.auto.tfvars` or `e2e_tests/terraform.tfvars` when you want real Darwin execution coverage. Because install/remove playbooks are destructive for the target host, local macOS mode requires explicit operator opt-in at runtime.

The E2E harness enables Nomad TLS by default and uses HTTPS with client certificates for local Nomad API operations in self-contained runs.

By default, the harness now provisions a single-node Nomad server in AWS for self-contained E2E runs. To target an existing cluster instead, set `deploy_nomad_server = false` and provide `nomad_server_address` in `e2e_tests/terraform.auto.tfvars` or `e2e_tests/terraform.tfvars`.

The default E2E host sizes use `t3a.small` for Amazon Linux/server nodes and `t3a.large` for the Windows node. This preserves the same x86 instance sizing profile as the previous T3 defaults while using AWS's lower-cost comparable T3a family.

The E2E harness automatically selects a default subnet whose Availability Zone supports all requested EC2 instance types, avoiding unsupported-AZ failures from lexicographically first default subnets. In self-contained mode it passes a deterministic private IP for the Nomad server to client configuration in the default TLS-enabled flow, while local ACL bootstrap convenience still defaults to the server's public API endpoint. Local macOS client mode with `local` connection requires private network reachability to that RPC endpoint (`:4647`); when your workstation cannot reach the VPC directly, use the local tunnel helpers under `e2e_tests/scripts/` (or the corresponding `make e2e-setup-local-macos-tunnel` / `make e2e-cleanup-local-macos-tunnel` targets) to preserve the private RPC target while transporting it over SSH.

For remote-safe E2E runs, local artifacts in `e2e_tests/.artifacts/` are generated on your machine by `e2e_tests/scripts/generate_inventory.sh` from Terraform outputs, including `e2e_rsa.pem`, `inventory.ini`, and `extra_vars.yml`.

Terraform decrypts the Windows administrator password natively via `rsadecrypt()` and exposes the rendered inventory/extra-vars content as outputs consumed by local tooling.

Use the E2E guide for setup and usage details:

- `e2e_tests/README.md`

Convenience Make targets:

- `make e2e-init`
- `make e2e-plan`
- `make e2e-apply`
- `make e2e-bootstrap-acl`
- `make e2e-install`
- `make e2e-assert-install`
- `make e2e-check`
- `make e2e-remove`
- `make e2e-assert-remove`
- `make e2e-destroy`
