#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXAMPLE_FILE="${REPO_ROOT}/.env.example"
ENV_FILE="${REPO_ROOT}/.env"
NON_INTERACTIVE=0
FORCE=0
NO_COLOR=0
CURRENT_STEP="startup"
DIR_CREATED=0
DIR_REUSED=0
WARNINGS=0
FAILURES=0
DOCKER_BIN="${DOCKER_BIN:-}"
COMPOSE_CMD=()
COMPOSE_CMD_DISPLAY=""

if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
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

usage() {
  cat <<USAGE
Usage: scripts/setup.sh [options]

Options:
  --non-interactive   Validate and use an existing env file without prompts.
  --env-file PATH     Path to env file (default: .env in repo root).
  --force             Overwrite existing env values without reuse prompt.
  --no-color          Disable colored output.
  -h, --help          Show this help.

Environment:
  DOCKER_BIN          Override the docker binary path.
  DOCKER_COMPOSE_BIN  Override the docker-compose binary path.
USAGE
}

print_header() {
  printf "%b\n" "${C_BOLD}${C_BLUE}============================================================${C_RESET}"
  printf "%b\n" "${C_BOLD}${C_BLUE}  Jellyfin Docker Setup${C_RESET}"
  printf "%b\n" "${C_DIM}  Repository: ${REPO_ROOT}${C_RESET}"
  printf "%b\n" "${C_BOLD}${C_BLUE}============================================================${C_RESET}"
  printf "\n"
}

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

log_warn() {
  WARNINGS=$((WARNINGS + 1))
  printf "%b\n" "${C_YELLOW}[WARN]${C_RESET} $*"
}

log_err() {
  printf "%b\n" "${C_RED}[ERR ]${C_RESET} $*" >&2
}

die() {
  FAILURES=$((FAILURES + 1))
  log_err "$*"
  exit 1
}

