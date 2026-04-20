.PHONY: help check terraform-check terraform-fmt-check terraform-init terraform-validate tflint ansible-check ansible-lint e2e e2e-check e2e-terraform-check e2e-terraform-fmt-check e2e-terraform-init e2e-terraform-validate e2e-ansible-check e2e-remove e2e-init e2e-ensure-tfvars e2e-plan e2e-apply e2e-generate-inventory e2e-wait-ready e2e-bootstrap-acl e2e-setup-local-macos-tunnel e2e-cleanup-local-macos-tunnel e2e-install e2e-assert-install e2e-run-test-jobs e2e-run-remove e2e-assert-remove e2e-destroy e2e-venv

E2E_TFVARS_FILE ?= e2e_tests/terraform.auto.tfvars
E2E_TFVARS_FILE_ALT ?= e2e_tests/terraform.tfvars
E2E_TFVARS_EXAMPLE ?= e2e_tests/terraform.tfvars.example
E2E_ARTIFACTS_DIR ?= e2e_tests/.artifacts
E2E_VENV_DIR ?= .venv
E2E_VENV_BIN_DIR ?= $(E2E_VENV_DIR)/bin
E2E_REQUIREMENTS_FILE ?= e2e_tests/requirements.txt
E2E_VENV_STAMP ?= $(E2E_VENV_DIR)/.e2e-requirements-stamp
E2E_VENV_PATH_PREFIX = VIRTUAL_ENV="$(abspath $(E2E_VENV_DIR))" PATH="$(abspath $(E2E_VENV_BIN_DIR)):$$PATH"
E2E_INVENTORY_FILE ?= e2e_tests/.artifacts/inventory.ini
E2E_EXTRA_VARS_FILE ?= e2e_tests/.artifacts/extra_vars.yml

help:
	@printf '%s\n' \
		'Available targets:' \
		'  help                  Show this help output' \
		'  check                 Run repository Terraform and Ansible checks' \
		'  terraform-check       Run root Terraform fmt and validate checks' \
		'  ansible-check         Run root Ansible syntax checks' \
		'  ansible-lint          Run root Ansible lint checks' \
		'  tflint                Run Terraform lint checks' \
		'' \
		'  e2e-check             Run non-destructive E2E Terraform and Ansible checks' \
		'  e2e-init              Initialize the e2e_tests Terraform working directory' \
		'  e2e-plan              Run Terraform plan for e2e_tests' \
		'  e2e-apply             Apply e2e_tests infrastructure and generate inventory' \
		'  e2e-bootstrap-acl     Bootstrap Nomad ACLs for the E2E Nomad server' \
		'  e2e-setup-local-macos-tunnel  Create local macOS loopback alias + SSH tunnel for Nomad RPC' \
		'  e2e-cleanup-local-macos-tunnel Remove local macOS loopback alias + SSH tunnel artifacts' \
		'  e2e-install           Run the install playbook against E2E hosts' \
		'  e2e-assert-install    Run E2E install assertions' \
		'  e2e-run-test-jobs     Submit pre-remove Nomad test jobs' \
		'  e2e-run-remove        Run the remove playbook against E2E hosts' \
		'  e2e-assert-remove     Run E2E remove assertions' \
		'  e2e-destroy           Destroy e2e_tests infrastructure' \
		'  e2e-remove            Destroy e2e_tests artifacts and local Terraform state' \
		'  e2e                  Apply infra and run install-side E2E flow'

check: terraform-check tflint ansible-check ansible-lint

terraform-check: terraform-fmt-check terraform-validate

terraform-fmt-check:
	terraform fmt -recursive

terraform-init:
	terraform init -backend=false -input=false

terraform-validate: terraform-init
	terraform validate

tflint:
	tflint

$(E2E_VENV_STAMP): $(E2E_REQUIREMENTS_FILE)
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "python3 is required to create the E2E virtual environment."; \
		exit 1; \
	fi
	python3 -m venv "$(E2E_VENV_DIR)"
	"$(E2E_VENV_BIN_DIR)/python" -m pip install --upgrade pip setuptools wheel
	"$(E2E_VENV_BIN_DIR)/python" -m pip install -r "$(E2E_REQUIREMENTS_FILE)"
	@touch "$(E2E_VENV_STAMP)"

e2e-venv: $(E2E_VENV_STAMP)


ansible-check: e2e-venv
	$(E2E_VENV_PATH_PREFIX) ansible-playbook --inventory "localhost," --syntax-check ansible/install_nomad_client.yml
	$(E2E_VENV_PATH_PREFIX) ansible-playbook --inventory "localhost," --syntax-check ansible/remove_nomad_client.yml

