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
  - `nomad` (required only when auto-generating client introduction tokens in ACL-enabled self-hosted mode)

When you use the repository `make` targets for Ansible or E2E workflows, the Makefile now creates or refreshes a repo-local virtual environment at `.venv/` and installs the Python dependencies from `e2e_tests/requirements.txt` before running the playbooks.

The E2E harness generates a disposable PEM-encoded RSA key pair automatically. Local E2E artifacts are written under `e2e_tests/.artifacts/` by `e2e_tests/scripts/generate_inventory.sh`, using Terraform outputs:

- `e2e_rsa.pem` (private key)
- `inventory.ini` (Ansible inventory)
- `extra_vars.yml` (Ansible extra vars)
- `nomad-agent-ca.pem` (Nomad TLS CA certificate for local API calls)
- `global-cli-nomad.pem` (Nomad TLS client certificate for local API calls)
- `global-cli-nomad-key.pem` (Nomad TLS client key for local API calls)
- `nomad_client_intro_token.txt` (auto-generated Nomad client introduction token in ACL-enabled self-hosted mode)

Terraform also decrypts the Windows administrator password natively via `rsadecrypt()` and exposes rendered inventory/vars content for local generation.

## Backend configuration (HCP Terraform)

1. Copy `backend.hcl.example` to `backend.hcl`.
1. Set your organization and workspace in `backend.hcl`.
1. Initialize:

   terraform -chdir=e2e_tests init -backend-config=backend.hcl

## Required Terraform variables

Create a local tfvars file first:

1. Copy `terraform.tfvars.example` to either `terraform.auto.tfvars` or `terraform.tfvars`.
1. Choose one mode:
   - Keep `deploy_nomad_server = true` (default) for self-contained single-node server.
   - Set `deploy_nomad_server = false` and set `nomad_server_address` to an external server.

When using `make e2e` from the repository root, the Makefile now creates `e2e_tests/terraform.auto.tfvars` from the example if both supported tfvars files are missing and exits with instructions, so you can fill in the required values before retrying.

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
   - If empty and running self-hosted E2E (`deploy_nomad_server = true`) with ACL enabled, the harness auto-generates a token and stores it in `.artifacts/nomad_client_intro_token.txt`.
   - If set, the provided value is authoritative and auto-generated token artifacts are ignored.
- `allowed_cidr_blocks`: restrict access to ports `22`, `5986`, and `4646` (Nomad API readiness checks).
- `deploy_local_macos_client`: optionally include your local macOS machine as an additional `nomad_clients` target (disabled by default).
   - Default mode (`false`) keeps the existing AWS-only host behavior.
   - Set `deploy_local_macos_client = true` in `terraform.auto.tfvars` or `terraform.tfvars` to enable local macOS execution.
   - Optional local settings:
      - `local_macos_connection` (`local` or `ssh`, default `local`)
      - `local_macos_host_alias` (default `macos-local`)
      - `local_macos_ssh_host` and `local_macos_ssh_user` (required only for `ssh` mode)
   - In self-contained mode, local macOS `local` connection requires private network reachability to the Nomad server RPC address (`:4647`).
   - If your workstation cannot route to the VPC directly, use `bash e2e_tests/scripts/setup_local_macos_nomad_tunnel.sh` (or `make e2e-setup-local-macos-tunnel`) to create a loopback alias + SSH tunnel that preserves the private RPC target from the Nomad agent's perspective.
   - Use `bash e2e_tests/scripts/cleanup_local_macos_nomad_tunnel.sh` (or `make e2e-cleanup-local-macos-tunnel`) to remove the alias/tunnel after the E2E run.

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

