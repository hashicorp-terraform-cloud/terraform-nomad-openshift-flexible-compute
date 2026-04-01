.PHONY: check terraform-check terraform-fmt-check terraform-init terraform-validate tflint ansible-check ansible-lint e2e e2e-remove e2e-init e2e-ensure-tfvars e2e-plan e2e-apply e2e-generate-inventory e2e-wait-ready e2e-bootstrap-acl e2e-install e2e-assert-install e2e-run-test-jobs e2e-run-remove e2e-assert-remove e2e-destroy e2e-venv

E2E_TFVARS_FILE ?= e2e_tests/terraform.tfvars
E2E_TFVARS_EXAMPLE ?= e2e_tests/terraform.tfvars.example
E2E_ARTIFACTS_DIR ?= e2e_tests/.artifacts
E2E_VENV_DIR ?= .venv
E2E_VENV_BIN_DIR ?= $(E2E_VENV_DIR)/bin
E2E_REQUIREMENTS_FILE ?= e2e_tests/requirements.txt
E2E_VENV_STAMP ?= $(E2E_VENV_DIR)/.e2e-requirements-stamp
E2E_VENV_PATH_PREFIX = VIRTUAL_ENV="$(abspath $(E2E_VENV_DIR))" PATH="$(abspath $(E2E_VENV_BIN_DIR)):$$PATH"
E2E_INVENTORY_FILE ?= e2e_tests/.artifacts/inventory.ini
E2E_EXTRA_VARS_FILE ?= e2e_tests/.artifacts/extra_vars.yml

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

e2e-remove:
	-terraform -chdir=e2e_tests destroy -auto-approve
	rm -rf e2e_tests/.artifacts
	rm -rf e2e_tests/.terraform
	rm -f e2e_tests/.terraform.lock.hcl

e2e-init:
	terraform -chdir=e2e_tests init 

e2e-ensure-tfvars:
	@if [ ! -f "$(E2E_TFVARS_FILE)" ]; then \
		cp "$(E2E_TFVARS_EXAMPLE)" "$(E2E_TFVARS_FILE)"; \
		echo "Created $(E2E_TFVARS_FILE) from $(E2E_TFVARS_EXAMPLE)."; \
		echo "Review $(E2E_TFVARS_FILE) and rerun make e2e."; \
		exit 1; \
	fi

e2e-plan: e2e-ensure-tfvars
	terraform -chdir=e2e_tests plan

e2e-apply: e2e-ensure-tfvars
	terraform -chdir=e2e_tests apply
	@$(MAKE) e2e-generate-inventory

e2e-generate-inventory:
	bash e2e_tests/scripts/generate_inventory.sh

e2e-wait-ready:
	bash e2e_tests/scripts/wait_for_ready.sh

e2e-bootstrap-acl:
	bash e2e_tests/scripts/bootstrap_acl.sh

e2e-install: e2e-venv e2e-generate-inventory
	bash e2e_tests/scripts/preflight.sh
	$(E2E_VENV_PATH_PREFIX) OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ansible-playbook -i "$(E2E_INVENTORY_FILE)" ansible/install_nomad_client.yml --limit "$${E2E_LIMIT:-nomad_clients}" --extra-vars "@$(E2E_EXTRA_VARS_FILE)"

e2e-assert-install: e2e-venv e2e-generate-inventory
	bash e2e_tests/scripts/preflight.sh
	$(E2E_VENV_PATH_PREFIX) OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ansible-playbook -i "$(E2E_INVENTORY_FILE)" e2e_tests/ansible/assert_install.yml --limit "$${E2E_LIMIT:-nomad_clients}" --extra-vars "@$(E2E_EXTRA_VARS_FILE)"

e2e-run-test-jobs: e2e-venv
	$(E2E_VENV_PATH_PREFIX) bash e2e_tests/scripts/run_test_jobs.sh

e2e-run-remove: e2e-venv e2e-run-test-jobs e2e-generate-inventory
	bash e2e_tests/scripts/preflight.sh
	$(E2E_VENV_PATH_PREFIX) OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ansible-playbook -i "$(E2E_INVENTORY_FILE)" ansible/remove_nomad_client.yml --limit "$${E2E_LIMIT:-nomad_clients}"

e2e-assert-remove: e2e-venv e2e-generate-inventory
	bash e2e_tests/scripts/preflight.sh
	$(E2E_VENV_PATH_PREFIX) OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ansible-playbook -i "$(E2E_INVENTORY_FILE)" e2e_tests/ansible/assert_remove.yml --limit "$${E2E_LIMIT:-nomad_clients}" --extra-vars "@$(E2E_EXTRA_VARS_FILE)"

e2e-destroy:
	terraform -chdir=e2e_tests destroy
