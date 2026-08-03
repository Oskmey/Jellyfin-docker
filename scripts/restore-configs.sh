#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
ARCHIVE=""
FORCE=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: scripts/restore-configs.sh --archive PATH [--env-file PATH] [--dry-run] [--force]

Validates and restores an archive created by scripts/backup-configs.sh into
COMMON_PATH. Existing non-empty configuration directories are refused unless
--force is supplied. This never restores .env, Gluetun control credentials,
media libraries, or downloads.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
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

path_is_allowed() {
  local path="${1%/}"
  case "${path}" in
    Jellyfin/Config|Jellyfin/Config/*|\
    Jellyseerr/Config|Jellyseerr/Config/*|\
    Sonarr/Config|Sonarr/Config/*|\
    Radarr/Config|Radarr/Config/*|\
    Prowlarr/Config|Prowlarr/Config/*|\
    Bazarr/Config|Bazarr/Config/*|\
    Qbittorrent/Config|Qbittorrent/Config/*|\
    Homarr/AppData|Homarr/AppData/*|\
    Glances/glances.conf|\
    Homepage/Config|Homepage/Config/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || fail "--archive requires a path."
      ARCHIVE="$2"
      shift 2
      ;;
    --env-file)
      [[ $# -ge 2 ]] || fail "--env-file requires a path."
      ENV_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${ARCHIVE}" ]] || fail "--archive is required."
ENV_FILE="$(resolve_path "${ENV_FILE}")"
ARCHIVE="$(resolve_path "${ARCHIVE}")"
[[ -f "${ENV_FILE}" ]] || fail "Missing env file: ${ENV_FILE}"
[[ -f "${ARCHIVE}" ]] || fail "Missing backup archive: ${ARCHIVE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

[[ -n "${COMMON_PATH:-}" ]] || fail "COMMON_PATH is missing in ${ENV_FILE}"
[[ "${PUID:-}" =~ ^[0-9]+$ ]] || fail "PUID must be numeric in ${ENV_FILE}"
[[ "${PGID:-}" =~ ^[0-9]+$ ]] || fail "PGID must be numeric in ${ENV_FILE}"

common_path_abs="$(resolve_path "${COMMON_PATH}")"
[[ -d "${common_path_abs}" ]] || fail "COMMON_PATH does not exist: ${common_path_abs}"

archive_entries=()
while IFS= read -r entry; do
  [[ -n "${entry}" ]] || continue
  [[ "${entry}" != /* ]] || fail "Archive contains an absolute path: ${entry}"
  [[ ! "/${entry}/" =~ /\.\.?/ ]] || fail "Archive contains path traversal: ${entry}"
  path_is_allowed "${entry}" || fail "Archive contains a path outside the configuration allowlist: ${entry}"
  archive_entries+=("${entry}")
done < <(tar -tzf "${ARCHIVE}")

[[ "${#archive_entries[@]}" -gt 0 ]] || fail "Archive is empty."

top_level_paths=(
  "Jellyfin/Config"
  "Jellyseerr/Config"
  "Sonarr/Config"
  "Radarr/Config"
  "Prowlarr/Config"
  "Bazarr/Config"
  "Qbittorrent/Config"
  "Homarr/AppData"
  "Glances/glances.conf"
  "Homepage/Config"
)

for path in "${top_level_paths[@]}"; do
  if printf '%s\n' "${archive_entries[@]}" | grep -Eq "^${path}(/|$)" &&
     [[ -e "${common_path_abs}/${path}" ]] &&
     { [[ -f "${common_path_abs}/${path}" ]] || find "${common_path_abs}/${path}" -mindepth 1 -print -quit | grep -q .; } &&
     [[ "${FORCE}" -ne 1 ]]; then
    fail "Refusing to overwrite non-empty ${common_path_abs}/${path}; stop the stack, take a fresh backup, then rerun with --force."
  fi
done

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf 'Validated %s entries for restore into %s\n' "${#archive_entries[@]}" "${common_path_abs}"
  exit 0
fi

stage_dir="$(mktemp -d "${common_path_abs}/.restore-configs.XXXXXX")" || fail "Failed to create restore staging directory."
cleanup() {
  rm -rf -- "${stage_dir}"
}
trap cleanup EXIT

tar -xzf "${ARCHIVE}" -C "${stage_dir}"
if find "${stage_dir}" -type l -print -quit | grep -q .; then
  fail "Archive contains symbolic links; restore aborted."
fi
find "${stage_dir}" -type f -perm /6000 -exec chmod a-s {} +
cp -a "${stage_dir}/." "${common_path_abs}/"

for service_root in Jellyfin Jellyseerr Sonarr Radarr Prowlarr Bazarr Qbittorrent Homarr Glances Homepage; do
  [[ -d "${stage_dir}/${service_root}" ]] || continue
  chown "${PUID}:${PGID}" "${common_path_abs}/${service_root}" || fail "Failed to set ownership on restored ${service_root} root."
  chmod 0750 "${common_path_abs}/${service_root}" || fail "Failed to restrict restored ${service_root} root permissions."
done

for path in "${top_level_paths[@]}"; do
  [[ -e "${stage_dir}/${path}" ]] || continue
  chown -R "${PUID}:${PGID}" "${common_path_abs}/${path}" || fail "Failed to set ownership on restored ${path}."
done

echo "Configuration restore completed: ${ARCHIVE}"
echo "HOMARR_SECRET_ENCRYPTION_KEY and Gluetun credentials were not restored; keep the existing protected values."
