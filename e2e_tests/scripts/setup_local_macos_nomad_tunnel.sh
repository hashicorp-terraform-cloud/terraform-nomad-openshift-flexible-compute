#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${E2E_DIR}/.artifacts"
STATE_FILE="${ARTIFACTS_DIR}/local_macos_nomad_tunnel.env"
LOG_FILE="${ARTIFACTS_DIR}/local_macos_nomad_tunnel.log"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

cleanup_managed_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    return 0
  fi

  # shellcheck disable=SC1090
  source "${STATE_FILE}"

  if [[ -n "${tunnel_pid:-}" ]] && kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
    kill "${tunnel_pid}" >/dev/null 2>&1 || true

    local wait_attempt=1
    while [[ ${wait_attempt} -le 10 ]]; do
      if ! kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
        break
      fi

      sleep 1
      wait_attempt=$((wait_attempt + 1))
    done

    if kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
      kill -9 "${tunnel_pid}" >/dev/null 2>&1 || true
    fi
  fi

  if [[ "${alias_added:-0}" == "1" ]] && [[ -n "${private_ip:-}" ]]; then
    if ifconfig lo0 | grep -F "inet ${private_ip} " >/dev/null 2>&1; then
      sudo ifconfig lo0 -alias "${private_ip}" >/dev/null 2>&1 || true
    fi
  fi

  rm -f "${STATE_FILE}"
}

require_command "ssh" "Install OpenSSH client and ensure it is on PATH."
require_command "sudo" "Install/configure sudo for local macOS tunnel setup."
require_command "ifconfig" "macOS ifconfig is required for local loopback alias management."
require_command "terraform" "Install Terraform and ensure it is on PATH."
require_command "jq" "Install jq and ensure it is on PATH."

if [[ "$(uname -s)" != "Darwin" ]]; then
  log_info "Skipping local macOS Nomad tunnel setup because this host is not macOS."
  exit 0
fi

ensure_artifacts_dir "${ARTIFACTS_DIR}"

if ! ensure_tf_outputs_json; then
  log_error "Failed to retrieve Terraform outputs from ${E2E_DIR}. Ensure terraform apply completed successfully."
  exit 1
fi

deploy_local_macos_client="$(tf_output_with_default "deploy_local_macos_client" "false")"
local_macos_connection="$(tf_output_with_default "local_macos_connection" "local")"
deploy_nomad_server="$(tf_output_with_default "deploy_nomad_server" "false")"

if [[ "${deploy_local_macos_client}" != "true" ]]; then
  log_info "Skipping local macOS Nomad tunnel setup because deploy_local_macos_client is false."
  exit 0
fi

if [[ "${local_macos_connection}" != "local" ]]; then
  log_info "Skipping local macOS Nomad tunnel setup because local_macos_connection=${local_macos_connection}."
  exit 0
fi

if [[ "${deploy_nomad_server}" != "true" ]]; then
  log_info "Skipping local macOS Nomad tunnel setup because deploy_nomad_server is false."
  exit 0
fi

private_ip="$(tf_output_optional "nomad_server_private_ip")"
public_ip="$(tf_output_optional "nomad_server_public_ip")"
ssh_user="$(tf_output_with_default "linux_ssh_user" "ec2-user")"
key_file="${ARTIFACTS_DIR}/e2e_rsa.pem"

if [[ -z "${private_ip}" || "${private_ip}" == "null" ]]; then
  log_error "Unable to determine nomad_server_private_ip from Terraform outputs."
  exit 1
fi

if [[ -z "${public_ip}" || "${public_ip}" == "null" ]]; then
  log_error "Unable to determine nomad_server_public_ip from Terraform outputs."
  exit 1
fi

require_file "${key_file}" "E2E SSH private key"

if port_open "${private_ip}" 4647 3; then
  log_info "Nomad RPC is already reachable at ${private_ip}:4647; no local tunnel setup is required."
  exit 0
fi

if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"

  if [[ "${managed_private_ip:-}" == "${private_ip}" ]] \
    && [[ -n "${tunnel_pid:-}" ]] \
    && kill -0 "${tunnel_pid}" >/dev/null 2>&1 \
    && port_open "${private_ip}" 4647 3; then
    log_info "Existing managed local macOS Nomad tunnel is healthy for ${private_ip}:4647."
    exit 0
  fi

  log_warn "Found stale local macOS Nomad tunnel state; cleaning it up before recreating the tunnel."
  cleanup_managed_state
fi

alias_added=0
if ! ifconfig lo0 | grep -F "inet ${private_ip} " >/dev/null 2>&1; then
  log_info "Adding loopback alias ${private_ip}/32 on lo0 for local Nomad RPC forwarding."
  sudo ifconfig lo0 alias "${private_ip}" 255.255.255.255
  alias_added=1
else
  log_info "Loopback alias ${private_ip} already exists on lo0."
fi

log_info "Starting SSH tunnel from ${private_ip}:4647 to ${private_ip}:4647 via ${ssh_user}@${public_ip}."
ssh \
  -N \
  -i "${key_file}" \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o LogLevel=ERROR \
  -L "${private_ip}:4647:${private_ip}:4647" \
  "${ssh_user}@${public_ip}" >>"${LOG_FILE}" 2>&1 &
tunnel_pid=$!

cleanup_on_failure() {
  if kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
    kill "${tunnel_pid}" >/dev/null 2>&1 || true
  fi

  if [[ "${alias_added}" == "1" ]] && ifconfig lo0 | grep -F "inet ${private_ip} " >/dev/null 2>&1; then
    sudo ifconfig lo0 -alias "${private_ip}" >/dev/null 2>&1 || true
  fi
}

if ! wait_for_port_open "${private_ip}" 4647 15 1 3; then
  cleanup_on_failure
  log_error "Timed out waiting for the local macOS Nomad tunnel to expose ${private_ip}:4647."
  log_error "Inspect ${LOG_FILE} for SSH tunnel diagnostics."
  exit 1
fi

cat >"${STATE_FILE}" <<EOF
managed_private_ip="${private_ip}"
managed_public_ip="${public_ip}"
managed_ssh_user="${ssh_user}"
managed_key_file="${key_file}"
private_ip="${private_ip}"
alias_added="${alias_added}"
tunnel_pid="${tunnel_pid}"
log_file="${LOG_FILE}"
EOF

log_info "Local macOS Nomad tunnel is ready at ${private_ip}:4647."
log_info "Use 'bash e2e_tests/scripts/cleanup_local_macos_nomad_tunnel.sh' when you are done."
