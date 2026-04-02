# Ansible E2E tests (AWS)

This directory contains an Ansible-focused end-to-end harness that validates Nomad client install and removal on Amazon Linux, optional Red Hat Enterprise Linux, and Windows using the existing playbooks in `../ansible/`.

## Scope

- Optionally provisions a single-node Nomad server for self-contained E2E runs.
- Provisions Amazon Linux and Windows EC2 instances for test targets, with optional additional Red Hat Enterprise Linux coverage.
- Generates dynamic Ansible inventory and extra vars.
- Runs `ansible/install_nomad_client.yml` and `ansible/remove_nomad_client.yml` directly (OSS Ansible).
- Validates install and remove outcomes with assertion playbooks.

This harness focuses on Ansible lifecycle behavior and supports two modes:

- **Default (self-contained):** deploys a single-node Nomad server in AWS for E2E runs.
- **External server:** skips server provisioning and targets your existing Nomad deployment.

By default, the harness enables Nomad TLS encryption for server/client traffic and uses HTTPS with client certificates for Nomad API operations (`verify_https_client = true`).

In self-contained mode (`deploy_nomad_server = true`), Nomad ACLs are enabled by default (`nomad_acl_enabled = true`). The E2E Make targets bootstrap ACLs automatically and propagate the bootstrap management token to generated local extra vars for authenticated install/remove assertions.

## Prerequisites

- Terraform `>= 1.11`
- AWS credentials with permissions for EC2, VPC data lookups, and key pairs
- HCP Terraform organization and workspace (for remote backend)
- Ansible with required collections:
  - `ansible.windows`
  - `community.windows`
   - Python WinRM dependencies in Ansible's Python environment: `pywinrm`, `requests-ntlm`, and `pyspnego`
- Local tools:
  - `jq`
  - `curl`

When you use the repository `make` targets for Ansible or E2E workflows, the Makefile now creates or refreshes a repo-local virtual environment at `.venv/` and installs the Python dependencies from `e2e_tests/requirements.txt` before running the playbooks.

The E2E harness generates a disposable PEM-encoded RSA key pair automatically. Local E2E artifacts are written under `e2e_tests/.artifacts/` by `e2e_tests/scripts/generate_inventory.sh`, using Terraform outputs:

- `e2e_rsa.pem` (private key)
- `inventory.ini` (Ansible inventory)
- `extra_vars.yml` (Ansible extra vars)
- `nomad-agent-ca.pem` (Nomad TLS CA certificate for local API calls)
- `global-cli-nomad.pem` (Nomad TLS client certificate for local API calls)
- `global-cli-nomad-key.pem` (Nomad TLS client key for local API calls)

Terraform also decrypts the Windows administrator password natively via `rsadecrypt()` and exposes rendered inventory/vars content for local generation.

## Backend configuration (HCP Terraform)

1. Copy `backend.hcl.example` to `backend.hcl`.
1. Set your organization and workspace in `backend.hcl`.
1. Initialize:

   terraform -chdir=e2e_tests init -backend-config=backend.hcl

## Required Terraform variables

Create a local tfvars file first:

1. Copy `terraform.tfvars.example` to `terraform.tfvars`.
1. Choose one mode:
   - Keep `deploy_nomad_server = true` (default) for self-contained single-node server.
   - Set `deploy_nomad_server = false` and set `nomad_server_address` to an external server.

When using `make e2e` from the repository root, the Makefile now creates `e2e_tests/terraform.tfvars` from the example if it is missing and exits with instructions, so you can fill in the required value before retrying.

At minimum, set either:

- `deploy_nomad_server = true` (default), or
- `deploy_nomad_server = false` **and** `nomad_server_address`.

TLS inputs:

- Self-contained mode (`deploy_nomad_server = true`) auto-generates a test CA and Nomad server/client/CLI certificates.
- External-server mode with TLS requires supplying:
   - `nomad_tls_ca_pem`
   - `nomad_tls_client_cert_pem`
   - `nomad_tls_client_key_pem`

Optional:

- `client_introduction_token`: for ACL-protected clusters using client introduction token flow.
- `allowed_cidr_blocks`: restrict access to ports `22`, `5986`, and `4646` (Nomad API readiness checks).

When you use `make e2e-*`, you do **not** need to manage SSH key material manually. If you run Terraform directly instead of using the Makefile, the harness still generates a disposable key pair automatically.

When `deploy_nomad_server = true`, the harness now chooses the first default subnet whose Availability Zone supports **all** requested EC2 instance types (Amazon Linux, Windows, optional Red Hat, and the optional self-hosted Nomad server). This avoids failures caused by default subnets in unsupported AZs such as `us-east-1e`.

Default instance sizes are chosen to stay x86-compatible with the current Amazon Linux and Windows AMIs while reducing cost versus comparable T3 sizes:

- `linux_instance_type = "t3a.small"`
- `nomad_server_instance_type = "t3a.small"`
- `windows_instance_type = "t3a.large"`

Optional Red Hat client settings:

- `deploy_redhat_client = true`
- `redhat_ami_id = "ami-..."`
- `redhat_instance_type = "t3a.small"`

AWS's official EC2 T3/T3a documentation shows the same vCPU and memory sizes for T3 and T3a, and states that T3a delivers up to 10% cost savings over comparable instance types.

