#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
DOCKER_BIN="${DOCKER_BIN:-}"
COMPOSE_CMD=()
COMPOSE_CMD_DISPLAY=""
FIX_ENV=0
ROUTE_CHECK_HOST="127.0.0.1"

usage() {
  cat <<'USAGE'
Usage: scripts/security-check.sh [--env-file PATH] [--fix-env]

Checks:
  - docker compose config validation
  - nginx syntax and local route responses
  - Homarr/Glances isolation from the Docker socket and host ports
  - read-only Docker socket proxy behavior
  - authenticated, read-only Gluetun telemetry configuration
  - Gluetun health
  - qBittorrent network namespace sharing with Gluetun
  - Mullvad egress from Gluetun and qBittorrent
  - direct egress from Sonarr

Environment:
  DOCKER_BIN          Override the docker binary path.
  DOCKER_COMPOSE_BIN  Override the docker-compose binary path.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

log_ok() {
  echo "OK: $*"
}

log_info() {
  echo "INFO: $*"
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

  fail "Docker is not available. Set DOCKER_BIN or install docker."
}

detect_compose_command() {
  if [[ -n "${DOCKER_COMPOSE_BIN:-}" ]]; then
    [[ -x "${DOCKER_COMPOSE_BIN}" ]] || fail "DOCKER_COMPOSE_BIN is not executable: ${DOCKER_COMPOSE_BIN}"
    COMPOSE_CMD=("${DOCKER_COMPOSE_BIN}")
    COMPOSE_CMD_DISPLAY="${DOCKER_COMPOSE_BIN}"
    return
  fi

  resolve_docker_bin

  if "${DOCKER_BIN}" compose version >/dev/null 2>&1; then
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

warn() {
  echo "WARN: $*" >&2
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

  case "${BIND_IP}" in
    0.0.0.0)
      ROUTE_CHECK_HOST="127.0.0.1"
      ;;
    ::)
      ROUTE_CHECK_HOST="[::1]"
      ;;
    *:*)
      ROUTE_CHECK_HOST="[${BIND_IP}]"
      ;;
    *)
      ROUTE_CHECK_HOST="${BIND_IP}"
      ;;
  esac
}

validate_hex_secret() {
  local key="$1"
  local value="${!key:-}"

  [[ "${value}" =~ ^[[:xdigit:]]{64}$ ]] || fail "${key} must contain exactly 64 hexadecimal characters."
}

get_service_container() {
  local service="$1"
  local container_id

  container_id="$(run_compose --env-file "${ENV_FILE}" ps -q "${service}")"
  [[ -n "${container_id}" ]] || fail "Service is not running: ${service}"
  printf '%s' "${container_id}"
}

assert_no_published_ports() {
  local label="$1"
  local container_id="$2"
  local bindings

  bindings="$("${DOCKER_BIN}" inspect --format '{{range $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp .HostPort}}{{end}}{{end}}' "${container_id}")"
  [[ -z "${bindings}" ]] || fail "${label} unexpectedly publishes a host port: ${bindings}"
  log_ok "${label} has no published host ports."
}

assert_no_docker_socket_mount() {
  local label="$1"
  local container_id="$2"
  local mounts

  mounts="$("${DOCKER_BIN}" inspect --format '{{range .Mounts}}{{println .Source "|" .Destination "|" .RW}}{{end}}' "${container_id}")"
  [[ "${mounts}" != *'/var/run/docker.sock'* ]] || fail "${label} mounts the Docker socket directly."
  log_ok "${label} has no direct Docker socket mount."
}

assert_read_only_mount() {
  local label="$1"
  local container_id="$2"
  local destination="$3"
  local mount_state

  mount_state="$("${DOCKER_BIN}" inspect --format "{{range .Mounts}}{{if eq .Destination \"${destination}\"}}{{println .RW}}{{end}}{{end}}" "${container_id}")"
  [[ "${mount_state}" == "false" ]] || fail "${label} must mount ${destination} read-only."
  log_ok "${label} mounts ${destination} read-only."
}

assert_container_env() {
  local container_id="$1"
  local expected="$2"
  local env_lines

  env_lines="$("${DOCKER_BIN}" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${container_id}")"
  grep -Fqx "${expected}" <<< "${env_lines}" || fail "Missing required container setting: ${expected}"
}

check_docker_proxy_policy() {
  local homarr_id="$1"
  local proxy_id="$2"
  local status

  assert_container_env "${proxy_id}" "POST=0"
  assert_container_env "${proxy_id}" "CONTAINERS=1"
  assert_container_env "${proxy_id}" "INFO=1"
  assert_container_env "${proxy_id}" "PING=1"
  assert_container_env "${proxy_id}" "VERSION=1"

  "${DOCKER_BIN}" exec "${homarr_id}" node -e \
    "fetch('http://docker-socket-proxy:2375/_ping').then(async r=>process.exit(r.ok&&(await r.text()).trim()==='OK'?0:1)).catch(()=>process.exit(1))" || \
    fail "Homarr cannot read the Docker proxy health endpoint."

  status="$("${DOCKER_BIN}" exec "${homarr_id}" node -e \
    "fetch('http://docker-socket-proxy:2375/containers/security-check-does-not-exist/start',{method:'POST'}).then(r=>console.log(r.status)).catch(()=>process.exit(1))")"
  [[ "${status}" == "403" ]] || fail "Docker proxy accepted or mishandled a POST request (status ${status:-unknown})."
  log_ok "Docker proxy permits telemetry GETs and rejects container-control POSTs."
}

