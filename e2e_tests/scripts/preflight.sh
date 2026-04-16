#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

check_python_module() {
  local python_executable="$1"
  local module_name="$2"
  local install_hint="$3"

  if ! "${python_executable}" -c "import ${module_name}" >/dev/null 2>&1; then
    echo "Missing Python module '${module_name}' required by Ansible WinRM connection." >&2
    echo "Ansible interpreter: ${python_executable}" >&2
    echo "Install it in the Python environment used by Ansible, e.g.: ${install_hint}" >&2
    exit 1
  fi
}

detect_ansible_python() {
  local ansible_version_output
  if ! ansible_version_output="$(ansible --version 2>/dev/null)"; then
    log_error "Failed to run 'ansible --version'."
    log_error "Ensure Ansible is correctly installed and available on PATH."
    exit 1
  fi

  local ansible_python
  ansible_python="$(sed -nE 's/.*\((\/[^)]*python[^)]*)\).*/\1/p' <<<"${ansible_version_output}" | tail -n 1)"

  if [[ -n "${ansible_python}" && -x "${ansible_python}" ]]; then
    printf '%s\n' "${ansible_python}"
    return 0
  fi

  log_warn "Could not detect Ansible Python interpreter from 'ansible --version'; defaulting to python3."

  printf '%s\n' "python3"
}

require_command "ansible" "Install Ansible and ensure it is on PATH."
require_command "ansible-playbook" "Install Ansible and ensure it is on PATH."
require_command "python3" "Install Python 3 and ensure it is on PATH."

ansible_python_executable="$(detect_ansible_python)"

check_python_module "${ansible_python_executable}" "winrm" "${ansible_python_executable} -m pip install pywinrm"
check_python_module "${ansible_python_executable}" "requests" "${ansible_python_executable} -m pip install requests"
check_python_module "${ansible_python_executable}" "requests_ntlm" "${ansible_python_executable} -m pip install requests-ntlm"
check_python_module "${ansible_python_executable}" "spnego" "${ansible_python_executable} -m pip install pyspnego"

require_command "terraform" "Install Terraform and ensure it is on PATH."
require_command "jq" "Install jq and ensure it is on PATH."

if ! ensure_tf_outputs_json; then
  log_error "Failed to retrieve Terraform outputs from ${E2E_DIR}. Ensure terraform apply completed successfully."
  exit 1
fi

deploy_local_macos_client="$(tf_output_with_default "deploy_local_macos_client" "false")"
local_macos_connection="$(tf_output_with_default "local_macos_connection" "local")"
deploy_nomad_server="$(tf_output_with_default "deploy_nomad_server" "false")"

if [[ "${deploy_local_macos_client}" == "true" ]]; then
  log_warn "Local macOS E2E target mode is enabled."
  log_warn "Install/remove playbooks will modify local Nomad files and service state."

  if [[ "${E2E_ALLOW_LOCAL_MACOS_DESTRUCTIVE:-}" != "true" ]]; then
    log_warn "Proceeding because deploy_local_macos_client=true is already an explicit opt-in in Terraform inputs."
    log_warn "Set E2E_ALLOW_LOCAL_MACOS_DESTRUCTIVE=true to silence this warning in automated runs."
  fi

  if [[ "${local_macos_connection}" == "local" ]]; then
    require_command "sudo" "Install/configure sudo for local macOS E2E execution."

    if ! sudo -n true >/dev/null 2>&1; then
      log_warn "Local macOS mode needs elevated privileges. Attempting to refresh sudo credentials."
      log_warn "You may be prompted for your password once before playbook execution."

      if ! sudo -v; then
        log_error "Failed to acquire sudo credentials for local macOS execution."
        log_error "Ensure your user can run sudo, then retry."
        exit 1
      fi

      if ! sudo -n true >/dev/null 2>&1; then
        log_error "Sudo credential refresh succeeded, but non-interactive sudo is still unavailable."
        log_error "Adjust sudo policy or use local_macos_connection=ssh."
        exit 1
      fi
    fi

    if [[ "${deploy_nomad_server}" == "true" ]]; then
      nomad_server_private_ip="$(tf_output_optional "nomad_server_private_ip")"

      if [[ -n "${nomad_server_private_ip}" && "${nomad_server_private_ip}" != "null" ]]; then
        if ! port_open "${nomad_server_private_ip}" 4647 3; then
          log_error "Local macOS cannot currently reach Nomad RPC at ${nomad_server_private_ip}:4647."
          log_error "Run 'bash e2e_tests/scripts/setup_local_macos_nomad_tunnel.sh' (or 'make e2e-setup-local-macos-tunnel') first,"
          log_error "or switch to local_macos_connection=ssh if you want to avoid local tunnel management."
          exit 1
        fi
      fi
    fi
  fi
fi
