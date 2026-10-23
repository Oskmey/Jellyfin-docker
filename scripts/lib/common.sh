#!/usr/bin/env bash
# Shared helpers for the stack scripts. Callers set REPO_ROOT and ENV_FILE
# before use, and may redefine error, warn, and fail after sourcing to route
# messages through their own logging.

# shellcheck disable=SC2034 # COMPOSE_CMD_DISPLAY is read by the callers.

DOCKER_BIN="${DOCKER_BIN:-}"
COMPOSE_CMD=()
COMPOSE_CMD_DISPLAY=""
REQUIRED_ENV_KEYS=(
  COMMON_PATH TZ PUID PGID HOMARR_BASE_URL HOMARR_SECRET_ENCRYPTION_KEY
  GLUETUN_CONTROL_API_KEY WIREGUARD_ADDRESSES WIREGUARD_PRIVATE_KEY
  WIREGUARD_ALLOWED_IPS
)
TERRAMASTER_DOCKER_BIN="/Volume1/@apps/DockerEngine/dockerd/bin/docker"

error() {
  echo "ERROR: $*" >&2
}

warn() {
  echo "WARN: $*" >&2
}

fail() {
  error "$*"
  exit 1
}

resolve_path() {
  local value="$1"
  if [[ "${value}" = /* ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "${REPO_ROOT}/${value}"
  fi
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

  if [[ -x "${TERRAMASTER_DOCKER_BIN}" ]]; then
    DOCKER_BIN="${TERRAMASTER_DOCKER_BIN}"
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
  (
    cd "${REPO_ROOT}" || exit
    "${COMPOSE_CMD[@]}" "$@"
  )
}

env_file_has_crlf() {
  LC_ALL=C grep -q $'\r$' "$1"
}

normalize_env_file_line_endings() {
  local env_path="$1"
  local tmp_file

  tmp_file="$(mktemp "${env_path}.tmp.XXXXXX")" || fail "Failed to create temp file for ${env_path}."
  if ! sed 's/\r$//' "${env_path}" > "${tmp_file}"; then
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
  local mode

  [[ -f "${env_path}" ]] || return 0
  if [[ "$(uname -s 2>/dev/null)" =~ ^(MINGW|MSYS|CYGWIN) ]]; then
    return 0
  fi

  mode="$(stat -c '%a' "${env_path}" 2>/dev/null || true)"
  [[ -n "${mode}" ]] || return 0
  [[ "${mode}" == "600" ]]
}

ensure_env_file_permissions() {
  local env_path="$1"

  [[ -f "${env_path}" ]] || return 0
  chmod 600 "${env_path}" 2>/dev/null || warn "Failed to restrict permissions on ${env_path}; secure it manually."
}

# Repairs line endings and permissions when fix is 1; otherwise only warns.
prepare_env_file() {
  local env_path="$1"
  local fix="$2"

  if env_file_has_crlf "${env_path}"; then
    if [[ "${fix}" -eq 1 ]]; then
      normalize_env_file_line_endings "${env_path}"
    else
      warn "Detected Windows line endings in ${env_path}; rerun with --fix-env to convert to Unix LF."
    fi
  fi

  if ! env_file_permissions_are_restricted "${env_path}"; then
    if [[ "${fix}" -eq 1 ]]; then
      ensure_env_file_permissions "${env_path}"
    else
      warn "${env_path} permissions are broader than 600; rerun with --fix-env to tighten them when supported."
    fi
  fi
}

load_env_file() {
  local env_path="$1"

  [[ -f "${env_path}" ]] || fail "Missing env file: ${env_path}"
  set -a
  # shellcheck disable=SC1090
  source "${env_path}"
  set +a
}

detect_render_gid() {
  local device_gid
  local named_gid=""

  if command -v getent >/dev/null 2>&1 && getent group render >/dev/null 2>&1; then
    named_gid="$(getent group render | awk -F: '{print $3}')"
  fi

  if [[ -e /dev/dri/renderD128 ]] && device_gid="$(stat -c '%g' /dev/dri/renderD128 2>/dev/null)"; then
    if [[ -n "${named_gid}" && "${named_gid}" != "${device_gid}" ]]; then
      warn "The render group GID (${named_gid}) differs from renderD128 (${device_gid}); using the device GID."
    fi
    printf '%s' "${device_gid}"
    return
  fi

  printf '%s' "${named_gid:-109}"
}

apply_env_defaults() {
  BIND_IP="${BIND_IP:-0.0.0.0}"
  WIREGUARD_ALLOWED_IPS="${WIREGUARD_ALLOWED_IPS:-0.0.0.0/0}"
  JELLYFIN_RENDER_GID="${JELLYFIN_RENDER_GID:-$(detect_render_gid)}"
  LOG_MAX_SIZE="${LOG_MAX_SIZE:-10m}"
  LOG_MAX_FILE="${LOG_MAX_FILE:-3}"
  HOMARR_BASE_URL="${HOMARR_BASE_URL:-http://localhost:${NGINX_PORT:-8090}}"
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
  if [[ "${key}" == HOMARR_BASE_URL ]]; then
    [[ "${value}" =~ ^https?://[^/?#@[:space:]]+/?$ && "${value}" != *\\* ]] ||
      fail "HOMARR_BASE_URL must be an http:// or https:// origin, optionally ending in /, without credentials, a path, query, or fragment."
    return 0
  fi
  [[ "${value}" =~ ^https?://[^[:space:]]+$ ]] || fail "${key} must start with http:// or https:// and contain no spaces: ${value}"
}

validate_hex_secret() {
  local key="$1"
  local value="${!key:-}"

  [[ "${value}" =~ ^[[:xdigit:]]{64}$ ]] || fail "${key} must contain exactly 64 hexadecimal characters."
}

# Reports every missing key before failing, then validates value formats.
validate_required_env() {
  local key
  local missing=0

  apply_env_defaults
  for key in "${REQUIRED_ENV_KEYS[@]}"; do
    if [[ -z "${!key:-}" ]]; then
      error "${key} is missing in ${ENV_FILE}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || exit 1

  validate_integer "PUID"
  validate_integer "PGID"
  validate_integer "JELLYFIN_RENDER_GID"
  validate_port "NGINX_PORT"
  validate_port "JELLYSEERR_PORT"
  validate_http_url "HOMARR_BASE_URL"
  validate_http_url "JELLYSEERR_EXTERNAL_URL"
  validate_hex_secret "HOMARR_SECRET_ENCRYPTION_KEY"
  validate_hex_secret "GLUETUN_CONTROL_API_KEY"
}
