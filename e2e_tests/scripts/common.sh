#!/usr/bin/env bash

if [[ "${E2E_COMMON_SH_LOADED:-0}" == "1" ]]; then
  return 0
fi
E2E_COMMON_SH_LOADED="1"

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

require_command() {
  local command_name="$1"
  local guidance="${2:-}"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    log_error "${command_name} is required."
    if [[ -n "${guidance}" ]]; then
      echo "${guidance}" >&2
    fi
    exit 1
  fi
}

require_file() {
  local file_path="$1"
  local description="${2:-file}"

  if [[ -z "${file_path}" ]]; then
    log_error "${description} is required."
    exit 1
  fi

  if [[ ! -f "${file_path}" ]]; then
    log_error "${description} not found at ${file_path}."
    exit 1
  fi
}

ensure_artifacts_dir() {
  local artifacts_dir="$1"
  mkdir -p "${artifacts_dir}"
}

secure_write_file() {
  local destination_file="$1"
  local content="$2"
  local mode="${3:-600}"

  mkdir -p "$(dirname "${destination_file}")"
  printf '%s' "${content}" > "${destination_file}"
  chmod "${mode}" "${destination_file}"
}

port_open() {
  local host="$1"
  local port="$2"
  local timeout_seconds="${3:-5}"

  if nc -z -w "${timeout_seconds}" "${host}" "${port}" >/dev/null 2>&1; then
    return 0
  fi

  if nc -z "${host}" "${port}" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

ensure_tf_outputs_json() {
  if [[ -n "${TF_OUTPUTS_JSON:-}" ]]; then
    return 0
  fi

  require_command "terraform" "Install Terraform and ensure it is on PATH."
  require_command "jq" "Install jq and ensure it is on PATH."

  if [[ -z "${E2E_DIR:-}" ]]; then
    log_error "E2E_DIR is not set."
    exit 1
  fi

  if ! TF_OUTPUTS_JSON="$(terraform -chdir="${E2E_DIR}" output -json 2>/dev/null)"; then
    TF_OUTPUTS_JSON=""
    return 1
  fi

  return 0
}

tf_output_optional() {
  local output_name="$1"

  if ! ensure_tf_outputs_json; then
    return 0
  fi

  jq -r --arg name "${output_name}" '
    if has($name) then
      .[$name].value
      | if . == null then "null"
        elif type == "string" then .
        else tostring
        end
    else
      empty
    end
  ' <<<"${TF_OUTPUTS_JSON}"
}

tf_output_with_default() {
  local output_name="$1"
  local default_value="$2"
  local output_value

  output_value="$(tf_output_optional "${output_name}")"

  if [[ -z "${output_value}" ]]; then
    printf '%s\n' "${default_value}"
    return 0
  fi

  printf '%s\n' "${output_value}"
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
  max_attempts="${E2E_WINDOWS_WAIT_MAX_ATTEMPTS:-10}"
  local sleep_seconds
  sleep_seconds="${E2E_WINDOWS_WAIT_SLEEP_SECONDS:-10}"
  local attempt
  attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if windows_winrm_https_ready "${windows_ip}"; then
      log_info "Windows WinRM is reachable at https://${windows_ip}:5986/wsman."
      return 0
    fi

    local tcp_state
    tcp_state="closed"
    if port_open "${windows_ip}" 5986 5; then
      tcp_state="open"
    fi

    log_info "Waiting for Windows WinRM readiness (${attempt}/${max_attempts}) at https://${windows_ip}:5986/wsman (TCP 5986 ${tcp_state})..."
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done

  log_error "Timed out waiting for Windows WinRM readiness at https://${windows_ip}:5986/wsman."
  return 1
}

ssh_tcp_ready() {
  local host_ip="$1"
  port_open "${host_ip}" 22 5
}

wait_for_ssh_ready() {
  local host_ip="$1"
  local host_label="$2"

  local max_attempts
  max_attempts="${E2E_SSH_WAIT_MAX_ATTEMPTS:-10}"
  local sleep_seconds
  sleep_seconds="${E2E_SSH_WAIT_SLEEP_SECONDS:-10}"
  local attempt
  attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if ssh_tcp_ready "${host_ip}"; then
      log_info "${host_label} SSH is reachable at ${host_ip}:22."
      return 0
    fi

    log_info "Waiting for ${host_label} SSH readiness (${attempt}/${max_attempts}) at ${host_ip}:22..."
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done

  log_error "Timed out waiting for ${host_label} SSH readiness at ${host_ip}:22."
  return 1
}

wait_for_nomad_server_ready() {
  local artifacts_dir="$1"
  local nomad_ca_cert_file="${artifacts_dir}/nomad-agent-ca.pem"
  local nomad_client_cert_file="${artifacts_dir}/global-cli-nomad.pem"
  local nomad_client_key_file="${artifacts_dir}/global-cli-nomad-key.pem"

  local deploy_nomad_server
  deploy_nomad_server="$(tf_output_with_default "deploy_nomad_server" "false")"

  if [[ "${deploy_nomad_server}" != "true" ]]; then
    return 0
  fi

  local nomad_server_public_ip
  nomad_server_public_ip="$(tf_output_optional "nomad_server_public_ip")"

  if [[ -z "${nomad_server_public_ip}" || "${nomad_server_public_ip}" == "null" ]]; then
    log_error "Unable to determine nomad_server_public_ip for readiness check."
    return 1
  fi

  local nomad_tls_enabled
  nomad_tls_enabled="$(tf_output_with_default "nomad_tls_enabled" "false")"

  local nomad_addr
  if [[ "${nomad_tls_enabled}" == "true" ]]; then
    nomad_addr="https://${nomad_server_public_ip}:4646"
  else
    nomad_addr="http://${nomad_server_public_ip}:4646"
  fi

  if [[ "${nomad_tls_enabled}" == "true" ]]; then
    secure_write_file "${nomad_ca_cert_file}" "$(tf_output_optional "nomad_tls_ca_pem")" 644
    secure_write_file "${nomad_client_cert_file}" "$(tf_output_optional "nomad_tls_client_cert_pem")" 644
    secure_write_file "${nomad_client_key_file}" "$(tf_output_optional "nomad_tls_client_key_pem")" 600
  fi

  local max_attempts
  max_attempts="${E2E_NOMAD_WAIT_MAX_ATTEMPTS:-10}"
  local sleep_seconds
  sleep_seconds="${E2E_NOMAD_WAIT_SLEEP_SECONDS:-10}"
  local attempt
  attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    local leader
    local curl_args
    curl_args=(--silent --show-error --max-time 5)
    if [[ "${nomad_tls_enabled}" == "true" ]]; then
      curl_args+=(--cacert "${nomad_ca_cert_file}" --cert "${nomad_client_cert_file}" --key "${nomad_client_key_file}")
    fi

    leader="$(curl "${curl_args[@]}" "${nomad_addr}/v1/status/leader" || true)"
    if [[ -n "${leader}" && "${leader}" != '""' ]]; then
      log_info "Nomad server is ready at ${nomad_addr} (leader: ${leader})."
      return 0
    fi

    log_info "Waiting for Nomad server API readiness (${attempt}/${max_attempts}) at ${nomad_addr}..."
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done

  log_error "Timed out waiting for Nomad server readiness at ${nomad_addr}."
  return 1
}
