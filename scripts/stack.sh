#!/usr/bin/env bash
# Single entrypoint for the media stack helpers:
#   setup, doctor, security-check, backup, restore
# Run `scripts/stack.sh help` for usage. Sourcing this file only defines the
# helpers, so tests can exercise them without running a command.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

CURRENT_STEP="startup"
WARNINGS=0
FAILURES=0

set_colors() {
  if [[ "$1" -eq 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RED='\033[31m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_BLUE='\033[34m'
    C_CYAN='\033[36m'
  else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
  fi
}

# Colour only on a terminal, and never when NO_COLOR is set (no-color.org).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  set_colors 1
else
  set_colors 0
fi

log_step() {
  CURRENT_STEP="$*"
  printf "\n"
  printf "%b\n" "${C_BOLD}${C_CYAN}==> ${CURRENT_STEP}${C_RESET}"
}

log_info() {
  printf "%b\n" "${C_BLUE}[INFO]${C_RESET} $*"
}

log_ok() {
  printf "%b\n" "${C_GREEN}[ OK ]${C_RESET} $*"
}

log_skip() {
  printf "%b\n" "${C_DIM}[SKIP]${C_RESET} $*"
}

# Warnings go to stderr because helpers such as detect_render_gid run in
# command substitutions.
log_warn() {
  WARNINGS=$((WARNINGS + 1))
  printf "%b\n" "${C_YELLOW}[WARN]${C_RESET} $*" >&2
}

log_err() {
  printf "%b\n" "${C_RED}[ERR ]${C_RESET} $*" >&2
}

error() {
  log_err "$*"
}

warn() {
  log_warn "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  log_err "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# Shared helpers: Docker detection, env loading, and validation
# ---------------------------------------------------------------------------

DOCKER_BIN="${DOCKER_BIN:-}"
COMPOSE_CMD=()
COMPOSE_CMD_DISPLAY=""
REQUIRED_ENV_KEYS=(
  COMMON_PATH TZ PUID PGID HOMARR_BASE_URL HOMARR_SECRET_ENCRYPTION_KEY
  GLUETUN_CONTROL_API_KEY WIREGUARD_ADDRESSES WIREGUARD_PRIVATE_KEY
  WIREGUARD_ALLOWED_IPS
)
TERRAMASTER_DOCKER_BIN="/Volume1/@apps/DockerEngine/dockerd/bin/docker"

# Resolves values from .env (such as COMMON_PATH) against the repository root.
resolve_path() {
  local value="$1"
  if [[ "${value}" = /* ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "${REPO_ROOT}/${value}"
  fi
}

# Resolves command-line paths against the caller's working directory.
resolve_cli_path() {
  local value="$1"
  if [[ "${value}" = /* ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "${PWD}/${value}"
  fi
}

require_arg_value() {
  local option="$1"
  local count="$2"
  [[ "${count}" -ge 2 ]] || fail "${option} requires a value."
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

# Backup and restore read only COMMON_PATH/PUID/PGID, so they refuse CRLF
# files instead of loading paths with a trailing carriage return.
load_env_file_strict() {
  local env_path="$1"

  [[ -f "${env_path}" ]] || fail "Missing env file: ${env_path}"
  ! env_file_has_crlf "${env_path}" || fail "${env_path} has Windows line endings; run scripts/stack.sh doctor --fix-env first."
  load_env_file "${env_path}"
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

# ---------------------------------------------------------------------------
# setup: interactive setup and env generation
# ---------------------------------------------------------------------------

SETUP_ENV_KEYS=(
  COMMON_PATH TZ PUID PGID JELLYFIN_RENDER_GID BIND_IP NGINX_PORT
  HOMARR_BASE_URL HOMARR_SECRET_ENCRYPTION_KEY GLUETUN_CONTROL_API_KEY
  JELLYSEERR_PORT LOG_MAX_SIZE LOG_MAX_FILE JELLYSEERR_EXTERNAL_URL
  SERVER_COUNTRIES WIREGUARD_ADDRESSES WIREGUARD_PRIVATE_KEY
  WIREGUARD_ALLOWED_IPS
)
SETUP_DIR_CREATED=0
SETUP_DIR_REUSED=0

setup_usage() {
  cat <<USAGE
Usage: scripts/stack.sh setup [options]

Generates .env, creates only missing data and configuration folders, writes the
restricted Gluetun telemetry policy and Glances config, and validates Compose.

Options:
  --non-interactive   Validate and use an existing env file without prompts.
  --env-file PATH     Path to env file (default: .env in repo root).
  --force             Overwrite existing env values without reuse prompt.
  --no-color          Disable colored output (NO_COLOR=1 works too).
  -h, --help          Show this help.

Environment:
  DOCKER_BIN          Override the docker binary path.
  DOCKER_COMPOSE_BIN  Override the docker-compose binary path.
USAGE
}

setup_print_header() {
  printf "%b\n" "${C_BOLD}${C_BLUE}============================================================${C_RESET}"
  printf "%b\n" "${C_BOLD}${C_BLUE}  Jellyfin Docker Setup${C_RESET}"
  printf "%b\n" "${C_DIM}  Repository: ${REPO_ROOT}${C_RESET}"
  printf "%b\n" "${C_BOLD}${C_BLUE}============================================================${C_RESET}"
  printf "\n"
}

setup_on_error() {
  local exit_code="$1"
  local line_no="$2"
  local command="$3"
  local source_file="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"

  FAILURES=$((FAILURES + 1))
  log_err "Step failed: ${CURRENT_STEP}"
  log_err "Location: ${source_file}:${line_no}"
  log_err "Exit code: ${exit_code}"
  log_err "Command: ${command}"
}

setup_mask_value() {
  local value="$1"
  local len=${#value}
  if [[ "${len}" -le 8 ]]; then
    printf '********'
    return
  fi
  printf '%s****%s' "${value:0:4}" "${value: -4}"
}

setup_generate_hex_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi

  [[ -r /dev/urandom ]] || fail "Cannot generate secrets: openssl is unavailable and /dev/urandom is not readable."
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

setup_validate_env_value() {
  local key="$1"
  local value="$2"

  [[ "${value}" != *"'"* && "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] ||
    fail "${key} cannot contain single quotes or line breaks in an env file."
}

setup_validate_env_serialization() {
  local key
  for key in "${SETUP_ENV_KEYS[@]}"; do
    setup_validate_env_value "${key}" "${!key-}"
  done
}

setup_upsert_env_value() {
  local key="$1"
  local value="$2"
  local tmp_file

  setup_validate_env_value "${key}" "${value}"
  [[ -f "${ENV_FILE}" ]] || return 0
  tmp_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")" || fail "Failed to create temporary env file."
  if ! ENV_UPDATE_KEY="${key}" ENV_UPDATE_LINE="${key}='${value}'" awk '
    BEGIN { key=ENVIRON["ENV_UPDATE_KEY"]; line=ENVIRON["ENV_UPDATE_LINE"] }
    $0 ~ "^" key "=" { print line; found=1; next }
    { print }
    END { if (!found) print line }
  ' "${ENV_FILE}" > "${tmp_file}"; then
    rm -f "${tmp_file}"
    fail "Failed to update ${key} in ${ENV_FILE}."
  fi
  if ! chmod 0600 "${tmp_file}" || ! mv "${tmp_file}" "${ENV_FILE}"; then
    rm -f "${tmp_file}"
    fail "Failed to replace ${ENV_FILE}."
  fi
}

setup_ensure_generated_secrets() {
  local persist="${1:-1}"
  local homarr_url_generated=0
  local homarr_generated=0
  local gluetun_generated=0
  local render_gid_generated=0

  if [[ -z "${JELLYFIN_RENDER_GID:-}" ]]; then
    JELLYFIN_RENDER_GID="$(detect_render_gid)"
    export JELLYFIN_RENDER_GID
    render_gid_generated=1
  fi

  if [[ -z "${HOMARR_BASE_URL:-}" ]]; then
    HOMARR_BASE_URL="http://localhost:${NGINX_PORT:-8090}"
    export HOMARR_BASE_URL
    homarr_url_generated=1
  fi
  if [[ -z "${HOMARR_SECRET_ENCRYPTION_KEY:-}" || "${HOMARR_SECRET_ENCRYPTION_KEY}" == "GENERATE_WITH_SETUP" ]]; then
    HOMARR_SECRET_ENCRYPTION_KEY="$(setup_generate_hex_secret)"
    export HOMARR_SECRET_ENCRYPTION_KEY
    homarr_generated=1
  fi
  if [[ -z "${GLUETUN_CONTROL_API_KEY:-}" || "${GLUETUN_CONTROL_API_KEY}" == "GENERATE_WITH_SETUP" ]]; then
    GLUETUN_CONTROL_API_KEY="$(setup_generate_hex_secret)"
    export GLUETUN_CONTROL_API_KEY
    gluetun_generated=1
  fi

  validate_hex_secret "HOMARR_SECRET_ENCRYPTION_KEY"
  validate_hex_secret "GLUETUN_CONTROL_API_KEY"

  [[ "${persist}" -eq 1 ]] || return 0
  validate_required_env
  setup_validate_env_serialization

  if [[ "${render_gid_generated}" -eq 1 ]]; then
    setup_upsert_env_value "JELLYFIN_RENDER_GID" "${JELLYFIN_RENDER_GID}"
    log_ok "Stored detected JELLYFIN_RENDER_GID (${JELLYFIN_RENDER_GID})."
  fi
  if [[ "${homarr_url_generated}" -eq 1 ]]; then
    setup_upsert_env_value "HOMARR_BASE_URL" "${HOMARR_BASE_URL}"
    log_ok "Added default HOMARR_BASE_URL (${HOMARR_BASE_URL}); update it if clients use another LAN hostname."
  fi
  if [[ "${homarr_generated}" -eq 1 ]]; then
    setup_upsert_env_value "HOMARR_SECRET_ENCRYPTION_KEY" "${HOMARR_SECRET_ENCRYPTION_KEY}"
    log_ok "Generated and stored HOMARR_SECRET_ENCRYPTION_KEY ($(setup_mask_value "${HOMARR_SECRET_ENCRYPTION_KEY}"))."
  fi
  if [[ "${gluetun_generated}" -eq 1 ]]; then
    setup_upsert_env_value "GLUETUN_CONTROL_API_KEY" "${GLUETUN_CONTROL_API_KEY}"
    log_ok "Generated and stored GLUETUN_CONTROL_API_KEY ($(setup_mask_value "${GLUETUN_CONTROL_API_KEY}"))."
  fi
}

setup_source_env_file() {
  local env_path="$1"

  [[ -f "${env_path}" ]] || fail "Missing env file: ${env_path}"
  prepare_env_file "${env_path}" 1
  load_env_file "${env_path}"
}

setup_prompt_default() {
  local prompt="$1"
  local default="$2"
  local value

  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " value
  else
    read -r -p "${prompt}: " value
  fi

  if [[ -z "${value}" ]]; then
    value="${default}"
  fi
  printf '%s' "${value}"
}

setup_prompt_required() {
  local prompt="$1"
  local default="$2"
  local value=""

  while [[ -z "${value}" ]]; do
    if [[ -n "${default}" ]]; then
      read -r -p "${prompt} [${default}]: " value
      if [[ -z "${value}" ]]; then
        value="${default}"
      fi
    else
      read -r -p "${prompt}: " value
    fi
  done

  printf '%s' "${value}"
}

setup_prompt_secret_required() {
  local prompt="$1"
  local default="$2"
  local value=""

  while [[ -z "${value}" ]]; do
    if [[ -n "${default}" ]]; then
      read -r -s -p "${prompt} [$(setup_mask_value "${default}"), Enter keeps it]: " value
    else
      read -r -s -p "${prompt}: " value
    fi
    [[ ! -t 0 ]] || printf '\n' >&2
    if [[ -z "${value}" ]]; then
      value="${default}"
    fi
  done

  printf '%s' "${value}"
}

setup_write_env_file() {
  local key
  local tmp_file

  validate_required_env
  setup_validate_env_serialization
  tmp_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")" || fail "Failed to create temporary env file."
  if ! (
    printf '%s\n' '# Generated by scripts/stack.sh setup' || exit 1
    for key in "${SETUP_ENV_KEYS[@]}"; do
      printf "%s='%s'\n" "${key}" "${!key-}" || exit 1
    done
  ) > "${tmp_file}"; then
    rm -f "${tmp_file}"
    fail "Failed to write ${ENV_FILE}."
  fi
  if ! chmod 0600 "${tmp_file}" || ! mv "${tmp_file}" "${ENV_FILE}"; then
    rm -f "${tmp_file}"
    fail "Failed to replace ${ENV_FILE}."
  fi
  log_ok "Wrote ${ENV_FILE}"
}

setup_print_summary() {
  printf "\n"
  printf "%b\n" "${C_BOLD}Configuration Summary${C_RESET}"
  printf "  %-24s %s\n" "COMMON_PATH" "${COMMON_PATH}"
  printf "  %-24s %s\n" "COMMON_PATH (absolute)" "$(resolve_path "${COMMON_PATH}")"
  printf "  %-24s %s\n" "TZ" "${TZ}"
  printf "  %-24s %s\n" "PUID/PGID" "${PUID}/${PGID}"
  printf "  %-24s %s\n" "JELLYFIN_RENDER_GID" "${JELLYFIN_RENDER_GID}"
  printf "  %-24s %s\n" "BIND_IP" "${BIND_IP}"
  printf "  %-24s %s\n" "NGINX_PORT" "${NGINX_PORT}"
  printf "  %-24s %s\n" "HOMARR_BASE_URL" "${HOMARR_BASE_URL}"
  printf "  %-24s %s\n" "HOMARR_SECRET_KEY" "$(setup_mask_value "${HOMARR_SECRET_ENCRYPTION_KEY}")"
  printf "  %-24s %s\n" "GLUETUN_CONTROL_KEY" "$(setup_mask_value "${GLUETUN_CONTROL_API_KEY}")"
  printf "  %-24s %s\n" "JELLYSEERR_PORT" "${JELLYSEERR_PORT}"
  printf "  %-24s %s\n" "LOG_MAX_SIZE" "${LOG_MAX_SIZE}"
  printf "  %-24s %s\n" "LOG_MAX_FILE" "${LOG_MAX_FILE}"
  printf "  %-24s %s\n" "JELLYSEERR_EXTERNAL_URL" "${JELLYSEERR_EXTERNAL_URL}"
  printf "  %-24s %s\n" "SERVER_COUNTRIES" "${SERVER_COUNTRIES}"
  printf "  %-24s %s\n" "WIREGUARD_ADDRESSES" "$(setup_mask_value "${WIREGUARD_ADDRESSES}")"
  printf "  %-24s %s\n" "WIREGUARD_PRIVATE_KEY" "$(setup_mask_value "${WIREGUARD_PRIVATE_KEY}")"
  printf "  %-24s %s\n" "WIREGUARD_ALLOWED_IPS" "${WIREGUARD_ALLOWED_IPS}"
}

setup_ensure_directory() {
  local dir="$1"

  if [[ -d "${dir}" ]]; then
    SETUP_DIR_REUSED=$((SETUP_DIR_REUSED + 1))
    log_skip "Reused existing folder: ${dir}"
    return
  fi

  if [[ -e "${dir}" ]]; then
    fail "Path exists but is not a directory: ${dir}"
  fi

  mkdir -p "${dir}" || fail "Failed to create folder: ${dir}"
  chown "${PUID}:${PGID}" "${dir}" || fail "Failed to set ownership on ${dir} to ${PUID}:${PGID}"
  chmod 0770 "${dir}" || fail "Failed to set permissions on ${dir}"
  SETUP_DIR_CREATED=$((SETUP_DIR_CREATED + 1))
  log_ok "Created folder: ${dir}"
}

setup_print_final_summary() {
  printf "\n"
  printf "%b\n" "${C_BOLD}Setup Summary${C_RESET}"
  printf "  %-24s %s\n" "Directories created" "${SETUP_DIR_CREATED}"
  printf "  %-24s %s\n" "Directories reused" "${SETUP_DIR_REUSED}"
  printf "  %-24s %s\n" "Warnings" "${WARNINGS}"
  printf "  %-24s %s\n" "Failures" "${FAILURES}"
}

setup_create_directories() {
  local base_path
  local dir
  base_path="$(resolve_path "${COMMON_PATH}")"

  if [[ -d "${base_path}/Downloads" || -d "${base_path}/Sonarr/tvshows" || -d "${base_path}/Radarr/movies" ]]; then
    fail "Legacy media layout detected; move Downloads to Data/downloads, Sonarr/tvshows to Data/tvshows, and Radarr/movies to Data/movies before running setup."
  fi

  local dirs=(
    "${base_path}/Qbittorrent/Config"
    "${base_path}/Data/downloads"
    "${base_path}/Data/tvshows"
    "${base_path}/Data/movies"
    "${base_path}/Sonarr/Config"
    "${base_path}/Radarr/Config"
    "${base_path}/Prowlarr/Config"
    "${base_path}/Jellyfin/Config"
    "${base_path}/Jellyfin/Cache"
    "${base_path}/Jellyseerr/Config"
    "${base_path}/Bazarr/Config"
    "${base_path}/Homarr/AppData"
    "${base_path}/Glances"
    "${base_path}/Gluetun/Auth"
  )

  log_info "COMMON_PATH resolved to: ${base_path}"
  setup_ensure_directory "${base_path}"

  log_info "Ensuring media and config folders..."
  for dir in "${dirs[@]}"; do
    setup_ensure_directory "${dir}"
  done
  log_ok "Folder checks complete (${#dirs[@]} targets)."
}

setup_write_gluetun_auth_config() {
  local base_path
  local auth_file
  local temp_file

  base_path="$(resolve_path "${COMMON_PATH}")"
  auth_file="${base_path}/Gluetun/Auth/config.toml"
  temp_file="$(mktemp "${auth_file}.tmp.XXXXXX")" || fail "Failed to create temporary Gluetun auth config."

  if ! printf '%s\n' \
    '[[roles]]' \
    'name = "homarr-read-only"' \
    'routes = ["GET /v1/vpn/status", "GET /v1/dns/status", "GET /v1/publicip/ip"]' \
    'auth = "apikey"' \
    "apikey = \"${GLUETUN_CONTROL_API_KEY}\"" > "${temp_file}"; then
    rm -f "${temp_file}"
    fail "Failed to render Gluetun auth config."
  fi

  chown "${PUID}:${PGID}" "${temp_file}" || fail "Failed to set Gluetun auth config ownership."
  chmod 0600 "${temp_file}" || fail "Failed to restrict Gluetun auth config permissions."
  mv "${temp_file}" "${auth_file}" || fail "Failed to install Gluetun auth config."
  log_ok "Installed restricted Gluetun control-server auth config: ${auth_file}"
}

setup_write_glances_config() {
  local base_path
  local config_file
  local temp_file

  base_path="$(resolve_path "${COMMON_PATH}")"
  config_file="${base_path}/Glances/glances.conf"
  temp_file="$(mktemp "${config_file}.tmp.XXXXXX")" || fail "Failed to create temporary Glances config."

  if ! printf '%s\n' \
    '[outputs]' \
    'webui_allowed_hosts=glances,localhost,127.0.0.1' > "${temp_file}"; then
    rm -f "${temp_file}"
    fail "Failed to render Glances config."
  fi

  chown "${PUID}:${PGID}" "${temp_file}" || fail "Failed to set Glances config ownership."
  chmod 0644 "${temp_file}" || fail "Failed to set Glances config permissions."
  mv "${temp_file}" "${config_file}" || fail "Failed to install Glances config."
  log_ok "Installed internal-only Glances web API config: ${config_file}"
}

setup_run_preflight() {
  log_info "Running docker compose preflight validation..."
  run_compose --env-file "${ENV_FILE}" config > /dev/null
  log_ok "Compose preflight passed (${COMPOSE_CMD_DISPLAY})."
}

setup_interactive_collect() {
  local default_tz="UTC"
  local default_host="localhost"
  if [[ -f /etc/timezone ]]; then
    default_tz="$(< /etc/timezone)"
  fi
  if command -v hostname >/dev/null 2>&1; then
    default_host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'localhost')"
  fi

  local default_common_path="${COMMON_PATH:-./data}"
  local default_tz_value="${TZ:-${default_tz}}"
  local default_puid="${PUID:-$(id -u)}"
  local default_pgid="${PGID:-$(id -g)}"
  local default_render_gid="${JELLYFIN_RENDER_GID:-$(detect_render_gid)}"
  local default_bind_ip="${BIND_IP:-0.0.0.0}"
  local default_nginx_port="${NGINX_PORT:-8090}"
  local default_homarr_base_url="${HOMARR_BASE_URL:-http://${default_host}:${default_nginx_port}}"
  local default_jellyseerr_port="${JELLYSEERR_PORT:-5055}"
  local default_log_max_size="${LOG_MAX_SIZE:-10m}"
  local default_log_max_file="${LOG_MAX_FILE:-3}"
  local default_server_countries="${SERVER_COUNTRIES:-Sweden}"
  local default_allowed_ips="${WIREGUARD_ALLOWED_IPS:-0.0.0.0/0}"
  local jellyseerr_external_url_default=""

  printf "%b\n" "${C_BOLD}Environment Setup${C_RESET}"

  COMMON_PATH="$(setup_prompt_default "COMMON_PATH" "${default_common_path}")"
  TZ="$(setup_prompt_default "TZ" "${default_tz_value}")"
  PUID="$(setup_prompt_default "PUID" "${default_puid}")"
  PGID="$(setup_prompt_default "PGID" "${default_pgid}")"
  JELLYFIN_RENDER_GID="$(setup_prompt_default "JELLYFIN_RENDER_GID" "${default_render_gid}")"
  BIND_IP="$(setup_prompt_default "BIND_IP" "${default_bind_ip}")"
  NGINX_PORT="$(setup_prompt_default "NGINX_PORT" "${default_nginx_port}")"
  HOMARR_BASE_URL="$(setup_prompt_default "HOMARR_BASE_URL" "${default_homarr_base_url}")"
  JELLYSEERR_PORT="$(setup_prompt_default "JELLYSEERR_PORT" "${default_jellyseerr_port}")"
  LOG_MAX_SIZE="$(setup_prompt_default "LOG_MAX_SIZE" "${default_log_max_size}")"
  LOG_MAX_FILE="$(setup_prompt_default "LOG_MAX_FILE" "${default_log_max_file}")"
  jellyseerr_external_url_default="${JELLYSEERR_EXTERNAL_URL:-http://${default_host}:${JELLYSEERR_PORT}}"
  JELLYSEERR_EXTERNAL_URL="$(setup_prompt_default "JELLYSEERR_EXTERNAL_URL" "${jellyseerr_external_url_default}")"
  SERVER_COUNTRIES="$(setup_prompt_default "SERVER_COUNTRIES" "${default_server_countries}")"

  printf "\n"
  printf "%b\n" "${C_BOLD}Required WireGuard Settings${C_RESET}"

  WIREGUARD_ADDRESSES="$(setup_prompt_required "WIREGUARD_ADDRESSES" "${WIREGUARD_ADDRESSES:-}")"
  WIREGUARD_PRIVATE_KEY="$(setup_prompt_secret_required "WIREGUARD_PRIVATE_KEY" "${WIREGUARD_PRIVATE_KEY:-}")"
  WIREGUARD_ALLOWED_IPS="$(setup_prompt_default "WIREGUARD_ALLOWED_IPS" "${default_allowed_ips}")"
  setup_ensure_generated_secrets 0
}

setup_confirm_continue() {
  local answer
  read -r -p "Continue with these settings? [Y/n]: " answer
  if [[ -n "${answer}" && ! "${answer}" =~ ^[Yy]$ ]]; then
    fail "Setup cancelled by user."
  fi
}

setup_collect_and_write() {
  setup_interactive_collect
  setup_print_summary
  setup_confirm_continue
  setup_write_env_file
}

cmd_setup() {
  local non_interactive=0
  local force=0
  local reuse
  local example_file="${REPO_ROOT}/.env.example"

  trap 'setup_on_error $? ${LINENO} "$BASH_COMMAND"' ERR

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive)
        non_interactive=1
        shift
        ;;
      --env-file)
        require_arg_value "$1" "$#"
        ENV_FILE="$(resolve_cli_path "$2")"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      --no-color)
        set_colors 0
        shift
        ;;
      -h|--help)
        setup_usage
        return 0
        ;;
      *)
        fail "Unknown argument: $1 (see scripts/stack.sh setup --help)"
        ;;
    esac
  done

  [[ -f "${example_file}" ]] || fail "Missing ${example_file}"

  setup_print_header
  log_info "Environment file: ${ENV_FILE}"
  if [[ "${non_interactive}" -eq 1 ]]; then
    log_info "Mode: non-interactive"
  else
    log_info "Mode: interactive"
  fi

  log_step "Prerequisite checks"
  detect_compose_command
  log_ok "Docker Compose checks passed (${COMPOSE_CMD_DISPLAY})."

  log_step "Environment configuration"
  if [[ "${non_interactive}" -eq 1 ]]; then
    setup_source_env_file "${ENV_FILE}"
    setup_ensure_generated_secrets
    validate_required_env
    log_ok "Loaded and validated ${ENV_FILE}."
  elif [[ -f "${ENV_FILE}" ]]; then
    setup_source_env_file "${ENV_FILE}"

    if [[ "${force}" -eq 0 ]]; then
      read -r -p "${ENV_FILE} exists. Reuse and validate current values? [Y/n]: " reuse
      if [[ -z "${reuse}" || "${reuse}" =~ ^[Yy]$ ]]; then
        setup_ensure_generated_secrets
        validate_required_env
        log_ok "Using existing env file values."
      else
        setup_collect_and_write
      fi
    else
      setup_collect_and_write
    fi
  else
    setup_collect_and_write
  fi

  setup_ensure_generated_secrets
  validate_required_env
  log_ok "Required env values are present."

  log_step "Compose preflight"
  setup_run_preflight

  log_step "Folder provisioning"
  setup_create_directories

  log_step "Gluetun telemetry authentication"
  setup_write_gluetun_auth_config

  log_step "Glances API restrictions"
  setup_write_glances_config

  log_step "Final summary"
  setup_print_final_summary

  printf "\n"
  log_ok "Setup completed successfully."
  printf "%b\n" "${C_BOLD}Next:${C_RESET} ${COMPOSE_CMD_DISPLAY} --env-file ${ENV_FILE} up -d"
}

# ---------------------------------------------------------------------------
# doctor: read-only environment and Compose validation
# ---------------------------------------------------------------------------

doctor_usage() {
  cat <<'USAGE'
Usage: scripts/stack.sh doctor [--env-file PATH] [--fix-env]

Checks:
  - docker and compose availability (`docker compose` or `docker-compose`)
  - required env values and dashboard secret formats
  - COMMON_PATH write access and service directory ownership
  - Homarr memory headroom and Gluetun auth configuration
  - docker compose config validation

Read-only unless --fix-env is given, which converts CRLF line endings and
restricts the env file to mode 600.

Environment:
  DOCKER_BIN          Override the docker binary path.
  DOCKER_COMPOSE_BIN  Override the docker-compose binary path.
USAGE
}

doctor_check_data_layout() {
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
    if [[ -d "${path}" ]]; then legacy_found=1; fi
  done
  for path in "${data_paths[@]}"; do
    if [[ -d "${path}" ]]; then data_found=1; fi
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

  doctor_check_gluetun_auth_config "${common_path_abs}"
  doctor_check_glances_config "${common_path_abs}"
}

doctor_check_glances_config() {
  local common_path_abs="$1"
  local config_file="${common_path_abs}/Glances/glances.conf"

  [[ -f "${config_file}" ]] || fail "Missing Glances config: ${config_file}; rerun scripts/stack.sh setup."
  [[ "$(stat -c '%u:%g' "${config_file}" 2>/dev/null)" == "${PUID}:${PGID}" ]] || warn "Unexpected Glances config ownership; expected ${PUID}:${PGID}."
  grep -Fqx '[outputs]' "${config_file}" || fail "Glances config is missing the [outputs] section."
  grep -Fqx 'webui_allowed_hosts=glances,localhost,127.0.0.1' "${config_file}" || fail "Glances allowed hosts differ from the internal-only allowlist."
}

doctor_check_gluetun_auth_config() {
  local common_path_abs="$1"
  local auth_file="${common_path_abs}/Gluetun/Auth/config.toml"
  local mode

  [[ -f "${auth_file}" ]] || fail "Missing Gluetun auth config: ${auth_file}; rerun scripts/stack.sh setup."
  [[ "$(stat -c '%u:%g' "${auth_file}" 2>/dev/null)" == "${PUID}:${PGID}" ]] || fail "Unexpected Gluetun auth config ownership; expected ${PUID}:${PGID}."
  mode="$(stat -c '%a' "${auth_file}" 2>/dev/null || true)"
  [[ "${mode}" == "600" ]] || fail "Gluetun auth config must have mode 600: ${auth_file}"
  grep -Fq 'name = "homarr-read-only"' "${auth_file}" || fail "Gluetun auth config is missing the Homarr read-only role."
  grep -Fq 'routes = ["GET /v1/vpn/status", "GET /v1/dns/status", "GET /v1/publicip/ip"]' "${auth_file}" || fail "Gluetun auth routes differ from the required read-only allowlist."
  grep -Fqx "apikey = \"${GLUETUN_CONTROL_API_KEY}\"" "${auth_file}" || fail "Gluetun auth config does not match GLUETUN_CONTROL_API_KEY; rerun scripts/stack.sh setup."
}

# A warning, not a failure: with the stack already running, Homarr's own
# memory is no longer counted as available.
doctor_check_homarr_memory() {
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
  (( available_kib >= minimum_kib )) ||
    warn "Only $((available_kib / 1024)) MB memory available; Homarr needs about 500 MB when it starts."
}

doctor_check_render_gid() {
  local device_gid
  local named_gid=""
  if [[ -e /dev/dri/renderD128 ]]; then
    device_gid="$(stat -c '%g' /dev/dri/renderD128 2>/dev/null)" || return 0
    [[ "${JELLYFIN_RENDER_GID}" == "${device_gid}" ]] ||
      warn "JELLYFIN_RENDER_GID (${JELLYFIN_RENDER_GID}) differs from renderD128 (${device_gid}); update the env file and recreate Jellyfin."
    if command -v getent >/dev/null 2>&1; then
      named_gid="$(getent group render | awk -F: '{print $3}' || true)"
    fi
    if [[ -n "${named_gid}" && "${named_gid}" != "${device_gid}" ]]; then
      warn "The render group GID (${named_gid}) differs from renderD128 (${device_gid}); use the device GID."
    fi
  fi
  return 0
}

doctor_check_nas_devices() {
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

cmd_doctor() {
  local fix_env=0
  local common_path_abs
  local parent_dir

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        require_arg_value "$1" "$#"
        ENV_FILE="$(resolve_cli_path "$2")"
        shift 2
        ;;
      --fix-env)
        fix_env=1
        shift
        ;;
      -h|--help)
        doctor_usage
        return 0
        ;;
      *)
        fail "Unknown argument: $1 (see scripts/stack.sh doctor --help)"
        ;;
    esac
  done

  detect_compose_command

  [[ -f "${ENV_FILE}" ]] || fail "Missing env file: ${ENV_FILE}"
  prepare_env_file "${ENV_FILE}" "${fix_env}"
  load_env_file "${ENV_FILE}"
  validate_required_env
  doctor_check_nas_devices
  doctor_check_render_gid
  doctor_check_homarr_memory

  common_path_abs="$(resolve_path "${COMMON_PATH}")"
  if [[ -e "${common_path_abs}" ]]; then
    [[ -w "${common_path_abs}" ]] || fail "COMMON_PATH is not writable: ${common_path_abs}"
  else
    parent_dir="$(dirname "${common_path_abs}")"
    [[ -w "${parent_dir}" ]] || fail "Cannot create COMMON_PATH under: ${parent_dir}"
  fi

  doctor_check_data_layout "${common_path_abs}"

  run_compose --env-file "${ENV_FILE}" config > /dev/null

  log_ok "Doctor checks passed (${COMPOSE_CMD_DISPLAY}, ${WARNINGS} warnings)."
}

# ---------------------------------------------------------------------------
# security-check: live VPN, isolation, and routing verification
# ---------------------------------------------------------------------------

SECURITY_ROUTE_CHECK_HOST="127.0.0.1"

security_usage() {
  cat <<'USAGE'
Usage: scripts/stack.sh security-check [--env-file PATH] [--fix-env]

Checks (the stack must be running):
  - docker compose config validation
  - nginx syntax and local route responses
  - prefix-stripped routes redirect within their prefix
  - Homarr/Glances isolation from the Docker socket and host ports
  - authenticated, read-only Gluetun telemetry configuration
  - Gluetun health
  - qBittorrent network namespace sharing with Gluetun
  - qBittorrent TCP/UDP binding to the Gluetun tunnel
  - qBittorrent DHT availability when its local API is accessible
  - Mullvad egress from Gluetun and qBittorrent
  - direct egress from Sonarr

Environment:
  DOCKER_BIN          Override the docker binary path.
  DOCKER_COMPOSE_BIN  Override the docker-compose binary path.
USAGE
}

security_set_route_check_host() {
  case "${BIND_IP}" in
    0.0.0.0)
      SECURITY_ROUTE_CHECK_HOST="127.0.0.1"
      ;;
    ::)
      SECURITY_ROUTE_CHECK_HOST="[::1]"
      ;;
    *:*)
      SECURITY_ROUTE_CHECK_HOST="[${BIND_IP}]"
      ;;
    *)
      SECURITY_ROUTE_CHECK_HOST="${BIND_IP}"
      ;;
  esac
}

security_get_service_container() {
  local service="$1"
  local container_id

  container_id="$(run_compose --env-file "${ENV_FILE}" ps -q "${service}")"
  [[ -n "${container_id}" ]] || fail "Service is not running: ${service}"
  printf '%s' "${container_id}"
}

security_assert_no_published_ports() {
  local label="$1"
  local container_id="$2"
  local bindings

  bindings="$("${DOCKER_BIN}" inspect --format '{{range .NetworkSettings.Ports}}{{range .}}{{println .HostIp .HostPort}}{{end}}{{end}}' "${container_id}")"
  [[ -z "${bindings}" ]] || fail "${label} unexpectedly publishes a host port: ${bindings}"
  log_ok "${label} has no published host ports."
}

security_assert_no_docker_socket_mount() {
  local label="$1"
  local container_id="$2"
  local mounts

  mounts="$("${DOCKER_BIN}" inspect --format '{{range .Mounts}}{{println .Source "|" .Destination "|" .RW}}{{end}}' "${container_id}")"
  [[ "${mounts}" != *'/var/run/docker.sock'* ]] || fail "${label} mounts the Docker socket directly."
  log_ok "${label} has no direct Docker socket mount."
}

security_assert_read_only_mount() {
  local label="$1"
  local container_id="$2"
  local destination="$3"
  local mount_state

  mount_state="$("${DOCKER_BIN}" inspect --format "{{range .Mounts}}{{if eq .Destination \"${destination}\"}}{{println .RW}}{{end}}{{end}}" "${container_id}")"
  [[ "${mount_state}" == "false" ]] || fail "${label} must mount ${destination} read-only."
  log_ok "${label} mounts ${destination} read-only."
}

security_check_gluetun_control_policy() {
  local gluetun_id="$1"

  if "${DOCKER_BIN}" exec "${gluetun_id}" wget -qO- -T 10 http://127.0.0.1:8000/v1/vpn/status >/dev/null 2>&1; then
    fail "Gluetun telemetry endpoint permits unauthenticated access."
  fi

  # shellcheck disable=SC2016  # Expanded by the shell inside the container.
  "${DOCKER_BIN}" exec -e "SECURITY_CHECK_API_KEY=${GLUETUN_CONTROL_API_KEY}" "${gluetun_id}" sh -c \
    'wget -qO- -T 10 --header "X-API-Key: ${SECURITY_CHECK_API_KEY}" http://127.0.0.1:8000/v1/vpn/status >/dev/null' || \
    fail "Authenticated Gluetun VPN telemetry request failed."
  log_ok "Gluetun telemetry requires the configured API key."
}

security_fetch_container_json() {
  local container_id="$1"
  "${DOCKER_BIN}" exec "${container_id}" sh -lc '
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --connect-timeout 5 --max-time 15 https://am.i.mullvad.net/json
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- -T 15 https://am.i.mullvad.net/json
    else
      exit 127
    fi
  '
}

security_json_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "${json}" | sed -n "s/.*\"${field}\":\"\\([^\"]*\\)\".*/\\1/p"
}

security_json_boolean_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "${json}" | sed -n "s/.*\"${field}\":\\(true\\|false\\).*/\\1/p"
}

security_json_number_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "${json}" | sed -n "s/.*\"${field}\":\\([0-9][0-9]*\\).*/\\1/p"
}

security_fetch_qbittorrent_api_json() {
  local container_id="$1"
  local api_path="$2"

  # shellcheck disable=SC2016  # Expanded by the shell inside the container.
  "${DOCKER_BIN}" exec "${container_id}" sh -c '
    url="$1"
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --connect-timeout 5 --max-time 10 "${url}"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- -T 5 "${url}"
    else
      exit 127
    fi
  ' sh "http://127.0.0.1:8080/api/v2/${api_path}"
}

security_qbittorrent_recovery_hint() {
  cat >&2 <<EOF
In qBittorrent, open Settings -> Advanced and set:
  Network Interface: tun0
  Optional IP address to bind to: All IPv4 addresses
Keep DHT and PeX enabled, apply the settings, then run:
  ${COMPOSE_CMD_DISPLAY} restart qbittorrent
EOF
}

security_check_qbittorrent_tunnel_binding() {
  local gluetun_id="$1"
  local qbittorrent_id="$2"
  local listen_port
  local listeners
  local tunnel_endpoint
  local tunnel_ipv4

  tunnel_ipv4="$(
    "${DOCKER_BIN}" exec "${gluetun_id}" ip -4 -o address show dev tun0 2>/dev/null |
      awk '$3 == "inet" {sub(/\/.*/, "", $4); print $4; exit}'
  )"
  [[ -n "${tunnel_ipv4}" ]] || fail "Gluetun has no IPv4 address on tun0."

  listen_port="$(
    # shellcheck disable=SC2016  # Evaluated by awk inside the container.
    "${DOCKER_BIN}" exec "${qbittorrent_id}" awk -F= '
      $1 == "Session\\Port" {session_port = $2}
      $1 == "Connection\\PortRangeMin" {fallback_port = $2}
      END {
        if (session_port != "") print session_port
        else print fallback_port
      }
    ' /config/qBittorrent/qBittorrent.conf 2>/dev/null
  )"
  [[ "${listen_port}" =~ ^[0-9]+$ ]] || fail "Cannot determine qBittorrent's listening port."

  listeners="$("${DOCKER_BIN}" exec "${qbittorrent_id}" sh -c '
    if command -v netstat >/dev/null 2>&1; then
      netstat -lntu
    elif command -v ss >/dev/null 2>&1; then
      ss -lntu
    else
      exit 127
    fi
  ')" || fail "qBittorrent has no netstat or ss command for listener verification."
  tunnel_endpoint="${tunnel_ipv4}:${listen_port}"

  if ! awk -v endpoint="${tunnel_endpoint}" '
    $1 ~ /^tcp/ && index($0, endpoint) {tcp_bound = 1}
    $1 ~ /^udp/ && index($0, endpoint) {udp_bound = 1}
    END {exit !(tcp_bound && udp_bound)}
  ' <<< "${listeners}"; then
    security_qbittorrent_recovery_hint
    fail "qBittorrent is not listening on tun0 at ${tunnel_endpoint} for both TCP and UDP."
  fi

  log_ok "qBittorrent listens on tun0 at ${tunnel_endpoint} over TCP and UDP."
}

security_check_qbittorrent_dht() {
  local qbittorrent_id="$1"
  local dht_enabled
  local dht_nodes
  local preferences_json
  local transfer_json
  local attempt

  if ! preferences_json="$(security_fetch_qbittorrent_api_json "${qbittorrent_id}" "app/preferences" 2>/dev/null)"; then
    warn "Cannot query the local qBittorrent API; skipped DHT verification after the tunnel listener passed."
    return
  fi

  dht_enabled="$(security_json_boolean_field "${preferences_json}" "dht")"
  if [[ "${dht_enabled}" != "true" ]]; then
    security_qbittorrent_recovery_hint
    fail "qBittorrent DHT is disabled or its state could not be determined."
  fi

  for attempt in {0..12}; do
    transfer_json="$(security_fetch_qbittorrent_api_json "${qbittorrent_id}" "transfer/info" 2>/dev/null || true)"
    dht_nodes="$(security_json_number_field "${transfer_json}" "dht_nodes")"
    if [[ "${dht_nodes}" =~ ^[0-9]+$ ]] && (( dht_nodes > 0 )); then
      log_ok "qBittorrent DHT has ${dht_nodes} connected nodes."
      return
    fi
    if (( attempt < 12 )); then
      sleep 5
    fi
  done

  security_qbittorrent_recovery_hint
  fail "qBittorrent DHT remained at zero connected nodes for 60 seconds."
}

security_expect_mullvad_status() {
  local label="$1"
  local container_id="$2"
  local expected="$3"
  local json
  local ip

  json="$(security_fetch_container_json "${container_id}")" || fail "Failed to fetch Mullvad status from ${label}"
  ip="$(security_json_field "${json}" "ip")"

  if [[ "${expected}" == "true" ]]; then
    [[ "${json}" == *'"mullvad_exit_ip":true'* ]] || fail "${label} is not exiting via Mullvad. Response: ${json}"
    log_ok "${label} exits via Mullvad (${ip:-unknown IP})."
  else
    [[ "${json}" == *'"mullvad_exit_ip":false'* ]] || fail "${label} unexpectedly exits via Mullvad. Response: ${json}"
    log_ok "${label} exits directly (${ip:-unknown IP})."
  fi
}

security_http_status() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "${url}"
    return "$?"
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY'
import sys
import urllib.error
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=10) as response:
        print(response.status)
except urllib.error.HTTPError as exc:
    print(exc.code)
PY
    return "$?"
  fi

  fail "curl or python3 is required to probe nginx routes."
}

