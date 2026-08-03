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
  - required env values and dashboard secret formats
  - COMMON_PATH write access and service directory ownership
  - Homarr memory prerequisite and Gluetun auth configuration
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

  if [[ -x /Volume1/@apps/DockerEngine/dockerd/bin/docker ]]; then
    DOCKER_BIN="/Volume1/@apps/DockerEngine/dockerd/bin/docker"
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

  if [[ -n "${DOCKER_BIN:-}" && -x "$(dirname "${DOCKER_BIN}")/docker-compose" ]]; then
    COMPOSE_CMD=("$(dirname "${DOCKER_BIN}")/docker-compose")
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

validate_integer() {
  local key="$1"
  local value="${!key:-}"

  [[ -n "${value}" ]] || fail "${key} is missing in ${ENV_FILE}"
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "${key} must be numeric: ${value}"
}

validate_http_url() {
  local key="$1"
  local value="${!key:-}"

  [[ -n "${value}" ]] || return 0
  [[ "${value}" =~ ^https?://[^[:space:]]+$ ]] || fail "${key} must start with http:// or https:// and contain no spaces: ${value}"
}

validate_hex_secret() {
  local key="$1"
  local value="${!key:-}"

  [[ "${value}" =~ ^[[:xdigit:]]{64}$ ]] || fail "${key} must contain exactly 64 hexadecimal characters."
}

check_data_layout() {
  local common_path_abs="$1"
  local legacy_paths=(
    "${common_path_abs}/Downloads"
    "${common_path_abs}/Sonarr/tvshows"
    "${common_path_abs}/Radarr/movies"
  )
  local data_paths=(
    "${common_path_abs}/Data/downloads"
    "${common_path_abs}/Data/tvshows"
    "${common_path_abs}/Data/movies"
  )
  local path
  local legacy_found=0
  local data_found=0

  for path in "${legacy_paths[@]}"; do
    [[ -d "${path}" ]] && legacy_found=1
  done
  for path in "${data_paths[@]}"; do
    [[ -d "${path}" ]] && data_found=1
  done

  if [[ "${legacy_found}" -eq 1 && "${data_found}" -eq 1 ]]; then
    fail "Both legacy and Data media paths exist under ${common_path_abs}; resolve the layout before starting Compose."
  fi
  if [[ "${legacy_found}" -eq 1 ]]; then
    fail "Legacy media layout detected; move Downloads to Data/downloads, Sonarr/tvshows to Data/tvshows, and Radarr/movies to Data/movies before starting the updated stack."
  fi

  for path in \
    "${data_paths[@]}" \
    "${common_path_abs}/Homarr/AppData" \
    "${common_path_abs}/Glances" \
    "${common_path_abs}/Gluetun/Auth"; do
    [[ -e "${path}" ]] || continue
    [[ -d "${path}" ]] || fail "Expected directory: ${path}"
    [[ "$(stat -c '%u:%g' "${path}" 2>/dev/null)" == "${PUID}:${PGID}" ]] || warn "Unexpected ownership on ${path}; expected ${PUID}:${PGID}."
  done

  check_gluetun_auth_config "${common_path_abs}"
  check_glances_config "${common_path_abs}"
}

check_glances_config() {
  local common_path_abs="$1"
  local config_file="${common_path_abs}/Glances/glances.conf"

  [[ -f "${config_file}" ]] || fail "Missing Glances config: ${config_file}; rerun scripts/setup.sh."
  [[ "$(stat -c '%u:%g' "${config_file}" 2>/dev/null)" == "${PUID}:${PGID}" ]] || warn "Unexpected Glances config ownership; expected ${PUID}:${PGID}."
  grep -Fqx '[outputs]' "${config_file}" || fail "Glances config is missing the [outputs] section."
  grep -Fqx 'webui_allowed_hosts=glances,localhost,127.0.0.1' "${config_file}" || fail "Glances allowed hosts differ from the internal-only allowlist."
}

check_gluetun_auth_config() {
  local common_path_abs="$1"
  local auth_file="${common_path_abs}/Gluetun/Auth/config.toml"
  local mode

  [[ -f "${auth_file}" ]] || fail "Missing Gluetun auth config: ${auth_file}; rerun scripts/setup.sh."
  [[ "$(stat -c '%u:%g' "${auth_file}" 2>/dev/null)" == "${PUID}:${PGID}" ]] || fail "Unexpected Gluetun auth config ownership; expected ${PUID}:${PGID}."
  mode="$(stat -c '%a' "${auth_file}" 2>/dev/null || true)"
  [[ "${mode}" == "600" ]] || fail "Gluetun auth config must have mode 600: ${auth_file}"
  grep -Fq 'name = "homarr-read-only"' "${auth_file}" || fail "Gluetun auth config is missing the Homarr read-only role."
  grep -Fq 'routes = ["GET /v1/vpn/status", "GET /v1/dns/status", "GET /v1/publicip/ip"]' "${auth_file}" || fail "Gluetun auth routes differ from the required read-only allowlist."
  grep -Fqx "apikey = \"${GLUETUN_CONTROL_API_KEY}\"" "${auth_file}" || fail "Gluetun auth config does not match GLUETUN_CONTROL_API_KEY; rerun scripts/setup.sh."
}

check_homarr_memory() {
  local available_kib
  local minimum_kib=$((500 * 1024))

  [[ -r /proc/meminfo ]] || {
    warn "Cannot read /proc/meminfo; verify that at least 500 MB is available for Homarr."
    return
  }

  available_kib="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)"
  [[ "${available_kib}" =~ ^[0-9]+$ ]] || {
    warn "Cannot determine available memory; verify that at least 500 MB is available for Homarr."
    return
  }
  (( available_kib >= minimum_kib )) || fail "Homarr requires at least 500 MB available memory; detected $((available_kib / 1024)) MB."
}

detect_render_gid() {
  if command -v getent >/dev/null 2>&1 && getent group render >/dev/null 2>&1; then
    getent group render | awk -F: '{print $3}'
    return
  fi

  if [[ -e /dev/dri/renderD128 ]]; then
    stat -c '%g' /dev/dri/renderD128 2>/dev/null && return
  fi

  printf '109'
}

apply_env_defaults() {
  BIND_IP="${BIND_IP:-0.0.0.0}"
  JELLYFIN_RENDER_GID="${JELLYFIN_RENDER_GID:-$(detect_render_gid)}"
  LOG_MAX_SIZE="${LOG_MAX_SIZE:-10m}"
  LOG_MAX_FILE="${LOG_MAX_FILE:-3}"
  HOMARR_BASE_URL="${HOMARR_BASE_URL:-http://localhost:${NGINX_PORT:-8090}}"
}

check_nas_devices() {
  if [[ ! -e /dev/net/tun ]]; then
    warn "Missing /dev/net/tun; Gluetun cannot start until the NAS exposes the TUN device."
  fi

  if [[ ! -d /dev/dri ]]; then
    warn "Missing /dev/dri; Jellyfin Intel hardware acceleration will not be available."
    return
  fi

  if [[ ! -e /dev/dri/renderD128 ]]; then
    warn "Missing /dev/dri/renderD128; verify TerraMaster TOS exposes the Intel render device."
  fi
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

apply_env_defaults

required=(
  COMMON_PATH
  TZ
  PUID
  PGID
  HOMARR_BASE_URL
  HOMARR_SECRET_ENCRYPTION_KEY
  GLUETUN_CONTROL_API_KEY
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

validate_integer "PUID"
validate_integer "PGID"
validate_integer "JELLYFIN_RENDER_GID"
validate_port "NGINX_PORT"
validate_port "JELLYSEERR_PORT"
validate_http_url "HOMARR_BASE_URL"
validate_http_url "JELLYSEERR_EXTERNAL_URL"
validate_hex_secret "HOMARR_SECRET_ENCRYPTION_KEY"
validate_hex_secret "GLUETUN_CONTROL_API_KEY"
check_nas_devices
check_homarr_memory

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

check_data_layout "${common_path_abs}"

(
  cd "${REPO_ROOT}"
  run_compose --env-file "${ENV_FILE}" config > /dev/null
)

echo "Doctor checks passed (${COMPOSE_CMD_DISPLAY})."
