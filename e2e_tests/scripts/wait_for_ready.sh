#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
  exit 1
}

wait_for_nomad_server_ready

linux_ip="$(terraform -chdir="${E2E_DIR}" output -raw linux_public_ip)"
redhat_ip="$(terraform -chdir="${E2E_DIR}" output -raw redhat_public_ip 2>/dev/null || true)"
windows_ip="$(terraform -chdir="${E2E_DIR}" output -raw windows_public_ip)"
windows_password="$(terraform -chdir="${E2E_DIR}" output -raw windows_admin_password 2>/dev/null || true)"

if [[ -z "${windows_password}" || "${windows_password}" == "null" ]]; then
  echo "Windows administrator password is empty. Re-apply Terraform once EC2 password_data becomes available." >&2
  exit 1
fi

wait_for_ssh_ready "${linux_ip}" "linux-e2e"

if [[ -n "${redhat_ip}" && "${redhat_ip}" != "null" ]]; then
  wait_for_ssh_ready "${redhat_ip}" "redhat-e2e"
fi

wait_for_windows_winrm_ready "${windows_ip}"

echo "E2E hosts are ready."
