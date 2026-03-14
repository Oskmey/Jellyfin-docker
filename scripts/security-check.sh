#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
DOCKER_BIN="${DOCKER_BIN:-}"
COMPOSE_CMD=()
COMPOSE_CMD_DISPLAY=""

usage() {
  cat <<'USAGE'
Usage: scripts/security-check.sh [--env-file PATH]

Checks:
  - docker compose config validation
  - nginx syntax and local route responses
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

  fail "Docker Compose is not available. Set DOCKER_COMPOSE_BIN, or install docker compose/docker-compose."
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

    echo "WARN: Detected Windows line endings in ${env_path}; converted to Unix LF." >&2
  fi
}

get_service_container() {
  local service="$1"
  local container_id

  container_id="$(run_compose --env-file "${ENV_FILE}" ps -q "${service}")"
  [[ -n "${container_id}" ]] || fail "Service is not running: ${service}"
  printf '%s' "${container_id}"
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

  status="$(http_status "http://127.0.0.1:${NGINX_PORT:-8090}${path}")"
  case "${status}" in
    200|204|301|302|307|308)
      log_ok "Route ${path} responds locally with ${status}."
      ;;
    *)
      fail "Route ${path} returned unexpected status ${status}."
      ;;
  esac
}

expect_route_absent() {
  local path="$1"
  local status

  status="$(http_status "http://127.0.0.1:${NGINX_PORT:-8090}${path}")"
  [[ "${status}" == "404" ]] || fail "Route ${path} should be absent, but returned ${status}."
  log_ok "Route ${path} is absent (${status})."
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
normalize_env_file_line_endings "${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

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

gluetun_health="$("${DOCKER_BIN}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${gluetun_id}")"
[[ "${gluetun_health}" == "healthy" ]] || fail "Gluetun is not healthy: ${gluetun_health}"
log_ok "Gluetun is healthy."

qbittorrent_mode="$("${DOCKER_BIN}" inspect --format '{{.HostConfig.NetworkMode}}' "${qbittorrent_id}")"
[[ "${qbittorrent_mode}" == "container:${gluetun_id}" ]] || fail "qBittorrent is not sharing Gluetun's network namespace: ${qbittorrent_mode}"
log_ok "qBittorrent shares Gluetun's network namespace."

"${DOCKER_BIN}" exec "${nginx_id}" nginx -t > /dev/null
log_ok "nginx syntax validation passed."

expect_mullvad_status "Gluetun" "${gluetun_id}" "true"
expect_mullvad_status "qBittorrent" "${qbittorrent_id}" "true"
expect_mullvad_status "Sonarr" "${sonarr_id}" "false"

expect_route_ok "/health"
expect_route_ok "/jellyfin/"
expect_route_ok "/qbittorrent/"
expect_route_ok "/sonarr/"
expect_route_ok "/radarr/"
expect_route_ok "/prowlarr/"
expect_route_ok "/bazarr/"
expect_route_ok "/homepage/"
expect_route_absent "/portainer/"

log_info "Security checks passed."
