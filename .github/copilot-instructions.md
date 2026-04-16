# Project Guidelines

## Architecture
- This repository is a Terraform No Code module that deploys Nomad Enterprise on OpenShift and orchestrates Ansible Automation Platform (AAP) inventory + install/remove jobs.
- Keep file responsibilities intact: `versions.tf` (providers/versions), `main.tf` (resources/actions), `variables.tf` (inputs/validation), `outputs.tf` (exports).
- Treat `README.md` as the canonical behavior spec for prerequisites, providers, inputs, outputs, and Ansible role behavior. Update it in the same change when behavior changes.
- Preserve these contracts unless intentionally redesigning:
	- `load_balancer_ip` coupling across Helm `service.external.loadBalancerIP`, Helm `advertise.address`, and AAP `nomad_server_address`
	- `nomad_client_hosts` remains comma-separated and is split/trimmed into `aap_host` resources
	- `terraform_data.nomad_client_lifecycle` remains the orchestration point for install/remove side effects
	- `local.install_nomad_client_extra_vars` stays aligned with `ansible/roles/nomad_client_install/defaults/main.yml`
	- When `nomad_client_install_reset_state` is true, the install workflow must preserve expected intro-token semantics by rewriting `intro_token.jwt` after state directory reset on Linux, macOS, and Windows
	- E2E install assertions for intro token state must derive the expected token path from `nomad_state_dir` (with platform defaults), not hard-coded paths
	- Local macOS E2E `local` mode preserves the private Nomad RPC target by using the managed tunnel helpers under `e2e_tests/scripts/`; do not redesign that flow to depend on public RPC advertise addresses unless the broader AWS-first topology changes intentionally
- For detailed Terraform/Ansible editing rules, see:
	- `.github/instructions/terraform.instructions.md`
	- `.github/instructions/ansible.instructions.md`

## Build and Test
- Primary validation entry point: `make check`.
- Focused checks while iterating:
	- Terraform: `make terraform-check`, `make tflint`
	- Ansible: `make ansible-check`, `make ansible-lint`
	- E2E harness: `make e2e-install`, `make e2e-assert-install`, `make e2e-run-remove`, `make e2e-assert-remove`
- For local macOS E2E work, the tunnel helper targets `make e2e-setup-local-macos-tunnel` and `make e2e-cleanup-local-macos-tunnel` are the supported way to manage the private-RPC loopback alias and SSH tunnel lifecycle.
- Terraform direct flow (when needed): `terraform fmt -recursive`, `terraform init -backend=false -input=false`, `terraform validate`.
- E2E setup and runtime details live in `e2e_tests/README.md`.
- For install-role changes affecting rendered files, run `make e2e-install` before `make e2e-assert-install` so assertions validate the latest role behavior on hosts.

## Conventions
- Keep secrets out of Terraform and Ansible files. This module expects Kubernetes/OpenShift and AAP credentials via environment variables or HCP Terraform variable sets, not checked-in values.
- New Terraform inputs with constrained values or conditional requirements should include `validation` blocks in `variables.tf`.
- For Ansible changes, preserve role structure (`tasks/main.yml` delegates to focused task files; defaults in `roles/*/defaults/main.yml`).
- Keep AAP extra vars and Ansible defaults in sync for install workflow settings.
- Preserve cross-platform behavior in install/remove roles (RedHat, Debian, Linux direct-download, macOS `launchd`, Windows service paths).
- Use `ansible_facts[...]` / `ansible_facts.get(...)` for fact access; avoid deprecated top-level fact vars.