check_gluetun_control_policy() {
  local gluetun_id="$1"

  if "${DOCKER_BIN}" exec "${gluetun_id}" wget -qO- http://127.0.0.1:8000/v1/vpn/status >/dev/null 2>&1; then
    fail "Gluetun telemetry endpoint permits unauthenticated access."
  fi

  "${DOCKER_BIN}" exec -e "SECURITY_CHECK_API_KEY=${GLUETUN_CONTROL_API_KEY}" "${gluetun_id}" sh -c \
    'wget -qO- --header "X-API-Key: ${SECURITY_CHECK_API_KEY}" http://127.0.0.1:8000/v1/vpn/status >/dev/null' || \
    fail "Authenticated Gluetun VPN telemetry request failed."
  log_ok "Gluetun telemetry requires the configured API key."
}

fetch_container_json() {
  local container_id="$1"
  "${DOCKER_BIN}" exec "${container_id}" sh -lc '
    if command -v curl >/dev/null 2>&1; then
      curl -fsS https://am.i.mullvad.net/json
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- https://am.i.mullvad.net/json
    else
      exit 127
    fi
  '
}

json_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "${json}" | sed -n "s/.*\"${field}\":\"\\([^\"]*\\)\".*/\\1/p"
}

expect_mullvad_status() {
  local label="$1"
  local container_id="$2"
  local expected="$3"
  local json
  local ip

  json="$(fetch_container_json "${container_id}")" || fail "Failed to fetch Mullvad status from ${label}"
  ip="$(json_field "${json}" "ip")"

  if [[ "${expected}" == "true" ]]; then
    [[ "${json}" == *'"mullvad_exit_ip":true'* ]] || fail "${label} is not exiting via Mullvad. Response: ${json}"
    log_ok "${label} exits via Mullvad (${ip:-unknown IP})."
  else
    [[ "${json}" == *'"mullvad_exit_ip":false'* ]] || fail "${label} unexpectedly exits via Mullvad. Response: ${json}"
    log_ok "${label} exits directly (${ip:-unknown IP})."
  fi
}

http_status() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -sS -o /dev/null -w '%{http_code}' "${url}"
    return 0
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
    return 0
  fi

  fail "curl or python3 is required to probe nginx routes."
}

expect_route_ok() {
  local path="$1"
  local status

  status="$(http_status "http://${ROUTE_CHECK_HOST}:${NGINX_PORT:-8090}${path}")"
  case "${status}" in
    200|204|301|302|307|308)
      log_ok "Route ${path} responds locally with ${status}."
      ;;
    *)
      fail "Route ${path} returned unexpected status ${status}."
      ;;
  esac
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

[[ -f "${ENV_FILE}" ]] || fail "Missing env file: ${ENV_FILE}"
prepare_env_file "${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

apply_env_defaults
validate_hex_secret "HOMARR_SECRET_ENCRYPTION_KEY"
validate_hex_secret "GLUETUN_CONTROL_API_KEY"

detect_compose_command

(
  cd "${REPO_ROOT}"
  run_compose --env-file "${ENV_FILE}" config > /dev/null
)
log_ok "Compose config validates (${COMPOSE_CMD_DISPLAY})."

gluetun_id="$(get_service_container "gluetun")"
qbittorrent_id="$(get_service_container "qbittorrent")"
sonarr_id="$(get_service_container "sonarr")"
nginx_id="$(get_service_container "nginx-proxy")"
homarr_id="$(get_service_container "homarr")"
glances_id="$(get_service_container "glances")"
docker_proxy_id="$(get_service_container "docker-socket-proxy")"

gluetun_health="$("${DOCKER_BIN}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${gluetun_id}")"
[[ "${gluetun_health}" == "healthy" ]] || fail "Gluetun is not healthy: ${gluetun_health}"
log_ok "Gluetun is healthy."

qbittorrent_mode="$("${DOCKER_BIN}" inspect --format '{{.HostConfig.NetworkMode}}' "${qbittorrent_id}")"
[[ "${qbittorrent_mode}" == "container:${gluetun_id}" ]] || fail "qBittorrent is not sharing Gluetun's network namespace: ${qbittorrent_mode}"
log_ok "qBittorrent shares Gluetun's network namespace."

assert_no_published_ports "Homarr" "${homarr_id}"
assert_no_published_ports "Glances" "${glances_id}"
assert_no_published_ports "Docker socket proxy" "${docker_proxy_id}"
assert_no_docker_socket_mount "Homarr" "${homarr_id}"
assert_no_docker_socket_mount "Glances" "${glances_id}"
assert_read_only_mount "Docker socket proxy" "${docker_proxy_id}" "/var/run/docker.sock"
assert_read_only_mount "Gluetun" "${gluetun_id}" "/gluetun/auth/config.toml"
assert_read_only_mount "Glances" "${glances_id}" "/etc/glances.conf"
check_docker_proxy_policy "${homarr_id}" "${docker_proxy_id}"
check_gluetun_control_policy "${gluetun_id}"

"${DOCKER_BIN}" exec "${nginx_id}" nginx -t > /dev/null
log_ok "nginx syntax validation passed."

expect_mullvad_status "Gluetun" "${gluetun_id}" "true"
expect_mullvad_status "qBittorrent" "${qbittorrent_id}" "true"
expect_mullvad_status "Sonarr" "${sonarr_id}" "false"

expect_route_ok "/health"
expect_route_ok "/"
expect_route_ok "/jellyfin"
expect_route_ok "/jellyfin/"
expect_route_ok "/qbittorrent"
expect_route_ok "/qbittorrent/"
expect_route_ok "/sonarr"
expect_route_ok "/sonarr/"
expect_route_ok "/radarr"
expect_route_ok "/radarr/"
expect_route_ok "/prowlarr"
expect_route_ok "/prowlarr/"
expect_route_ok "/bazarr"
expect_route_ok "/bazarr/"
expect_route_ok "/homepage"
expect_route_ok "/homepage/"

log_info "Security checks passed."
