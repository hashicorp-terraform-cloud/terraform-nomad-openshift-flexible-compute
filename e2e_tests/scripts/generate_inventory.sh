#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${E2E_DIR}/.artifacts"
INVENTORY_FILE="${ARTIFACTS_DIR}/inventory.ini"
EXTRA_VARS_FILE="${ARTIFACTS_DIR}/extra_vars.yml"
TOKEN_FILE="${ARTIFACTS_DIR}/nomad_management_token.txt"
INTRO_TOKEN_FILE="${ARTIFACTS_DIR}/nomad_client_intro_token.txt"
NOMAD_CA_CERT_FILE="${ARTIFACTS_DIR}/nomad-agent-ca.pem"
NOMAD_CLIENT_CERT_FILE="${ARTIFACTS_DIR}/global-cli-nomad.pem"
NOMAD_CLIENT_KEY_FILE="${ARTIFACTS_DIR}/global-cli-nomad-key.pem"

# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

ensure_artifacts_dir "${ARTIFACTS_DIR}"

require_command "terraform" "Install Terraform and ensure it is on PATH."
require_command "jq" "Install jq and ensure it is on PATH."
require_command "curl" "Install curl and ensure it is on PATH."
require_command "nc" "Install netcat (nc) and ensure it is on PATH."
require_command "openssl" "Install openssl and ensure it is on PATH."

if ! ensure_tf_outputs_json; then
  log_error "Failed to retrieve Terraform outputs from ${E2E_DIR}. Ensure terraform apply completed successfully."
  exit 1
fi

write_generated_private_key_if_needed() {
  local private_key_file="$1"

  if [[ -f "${private_key_file}" ]]; then
    return 0
  fi

  local generated_private_key
  generated_private_key="$(tf_output_optional "generated_ssh_private_key_pem")"

  if [[ -z "${generated_private_key}" || "${generated_private_key}" == "null" ]]; then
    log_error "No SSH private key file found at ${private_key_file}, and Terraform did not return generated_ssh_private_key_pem."
    log_error "Set E2E_SSH_PRIVATE_KEY_FILE to an existing key, or apply Terraform so a disposable key is generated automatically."
    exit 1
  fi

  mkdir -p "$(dirname "${private_key_file}")"
  printf '%s\n' "${generated_private_key}" > "${private_key_file}"
  chmod 600 "${private_key_file}"
  log_info "Wrote generated E2E SSH private key to ${private_key_file}."
}

decrypt_windows_password() {
  local password_data="$1"
  local private_key_file="$2"

  if [[ -z "${password_data}" || "${password_data}" == "null" ]]; then
    echo ""
    return 0
  fi

  if ! openssl pkey -in "${private_key_file}" -noout >/dev/null 2>&1; then
    log_error "Unable to read ${private_key_file} with openssl. Use the PEM-encoded RSA private key written from generated_ssh_private_key_pem output."
    exit 1
  fi

  printf '%s' "${password_data}" \
    | openssl base64 -d -A \
    | openssl pkeyutl -decrypt -inkey "${private_key_file}" -pkeyopt rsa_padding_mode:pkcs1
}

if ! wait_for_nomad_server_ready "${ARTIFACTS_DIR}"; then
  log_error "Most common cause: security group ingress does not include your current source IP."
  log_error "Check e2e_tests/terraform.auto.tfvars or e2e_tests/terraform.tfvars -> allowed_cidr_blocks (must allow port 4646 from this machine)."
  log_error "If you are using external server mode, set deploy_nomad_server=false in terraform.auto.tfvars or terraform.tfvars."
  exit 1
fi

linux_ip="$(tf_output_optional "linux_public_ip")"
redhat_ip="$(tf_output_optional "redhat_public_ip")"
windows_ip="$(tf_output_optional "windows_public_ip")"
linux_user="$(tf_output_optional "linux_ssh_user")"
redhat_user="$(tf_output_with_default "redhat_ssh_user" "${linux_user}")"
windows_user="$(tf_output_optional "windows_admin_username")"
windows_password_data="$(tf_output_optional "windows_password_data")"
nomad_server_address="$(tf_output_optional "nomad_server_address")"
nomad_datacenter="$(tf_output_optional "nomad_datacenter")"
nomad_region="$(tf_output_optional "nomad_region")"
nomad_edition_tf="$(tf_output_optional "nomad_edition")"
nomad_version_tf="$(tf_output_optional "nomad_version")"
nomad_license_tf="$(tf_output_optional "nomad_license")"
inventory_ini_tf="$(tf_output_optional "inventory_ini")"
extra_vars_yaml_tf="$(tf_output_optional "extra_vars_yaml")"
client_intro_token="$(tf_output_optional "client_introduction_token")"
deploy_nomad_server_tf="$(tf_output_with_default "deploy_nomad_server" "false")"
nomad_acl_enabled_tf="$(tf_output_with_default "nomad_acl_enabled" "false")"
ssh_private_key_path="${E2E_SSH_PRIVATE_KEY_FILE:-${E2E_DIR}/.artifacts/e2e_rsa.pem}"

if [[ -z "${client_intro_token}" || "${client_intro_token}" == "null" ]]; then
  if [[ "${deploy_nomad_server_tf}" == "true" && "${nomad_acl_enabled_tf}" == "true" && -s "${INTRO_TOKEN_FILE}" ]]; then
    client_intro_token="$(cat "${INTRO_TOKEN_FILE}")"
  fi
fi

write_generated_private_key_if_needed "${ssh_private_key_path}"
require_file "${ssh_private_key_path}" "E2E_SSH_PRIVATE_KEY_FILE"

windows_password="$(decrypt_windows_password "${windows_password_data}" "${ssh_private_key_path}")"