security_expect_route_ok() {
  local path="$1"
  local status

  status="$(security_http_status "http://${SECURITY_ROUTE_CHECK_HOST}:${NGINX_PORT:-8090}${path}")" || fail "Route ${path} transport probe failed."
  case "${status}" in
    200|204|301|302|307|308)
      log_ok "Route ${path} responds locally with ${status}."
      ;;
    *)
      fail "Route ${path} returned unexpected status ${status}."
      ;;
  esac
}

security_expect_redirect_within() {
  local path="$1"
  local prefix="$2"
  local location
  local location_path

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is unavailable; skipped the redirect prefix check for ${path}."
    return
  fi

  location="$(curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{redirect_url}' \
    "http://${SECURITY_ROUTE_CHECK_HOST}:${NGINX_PORT:-8090}${path}")" || fail "Route ${path} transport probe failed."
  [[ -n "${location}" ]] || return 0
  location_path="/${location#*://*/}"
  [[ "${location_path}" == "${prefix}"* ]] || fail "Route ${path} redirects outside ${prefix}: ${location}"
  log_ok "Route ${path} redirects within ${prefix}."
}

cmd_security_check() {
  local fix_env=0
  local gluetun_id qbittorrent_id sonarr_id nginx_id homarr_id glances_id
  local gluetun_health qbittorrent_mode
  local route

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        require_arg_value "$1" "$#"
        ENV_FILE="$(resolve_cli_path "$2")"
        shift 2
        ;;
      --fix-env)
        fix_env=1
        shift
        ;;
      -h|--help)
        security_usage
        return 0
        ;;
      *)
        fail "Unknown argument: $1 (see scripts/stack.sh security-check --help)"
        ;;
    esac
  done

  [[ -f "${ENV_FILE}" ]] || fail "Missing env file: ${ENV_FILE}"
  prepare_env_file "${ENV_FILE}" "${fix_env}"
  load_env_file "${ENV_FILE}"

  apply_env_defaults
  security_set_route_check_host
  validate_hex_secret "HOMARR_SECRET_ENCRYPTION_KEY"
  validate_hex_secret "GLUETUN_CONTROL_API_KEY"

  detect_compose_command
  resolve_docker_bin || fail "Docker is not available. Set DOCKER_BIN or install docker."

  run_compose --env-file "${ENV_FILE}" config > /dev/null
  log_ok "Compose config validates (${COMPOSE_CMD_DISPLAY})."

  gluetun_id="$(security_get_service_container "gluetun")"
  qbittorrent_id="$(security_get_service_container "qbittorrent")"
  sonarr_id="$(security_get_service_container "sonarr")"
  nginx_id="$(security_get_service_container "nginx-proxy")"
  homarr_id="$(security_get_service_container "homarr")"
  glances_id="$(security_get_service_container "glances")"

  gluetun_health="$("${DOCKER_BIN}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${gluetun_id}")"
  [[ "${gluetun_health}" == "healthy" ]] || fail "Gluetun is not healthy: ${gluetun_health}"
  log_ok "Gluetun is healthy."

  qbittorrent_mode="$("${DOCKER_BIN}" inspect --format '{{.HostConfig.NetworkMode}}' "${qbittorrent_id}")"
  [[ "${qbittorrent_mode}" == "container:${gluetun_id}" ]] || fail "qBittorrent is not sharing Gluetun's network namespace: ${qbittorrent_mode}"
  log_ok "qBittorrent shares Gluetun's network namespace."

  security_assert_no_published_ports "Homarr" "${homarr_id}"
  security_assert_no_published_ports "Glances" "${glances_id}"
  security_assert_no_docker_socket_mount "Homarr" "${homarr_id}"
  security_assert_no_docker_socket_mount "Glances" "${glances_id}"
  security_assert_read_only_mount "Gluetun" "${gluetun_id}" "/gluetun/auth/config.toml"
  security_assert_read_only_mount "Glances" "${glances_id}" "/etc/glances.conf"
  security_check_gluetun_control_policy "${gluetun_id}"

  "${DOCKER_BIN}" exec "${nginx_id}" nginx -t > /dev/null
  log_ok "nginx syntax validation passed."

  security_expect_mullvad_status "Gluetun" "${gluetun_id}" "true"
  security_expect_mullvad_status "qBittorrent" "${qbittorrent_id}" "true"
  security_expect_mullvad_status "Sonarr" "${sonarr_id}" "false"
  security_check_qbittorrent_tunnel_binding "${gluetun_id}" "${qbittorrent_id}"
  security_check_qbittorrent_dht "${qbittorrent_id}"

  security_expect_route_ok "/health"
  security_expect_route_ok "/"
  for route in jellyfin qbittorrent sonarr radarr prowlarr bazarr homepage; do
    security_expect_route_ok "/${route}"
    security_expect_route_ok "/${route}/"
  done
  security_expect_redirect_within "/jellyfin/" "/jellyfin/"

  log_info "Security checks passed."
}