# Optional local macOS target (disabled by default)
# WARNING: this modifies local Nomad files and launchd state during install/remove.
# deploy_local_macos_client = true
# local_macos_connection    = "local"
# local_macos_host_alias    = "macos-local"
# SSH-mode alternative:
# local_macos_connection    = "ssh"
# local_macos_ssh_host      = "macbook.local"
# local_macos_ssh_user      = "your-user"

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

   In the same ACL-enabled self-hosted flow, when `client_introduction_token` is empty, the harness auto-generates a Nomad client introduction token and writes it to `e2e_tests/.artifacts/nomad_client_intro_token.txt`. `generate_inventory.sh` injects it into `extra_vars.yml` as both `nomad_client_intro_token` and `nomad_client_install_intro_token`.

   If you use `make e2e`, `make e2e-install`, `make e2e-assert-install`, `make e2e-run-remove`, `make e2e-assert-remove`, `make ansible-check`, or `make ansible-lint`, the Makefile will create `.venv/` with the required Ansible and WinRM Python packages automatically.

   The generated Linux and Red Hat inventory entries set SSH arguments to disable strict host key checking for ephemeral E2E hosts, which avoids failures due to recycled public IP host key mismatches.

   The generated SSH arguments also enforce `IdentitiesOnly=yes` with `PreferredAuthentications=publickey` so OpenSSH uses the generated E2E key first instead of trying unrelated keys from your local SSH agent. This avoids `Too many authentication failures` errors on hosts with low `MaxAuthTries` limits.

   In self-contained mode (`deploy_nomad_server = true`), readiness checks wait for the Nomad server API to report a leader and the default TLS-enabled client workflow uses a deterministic private IP for the Nomad server in generated extra vars. Tune wait behavior with:
   - `E2E_NOMAD_WAIT_MAX_ATTEMPTS` (default `30`)
   - `E2E_NOMAD_WAIT_SLEEP_SECONDS` (default `10`)

   Readiness checks also wait for the Windows HTTPS WinRM (`/wsman`) endpoint to respond before running playbooks, and print whether TCP port `5986` is still closed versus open-but-not-ready. Tune with:
   - `E2E_WINDOWS_WAIT_MAX_ATTEMPTS` (default `60`)
   - `E2E_WINDOWS_WAIT_SLEEP_SECONDS` (default `10`)

   Readiness checks also wait for SSH (`:22`) readiness on Amazon Linux and optional Red Hat hosts before invoking playbooks. Tune with:
   - `E2E_SSH_WAIT_MAX_ATTEMPTS` (default `60`)
   - `E2E_SSH_WAIT_SLEEP_SECONDS` (default `10`)

   The E2E harness defaults to community edition (`nomad`, version `1.11.3`) and derives package selection from `nomad_edition`. You can configure edition/version/license through either `e2e_tests/terraform.auto.tfvars` or `e2e_tests/terraform.tfvars` (`nomad_edition`, `nomad_version`, `nomad_license`). When `nomad_edition = "enterprise"`, `nomad_license` is required so the self-hosted Nomad server can start with a valid enterprise license.

   The generated extra vars also enable the Nomad `raw_exec` task driver on Windows E2E clients so `run_test_jobs.sh` can submit the Windows wait job prior to remove.

   The E2E install flow resets each client's Nomad state directory before service startup. This ensures clients can re-register cleanly when the self-hosted Nomad server is replaced between runs.

   On macOS controllers, the scripts automatically set `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` when not already set to avoid intermittent Ansible worker crashes during mixed SSH/WinRM execution.

   If `deploy_local_macos_client = true`, preflight enforces an explicit safety gate before destructive local execution. Set `E2E_ALLOW_LOCAL_MACOS_DESTRUCTIVE=true` to proceed.

   For local macOS `local` mode, the Make targets also run `make e2e-setup-local-macos-tunnel` automatically before install/assert/remove workflows. The helper is a no-op when local macOS mode is disabled, when `local_macos_connection = "ssh"`, or when direct private RPC reachability already works.

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

## Local macOS tunnel helpers

When the local macOS target cannot route directly to the self-hosted Nomad server private RPC endpoint, use these helpers:

- `bash e2e_tests/scripts/setup_local_macos_nomad_tunnel.sh`
- `bash e2e_tests/scripts/cleanup_local_macos_nomad_tunnel.sh`

Or via Make:

- `make e2e-setup-local-macos-tunnel`
- `make e2e-cleanup-local-macos-tunnel`

The setup helper:

- reads Terraform outputs for the self-hosted Nomad server public/private addresses
- adds the server private IP as a temporary `lo0` alias on your Mac when needed
- starts an SSH local-forward bound to that private IP on port `4647`
- leaves Nomad free to keep dialing the private RPC target already rendered in `nomad.hcl`

The cleanup helper:

- stops the managed SSH tunnel process if it is still running
- removes the temporary `lo0` alias if the setup helper created it
- clears the local state file under `e2e_tests/.artifacts/`

## ACL bootstrap helper

If your cluster has ACL enabled and is not bootstrapped yet:

```bash
bash e2e_tests/scripts/bootstrap_acl.sh https://your-nomad.example.com:4646
```

If you omit the address in self-contained mode, the script defaults to the E2E Nomad server **public** API endpoint so it remains reachable from your local machine. The script writes the bootstrap management token to `.artifacts/nomad_management_token.txt`.

When `client_introduction_token` is not set in Terraform outputs, the same script also ensures a client introduction token exists at `.artifacts/nomad_client_intro_token.txt` (requires local `nomad` CLI).

For default self-contained E2E make targets, this bootstrap step is automatic.

## Security notes

- Do not commit `backend.hcl`, private keys, inventories, or tokens.
- Keep `.artifacts/` local-only.
- Keep the generated private key file (`.artifacts/e2e_rsa.pem`) local-only and out of version control.
- Rotate and revoke any bootstrap tokens used during tests.