if [[ -z "${windows_password}" ]]; then
  log_error "Windows password is empty. Wait for EC2 password_data availability and re-run."
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

nomad_edition_e2e="${E2E_NOMAD_EDITION:-${nomad_edition_tf:-community}}"
nomad_version_e2e="${E2E_NOMAD_VERSION:-${nomad_version_tf:-}}"
nomad_license_e2e="${E2E_NOMAD_LICENSE:-${nomad_license_tf:-}}"

if [[ -z "${nomad_version_e2e}" ]]; then
  if [[ "${nomad_edition_e2e}" == "enterprise" ]]; then
    nomad_version_e2e="1.11.3+ent"
  else
    nomad_version_e2e="1.11.3"
  fi
fi

if [[ -z "${inventory_ini_tf}" || "${inventory_ini_tf}" == "null" ]]; then
  echo "Terraform output inventory_ini is empty. Ensure terraform apply completed successfully." >&2
  exit 1
fi

if [[ -z "${extra_vars_yaml_tf}" || "${extra_vars_yaml_tf}" == "null" ]]; then
  echo "Terraform output extra_vars_yaml is empty. Ensure terraform apply completed successfully." >&2
  exit 1
fi

inventory_ini_local="${inventory_ini_tf}"

default_private_key_path="${E2E_DIR}/.artifacts/e2e_rsa.pem"
default_private_key_path_escaped="${default_private_key_path//\//\\/}"
relative_private_key_path="./.artifacts/e2e_rsa.pem"
relative_private_key_path_escaped="${relative_private_key_path//\//\\/}"

inventory_ini_local="${inventory_ini_local//${default_private_key_path_escaped}/${ssh_private_key_path}}"
inventory_ini_local="${inventory_ini_local//${relative_private_key_path_escaped}/${ssh_private_key_path}}"

printf '%s\n' "${inventory_ini_local}" > "${INVENTORY_FILE}"
printf '%s\n' "${extra_vars_yaml_tf}" > "${EXTRA_VARS_FILE}"

if [[ -n "${nomad_version_e2e}" ]]; then
  sed -i.bak -E "s|^nomad_version: .*|nomad_version: \"${nomad_version_e2e}\"|" "${EXTRA_VARS_FILE}" && rm -f "${EXTRA_VARS_FILE}.bak"
fi

if [[ -n "${nomad_edition_e2e}" ]]; then
  sed -i.bak -E "s|^nomad_edition: .*|nomad_edition: \"${nomad_edition_e2e}\"|" "${EXTRA_VARS_FILE}" && rm -f "${EXTRA_VARS_FILE}.bak"
fi

if [[ -n "${nomad_license_e2e}" ]]; then
  nomad_license_e2e_escaped="${nomad_license_e2e//\\/\\\\}"
  nomad_license_e2e_escaped="${nomad_license_e2e_escaped//\"/\\\"}"
  if grep -Eq '^[[:space:]]*"?nomad_license"?:' "${EXTRA_VARS_FILE}"; then
    sed -i.bak -E "s|^[[:space:]]*\"?nomad_license\"?: .*|\"nomad_license\": \"${nomad_license_e2e_escaped}\"|" "${EXTRA_VARS_FILE}" && rm -f "${EXTRA_VARS_FILE}.bak"
  else
    echo "\"nomad_license\": \"${nomad_license_e2e_escaped}\"" >> "${EXTRA_VARS_FILE}"
  fi
fi

if [[ -f "${TOKEN_FILE}" ]]; then
  nomad_token="$(cat "${TOKEN_FILE}")"
  if [[ -n "${nomad_token}" ]]; then
    nomad_token_escaped="${nomad_token//\\/\\\\}"
    nomad_token_escaped="${nomad_token_escaped//\"/\\\"}"
    if grep -Eq '^[[:space:]]*"?nomad_token"?:' "${EXTRA_VARS_FILE}"; then
      sed -i.bak -E "s|^[[:space:]]*\"?nomad_token\"?: .*|\"nomad_token\": \"${nomad_token_escaped}\"|" "${EXTRA_VARS_FILE}" && rm -f "${EXTRA_VARS_FILE}.bak"
    else
      echo "\"nomad_token\": \"${nomad_token_escaped}\"" >> "${EXTRA_VARS_FILE}"
    fi
  fi
fi

client_intro_token_escaped="${client_intro_token//\\/\\\\}"
client_intro_token_escaped="${client_intro_token_escaped//\"/\\\"}"

if grep -Eq '^[[:space:]]*"?nomad_client_intro_token"?:' "${EXTRA_VARS_FILE}"; then
  sed -i.bak -E "s|^[[:space:]]*\"?nomad_client_intro_token\"?: .*|\"nomad_client_intro_token\": \"${client_intro_token_escaped}\"|" "${EXTRA_VARS_FILE}" && rm -f "${EXTRA_VARS_FILE}.bak"
else
  echo "\"nomad_client_intro_token\": \"${client_intro_token_escaped}\"" >> "${EXTRA_VARS_FILE}"
fi

if grep -Eq '^[[:space:]]*"?nomad_client_install_intro_token"?:' "${EXTRA_VARS_FILE}"; then
  sed -i.bak -E "s|^[[:space:]]*\"?nomad_client_install_intro_token\"?: .*|\"nomad_client_install_intro_token\": \"${client_intro_token_escaped}\"|" "${EXTRA_VARS_FILE}" && rm -f "${EXTRA_VARS_FILE}.bak"
else
  echo "\"nomad_client_install_intro_token\": \"${client_intro_token_escaped}\"" >> "${EXTRA_VARS_FILE}"
fi

echo "Generated inventory: ${INVENTORY_FILE}"
echo "Generated vars:      ${EXTRA_VARS_FILE}"