# ---------------------------------------------------------------------------
# backup: config-only archives
# ---------------------------------------------------------------------------

BACKUP_CONFIG_PATHS=(
  "Jellyfin/Config"
  "Jellyseerr/Config"
  "Sonarr/Config"
  "Radarr/Config"
  "Prowlarr/Config"
  "Bazarr/Config"
  "Qbittorrent/Config"
  "Homarr/AppData"
  "Glances/glances.conf"
  # Keep existing Homepage data recoverable even though its templates are gone.
  "Homepage/Config"
)
BACKUP_TEMP_ARCHIVE=""

backup_usage() {
  cat <<'USAGE'
Usage: scripts/stack.sh backup [--env-file PATH] [--output-dir PATH] [--keep N]

Creates a timestamped tar.gz archive containing only service configuration
folders from COMMON_PATH. Media libraries and downloads are intentionally
excluded. Stop application writers before taking this raw filesystem backup;
use application-supported exports for online backups. Secrets from .env and the
Gluetun control-server auth file are never included.

Options:
  --output-dir PATH   Archive folder (default: COMMON_PATH/Backups).
  --keep N            After a successful backup, keep only the newest N
                      archives in the output folder and delete older ones.
USAGE
}

backup_cleanup() {
  if [[ -n "${BACKUP_TEMP_ARCHIVE}" ]]; then
    rm -f -- "${BACKUP_TEMP_ARCHIVE}"
  fi
}

