#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${E2E_DIR}/.artifacts"
INVENTORY_FILE="${ARTIFACTS_DIR}/inventory.ini"
EXTRA_VARS_FILE="${ARTIFACTS_DIR}/extra_vars.yml"

mkdir -p "${ARTIFACTS_DIR}"

require_file() {
  local file_path="$1"
  local description="$2"

  if [[ -z "${file_path}" ]]; then
    echo "${description} is required." >&2
    exit 1
  fi

  if [[ ! -f "${file_path}" ]]; then
    echo "${description} not found at ${file_path}." >&2
    exit 1
  fi
}

write_generated_private_key_if_needed() {
  local private_key_file="$1"

  if [[ -f "${private_key_file}" ]]; then
    return 0
  fi

  local generated_private_key
  generated_private_key="$(terraform -chdir="${E2E_DIR}" output -raw generated_ssh_private_key_pem 2>/dev/null || true)"

  if [[ -z "${generated_private_key}" || "${generated_private_key}" == "null" ]]; then
    echo "No SSH private key file found at ${private_key_file}, and Terraform did not return generated_ssh_private_key_pem." >&2
    echo "Set E2E_SSH_PRIVATE_KEY_FILE to an existing key, or apply Terraform so a disposable key is generated automatically." >&2
    exit 1
  fi

  mkdir -p "$(dirname "${private_key_file}")"
  printf '%s\n' "${generated_private_key}" > "${private_key_file}"
  chmod 600 "${private_key_file}"
  echo "Wrote generated E2E SSH private key to ${private_key_file}."
}

decrypt_windows_password() {
  local password_data="$1"
  local private_key_file="$2"

  if [[ -z "${password_data}" || "${password_data}" == "null" ]]; then
    echo ""
    return 0
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to decrypt EC2 Windows password data." >&2
    exit 1
  fi

  if ! openssl pkey -in "${private_key_file}" -noout >/dev/null 2>&1; then
    echo "Unable to read ${private_key_file} with openssl. Use the PEM-encoded RSA private key written from generated_ssh_private_key_pem output." >&2
    exit 1
  fi

  printf '%s' "${password_data}" \
    | openssl base64 -d -A \
    | openssl pkeyutl -decrypt -inkey "${private_key_file}" -pkeyopt rsa_padding_mode:pkcs1
}

windows_winrm_https_ready() {
  local windows_ip="$1"
  local winrm_url
  winrm_url="https://${windows_ip}:5986/wsman"
  local http_code
  http_code="$(curl --silent --show-error --insecure --output /dev/null --write-out '%{http_code}' --max-time 5 "${winrm_url}" 2>/dev/null || true)"

  case "${http_code}" in
    401|405|500)
      return 0
      ;;
  esac

  return 1
}

wait_for_windows_winrm_ready() {
  local windows_ip="$1"

  local max_attempts
  max_attempts="${E2E_WINDOWS_WAIT_MAX_ATTEMPTS:-60}"
  local sleep_seconds
  sleep_seconds="${E2E_WINDOWS_WAIT_SLEEP_SECONDS:-10}"
  local attempt
  attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if windows_winrm_https_ready "${windows_ip}"; then
      echo "Windows WinRM is reachable at https://${windows_ip}:5986/wsman."
      return 0
    fi

    local tcp_state
    tcp_state="closed"
    if nc -z -w 5 "${windows_ip}" 5986 >/dev/null 2>&1; then
      tcp_state="open"
    fi

    echo "Waiting for Windows WinRM readiness (${attempt}/${max_attempts}) at https://${windows_ip}:5986/wsman (TCP 5986 ${tcp_state})..."
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for Windows WinRM readiness at https://${windows_ip}:5986/wsman." >&2
  echo "The Windows password_data was available, but the HTTPS WinRM endpoint never became ready." >&2
  echo "Check allowed_cidr_blocks includes your current IP and that the Windows host finished user_data bootstrapping." >&2
  echo "If TCP 5986 stayed closed, the WinRM HTTPS listener or Windows firewall rule likely never came up." >&2
  exit 1
}

ssh_tcp_ready() {
  local host_ip="$1"
  nc -z -w 5 "${host_ip}" 22 >/dev/null 2>&1
}

wait_for_ssh_ready() {
  local host_ip="$1"
  local host_label="$2"

  local max_attempts
  max_attempts="${E2E_SSH_WAIT_MAX_ATTEMPTS:-60}"
  local sleep_seconds
  sleep_seconds="${E2E_SSH_WAIT_SLEEP_SECONDS:-10}"
  local attempt
  attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if ssh_tcp_ready "${host_ip}"; then
      echo "${host_label} SSH is reachable at ${host_ip}:22."
      return 0
    fi

    echo "Waiting for ${host_label} SSH readiness (${attempt}/${max_attempts}) at ${host_ip}:22..."
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for ${host_label} SSH readiness at ${host_ip}:22." >&2
  echo "Check allowed_cidr_blocks includes your current IP and that SSH is enabled on the instance image." >&2
  exit 1
}

