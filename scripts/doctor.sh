#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
DOCKER_BIN="${DOCKER_BIN:-}"
COMPOSE_CMD=()
COMPOSE_CMD_DISPLAY=""
FIX_ENV=0

usage() {
  cat <<'USAGE'
Usage: scripts/doctor.sh [--env-file PATH] [--fix-env]

Checks:
  - docker and compose availability (`docker compose` or `docker-compose`)
  - required env values
  - COMMON_PATH write access
  - docker compose config validation

Environment:
  DOCKER_BIN          Override the docker binary path.
  DOCKER_COMPOSE_BIN  Override the docker-compose binary path.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

resolve_docker_bin() {
  if [[ -n "${DOCKER_BIN:-}" ]]; then
    [[ -x "${DOCKER_BIN}" ]] || fail "DOCKER_BIN is not executable: ${DOCKER_BIN}"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    DOCKER_BIN="$(command -v docker)"
    return 0
  fi

  return 1
}

detect_compose_command() {
  if [[ -n "${DOCKER_COMPOSE_BIN:-}" ]]; then
    [[ -x "${DOCKER_COMPOSE_BIN}" ]] || fail "DOCKER_COMPOSE_BIN is not executable: ${DOCKER_COMPOSE_BIN}"
    COMPOSE_CMD=("${DOCKER_COMPOSE_BIN}")
    COMPOSE_CMD_DISPLAY="${DOCKER_COMPOSE_BIN}"
    return
  fi

  if resolve_docker_bin && "${DOCKER_BIN}" compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("${DOCKER_BIN}" compose)
    COMPOSE_CMD_DISPLAY="${DOCKER_BIN} compose"
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=("$(command -v docker-compose)")
    COMPOSE_CMD_DISPLAY="${COMPOSE_CMD[0]}"
    return
  fi

  fail "Docker Compose is not available. Set DOCKER_COMPOSE_BIN, or install docker compose/docker-compose."
}

run_compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

env_file_has_crlf() {
  local env_path="$1"
  LC_ALL=C grep -q $'\r' "${env_path}"
}

normalize_env_file_line_endings() {
  local env_path="$1"
  local tmp_file

  tmp_file="$(mktemp "${env_path}.tmp.XXXXXX")"

  if [[ -z "${tmp_file}" ]]; then
    fail "Failed to create temp file for ${env_path}."
  fi

  if ! tr -d '\r' < "${env_path}" > "${tmp_file}"; then
    rm -f "${tmp_file}"
    fail "Failed to normalize line endings in ${env_path}."
  fi

  if ! mv "${tmp_file}" "${env_path}"; then
    rm -f "${tmp_file}"
    fail "Failed to replace ${env_path} after line ending normalization."
  fi

  warn "Detected Windows line endings in ${env_path}; converted to Unix LF."
}

env_file_permissions_are_restricted() {
  local env_path="$1"

  [[ -f "${env_path}" ]] || return 0

  if [[ "$(uname -s 2>/dev/null)" =~ ^(MINGW|MSYS|CYGWIN) ]]; then
    return 0
  fi

  local mode
  mode="$(stat -c '%a' "${env_path}" 2>/dev/null || true)"
  [[ -n "${mode}" ]] || return 0
  [[ "${mode}" == "600" ]]
}

ensure_env_file_permissions() {
  local env_path="$1"

  if chmod 600 "${env_path}" 2>/dev/null; then
    return 0
  fi

  warn "Failed to restrict permissions on ${env_path}; secure it manually."
}

resolve_path() {
  local path_value="$1"
  if [[ "${path_value}" = /* ]]; then
    printf '%s' "${path_value}"
  else
    printf '%s' "${REPO_ROOT}/${path_value}"
  fi
}

validate_port() {
  local key="$1"
  local value="${!key:-}"

  [[ -n "${value}" ]] || return 0
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "${key} must be a numeric port: ${value}"
  (( value >= 1 && value <= 65535 )) || fail "${key} must be between 1 and 65535: ${value}"
}

validate_http_url() {
  local key="$1"
  local value="${!key:-}"

  [[ -n "${value}" ]] || return 0
  [[ "${value}" =~ ^https?://[^[:space:]]+$ ]] || fail "${key} must start with http:// or https:// and contain no spaces: ${value}"
}

prepare_env_file() {
  local env_path="$1"

  if env_file_has_crlf "${env_path}"; then
    if [[ "${FIX_ENV}" -eq 1 ]]; then
      normalize_env_file_line_endings "${env_path}"
    else
      warn "Detected Windows line endings in ${env_path}; rerun with --fix-env to convert to Unix LF."
    fi
  fi

  if ! env_file_permissions_are_restricted "${env_path}"; then
    if [[ "${FIX_ENV}" -eq 1 ]]; then
      ensure_env_file_permissions "${env_path}"
    else
      warn "${env_path} permissions are broader than 600; rerun with --fix-env to tighten them when supported."
    fi
  fi

  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        fail "--env-file requires a path."
      fi
      ENV_FILE="$2"
      shift 2
      ;;
    --fix-env)
      FIX_ENV=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${ENV_FILE}" != /* ]]; then
  ENV_FILE="${REPO_ROOT}/${ENV_FILE}"
fi

detect_compose_command

if [[ ! -f "${ENV_FILE}" ]]; then
  fail "Missing env file: ${ENV_FILE}"
fi

prepare_env_file "${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

required=(
  COMMON_PATH
  TZ
  PUID
  PGID
  WIREGUARD_ADDRESSES
  WIREGUARD_PRIVATE_KEY
  WIREGUARD_PUBLIC_KEY
  WIREGUARD_ENDPOINT
  WIREGUARD_ALLOWED_IPS
)

missing=0
for key in "${required[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    echo "ERROR: ${key} is missing in ${ENV_FILE}" >&2
    missing=1
  fi
done

if [[ "${missing}" -ne 0 ]]; then
  exit 1
fi

validate_port "NGINX_PORT"
validate_port "JELLYSEERR_PORT"
validate_http_url "JELLYSEERR_EXTERNAL_URL"

common_path_abs="$(resolve_path "${COMMON_PATH}")"
if [[ -e "${common_path_abs}" ]]; then
  if [[ ! -w "${common_path_abs}" ]]; then
    fail "COMMON_PATH is not writable: ${common_path_abs}"
  fi
else
  parent_dir="$(dirname "${common_path_abs}")"
  if [[ ! -w "${parent_dir}" ]]; then
    fail "Cannot create COMMON_PATH under: ${parent_dir}"
  fi
fi

(
  cd "${REPO_ROOT}"
  run_compose --env-file "${ENV_FILE}" config > /dev/null
)

echo "Doctor checks passed (${COMPOSE_CMD_DISPLAY})."
