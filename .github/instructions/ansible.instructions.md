---
description: "Use when editing Ansible playbooks, roles, defaults, handlers, templates, or tasks under ansible/ and e2e_tests/ansible/. Covers cross-platform Nomad client install and remove behavior, role structure, Terraform/AAP extra var alignment, and ansible_facts usage."
name: "Ansible Role Guidelines"
applyTo: "{ansible/**,e2e_tests/ansible/**}"
---
# Ansible Role Guidelines

- Preserve the existing role structure:
  - `tasks/main.yml` delegates to focused files such as `install.yml`, `configure.yml`, and `service.yml`
  - role defaults live in `roles/*/defaults/main.yml`
- Maintain cross-platform parity for Nomad client lifecycle behavior across:
  - RedHat package install or removal
  - Debian package install or removal
  - Linux direct-download install or removal
  - macOS `launchd`
  - Windows service management
- Keep Terraform-passed AAP extra vars aligned with install-role defaults. If a new install-time setting is added in `main.tf`, represent it in `ansible/roles/nomad_client_install/defaults/main.yml` unless it is intentionally transient.
- For client introduction token behavior, keep E2E assertions and role inputs aligned with generated extra vars (`nomad_client_intro_token` and `nomad_client_install_intro_token`) so token-file expectations remain consistent across Terraform-driven and script-generated flows.
- When Ansible behavior exposed to module users changes, update `README.md` in the same change instead of documenting it only inside the role.
- Prefer role defaults and OS conditionals over host-specific hard-coded values.
- Use `ansible_facts[...]` (or `ansible_facts.get(...)`) for fact access in conditions and templates; avoid deprecated top-level fact vars such as `ansible_os_family`, `ansible_system`, `ansible_distribution_release`, and `ansible_architecture`.
- Preserve cross-platform intro token file semantics in install assertions and role behavior (`intro_token.jwt` in the configured client state directory for POSIX and Windows path variants).
- When `nomad_client_install_reset_state` is true, preserve state-reset parity across Linux, macOS, and Windows: stop the platform service, recreate the client state directory, and rewrite `intro_token.jwt` when an introduction token is present.
- For local macOS E2E `local` mode, preserve the private RPC target in rendered Nomad client configuration. The tunnel helpers make that private address reachable; the role should not switch macOS to a public RPC address as a workaround.
- Validate and check your work using this sequence:
  - For role/playbook edits under `ansible/**`: run `make ansible-check` then `make ansible-lint`.
  - For E2E assertion/playbook edits under `e2e_tests/ansible/**`: run `make e2e-ansible-check` (or `make e2e-check` for combined E2E validation).
  - If the change impacts E2E behavior or extra vars wiring, run `make e2e-check` before finalizing.
  - For final repository-level confidence, run `make check`.
