#!/usr/bin/env bash
set -euo pipefail

require_command() {
  local command_name="$1"
  local guidance="$2"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "${command_name} is required for E2E execution." >&2
    if [[ -n "${guidance}" ]]; then
      echo "${guidance}" >&2
    fi
    exit 1
  fi
}

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
  local ansible_python
  ansible_python="$(ansible --version | sed -nE 's/.*\((\/[^)]*python[^)]*)\).*/\1/p' | tail -n 1)"

  if [[ -n "${ansible_python}" && -x "${ansible_python}" ]]; then
    printf '%s\n' "${ansible_python}"
    return 0
  fi

  printf '%s\n' "python3"
}

require_command "ansible-playbook" "Install Ansible and ensure it is on PATH."
require_command "python3" "Install Python 3 and ensure it is on PATH."

ansible_python_executable="$(detect_ansible_python)"

check_python_module "${ansible_python_executable}" "winrm" "${ansible_python_executable} -m pip install pywinrm"
check_python_module "${ansible_python_executable}" "requests" "${ansible_python_executable} -m pip install requests"
check_python_module "${ansible_python_executable}" "requests_ntlm" "${ansible_python_executable} -m pip install requests-ntlm"
check_python_module "${ansible_python_executable}" "spnego" "${ansible_python_executable} -m pip install pyspnego"
