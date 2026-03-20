.PHONY: check terraform-check terraform-fmt-check terraform-init terraform-validate tflint ansible-check ansible-lint

check: terraform-check tflint ansible-check ansible-lint

terraform-check: terraform-fmt-check terraform-validate

terraform-fmt-check:
	terraform fmt -check -recursive

terraform-init:
	terraform init -backend=false -input=false

terraform-validate: terraform-init
	terraform validate

tflint:
	tflint

ansible-check:
	@if command -v ansible-playbook >/dev/null 2>&1; then \
		ansible-playbook --inventory "localhost," --syntax-check ansible/install_nomad_client.yml; \
		ansible-playbook --inventory "localhost," --syntax-check ansible/remove_nomad_client.yml; \
	else \
		echo "ansible-playbook not found; skipping Ansible syntax checks."; \
	fi

ansible-lint:
	ansible-lint ansible/install_nomad_client.yml ansible/remove_nomad_client.yml
