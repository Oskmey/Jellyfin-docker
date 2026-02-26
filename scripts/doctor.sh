#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
COMPOSE_CMD=()
COMPOSE_CMD_DISPLAY=""

usage() {
  cat <<'USAGE'
Usage: scripts/doctor.sh [--env-file PATH]

Checks:
  - docker and compose availability (`docker compose` or `docker-compose`)
  - required env values
  - COMMON_PATH write access
  - docker compose config validation
USAGE
}

detect_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    COMPOSE_CMD_DISPLAY="docker compose"
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    COMPOSE_CMD_DISPLAY="docker-compose"
    return
  fi

  echo "ERROR: Docker Compose is not available. Install either the 'docker compose' plugin or the 'docker-compose' binary." >&2
  exit 1
}

run_compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

normalize_env_file_line_endings() {
  local env_path="$1"
  local tmp_file

  if LC_ALL=C grep -q $'\r' "${env_path}"; then
    tmp_file="$(mktemp "${env_path}.tmp.XXXXXX")"

    if [[ -z "${tmp_file}" ]]; then
      echo "ERROR: Failed to create temp file for ${env_path}." >&2
      exit 1
    fi

    if ! tr -d '\r' < "${env_path}" > "${tmp_file}"; then
      rm -f "${tmp_file}"
      echo "ERROR: Failed to normalize line endings in ${env_path}." >&2
      exit 1
    fi

    if ! mv "${tmp_file}" "${env_path}"; then
      rm -f "${tmp_file}"
      echo "ERROR: Failed to replace ${env_path} after line ending normalization." >&2
      exit 1
    fi

    echo "WARN: Detected Windows line endings in ${env_path}; converted to Unix LF." >&2
  fi
}

resolve_path() {
  local path_value="$1"
  if [[ "${path_value}" = /* ]]; then
    printf '%s' "${path_value}"
  else
    printf '%s' "${REPO_ROOT}/${path_value}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --env-file requires a path." >&2
        exit 1
      fi
      ENV_FILE="$2"
      shift 2
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

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not in PATH." >&2
  exit 1
fi

detect_compose_command

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: Missing env file: ${ENV_FILE}" >&2
  exit 1
fi

normalize_env_file_line_endings "${ENV_FILE}"

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

common_path_abs="$(resolve_path "${COMMON_PATH}")"
if [[ -e "${common_path_abs}" ]]; then
  if [[ ! -w "${common_path_abs}" ]]; then
    echo "ERROR: COMMON_PATH is not writable: ${common_path_abs}" >&2
    exit 1
  fi
else
  parent_dir="$(dirname "${common_path_abs}")"
  if [[ ! -w "${parent_dir}" ]]; then
    echo "ERROR: Cannot create COMMON_PATH under: ${parent_dir}" >&2
    exit 1
  fi
fi

(
  cd "${REPO_ROOT}"
  run_compose --env-file "${ENV_FILE}" config > /dev/null
)

echo "Doctor checks passed (${COMPOSE_CMD_DISPLAY})."