ansible-lint: e2e-venv
	$(E2E_VENV_PATH_PREFIX) ansible-lint ansible/install_nomad_client.yml ansible/remove_nomad_client.yml

e2e: e2e-init e2e-apply e2e-install e2e-assert-install e2e-run-test-jobs
# e2e-run-remove e2e-assert-remove

e2e-check: e2e-terraform-check e2e-ansible-check e2e-ansible-lint

e2e-terraform-check: e2e-terraform-fmt-check e2e-terraform-validate

e2e-terraform-fmt-check:
	terraform -chdir=e2e_tests fmt -recursive

e2e-terraform-init:
	terraform -chdir=e2e_tests init -backend=false -input=false

e2e-terraform-validate: e2e-terraform-init
	terraform -chdir=e2e_tests validate

e2e-ansible-check: e2e-venv
	@tmp_inventory="$$(mktemp)"; \
	printf '[nomad_clients]\nsyntax-host ansible_connection=local\n' > "$$tmp_inventory"; \
	trap 'rm -f "$$tmp_inventory"' EXIT; \
	$(E2E_VENV_PATH_PREFIX) ansible-playbook --inventory "$$tmp_inventory" --syntax-check e2e_tests/ansible/assert_install.yml; \
	$(E2E_VENV_PATH_PREFIX) ansible-playbook --inventory "$$tmp_inventory" --syntax-check e2e_tests/ansible/assert_remove.yml

e2e-ansible-lint: e2e-venv
	$(E2E_VENV_PATH_PREFIX) ansible-lint e2e_tests/ansible/assert_install.yml e2e_tests/ansible/assert_remove.yml

e2e-remove:
	-terraform -chdir=e2e_tests destroy -auto-approve
	rm -rf e2e_tests/.artifacts
	rm -rf e2e_tests/.terraform
	rm -f e2e_tests/.terraform.lock.hcl

e2e-init:
	terraform -chdir=e2e_tests init 

e2e-ensure-tfvars:
	@if [ ! -f "$(E2E_TFVARS_FILE)" ] && [ ! -f "$(E2E_TFVARS_FILE_ALT)" ]; then \
		cp "$(E2E_TFVARS_EXAMPLE)" "$(E2E_TFVARS_FILE)"; \
		echo "Created $(E2E_TFVARS_FILE) from $(E2E_TFVARS_EXAMPLE)."; \
		echo "Either $(E2E_TFVARS_FILE) or $(E2E_TFVARS_FILE_ALT) is accepted for E2E local variables."; \
		echo "Review $(E2E_TFVARS_FILE) and rerun make e2e."; \
		exit 1; \
	fi

e2e-plan: e2e-ensure-tfvars
	terraform -chdir=e2e_tests plan

e2e-apply: e2e-ensure-tfvars
	terraform -chdir=e2e_tests apply --auto-approve
	@$(MAKE) e2e-generate-inventory

e2e-generate-inventory:
	bash e2e_tests/scripts/generate_inventory.sh

e2e-wait-ready:
	bash e2e_tests/scripts/wait_for_ready.sh

e2e-bootstrap-acl:
	bash e2e_tests/scripts/bootstrap_acl.sh

e2e-bootstrap-acl-auto:
	@deploy_nomad_server="$$(terraform -chdir=e2e_tests output -raw deploy_nomad_server 2>/dev/null || echo false)"; \
	nomad_acl_enabled="$$(terraform -chdir=e2e_tests output -raw nomad_acl_enabled 2>/dev/null || echo false)"; \
	if [ "$$deploy_nomad_server" = "true" ] && [ "$$nomad_acl_enabled" = "true" ]; then \
		echo "ACL is enabled for self-hosted E2E Nomad server; ensuring ACL artifacts and intro token..."; \
		$(MAKE) e2e-generate-inventory; \
		if ! bash e2e_tests/scripts/bootstrap_acl.sh; then \
			echo "ACL bootstrap/token preparation failed. If the cluster is already bootstrapped, set NOMAD_TOKEN in your environment and retry."; \
			exit 1; \
		fi; \
		$(MAKE) e2e-generate-inventory; \
	else \
		echo "Skipping ACL bootstrap (deploy_nomad_server=$$deploy_nomad_server, nomad_acl_enabled=$$nomad_acl_enabled)."; \
	fi

e2e-setup-local-macos-tunnel:
	bash e2e_tests/scripts/setup_local_macos_nomad_tunnel.sh