# Archive names start with a sortable timestamp, so name order is age order.
backup_prune() {
  local output_dir_abs="$1"
  local keep="$2"
  local archives=()
  local archive
  local index=0

  while IFS= read -r archive; do
    [[ -n "${archive}" ]] && archives+=("${archive}")
  done < <(find "${output_dir_abs}" -maxdepth 1 -type f -name 'media-stack-configs-*.tar.gz' -print | LC_ALL=C sort -r)

  for archive in "${archives[@]}"; do
    index=$((index + 1))
    (( index > keep )) || continue
    rm -f -- "${archive}" || fail "Failed to prune old backup: ${archive}"
    log_info "Pruned old backup: ${archive}"
  done
}

cmd_backup() {
  local output_dir=""
  local keep=""
  local common_path_abs output_dir_abs path timestamp archive_name archive_path
  local existing_paths=()

  umask 077

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        require_arg_value "$1" "$#"
        ENV_FILE="$(resolve_cli_path "$2")"
        shift 2
        ;;
      --output-dir)
        require_arg_value "$1" "$#"
        output_dir="$(resolve_cli_path "$2")"
        shift 2
        ;;
      --keep)
        require_arg_value "$1" "$#"
        keep="$2"
        [[ "${keep}" =~ ^[1-9][0-9]*$ ]] || fail "--keep must be a positive whole number: ${keep}"
        shift 2
        ;;
      -h|--help)
        backup_usage
        return 0
        ;;
      *)
        fail "Unknown argument: $1 (see scripts/stack.sh backup --help)"
        ;;
    esac
  done

  load_env_file_strict "${ENV_FILE}"
  [[ -n "${COMMON_PATH:-}" ]] || fail "COMMON_PATH is missing in ${ENV_FILE}"

  common_path_abs="$(resolve_path "${COMMON_PATH}")"
  [[ -d "${common_path_abs}" ]] || fail "COMMON_PATH does not exist: ${common_path_abs}"

  output_dir_abs="${output_dir:-${common_path_abs}/Backups}"
  mkdir -p "${output_dir_abs}"
  chmod 0700 "${output_dir_abs}" || fail "Failed to restrict backup directory permissions: ${output_dir_abs}"

  warn "Raw configuration archives require stopped application writers; a successful tar does not prove database consistency."
  if [[ -d "${common_path_abs}/Homarr/AppData" ]]; then
    warn "Export a Homarr backup ZIP too, and stop Homarr before copying AppData."
    warn "Keep HOMARR_SECRET_ENCRYPTION_KEY in a separate protected escrow; it is not included here."
  fi

  for path in "${BACKUP_CONFIG_PATHS[@]}"; do
    if [[ -e "${common_path_abs}/${path}" ]]; then
      existing_paths+=("${path}")
    else
      warn "Skipping missing config path: ${common_path_abs}/${path}"
    fi
  done

  [[ "${#existing_paths[@]}" -gt 0 ]] || fail "No config folders found under ${common_path_abs}."

  timestamp="$(date +%Y%m%d-%H%M%S)"
  trap backup_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  BACKUP_TEMP_ARCHIVE="$(mktemp "${output_dir_abs}/.media-stack-configs-${timestamp}.XXXXXX")" || fail "Failed to create backup staging file."
  archive_name="${BACKUP_TEMP_ARCHIVE##*/}"
  archive_path="${output_dir_abs}/${archive_name#.}.tar.gz"

  (
    cd "${common_path_abs}"
    tar -czf "${BACKUP_TEMP_ARCHIVE}" "${existing_paths[@]}"
  ) || fail "Backup creation failed; no archive was published."

  chmod 0600 "${BACKUP_TEMP_ARCHIVE}" || fail "Failed to restrict archive permissions."
  # The mktemp suffix keeps same-second backups distinct. Publish on the same
  # filesystem without overwriting another archive or requiring hardlink support.
  mv -n -- "${BACKUP_TEMP_ARCHIVE}" "${archive_path}" || fail "Failed to publish backup."
  [[ ! -e "${BACKUP_TEMP_ARCHIVE}" ]] || fail "Refusing to overwrite existing backup: ${archive_path}"

  log_ok "Config backup written: ${archive_path}"

  if [[ -n "${keep}" ]]; then
    backup_prune "${output_dir_abs}" "${keep}"
  fi
}

