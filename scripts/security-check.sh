#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
ENV_FILE="${REPO_ROOT}/.env"
FIX_ENV=0
ROUTE_CHECK_HOST="127.0.0.1"

usage() {
  cat <<'USAGE'
Usage: scripts/security-check.sh [--env-file PATH] [--fix-env]

Checks:
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

log_ok() {
  echo "OK: $*"
}

log_info() {
  echo "INFO: $*"
}

set_route_check_host() {
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

  bindings="$("${DOCKER_BIN}" inspect --format '{{range .NetworkSettings.Ports}}{{range .}}{{println .HostIp .HostPort}}{{end}}{{end}}' "${container_id}")"
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

check_gluetun_control_policy() {
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

fetch_container_json() {
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

json_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "${json}" | sed -n "s/.*\"${field}\":\"\\([^\"]*\\)\".*/\\1/p"
}

json_boolean_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "${json}" | sed -n "s/.*\"${field}\":\\(true\\|false\\).*/\\1/p"
}

json_number_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "${json}" | sed -n "s/.*\"${field}\":\\([0-9][0-9]*\\).*/\\1/p"
}

fetch_qbittorrent_api_json() {
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

qbittorrent_recovery_hint() {
  cat >&2 <<EOF
In qBittorrent, open Settings -> Advanced and set:
  Network Interface: tun0
  Optional IP address to bind to: All IPv4 addresses
Keep DHT and PeX enabled, apply the settings, then run:
  ${COMPOSE_CMD_DISPLAY} restart qbittorrent
EOF
}

check_qbittorrent_tunnel_binding() {
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
    qbittorrent_recovery_hint
    fail "qBittorrent is not listening on tun0 at ${tunnel_endpoint} for both TCP and UDP."
  fi

  log_ok "qBittorrent listens on tun0 at ${tunnel_endpoint} over TCP and UDP."
}

check_qbittorrent_dht() {
  local qbittorrent_id="$1"
  local dht_enabled
  local dht_nodes
  local preferences_json
  local transfer_json
  local attempt

  if ! preferences_json="$(fetch_qbittorrent_api_json "${qbittorrent_id}" "app/preferences" 2>/dev/null)"; then
    warn "Cannot query the local qBittorrent API; skipped DHT verification after the tunnel listener passed."
    return
  fi

  dht_enabled="$(json_boolean_field "${preferences_json}" "dht")"
  if [[ "${dht_enabled}" != "true" ]]; then
    qbittorrent_recovery_hint
    fail "qBittorrent DHT is disabled or its state could not be determined."
  fi

  for attempt in {0..12}; do
    transfer_json="$(fetch_qbittorrent_api_json "${qbittorrent_id}" "transfer/info" 2>/dev/null || true)"
    dht_nodes="$(json_number_field "${transfer_json}" "dht_nodes")"
    if [[ "${dht_nodes}" =~ ^[0-9]+$ ]] && (( dht_nodes > 0 )); then
      log_ok "qBittorrent DHT has ${dht_nodes} connected nodes."
      return
    fi
    if (( attempt < 12 )); then
      sleep 5
    fi
  done

  qbittorrent_recovery_hint
  fail "qBittorrent DHT remained at zero connected nodes for 60 seconds."
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

expect_route_ok() {
  local path="$1"
  local status

  status="$(http_status "http://${ROUTE_CHECK_HOST}:${NGINX_PORT:-8090}${path}")" || fail "Route ${path} transport probe failed."
  case "${status}" in
    200|204|301|302|307|308)
      log_ok "Route ${path} responds locally with ${status}."
      ;;
    *)
      fail "Route ${path} returned unexpected status ${status}."
      ;;
  esac
}

expect_redirect_within() {
  local path="$1"
  local prefix="$2"
  local location
  local location_path

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is unavailable; skipped the redirect prefix check for ${path}."
    return
  fi

  location="$(curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{redirect_url}' \
    "http://${ROUTE_CHECK_HOST}:${NGINX_PORT:-8090}${path}")" || fail "Route ${path} transport probe failed."
  [[ -n "${location}" ]] || return 0
  location_path="/${location#*://*/}"
  [[ "${location_path}" == "${prefix}"* ]] || fail "Route ${path} redirects outside ${prefix}: ${location}"
  log_ok "Route ${path} redirects within ${prefix}."
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
prepare_env_file "${ENV_FILE}" "${FIX_ENV}"
load_env_file "${ENV_FILE}"

apply_env_defaults
set_route_check_host
validate_hex_secret "HOMARR_SECRET_ENCRYPTION_KEY"
validate_hex_secret "GLUETUN_CONTROL_API_KEY"

detect_compose_command
resolve_docker_bin || fail "Docker is not available. Set DOCKER_BIN or install docker."

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

gluetun_health="$("${DOCKER_BIN}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${gluetun_id}")"
[[ "${gluetun_health}" == "healthy" ]] || fail "Gluetun is not healthy: ${gluetun_health}"
log_ok "Gluetun is healthy."

qbittorrent_mode="$("${DOCKER_BIN}" inspect --format '{{.HostConfig.NetworkMode}}' "${qbittorrent_id}")"
[[ "${qbittorrent_mode}" == "container:${gluetun_id}" ]] || fail "qBittorrent is not sharing Gluetun's network namespace: ${qbittorrent_mode}"
log_ok "qBittorrent shares Gluetun's network namespace."

assert_no_published_ports "Homarr" "${homarr_id}"
assert_no_published_ports "Glances" "${glances_id}"
assert_no_docker_socket_mount "Homarr" "${homarr_id}"
assert_no_docker_socket_mount "Glances" "${glances_id}"
assert_read_only_mount "Gluetun" "${gluetun_id}" "/gluetun/auth/config.toml"
assert_read_only_mount "Glances" "${glances_id}" "/etc/glances.conf"
check_gluetun_control_policy "${gluetun_id}"

"${DOCKER_BIN}" exec "${nginx_id}" nginx -t > /dev/null
log_ok "nginx syntax validation passed."

expect_mullvad_status "Gluetun" "${gluetun_id}" "true"
expect_mullvad_status "qBittorrent" "${qbittorrent_id}" "true"
expect_mullvad_status "Sonarr" "${sonarr_id}" "false"
check_qbittorrent_tunnel_binding "${gluetun_id}" "${qbittorrent_id}"
check_qbittorrent_dht "${qbittorrent_id}"

expect_route_ok "/health"
expect_route_ok "/"
expect_route_ok "/jellyfin"
expect_route_ok "/jellyfin/"
expect_redirect_within "/jellyfin/" "/jellyfin/"
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
