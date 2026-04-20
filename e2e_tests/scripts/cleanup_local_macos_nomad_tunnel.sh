#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${E2E_DIR}/.artifacts"
STATE_FILE="${ARTIFACTS_DIR}/local_macos_nomad_tunnel.env"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

require_command "sudo" "Install/configure sudo for local macOS tunnel cleanup."
require_command "ifconfig" "macOS ifconfig is required for local loopback alias management."

if [[ "$(uname -s)" != "Darwin" ]]; then
  log_info "Skipping local macOS Nomad tunnel cleanup because this host is not macOS."
  exit 0
fi

if [[ ! -f "${STATE_FILE}" ]]; then
  log_info "No managed local macOS Nomad tunnel state found at ${STATE_FILE}; nothing to clean up."
  exit 0
fi

# shellcheck disable=SC1090
source "${STATE_FILE}"

if [[ -n "${tunnel_pid:-}" ]] && kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
  log_info "Stopping managed SSH tunnel process ${tunnel_pid}."
  kill "${tunnel_pid}" >/dev/null 2>&1 || true

  wait_attempt=1
  while [[ ${wait_attempt} -le 10 ]]; do
    if ! kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
      break
    fi

    sleep 1
    wait_attempt=$((wait_attempt + 1))
  done

  if kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
    log_warn "SSH tunnel process ${tunnel_pid} did not exit cleanly; forcing termination."
    kill -9 "${tunnel_pid}" >/dev/null 2>&1 || true
  fi
else
  log_info "Managed SSH tunnel process is already stopped."
fi

if [[ "${alias_added:-0}" == "1" ]] && [[ -n "${private_ip:-}" ]]; then
  if ifconfig lo0 | grep -F "inet ${private_ip} " >/dev/null 2>&1; then
    log_info "Removing loopback alias ${private_ip} from lo0."
    sudo ifconfig lo0 -alias "${private_ip}"
  else
    log_info "Loopback alias ${private_ip} is already absent from lo0."
  fi
fi

rm -f "${STATE_FILE}"
log_info "Local macOS Nomad tunnel cleanup is complete."