wait_for_nomad_server_ready() {
  local deploy_nomad_server
  deploy_nomad_server="$(terraform -chdir="${E2E_DIR}" output -raw deploy_nomad_server 2>/dev/null || echo "false")"

  if [[ "${deploy_nomad_server}" != "true" ]]; then
    return 0
  fi

  local nomad_server_public_ip
  nomad_server_public_ip="$(terraform -chdir="${E2E_DIR}" output -raw nomad_server_public_ip 2>/dev/null || true)"

  if [[ -z "${nomad_server_public_ip}" || "${nomad_server_public_ip}" == "null" ]]; then
    echo "Unable to determine nomad_server_public_ip for readiness check." >&2
    exit 1
  fi

  local nomad_addr
  nomad_addr="http://${nomad_server_public_ip}:4646"
  local max_attempts
  max_attempts="${E2E_NOMAD_WAIT_MAX_ATTEMPTS:-30}"
  local sleep_seconds
  sleep_seconds="${E2E_NOMAD_WAIT_SLEEP_SECONDS:-10}"
  local attempt
  attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    local leader
    leader="$(curl --silent --show-error --max-time 5 "${nomad_addr}/v1/status/leader" || true)"
    if [[ -n "${leader}" && "${leader}" != '""' ]]; then
      echo "Nomad server is ready at ${nomad_addr} (leader: ${leader})."
      return 0
    fi

    echo "Waiting for Nomad server API readiness (${attempt}/${max_attempts}) at ${nomad_addr}..."
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for Nomad server readiness at ${nomad_addr}." >&2
  echo "Most common cause: security group ingress does not include your current source IP." >&2
  echo "Check e2e_tests/terraform.tfvars -> allowed_cidr_blocks (must allow port 4646 from this machine)." >&2
  echo "If you are using external server mode, set deploy_nomad_server=false in terraform.tfvars." >&2
  exit 1
}

wait_for_nomad_server_ready

linux_ip="$(terraform -chdir="${E2E_DIR}" output -raw linux_public_ip)"
redhat_ip="$(terraform -chdir="${E2E_DIR}" output -raw redhat_public_ip 2>/dev/null || true)"
windows_ip="$(terraform -chdir="${E2E_DIR}" output -raw windows_public_ip)"
linux_user="$(terraform -chdir="${E2E_DIR}" output -raw linux_ssh_user)"
redhat_user="$(terraform -chdir="${E2E_DIR}" output -raw redhat_ssh_user 2>/dev/null || echo "${linux_user}")"
windows_user="$(terraform -chdir="${E2E_DIR}" output -raw windows_admin_username)"
windows_password_data="$(terraform -chdir="${E2E_DIR}" output -raw windows_password_data || true)"
nomad_server_address="$(terraform -chdir="${E2E_DIR}" output -raw nomad_server_address)"
nomad_datacenter="$(terraform -chdir="${E2E_DIR}" output -raw nomad_datacenter)"
nomad_region="$(terraform -chdir="${E2E_DIR}" output -raw nomad_region)"
nomad_edition_tf="$(terraform -chdir="${E2E_DIR}" output -raw nomad_edition 2>/dev/null || true)"
nomad_version_tf="$(terraform -chdir="${E2E_DIR}" output -raw nomad_version 2>/dev/null || true)"
nomad_license_tf="$(terraform -chdir="${E2E_DIR}" output -raw nomad_license 2>/dev/null || true)"
inventory_ini_tf="$(terraform -chdir="${E2E_DIR}" output -raw inventory_ini 2>/dev/null || true)"
extra_vars_yaml_tf="$(terraform -chdir="${E2E_DIR}" output -raw extra_vars_yaml 2>/dev/null || true)"
client_intro_token="$(terraform -chdir="${E2E_DIR}" output -raw client_introduction_token || true)"
ssh_private_key_path="${E2E_SSH_PRIVATE_KEY_FILE:-${E2E_DIR}/.artifacts/e2e_rsa.pem}"

write_generated_private_key_if_needed "${ssh_private_key_path}"
require_file "${ssh_private_key_path}" "E2E_SSH_PRIVATE_KEY_FILE"

windows_password="$(decrypt_windows_password "${windows_password_data}" "${ssh_private_key_path}")"

if [[ -z "${windows_password}" ]]; then
  echo "Windows password is empty. Wait for EC2 password_data availability and re-run." >&2
  exit 1
fi

wait_for_ssh_ready "${linux_ip}" "linux-e2e"

if [[ -n "${redhat_ip}" && "${redhat_ip}" != "null" ]]; then
  wait_for_ssh_ready "${redhat_ip}" "redhat-e2e"
fi

wait_for_windows_winrm_ready "${windows_ip}"

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
inventory_ini_local="${inventory_ini_local//${E2E_DIR//\//\/}\/\.artifacts\/e2e_rsa\.pem/${ssh_private_key_path}}"

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
  if grep -q '^nomad_license:' "${EXTRA_VARS_FILE}"; then
    sed -i.bak -E "s|^nomad_license: .*|nomad_license: \"${nomad_license_e2e_escaped}\"|" "${EXTRA_VARS_FILE}" && rm -f "${EXTRA_VARS_FILE}.bak"
  else
    echo "nomad_license: \"${nomad_license_e2e_escaped}\"" >> "${EXTRA_VARS_FILE}"
  fi
fi

echo "Generated inventory: ${INVENTORY_FILE}"
echo "Generated vars:      ${EXTRA_VARS_FILE}"