on_error() {
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

trap 'on_error $? ${LINENO} "$BASH_COMMAND"' ERR

mask_value() {
  local value="$1"
  local len=${#value}
  if [[ "${len}" -le 8 ]]; then
    printf '********'
    return
  fi
  printf '%s****%s' "${value:0:4}" "${value: -4}"
}

ensure_env_file_permissions() {
  local env_path="$1"

  [[ -f "${env_path}" ]] || return 0

  if chmod 600 "${env_path}" 2>/dev/null; then
    return 0
  fi

  log_warn "Failed to restrict permissions on ${env_path}; secure it manually."
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
    [[ -x "${DOCKER_BIN}" ]] || die "DOCKER_BIN is not executable: ${DOCKER_BIN}"
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
    [[ -x "${DOCKER_COMPOSE_BIN}" ]] || die "DOCKER_COMPOSE_BIN is not executable: ${DOCKER_COMPOSE_BIN}"
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

  die "Docker Compose is not available. Set DOCKER_COMPOSE_BIN, or install docker compose/docker-compose."
}

require_commands() {
  detect_compose_command
}

run_compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

normalize_env_file_line_endings() {
  local env_path="$1"
  local tmp_file

  if LC_ALL=C grep -q $'\r' "${env_path}"; then
    tmp_file="$(mktemp "${env_path}.tmp.XXXXXX")" || die "Failed to create temp file for ${env_path}."

    if ! tr -d '\r' < "${env_path}" > "${tmp_file}"; then
      rm -f "${tmp_file}"
      die "Failed to normalize line endings in ${env_path}."
    fi

    if ! mv "${tmp_file}" "${env_path}"; then
      rm -f "${tmp_file}"
      die "Failed to replace ${env_path} after line ending normalization."
    fi

    log_warn "Detected Windows line endings in ${env_path}; converted to Unix LF."
  fi
}

source_env_file() {
  local env_path="$1"

  [[ -f "${env_path}" ]] || die "Missing env file: ${env_path}"
  normalize_env_file_line_endings "${env_path}"
  ensure_env_file_permissions "${env_path}"

  set -a
  # shellcheck disable=SC1090
  source "${env_path}"
  set +a
}

prompt_default() {
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

prompt_required() {
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

validate_port() {
  local key="$1"
  local value="${!key:-}"

  [[ -n "${value}" ]] || return 0
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${key} must be a numeric port: ${value}"
  (( value >= 1 && value <= 65535 )) || die "${key} must be between 1 and 65535: ${value}"
}

validate_http_url() {
  local key="$1"
  local value="${!key:-}"

  [[ -n "${value}" ]] || return 0
  [[ "${value}" =~ ^https?://[^[:space:]]+$ ]] || die "${key} must start with http:// or https:// and contain no spaces: ${value}"
}

validate_required_env() {
  local missing=0
  local required=(
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

  for key in "${required[@]}"; do
    if [[ -z "${!key:-}" ]]; then
      log_err "${key} is missing in ${ENV_FILE}"
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi

  validate_port "NGINX_PORT"
  validate_port "JELLYSEERR_PORT"
  validate_http_url "JELLYSEERR_EXTERNAL_URL"
}

load_env_file() {
  source_env_file "${ENV_FILE}"
}

write_env_file() {
  cat > "${ENV_FILE}" <<ENVEOF
# Generated by scripts/setup.sh
COMMON_PATH=${COMMON_PATH}
TZ=${TZ}
PUID=${PUID}
PGID=${PGID}
NGINX_PORT=${NGINX_PORT}
JELLYSEERR_PORT=${JELLYSEERR_PORT}
JELLYSEERR_EXTERNAL_URL=${JELLYSEERR_EXTERNAL_URL}
SERVER_COUNTRIES=${SERVER_COUNTRIES}
WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES}
WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY}
WIREGUARD_PUBLIC_KEY=${WIREGUARD_PUBLIC_KEY}
WIREGUARD_ENDPOINT=${WIREGUARD_ENDPOINT}
WIREGUARD_ALLOWED_IPS=${WIREGUARD_ALLOWED_IPS}
ENVEOF
  ensure_env_file_permissions "${ENV_FILE}"
  log_ok "Wrote ${ENV_FILE}"
}

print_summary() {
  printf "\n"
  printf "%b\n" "${C_BOLD}Configuration Summary${C_RESET}"
  printf "  %-24s %s\n" "COMMON_PATH" "${COMMON_PATH}"
  printf "  %-24s %s\n" "COMMON_PATH (absolute)" "$(resolve_path "${COMMON_PATH}")"
  printf "  %-24s %s\n" "TZ" "${TZ}"
  printf "  %-24s %s\n" "PUID/PGID" "${PUID}/${PGID}"
  printf "  %-24s %s\n" "NGINX_PORT" "${NGINX_PORT}"
  printf "  %-24s %s\n" "JELLYSEERR_PORT" "${JELLYSEERR_PORT}"
  printf "  %-24s %s\n" "JELLYSEERR_EXTERNAL_URL" "${JELLYSEERR_EXTERNAL_URL}"
  printf "  %-24s %s\n" "SERVER_COUNTRIES" "${SERVER_COUNTRIES}"
  printf "  %-24s %s\n" "WIREGUARD_ADDRESSES" "$(mask_value "${WIREGUARD_ADDRESSES}")"
  printf "  %-24s %s\n" "WIREGUARD_PRIVATE_KEY" "$(mask_value "${WIREGUARD_PRIVATE_KEY}")"
  printf "  %-24s %s\n" "WIREGUARD_PUBLIC_KEY" "$(mask_value "${WIREGUARD_PUBLIC_KEY}")"
  printf "  %-24s %s\n" "WIREGUARD_ENDPOINT" "${WIREGUARD_ENDPOINT}"
  printf "  %-24s %s\n" "WIREGUARD_ALLOWED_IPS" "${WIREGUARD_ALLOWED_IPS}"
}

ensure_directory() {
  local dir="$1"

  if [[ -d "${dir}" ]]; then
    DIR_REUSED=$((DIR_REUSED + 1))
    log_skip "Reused existing folder: ${dir}"
    return
  fi

  if [[ -e "${dir}" ]]; then
    die "Path exists but is not a directory: ${dir}"
  fi

  mkdir -p "${dir}" || die "Failed to create folder: ${dir}"
  DIR_CREATED=$((DIR_CREATED + 1))
  log_ok "Created folder: ${dir}"
}

print_final_summary() {
  printf "\n"
  printf "%b\n" "${C_BOLD}Setup Summary${C_RESET}"
  printf "  %-24s %s\n" "Directories created" "${DIR_CREATED}"
  printf "  %-24s %s\n" "Directories reused" "${DIR_REUSED}"
  printf "  %-24s %s\n" "Warnings" "${WARNINGS}"
  printf "  %-24s %s\n" "Failures" "${FAILURES}"
}

create_directories() {
  local base_path
  base_path="$(resolve_path "${COMMON_PATH}")"

  local dirs=(
    "${base_path}/Qbittorrent/Config"
    "${base_path}/Downloads"
    "${base_path}/Sonarr/Config"
    "${base_path}/Sonarr/Backup"
    "${base_path}/Sonarr/tvshows"
    "${base_path}/Radarr/Config"
    "${base_path}/Radarr/Backup"
    "${base_path}/Radarr/movies"
    "${base_path}/Prowlarr/Config"
    "${base_path}/Prowlarr/Backup"
    "${base_path}/Jellyfin/Config"
    "${base_path}/Jellyfin/Cache"
    "${base_path}/Jellyseerr/Config"
    "${base_path}/Bazarr/Config"
    "${base_path}/Homepage/Config"
  )

  log_info "COMMON_PATH resolved to: ${base_path}"
  ensure_directory "${base_path}"

  log_info "Ensuring media and config folders..."
  for dir in "${dirs[@]}"; do
    ensure_directory "${dir}"
  done
  log_ok "Folder checks complete (${#dirs[@]} targets)."
}

sync_homepage_config() {
  log_info "Syncing repo-managed Homepage config..."
  "${SCRIPT_DIR}/sync-homepage-config.sh" --env-file "${ENV_FILE}"
  log_ok "Homepage config synced."
}

run_preflight() {
  log_info "Running docker compose preflight validation..."
  (
    cd "${REPO_ROOT}"
    run_compose --env-file "${ENV_FILE}" config > /dev/null
  )
  log_ok "Compose preflight passed (${COMPOSE_CMD_DISPLAY})."
}

interactive_collect() {
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
  local default_nginx_port="${NGINX_PORT:-8090}"
  local default_jellyseerr_port="${JELLYSEERR_PORT:-5055}"
  local default_server_countries="${SERVER_COUNTRIES:-Sweden}"
  local default_allowed_ips="${WIREGUARD_ALLOWED_IPS:-0.0.0.0/0,::/0}"
  local jellyseerr_external_url_default=""

  printf "%b\n" "${C_BOLD}Environment Setup${C_RESET}"

  COMMON_PATH="$(prompt_default "COMMON_PATH" "${default_common_path}")"
  TZ="$(prompt_default "TZ" "${default_tz_value}")"
  PUID="$(prompt_default "PUID" "${default_puid}")"
  PGID="$(prompt_default "PGID" "${default_pgid}")"
  NGINX_PORT="$(prompt_default "NGINX_PORT" "${default_nginx_port}")"
  JELLYSEERR_PORT="$(prompt_default "JELLYSEERR_PORT" "${default_jellyseerr_port}")"
  jellyseerr_external_url_default="${JELLYSEERR_EXTERNAL_URL:-http://${default_host}:${JELLYSEERR_PORT}}"
  JELLYSEERR_EXTERNAL_URL="$(prompt_default "JELLYSEERR_EXTERNAL_URL" "${jellyseerr_external_url_default}")"
  SERVER_COUNTRIES="$(prompt_default "SERVER_COUNTRIES" "${default_server_countries}")"

  printf "\n"
  printf "%b\n" "${C_BOLD}Required WireGuard Settings${C_RESET}"

  WIREGUARD_ADDRESSES="$(prompt_required "WIREGUARD_ADDRESSES" "${WIREGUARD_ADDRESSES:-}")"
  WIREGUARD_PRIVATE_KEY="$(prompt_required "WIREGUARD_PRIVATE_KEY" "${WIREGUARD_PRIVATE_KEY:-}")"
  WIREGUARD_PUBLIC_KEY="$(prompt_required "WIREGUARD_PUBLIC_KEY" "${WIREGUARD_PUBLIC_KEY:-}")"
  WIREGUARD_ENDPOINT="$(prompt_required "WIREGUARD_ENDPOINT" "${WIREGUARD_ENDPOINT:-}")"
  WIREGUARD_ALLOWED_IPS="$(prompt_default "WIREGUARD_ALLOWED_IPS" "${default_allowed_ips}")"
}

confirm_continue() {
  local answer
  read -r -p "Continue with these settings? [Y/n]: " answer
  if [[ -n "${answer}" && ! "${answer}" =~ ^[Yy]$ ]]; then
    die "Setup cancelled by user."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    --env-file)
      [[ $# -ge 2 ]] || die "--env-file requires a path"
      ENV_FILE="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --no-color)
      NO_COLOR=1
      C_RESET=''
      C_BOLD=''
      C_DIM=''
      C_RED=''
      C_GREEN=''
      C_YELLOW=''
      C_BLUE=''
      C_CYAN=''
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ "${ENV_FILE}" != /* ]]; then
  ENV_FILE="${REPO_ROOT}/${ENV_FILE}"
fi

[[ -f "${EXAMPLE_FILE}" ]] || die "Missing ${EXAMPLE_FILE}"

print_header
log_info "Environment file: ${ENV_FILE}"
if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
  log_info "Mode: non-interactive"
else
  log_info "Mode: interactive"
fi

log_step "Prerequisite checks"
require_commands
log_ok "Docker Compose checks passed (${COMPOSE_CMD_DISPLAY})."

log_step "Environment configuration"
if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
  load_env_file
  validate_required_env
  log_ok "Loaded and validated ${ENV_FILE}."
else
  if [[ -f "${ENV_FILE}" ]]; then
    source_env_file "${ENV_FILE}"

    if [[ "${FORCE}" -eq 0 ]]; then
      read -r -p "${ENV_FILE} exists. Reuse and validate current values? [Y/n]: " reuse
      if [[ -z "${reuse}" || "${reuse}" =~ ^[Yy]$ ]]; then
        validate_required_env
        log_ok "Using existing env file values."
      else
        interactive_collect
        print_summary
        confirm_continue
        write_env_file
      fi
    else
      interactive_collect
      print_summary
      confirm_continue
      write_env_file
    fi
  else
    interactive_collect
    print_summary
    confirm_continue
    write_env_file
  fi
fi

validate_required_env
log_ok "Required env values are present."

log_step "Folder provisioning"
create_directories

log_step "Homepage dashboard sync"
sync_homepage_config

log_step "Compose preflight"
run_preflight

log_step "Final summary"
print_final_summary

printf "\n"
log_ok "Setup completed successfully."
printf "%b\n" "${C_BOLD}Next:${C_RESET} ${COMPOSE_CMD_DISPLAY} --env-file ${ENV_FILE} up -d"
