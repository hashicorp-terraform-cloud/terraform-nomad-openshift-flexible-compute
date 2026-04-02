#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${E2E_DIR}/.artifacts"
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

ensure_tf_outputs_json || true

NOMAD_ADDR_INPUT="${1:-${NOMAD_ADDR:-}}"
if [[ -z "${NOMAD_ADDR_INPUT}" ]]; then
  deploy_nomad_server="$(tf_output_with_default "deploy_nomad_server" "false")"

  if [[ "${deploy_nomad_server}" == "true" ]]; then
    nomad_server_public_ip="$(tf_output_optional "nomad_server_public_ip")"
    if [[ -n "${nomad_server_public_ip}" && "${nomad_server_public_ip}" != "null" ]]; then
      nomad_tls_enabled="$(tf_output_with_default "nomad_tls_enabled" "false")"
      if [[ "${nomad_tls_enabled}" == "true" ]]; then
        NOMAD_ADDR_INPUT="https://${nomad_server_public_ip}:4646"
      else
        NOMAD_ADDR_INPUT="http://${nomad_server_public_ip}:4646"
      fi
    fi
  fi

  if [[ -z "${NOMAD_ADDR_INPUT}" ]]; then
    NOMAD_ADDR_INPUT="$(tf_output_optional "nomad_addr")"
  fi
fi

if [[ -z "${NOMAD_ADDR_INPUT}" ]]; then
  echo "No Nomad address provided. Use NOMAD_ADDR or pass as first argument." >&2
  exit 1
fi

curl_args=(--silent --show-error --request POST)
if [[ -f "${NOMAD_CA_CERT_FILE}" && -f "${NOMAD_CLIENT_CERT_FILE}" && -f "${NOMAD_CLIENT_KEY_FILE}" ]]; then
  curl_args+=(--cacert "${NOMAD_CA_CERT_FILE}" --cert "${NOMAD_CLIENT_CERT_FILE}" --key "${NOMAD_CLIENT_KEY_FILE}")
fi

configured_intro_token="$(tf_output_optional "client_introduction_token")"
configured_intro_token="${configured_intro_token//[$'\r\n']/}"

secret_id=""

if [[ -s "${TOKEN_FILE}" ]]; then
  secret_id="$(cat "${TOKEN_FILE}")"
  echo "Reusing Nomad management token from ${TOKEN_FILE}."
elif [[ -n "${NOMAD_TOKEN:-}" ]]; then
  secret_id="${NOMAD_TOKEN}"
  printf "%s" "${secret_id}" > "${TOKEN_FILE}"
  echo "Persisted NOMAD_TOKEN from environment to ${TOKEN_FILE}."
else
  set +e
  bootstrap_response="$(curl "${curl_args[@]}" "${NOMAD_ADDR_INPUT%/}/v1/acl/bootstrap" 2>&1)"
  bootstrap_exit_code=$?
  set -e

  if [[ ${bootstrap_exit_code} -ne 0 ]]; then
    echo "Failed to bootstrap ACLs at ${NOMAD_ADDR_INPUT%/}/v1/acl/bootstrap:" >&2
    echo "curl exited with status ${bootstrap_exit_code}. Response details were suppressed to avoid leaking sensitive content." >&2
    echo "If ACLs were already bootstrapped, set NOMAD_TOKEN or create ${TOKEN_FILE} and retry." >&2
    exit 1
  fi

  secret_id="$(echo "${bootstrap_response}" | jq -r '.SecretID // empty')"
fi

if [[ -z "${secret_id}" ]]; then
  echo "No management token is available for intro token generation." >&2
  exit 1
fi

printf "%s" "${secret_id}" > "${TOKEN_FILE}"
echo "Wrote Nomad management token to ${TOKEN_FILE}"

if [[ -n "${configured_intro_token}" ]]; then
  rm -f "${INTRO_TOKEN_FILE}"
  echo "Skipping intro token generation because Terraform input client_introduction_token is set."
  exit 0
fi

if [[ -s "${INTRO_TOKEN_FILE}" ]]; then
  echo "Reusing existing generated intro token at ${INTRO_TOKEN_FILE}."
  exit 0
fi

if ! command -v nomad >/dev/null 2>&1; then
  echo "nomad CLI is required to auto-generate a client introduction token." >&2
  echo "Install nomad locally, or set client_introduction_token in e2e_tests/terraform.tfvars." >&2
  exit 1
fi

nomad_cli_env=(
  "NOMAD_ADDR=${NOMAD_ADDR_INPUT}"
  "NOMAD_TOKEN=${secret_id}"
)

if [[ -f "${NOMAD_CA_CERT_FILE}" && -f "${NOMAD_CLIENT_CERT_FILE}" && -f "${NOMAD_CLIENT_KEY_FILE}" ]]; then
  nomad_cli_env+=(
    "NOMAD_CACERT=${NOMAD_CA_CERT_FILE}"
    "NOMAD_CLIENT_CERT=${NOMAD_CLIENT_CERT_FILE}"
    "NOMAD_CLIENT_KEY=${NOMAD_CLIENT_KEY_FILE}"
  )
fi

intro_token_json="$(env "${nomad_cli_env[@]}" nomad node intro create -json)"
intro_token="$(echo "${intro_token_json}" | jq -r '.JWT // empty')"

if [[ -z "${intro_token}" ]]; then
  echo "Failed to parse generated client introduction token from nomad CLI response." >&2
  echo "${intro_token_json}" >&2
  exit 1
fi

printf "%s" "${intro_token}" > "${INTRO_TOKEN_FILE}"
echo "Wrote Nomad client introduction token to ${INTRO_TOKEN_FILE}"
