#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${E2E_DIR}/.artifacts"
TOKEN_FILE="${ARTIFACTS_DIR}/nomad_management_token.txt"
NOMAD_CA_CERT_FILE="${ARTIFACTS_DIR}/nomad-agent-ca.pem"
NOMAD_CLIENT_CERT_FILE="${ARTIFACTS_DIR}/global-cli-nomad.pem"
NOMAD_CLIENT_KEY_FILE="${ARTIFACTS_DIR}/global-cli-nomad-key.pem"

mkdir -p "${ARTIFACTS_DIR}"

NOMAD_ADDR_INPUT="${1:-${NOMAD_ADDR:-}}"
if [[ -z "${NOMAD_ADDR_INPUT}" ]]; then
  deploy_nomad_server="$(terraform -chdir="${E2E_DIR}" output -raw deploy_nomad_server 2>/dev/null || echo "false")"

  if [[ "${deploy_nomad_server}" == "true" ]]; then
    nomad_server_public_ip="$(terraform -chdir="${E2E_DIR}" output -raw nomad_server_public_ip 2>/dev/null || true)"
    if [[ -n "${nomad_server_public_ip}" && "${nomad_server_public_ip}" != "null" ]]; then
      nomad_tls_enabled="$(terraform -chdir="${E2E_DIR}" output -raw nomad_tls_enabled 2>/dev/null || echo "false")"
      if [[ "${nomad_tls_enabled}" == "true" ]]; then
        NOMAD_ADDR_INPUT="https://${nomad_server_public_ip}:4646"
      else
        NOMAD_ADDR_INPUT="http://${nomad_server_public_ip}:4646"
      fi
    fi
  fi

  if [[ -z "${NOMAD_ADDR_INPUT}" ]]; then
    NOMAD_ADDR_INPUT="$(terraform -chdir="${E2E_DIR}" output -raw nomad_addr || true)"
  fi
fi

if [[ -z "${NOMAD_ADDR_INPUT}" ]]; then
  echo "No Nomad address provided. Use NOMAD_ADDR or pass as first argument." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for bootstrap_acl.sh" >&2
  exit 1
fi

curl_args=(--fail --silent --show-error --request POST)
if [[ -f "${NOMAD_CA_CERT_FILE}" && -f "${NOMAD_CLIENT_CERT_FILE}" && -f "${NOMAD_CLIENT_KEY_FILE}" ]]; then
  curl_args+=(--cacert "${NOMAD_CA_CERT_FILE}" --cert "${NOMAD_CLIENT_CERT_FILE}" --key "${NOMAD_CLIENT_KEY_FILE}")
fi

bootstrap_response="$(curl "${curl_args[@]}" "${NOMAD_ADDR_INPUT%/}/v1/acl/bootstrap")"
secret_id="$(echo "${bootstrap_response}" | jq -r '.SecretID // empty')"

if [[ -z "${secret_id}" ]]; then
  echo "Failed to parse SecretID from bootstrap response:" >&2
  echo "${bootstrap_response}" >&2
  exit 1
fi

printf "%s" "${secret_id}" > "${TOKEN_FILE}"
echo "Wrote Nomad management token to ${TOKEN_FILE}"
