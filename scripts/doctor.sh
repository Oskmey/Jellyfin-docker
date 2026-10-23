#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
ENV_FILE="${REPO_ROOT}/.env"
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

check_render_gid() {
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

prepare_env_file "${ENV_FILE}" "${FIX_ENV}"
load_env_file "${ENV_FILE}"
validate_required_env
check_nas_devices
check_render_gid
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
