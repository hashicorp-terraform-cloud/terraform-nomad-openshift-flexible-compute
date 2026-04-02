---
description: "Use when editing Terraform files in this Nomad OpenShift AAP module. Covers file boundaries, Terraform Actions, No Code input validation, README sync, and the load_balancer_ip plus client rollout contracts."
name: "Terraform Module Guidelines"
applyTo: "**/*.tf"
---
# Terraform Module Guidelines

- Keep file responsibilities fixed:
  - `versions.tf` for provider and Terraform version constraints
  - `main.tf` for locals, resources, and Terraform Actions
  - `variables.tf` for inputs and `validation` blocks
  - `outputs.tf` for exported values
- Treat `README.md` as the canonical source for prerequisites, provider credentials, and input/output documentation. Update it when Terraform behavior, inputs, outputs, or conditional requirements change.
- Preserve the `load_balancer_ip` contract unless you are intentionally redesigning it. The same value currently feeds Helm `service.external.loadBalancerIP`, Helm `advertise.address`, and AAP `nomad_server_address`.
- Keep `nomad_client_hosts` as a comma-separated string unless the design intentionally changes. If you change its shape, update resource iteration, outputs, and `README.md` together.
- Add `validation` blocks in `variables.tf` for new constrained or conditional inputs.
- Keep `terraform_data.nomad_client_lifecycle` as the orchestration point for AAP install or remove side effects. If rollout triggers change, update its `input`, `depends_on`, and action wiring together.
- Keep `local.install_nomad_client_extra_vars` aligned with `ansible/roles/nomad_client_install/defaults/main.yml` and `README.md` whenever you add install-time settings.
- For E2E shell helpers that consume Terraform outputs (for example under `e2e_tests/scripts/`), prefer a single `terraform output -json` read plus helper accessors over repeated `terraform output -raw` calls. This avoids repeated CLI invocations and keeps all derived values based on a single output snapshot.
- In remote-run contexts (for example HCP Terraform), do not rely on `local_file` or `local_sensitive_file` for artifacts needed on the developer machine (such as E2E inventory files). Expose required content through outputs and generate local artifacts with local scripts/Make targets.
- Preserve the E2E client introduction token contract: manual `client_introduction_token` input remains authoritative, while self-hosted ACL-enabled E2E flows may auto-generate a fallback token artifact consumed by local scripts.
- Validate and check your work using this sequence:
  - For root Terraform changes: run `make terraform-check` and, when relevant, `make tflint`.
  - For `e2e_tests/*.tf` changes: run `make e2e-terraform-check` (or `make e2e-check` for combined Terraform+Ansible E2E checks).
  - For `e2e_tests/scripts/*.sh` changes that affect Terraform output consumption or E2E orchestration, run `bash -n <script>` for edited scripts and then `make e2e-check`.
  - For final repository-level confidence, run `make check`.