# ---------------------------------------------------------------------------
# restore: allowlisted config restore with rollback
# ---------------------------------------------------------------------------

RESTORE_TARGETS=(
  "Jellyfin/Config" "Jellyseerr/Config" "Sonarr/Config" "Radarr/Config"
  "Prowlarr/Config" "Bazarr/Config" "Qbittorrent/Config" "Homarr/AppData"
  "Glances/glances.conf" "Homepage/Config"
)
# Rollback state lives in globals because the EXIT trap reads it after
# cmd_restore has returned or exited.
RESTORE_COMMON_PATH=""
RESTORE_STAGE_DIR=""
RESTORE_ATTEMPTED=()
RESTORE_CREATED_PARENTS=()
RESTORE_COMMITTED=0

restore_usage() {
  cat <<'USAGE'
Usage: scripts/stack.sh restore --archive PATH [--env-file PATH] [--dry-run] [--force]

Validates and restores an archive created by scripts/stack.sh backup into
COMMON_PATH. Existing non-empty configuration directories are refused unless
--force is supplied. Archived targets are replaced, not merged; destination-only
files in those targets are removed. Stop writers and back up before restoring.
This never restores .env, Gluetun control credentials,
media libraries, or downloads.
USAGE
}

restore_path_matches_target() {
  local member="${1%/}" target="$2"
  [[ "${member}" == "${target}" ]] ||
    { [[ "${target}" != "Glances/glances.conf" && "${member}" == "${target}/"* ]]; }
}