e2e-cleanup-local-macos-tunnel:
	bash e2e_tests/scripts/cleanup_local_macos_nomad_tunnel.sh

e2e-install: e2e-venv e2e-bootstrap-acl-auto e2e-generate-inventory e2e-setup-local-macos-tunnel
	bash e2e_tests/scripts/preflight.sh
	@deploy_local_macos_client="$$(terraform -chdir=e2e_tests output -raw deploy_local_macos_client 2>/dev/null || echo false)"; \
	local_macos_connection="$$(terraform -chdir=e2e_tests output -raw local_macos_connection 2>/dev/null || echo local)"; \
	become_arg=""; \
	if [ "$$deploy_local_macos_client" = "true" ] && [ "$$local_macos_connection" = "local" ]; then \
		become_arg="--ask-become-pass"; \
	fi; \
	$(E2E_VENV_PATH_PREFIX) OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ansible-playbook $$become_arg -i "$(E2E_INVENTORY_FILE)" ansible/install_nomad_client.yml --limit "$${E2E_LIMIT:-nomad_clients}" --extra-vars "@$(E2E_EXTRA_VARS_FILE)"

e2e-assert-install: e2e-venv e2e-bootstrap-acl-auto e2e-generate-inventory e2e-setup-local-macos-tunnel
	bash e2e_tests/scripts/preflight.sh
	@deploy_local_macos_client="$$(terraform -chdir=e2e_tests output -raw deploy_local_macos_client 2>/dev/null || echo false)"; \
	local_macos_connection="$$(terraform -chdir=e2e_tests output -raw local_macos_connection 2>/dev/null || echo local)"; \
	become_arg=""; \
	if [ "$$deploy_local_macos_client" = "true" ] && [ "$$local_macos_connection" = "local" ]; then \
		become_arg="--ask-become-pass"; \
	fi; \
	$(E2E_VENV_PATH_PREFIX) OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ansible-playbook $$become_arg -i "$(E2E_INVENTORY_FILE)" e2e_tests/ansible/assert_install.yml --limit "$${E2E_LIMIT:-nomad_clients}" --extra-vars "@$(E2E_EXTRA_VARS_FILE)"

e2e-run-test-jobs: e2e-venv
	$(E2E_VENV_PATH_PREFIX) bash e2e_tests/scripts/run_test_jobs.sh

e2e-run-remove: e2e-venv e2e-bootstrap-acl-auto e2e-run-test-jobs e2e-generate-inventory e2e-setup-local-macos-tunnel
	bash e2e_tests/scripts/preflight.sh
	@deploy_local_macos_client="$$(terraform -chdir=e2e_tests output -raw deploy_local_macos_client 2>/dev/null || echo false)"; \
	local_macos_connection="$$(terraform -chdir=e2e_tests output -raw local_macos_connection 2>/dev/null || echo local)"; \
	become_arg=""; \
	if [ "$$deploy_local_macos_client" = "true" ] && [ "$$local_macos_connection" = "local" ]; then \
		become_arg="--ask-become-pass"; \
	fi; \
	$(E2E_VENV_PATH_PREFIX) OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ansible-playbook $$become_arg -i "$(E2E_INVENTORY_FILE)" ansible/remove_nomad_client.yml --limit "$${E2E_LIMIT:-nomad_clients}" --extra-vars "@$(E2E_EXTRA_VARS_FILE)"

e2e-assert-remove: e2e-venv e2e-bootstrap-acl-auto e2e-generate-inventory e2e-setup-local-macos-tunnel
	bash e2e_tests/scripts/preflight.sh
	@deploy_local_macos_client="$$(terraform -chdir=e2e_tests output -raw deploy_local_macos_client 2>/dev/null || echo false)"; \
	local_macos_connection="$$(terraform -chdir=e2e_tests output -raw local_macos_connection 2>/dev/null || echo local)"; \
	become_arg=""; \
	if [ "$$deploy_local_macos_client" = "true" ] && [ "$$local_macos_connection" = "local" ]; then \
		become_arg="--ask-become-pass"; \
	fi; \
	$(E2E_VENV_PATH_PREFIX) OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ansible-playbook $$become_arg -i "$(E2E_INVENTORY_FILE)" e2e_tests/ansible/assert_remove.yml --limit "$${E2E_LIMIT:-nomad_clients}" --extra-vars "@$(E2E_EXTRA_VARS_FILE)"

e2e-destroy:
	terraform -chdir=e2e_tests destroy
