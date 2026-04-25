#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
OUTPUT_DIR=""

usage() {
  cat <<'USAGE'
Usage: scripts/backup-configs.sh [--env-file PATH] [--output-dir PATH]

Creates a timestamped tar.gz archive containing only service configuration
folders from COMMON_PATH. Media libraries and downloads are intentionally
excluded.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

resolve_path() {
  local value="$1"
  if [[ "${value}" = /* ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "${REPO_ROOT}/${value}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      [[ $# -ge 2 ]] || fail "--env-file requires a path."
      ENV_FILE="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a path."
      OUTPUT_DIR="$2"
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

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

[[ -n "${COMMON_PATH:-}" ]] || fail "COMMON_PATH is missing in ${ENV_FILE}"

common_path_abs="$(resolve_path "${COMMON_PATH}")"
[[ -d "${common_path_abs}" ]] || fail "COMMON_PATH does not exist: ${common_path_abs}"

if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="${common_path_abs}/Backups"
fi
output_dir_abs="$(resolve_path "${OUTPUT_DIR}")"
mkdir -p "${output_dir_abs}"

config_paths=(
  "Jellyfin/Config"
  "Jellyseerr/Config"
  "Sonarr/Config"
  "Radarr/Config"
  "Prowlarr/Config"
  "Bazarr/Config"
  "Qbittorrent/Config"
  "Homepage/Config"
)

existing_paths=()
for path in "${config_paths[@]}"; do
  if [[ -d "${common_path_abs}/${path}" ]]; then
    existing_paths+=("${path}")
  else
    warn "Skipping missing config folder: ${common_path_abs}/${path}"
  fi
done

[[ "${#existing_paths[@]}" -gt 0 ]] || fail "No config folders found under ${common_path_abs}."

timestamp="$(date +%Y%m%d-%H%M%S)"
archive_path="${output_dir_abs}/media-stack-configs-${timestamp}.tar.gz"

(
  cd "${common_path_abs}"
  tar -czf "${archive_path}" "${existing_paths[@]}"
)

echo "Config backup written: ${archive_path}"