restore_path_is_allowed() {
  local target
  for target in "${RESTORE_TARGETS[@]}"; do
    if restore_path_matches_target "$1" "${target}"; then return 0; fi
  done
  return 1
}

restore_cleanup() {
  local index path target original parent rollback_failed=0
  [[ -n "${RESTORE_STAGE_DIR}" ]] || return 0
  if [[ "${RESTORE_COMMITTED}" -ne 1 ]]; then
    for ((index=${#RESTORE_ATTEMPTED[@]}-1; index>=0; index--)); do
      path="${RESTORE_ATTEMPTED[index]}"
      target="${RESTORE_COMMON_PATH}/${path}"
      original="${RESTORE_STAGE_DIR}/originals/${path}"
      if [[ -e "${original}" || ! -e "${RESTORE_STAGE_DIR}/new/${path}" ]]; then
        if [[ -e "${target}" ]] && ! mv -- "${target}" "${RESTORE_STAGE_DIR}/rejected/${path}"; then
          rollback_failed=1
          continue
        fi
        if [[ -e "${original}" ]] && ! mv -- "${original}" "${target}"; then rollback_failed=1; fi
      fi
    done
    for parent in "${RESTORE_CREATED_PARENTS[@]}"; do rmdir -- "${parent}" 2>/dev/null || true; done
  fi
  if [[ "${rollback_failed}" -eq 1 ]]; then
    printf 'ERROR: Recovery could not complete; originals retained in %s/originals\n' "${RESTORE_STAGE_DIR}" >&2
  else
    rm -rf -- "${RESTORE_STAGE_DIR}"
  fi
}

cmd_restore() {
  local archive="" force=0 dry_run=0
  local common_device archive_listing archive_types entry path parent target destination
  local archive_entries=()
  local selected_paths=()

  umask 077

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive)
        require_arg_value "$1" "$#"
        archive="$(resolve_cli_path "$2")"
        shift 2
        ;;
      --env-file)
        require_arg_value "$1" "$#"
        ENV_FILE="$(resolve_cli_path "$2")"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      -h|--help)
        restore_usage
        return 0
        ;;
      *)
        fail "Unknown argument: $1 (see scripts/stack.sh restore --help)"
        ;;
    esac
  done

  [[ -n "${archive}" ]] || fail "--archive is required."
  [[ -f "${ENV_FILE}" ]] || fail "Missing env file: ${ENV_FILE}"
  [[ -f "${archive}" ]] || fail "Missing backup archive: ${archive}"

  load_env_file_strict "${ENV_FILE}"

  [[ -n "${COMMON_PATH:-}" ]] || fail "COMMON_PATH is missing in ${ENV_FILE}"
  [[ "${PUID:-}" =~ ^[0-9]+$ ]] || fail "PUID must be numeric in ${ENV_FILE}"
  [[ "${PGID:-}" =~ ^[0-9]+$ ]] || fail "PGID must be numeric in ${ENV_FILE}"

  RESTORE_COMMON_PATH="$(resolve_path "${COMMON_PATH}")"
  [[ -d "${RESTORE_COMMON_PATH}" ]] || fail "COMMON_PATH does not exist: ${RESTORE_COMMON_PATH}"
  RESTORE_COMMON_PATH="$(cd -- "${RESTORE_COMMON_PATH}" && pwd -P)"
  common_device="$(stat -c '%d' "${RESTORE_COMMON_PATH}")"

  archive_listing="$(tar -tzf "${archive}")" || fail "Failed to list backup archive; it may be truncated or corrupt."
  archive_types="$(LC_ALL=C tar -tvzf "${archive}")" || fail "Failed to inspect backup archive member types."
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    case "${entry:0:1}" in
      -|d) ;;
      l) fail "Archive contains symbolic links; restore aborted." ;;
      *) fail "Archive contains unsupported member types; only regular files and directories are allowed." ;;
    esac
  done <<< "${archive_types}"

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    [[ "${entry}" != /* ]] || fail "Archive contains an absolute path: ${entry}"
    [[ ! "/${entry}/" =~ /\.\.?/ ]] || fail "Archive contains path traversal: ${entry}"
    restore_path_is_allowed "${entry}" || fail "Archive contains a path outside the configuration allowlist: ${entry}"
    archive_entries+=("${entry}")
  done <<< "${archive_listing}"

  [[ "${#archive_entries[@]}" -gt 0 ]] || fail "Archive is empty."

  for path in "${RESTORE_TARGETS[@]}"; do
    for entry in "${archive_entries[@]}"; do
      if restore_path_matches_target "${entry}" "${path}"; then
        selected_paths+=("${path}")
        break
      fi
    done
  done

  for path in "${selected_paths[@]}"; do
    parent="${RESTORE_COMMON_PATH}/${path%/*}"
    target="${RESTORE_COMMON_PATH}/${path}"
    [[ ! -L "${parent}" && ! -L "${target}" ]] || fail "Restore destination contains a symbolic link: ${path}"
    [[ ! -e "${parent}" || -d "${parent}" ]] || fail "Restore parent is not a directory: ${parent}"
    # Renames must stay on one filesystem; mv could otherwise copy and remove
    # files before failing on a separately mounted configuration directory.
    for destination in "${parent}" "${target}"; do
      if [[ -e "${destination}" ]]; then
        [[ "$(stat -c '%d' "${destination}")" == "${common_device}" ]] ||
          fail "Restore target is on another filesystem; use a native application restore: ${destination}"
      fi
    done
    if [[ -e "${target}" ]]; then
      if [[ "${path}" == "Glances/glances.conf" ]]; then
        [[ -f "${target}" ]] || fail "Restore target must be a regular file: ${target}"
      else
        [[ -d "${target}" ]] || fail "Restore target must be a directory: ${target}"
      fi
    fi
    if [[ -e "${target}" && "${force}" -ne 1 ]] &&
       { [[ -f "${target}" ]] || [[ -n "$(find "${target}" -mindepth 1 -print -quit)" ]]; }; then
      fail "Refusing to overwrite non-empty ${RESTORE_COMMON_PATH}/${path}; stop the stack, take a fresh backup, then rerun with --force."
    fi
  done

  if [[ "${dry_run}" -eq 1 ]]; then
    printf 'Validated %s entries for restore into %s\n' "${#archive_entries[@]}" "${RESTORE_COMMON_PATH}"
    return 0
  fi

  RESTORE_STAGE_DIR="$(mktemp -d "${RESTORE_COMMON_PATH}/.restore-configs.XXXXXX")" || fail "Failed to create restore staging directory."
  RESTORE_ATTEMPTED=()
  RESTORE_CREATED_PARENTS=()
  RESTORE_COMMITTED=0
  trap restore_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  mkdir "${RESTORE_STAGE_DIR}/new" "${RESTORE_STAGE_DIR}/originals" "${RESTORE_STAGE_DIR}/rejected"
  tar -xzf "${archive}" -C "${RESTORE_STAGE_DIR}/new"
  if [[ -n "$(find "${RESTORE_STAGE_DIR}/new" -type l -print -quit)" ]]; then
    fail "Archive contains symbolic links; restore aborted."
  fi
  find "${RESTORE_STAGE_DIR}/new" -perm /6000 -exec chmod a-s {} +
  for path in "${selected_paths[@]}"; do
    if [[ "${path}" == "Glances/glances.conf" ]]; then
      [[ -f "${RESTORE_STAGE_DIR}/new/${path}" ]] || fail "Archived Glances config is not a regular file."
    else
      [[ -d "${RESTORE_STAGE_DIR}/new/${path}" ]] || fail "Archived configuration is not a directory: ${path}"
    fi
    chown -R "${PUID}:${PGID}" "${RESTORE_STAGE_DIR}/new/${path}" || fail "Failed to prepare ownership for ${path}."
    mkdir -p "${RESTORE_STAGE_DIR}/originals/${path%/*}" "${RESTORE_STAGE_DIR}/rejected/${path%/*}"
  done

  for path in "${selected_paths[@]}"; do
    parent="${RESTORE_COMMON_PATH}/${path%/*}"
    if [[ ! -d "${parent}" ]]; then
      mkdir "${parent}"
      RESTORE_CREATED_PARENTS+=("${parent}")
      chown "${PUID}:${PGID}" "${parent}"
      chmod 0750 "${parent}"
    fi
    target="${RESTORE_COMMON_PATH}/${path}"
    RESTORE_ATTEMPTED+=("${path}")
    if [[ -e "${target}" ]]; then
      mv -- "${target}" "${RESTORE_STAGE_DIR}/originals/${path}" || fail "Failed to preserve existing ${path}."
    fi
    mv -- "${RESTORE_STAGE_DIR}/new/${path}" "${target}" || fail "Failed to replace ${path}; rolling back."
  done
  RESTORE_COMMITTED=1

  log_ok "Configuration restore completed: ${archive}"
  log_info "HOMARR_SECRET_ENCRYPTION_KEY and Gluetun credentials were not restored; keep the existing protected values."
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage: scripts/stack.sh <command> [options]

Commands:
  setup            Interactive setup and .env generation
  doctor           Read-only environment and Compose validation (--fix-env is opt-in)
  security-check   Read-only VPN, isolation, and routing checks on the running stack
  backup           Config-only backup archive under COMMON_PATH/Backups
  restore          Allowlisted config restore with dry-run and overwrite protection
  help             Show this help

Run scripts/stack.sh <command> --help for command options. Relative paths given
on the command line resolve from the current directory; COMMON_PATH in .env
resolves from the repository root.
USAGE
}

main() {
  local subcommand="${1:-}"
  [[ $# -eq 0 ]] || shift

  case "${subcommand}" in
    setup) cmd_setup "$@" ;;
    doctor) cmd_doctor "$@" ;;
    security-check) cmd_security_check "$@" ;;
    backup) cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    help|-h|--help) usage ;;
    "")
      usage >&2
      exit 1
      ;;
    *)
      log_err "Unknown command: ${subcommand}"
      usage >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
