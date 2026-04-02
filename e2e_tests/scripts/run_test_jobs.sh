#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${E2E_DIR}/.artifacts"
TOKEN_FILE="${ARTIFACTS_DIR}/nomad_management_token.txt"
NOMAD_CA_CERT_FILE="${ARTIFACTS_DIR}/nomad-agent-ca.pem"
NOMAD_CLIENT_CERT_FILE="${ARTIFACTS_DIR}/global-cli-nomad.pem"
NOMAD_CLIENT_KEY_FILE="${ARTIFACTS_DIR}/global-cli-nomad-key.pem"

require_command() {
  local command_name="$1"
  local guidance="$2"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "${command_name} is required for E2E test job submission." >&2
    if [[ -n "${guidance}" ]]; then
      echo "${guidance}" >&2
    fi
    exit 1
  fi
}

resolve_nomad_addr() {
  local nomad_addr_input
  nomad_addr_input="${1:-${NOMAD_ADDR:-}}"

  if [[ -z "${nomad_addr_input}" ]]; then
    local deploy_nomad_server
    deploy_nomad_server="$(terraform -chdir="${E2E_DIR}" output -raw deploy_nomad_server 2>/dev/null || echo "false")"

    if [[ "${deploy_nomad_server}" == "true" ]]; then
      local nomad_server_public_ip
      nomad_server_public_ip="$(terraform -chdir="${E2E_DIR}" output -raw nomad_server_public_ip 2>/dev/null || true)"
      if [[ -n "${nomad_server_public_ip}" && "${nomad_server_public_ip}" != "null" ]]; then
        local nomad_tls_enabled
        nomad_tls_enabled="$(terraform -chdir="${E2E_DIR}" output -raw nomad_tls_enabled 2>/dev/null || echo "false")"
        if [[ "${nomad_tls_enabled}" == "true" ]]; then
          nomad_addr_input="https://${nomad_server_public_ip}:4646"
        else
          nomad_addr_input="http://${nomad_server_public_ip}:4646"
        fi
      fi
    fi

    if [[ -z "${nomad_addr_input}" ]]; then
      nomad_addr_input="$(terraform -chdir="${E2E_DIR}" output -raw nomad_addr 2>/dev/null || true)"
    fi
  fi

  if [[ -z "${nomad_addr_input}" || "${nomad_addr_input}" == "null" ]]; then
    echo "No Nomad address provided. Use NOMAD_ADDR or pass as first argument." >&2
    exit 1
  fi

  if [[ "${nomad_addr_input}" != http://* && "${nomad_addr_input}" != https://* ]]; then
    nomad_addr_input="http://${nomad_addr_input}"
  fi

  printf '%s\n' "${nomad_addr_input%/}"
}

build_curl_args() {
  local nomad_token="$1"
  local nomad_tls_enabled
  nomad_tls_enabled="$(terraform -chdir="${E2E_DIR}" output -raw nomad_tls_enabled 2>/dev/null || echo "false")"

  CURL_ARGS=(--fail --silent --show-error)
  if [[ -n "${nomad_token}" ]]; then
    CURL_ARGS+=(--header "X-Nomad-Token: ${nomad_token}")
  fi
  if [[ "${nomad_tls_enabled}" == "true" ]]; then
    if [[ ! -f "${NOMAD_CA_CERT_FILE}" ]]; then
      terraform -chdir="${E2E_DIR}" output -raw nomad_tls_ca_pem > "${NOMAD_CA_CERT_FILE}"
    fi
    if [[ ! -f "${NOMAD_CLIENT_CERT_FILE}" ]]; then
      terraform -chdir="${E2E_DIR}" output -raw nomad_tls_client_cert_pem > "${NOMAD_CLIENT_CERT_FILE}"
    fi
    if [[ ! -f "${NOMAD_CLIENT_KEY_FILE}" ]]; then
      terraform -chdir="${E2E_DIR}" output -raw nomad_tls_client_key_pem > "${NOMAD_CLIENT_KEY_FILE}"
      chmod 600 "${NOMAD_CLIENT_KEY_FILE}"
    fi
    CURL_ARGS+=(--cacert "${NOMAD_CA_CERT_FILE}" --cert "${NOMAD_CLIENT_CERT_FILE}" --key "${NOMAD_CLIENT_KEY_FILE}")
  fi
}

api_get_json() {
  local path="$1"
  curl "${CURL_ARGS[@]}" "${NOMAD_ADDR}${path}"
}

count_runnable_nodes() {
  local target_os="$1"
  local driver_name="$2"

  api_get_json "/v1/nodes" \
    | jq -r '.[].ID' \
    | while read -r node_id; do
      api_get_json "/v1/node/${node_id}"
    done \
    | jq -s --arg target_os "${target_os}" --arg driver_name "${driver_name}" '
      [
        .[]
        | select(
            .Status == "ready"
            and .SchedulingEligibility == "eligible"
            and ((.Drain // false) == false)
            and ((.Drivers[$driver_name].Detected // false) == true)
            and ((.Drivers[$driver_name].Healthy // false) == true)
            and (
              if $target_os == "windows"
              then ((.Attributes["kernel.name"] // "") | ascii_downcase) == "windows"
              else ((.Attributes["kernel.name"] // "") | ascii_downcase) != "windows"
              end
            )
          )
      ]
      | length
    '
}

submit_job() {
  local job_name="$1"
  local payload="$2"

  curl "${CURL_ARGS[@]}" \
    --request POST \
    --header "Content-Type: application/json" \
    --data "${payload}" \
    "${NOMAD_ADDR}/v1/jobs" >/dev/null

  echo "Submitted ${job_name} job."
}

wait_for_running_allocs() {
  local job_id="$1"
  local expected_count="$2"
  local max_attempts
  max_attempts="${E2E_TEST_JOB_WAIT_MAX_ATTEMPTS:-20}"
  local sleep_seconds
  sleep_seconds="${E2E_TEST_JOB_WAIT_SLEEP_SECONDS:-5}"
  local attempt
  attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    local running_allocs
    running_allocs="$({
      api_get_json "/v1/job/${job_id}/allocations" \
      | jq '[.[] | select(.ClientStatus == "running")] | length'
    } || echo 0)"

    if [[ "${running_allocs}" =~ ^[0-9]+$ ]] && [[ ${running_allocs} -ge ${expected_count} ]]; then
      echo "Job ${job_id} has ${running_allocs}/${expected_count} running allocations."
      return 0
    fi

    echo "Waiting for job ${job_id} allocations (${running_allocs}/${expected_count}) (${attempt}/${max_attempts})..."
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for job ${job_id} to reach ${expected_count} running allocations." >&2
  return 1
}

require_command "terraform" "Install Terraform and ensure it is on PATH."
require_command "curl" "Install curl and ensure it is on PATH."
require_command "jq" "Install jq and ensure it is on PATH."

mkdir -p "${ARTIFACTS_DIR}"

NOMAD_ADDR="$(resolve_nomad_addr "${1:-}")"
NOMAD_TOKEN="${2:-${NOMAD_TOKEN:-}}"
NOMAD_DATACENTER="$(terraform -chdir="${E2E_DIR}" output -raw nomad_datacenter 2>/dev/null || echo "dc1")"

if [[ -z "${NOMAD_TOKEN}" ]] && [[ -f "${TOKEN_FILE}" ]]; then
  NOMAD_TOKEN="$(cat "${TOKEN_FILE}")"
fi

build_curl_args "${NOMAD_TOKEN}"

linux_eligible_nodes="$(count_runnable_nodes "linux" "exec")"
windows_eligible_nodes="$(count_runnable_nodes "windows" "raw_exec")"

echo "Eligible Nomad clients -> linux-like(exec): ${linux_eligible_nodes}, windows(raw_exec): ${windows_eligible_nodes}"

if [[ "${linux_eligible_nodes}" =~ ^[0-9]+$ ]] && [[ ${linux_eligible_nodes} -gt 0 ]]; then
  read -r -d '' linux_job_payload <<JSON || true
{"Job":{"ID":"e2e-pre-remove-linux","Name":"e2e-pre-remove-linux","Type":"system","Datacenters":["${NOMAD_DATACENTER}"],"TaskGroups":[{"Name":"linux","Tasks":[{"Name":"sleep","Driver":"exec","Config":{"command":"/bin/sh","args":["-c","while true; do sleep 30; done"]},"Resources":{"CPU":100,"MemoryMB":64}}],"Constraints":[{"LTarget":"\${attr.kernel.name}","Operand":"!=","RTarget":"windows"}]}]}}
JSON

  submit_job "e2e-pre-remove-linux" "${linux_job_payload}"
  wait_for_running_allocs "e2e-pre-remove-linux" "${linux_eligible_nodes}"
else
  echo "Skipping Linux test job because no eligible non-Windows clients were found."
fi

if [[ "${windows_eligible_nodes}" =~ ^[0-9]+$ ]] && [[ ${windows_eligible_nodes} -gt 0 ]]; then
  read -r -d '' windows_job_payload <<JSON || true
{"Job":{"ID":"e2e-pre-remove-windows","Name":"e2e-pre-remove-windows","Type":"system","Datacenters":["${NOMAD_DATACENTER}"],"TaskGroups":[{"Name":"windows","Tasks":[{"Name":"sleep","Driver":"raw_exec","Config":{"command":"powershell.exe","args":["-NoProfile","-Command","while (\$true) { Start-Sleep -Seconds 30 }"]},"Resources":{"CPU":100,"MemoryMB":128}}],"Constraints":[{"LTarget":"\${attr.kernel.name}","Operand":"=","RTarget":"windows"}]}]}}
JSON

  submit_job "e2e-pre-remove-windows" "${windows_job_payload}"
  wait_for_running_allocs "e2e-pre-remove-windows" "${windows_eligible_nodes}"
else
  echo "Skipping Windows test job because no eligible Windows clients were found."
fi

echo "Pre-remove test jobs are submitted and running on eligible nodes."