Example local tfvars (do not commit):

```hcl
# Self-contained mode (default)
deploy_nomad_server      = true
nomad_acl_enabled        = true

# Optional instance size overrides
# linux_instance_type        = "t3a.small"
# nomad_server_instance_type = "t3a.small"
# windows_instance_type      = "t3a.large"

# Optional Red Hat client host
# deploy_redhat_client = true
# redhat_ami_id        = "ami-xxxxxxxxxxxxxxxxx"
# redhat_instance_type = "t3a.small"
# redhat_ssh_user      = "ec2-user"

# External-server mode (optional)
# deploy_nomad_server    = false
# nomad_server_address   = "lb.example.internal"

client_introduction_token = ""
allowed_cidr_blocks       = ["0.0.0.0/0"]

# Recommended after first run: tighten to your public source CIDR, for example:
# allowed_cidr_blocks     = ["198.51.100.24/32"]
```

## Workflow

From repository root:

1. Provision test hosts:

   make e2e-apply

1. Run install playbook:

   make e2e-install

   When ACL is enabled for a self-hosted E2E server, `make e2e-install` bootstraps ACLs automatically and writes a local management token file at `e2e_tests/.artifacts/nomad_management_token.txt`. The token is then injected into generated `extra_vars.yml` as `nomad_token` for authenticated Nomad API checks and remove workflow drain/purge operations.

   If you use `make e2e`, `make e2e-install`, `make e2e-assert-install`, `make e2e-run-remove`, `make e2e-assert-remove`, `make ansible-check`, or `make ansible-lint`, the Makefile will create `.venv/` with the required Ansible and WinRM Python packages automatically.

   The generated Linux inventory sets SSH arguments to disable strict host key checking for ephemeral E2E hosts, which avoids failures due to recycled public IP host key mismatches.

   In self-contained mode (`deploy_nomad_server = true`), readiness checks wait for the Nomad server API to report a leader and the default TLS-enabled client workflow uses a deterministic private IP for the Nomad server in generated extra vars. Tune wait behavior with:
   - `E2E_NOMAD_WAIT_MAX_ATTEMPTS` (default `30`)
   - `E2E_NOMAD_WAIT_SLEEP_SECONDS` (default `10`)

   Readiness checks also wait for the Windows HTTPS WinRM (`/wsman`) endpoint to respond before running playbooks, and print whether TCP port `5986` is still closed versus open-but-not-ready. Tune with:
   - `E2E_WINDOWS_WAIT_MAX_ATTEMPTS` (default `60`)
   - `E2E_WINDOWS_WAIT_SLEEP_SECONDS` (default `10`)

   Readiness checks also wait for SSH (`:22`) readiness on Amazon Linux and optional Red Hat hosts before invoking playbooks. Tune with:
   - `E2E_SSH_WAIT_MAX_ATTEMPTS` (default `60`)
   - `E2E_SSH_WAIT_SLEEP_SECONDS` (default `10`)

   The E2E harness defaults to community edition (`nomad`, version `1.11.3`) and derives package selection from `nomad_edition`. You can configure edition/version/license through `e2e_tests/terraform.tfvars` (`nomad_edition`, `nomad_version`, `nomad_license`). When `nomad_edition = "enterprise"`, `nomad_license` is required so the self-hosted Nomad server can start with a valid enterprise license.

   The generated extra vars also enable the Nomad `raw_exec` task driver on Windows E2E clients so `run_test_jobs.sh` can submit the Windows wait job prior to remove.

   The E2E install flow resets each client's Nomad state directory before service startup. This ensures clients can re-register cleanly when the self-hosted Nomad server is replaced between runs.

   On macOS controllers, the scripts automatically set `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` when not already set to avoid intermittent Ansible worker crashes during mixed SSH/WinRM execution.

1. Assert install behavior:

   make e2e-assert-install

1. Start cross-platform system jobs (one allocation per eligible Nomad client) before removal to validate drain/eviction behavior:

   make e2e-run-test-jobs

1. Run remove playbook:

   make e2e-run-remove

1. Assert remove behavior:

   make e2e-assert-remove

As a convenience, `make e2e-check` runs non-destructive E2E validation tasks, including Terraform formatting and validation under `e2e_tests/` plus syntax checks for the E2E assertion playbooks.

1. Destroy test hosts:

   make e2e-destroy

When using Make targets, `make e2e-run-remove` now runs `make e2e-run-test-jobs` first so removal always executes with active test workloads on eligible clients.

## ACL bootstrap helper

If your cluster has ACL enabled and is not bootstrapped yet:

```bash
bash e2e_tests/scripts/bootstrap_acl.sh https://your-nomad.example.com:4646
```

If you omit the address in self-contained mode, the script defaults to the E2E Nomad server **public** API endpoint so it remains reachable from your local machine. The script writes the bootstrap management token to `.artifacts/nomad_management_token.txt`.

For default self-contained E2E make targets, this bootstrap step is automatic.

## Security notes

- Do not commit `backend.hcl`, private keys, inventories, or tokens.
- Keep `.artifacts/` local-only.
- Keep the generated private key file (`.artifacts/e2e_rsa.pem`) local-only and out of version control.
- Rotate and revoke any bootstrap tokens used during tests.
