#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

require_command "terraform" "Install Terraform and ensure it is on PATH."
require_command "jq" "Install jq and ensure it is on PATH."
require_command "curl" "Install curl and ensure it is on PATH."
require_command "nc" "Install netcat (nc) and ensure it is on PATH."

ARTIFACTS_DIR="${E2E_DIR}/.artifacts"
ensure_artifacts_dir "${ARTIFACTS_DIR}"

if ! ensure_tf_outputs_json; then
  log_error "Failed to retrieve Terraform outputs from ${E2E_DIR}. Ensure terraform apply completed successfully."
  exit 1
fi

if ! wait_for_nomad_server_ready "${ARTIFACTS_DIR}"; then
  log_error "Most common cause: security group ingress does not include your current source IP."
  log_error "Check e2e_tests/terraform.auto.tfvars or e2e_tests/terraform.tfvars -> allowed_cidr_blocks (must allow port 4646 from this machine)."
  log_error "If you are using external server mode, set deploy_nomad_server=false in terraform.auto.tfvars or terraform.tfvars."
  exit 1
fi

linux_ip="$(tf_output_optional "linux_public_ip")"
redhat_ip="$(tf_output_optional "redhat_public_ip")"
windows_ip="$(tf_output_optional "windows_public_ip")"
windows_password="$(tf_output_optional "windows_admin_password")"

if [[ -z "${windows_password}" || "${windows_password}" == "null" ]]; then
  log_error "Windows administrator password is empty. Re-apply Terraform once EC2 password_data becomes available."
  exit 1
fi

if ! wait_for_ssh_ready "${linux_ip}" "linux-e2e"; then
  log_error "Check allowed_cidr_blocks includes your current IP and that SSH is enabled on the instance image."
  exit 1
fi

if [[ -n "${redhat_ip}" && "${redhat_ip}" != "null" ]]; then
  if ! wait_for_ssh_ready "${redhat_ip}" "redhat-e2e"; then
    log_error "Check allowed_cidr_blocks includes your current IP and that SSH is enabled on the instance image."
    exit 1
  fi
fi

if ! wait_for_windows_winrm_ready "${windows_ip}"; then
  log_error "The Windows password_data was available, but the HTTPS WinRM endpoint never became ready."
  log_error "Check allowed_cidr_blocks includes your current IP and that the Windows host finished user_data bootstrapping."
  log_error "If TCP 5986 stayed closed, the WinRM HTTPS listener or Windows firewall rule likely never came up."
  exit 1
fi

echo "E2E hosts are ready."
