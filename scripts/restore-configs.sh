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
--force is supplied. Archived targets are replaced, not merged; destination-only
files in those targets are removed. Stop writers and back up before restoring.
This never restores .env, Gluetun control credentials,
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

top_level_paths=(
  "Jellyfin/Config" "Jellyseerr/Config" "Sonarr/Config" "Radarr/Config"
  "Prowlarr/Config" "Bazarr/Config" "Qbittorrent/Config" "Homarr/AppData"
  "Glances/glances.conf" "Homepage/Config"
)

path_matches_target() {
  local member="${1%/}" target="$2"
  [[ "${member}" == "${target}" ]] ||
    { [[ "${target}" != "Glances/glances.conf" && "${member}" == "${target}/"* ]]; }
}

path_is_allowed() {
  local target
  for target in "${top_level_paths[@]}"; do
    if path_matches_target "$1" "${target}"; then return 0; fi
  done
  return 1
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
common_path_abs="$(cd -- "${common_path_abs}" && pwd -P)"
common_device="$(stat -c '%d' "${common_path_abs}")"

archive_listing="$(tar -tzf "${ARCHIVE}")" || fail "Failed to list backup archive; it may be truncated or corrupt."
archive_types="$(LC_ALL=C tar -tvzf "${ARCHIVE}")" || fail "Failed to inspect backup archive member types."
while IFS= read -r entry; do
  [[ -n "${entry}" ]] || continue
  case "${entry:0:1}" in
    -|d) ;;
    l) fail "Archive contains symbolic links; restore aborted." ;;
    *) fail "Archive contains unsupported member types; only regular files and directories are allowed." ;;
  esac
done <<< "${archive_types}"

archive_entries=()
while IFS= read -r entry; do
  [[ -n "${entry}" ]] || continue
  [[ "${entry}" != /* ]] || fail "Archive contains an absolute path: ${entry}"
  [[ ! "/${entry}/" =~ /\.\.?/ ]] || fail "Archive contains path traversal: ${entry}"
  path_is_allowed "${entry}" || fail "Archive contains a path outside the configuration allowlist: ${entry}"
  archive_entries+=("${entry}")
done <<< "${archive_listing}"

[[ "${#archive_entries[@]}" -gt 0 ]] || fail "Archive is empty."

selected_paths=()
for path in "${top_level_paths[@]}"; do
  for entry in "${archive_entries[@]}"; do
    if path_matches_target "${entry}" "${path}"; then
      selected_paths+=("${path}")
      break
    fi
  done
done

for path in "${selected_paths[@]}"; do
  parent="${common_path_abs}/${path%/*}"
  target="${common_path_abs}/${path}"
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
  if [[ -e "${target}" && "${FORCE}" -ne 1 ]] &&
     { [[ -f "${target}" ]] || [[ -n "$(find "${target}" -mindepth 1 -print -quit)" ]]; }; then
    fail "Refusing to overwrite non-empty ${common_path_abs}/${path}; stop the stack, take a fresh backup, then rerun with --force."
  fi
done

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf 'Validated %s entries for restore into %s\n' "${#archive_entries[@]}" "${common_path_abs}"
  exit 0
fi

stage_dir="$(mktemp -d "${common_path_abs}/.restore-configs.XXXXXX")" || fail "Failed to create restore staging directory."
attempted_paths=()
created_parents=()
committed=0
cleanup() {
  local index path target original rollback_failed=0
  if [[ "${committed}" -ne 1 ]]; then
    for ((index=${#attempted_paths[@]}-1; index>=0; index--)); do
      path="${attempted_paths[index]}"
      target="${common_path_abs}/${path}"
      original="${stage_dir}/originals/${path}"
      if [[ -e "${original}" || ! -e "${stage_dir}/new/${path}" ]]; then
        if [[ -e "${target}" ]] && ! mv -- "${target}" "${stage_dir}/rejected/${path}"; then
          rollback_failed=1
          continue
        fi
        if [[ -e "${original}" ]] && ! mv -- "${original}" "${target}"; then rollback_failed=1; fi
      fi
    done
    for parent in "${created_parents[@]}"; do rmdir -- "${parent}" 2>/dev/null || true; done
  fi
  if [[ "${rollback_failed}" -eq 1 ]]; then
    printf 'ERROR: Recovery could not complete; originals retained in %s/originals\n' "${stage_dir}" >&2
  else
    rm -rf -- "${stage_dir}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "${stage_dir}/new" "${stage_dir}/originals" "${stage_dir}/rejected"
tar -xzf "${ARCHIVE}" -C "${stage_dir}/new"
if [[ -n "$(find "${stage_dir}/new" -type l -print -quit)" ]]; then
  fail "Archive contains symbolic links; restore aborted."
fi
find "${stage_dir}/new" -perm /6000 -exec chmod a-s {} +
for path in "${selected_paths[@]}"; do
  if [[ "${path}" == "Glances/glances.conf" ]]; then
    [[ -f "${stage_dir}/new/${path}" ]] || fail "Archived Glances config is not a regular file."
  else
    [[ -d "${stage_dir}/new/${path}" ]] || fail "Archived configuration is not a directory: ${path}"
  fi
  chown -R "${PUID}:${PGID}" "${stage_dir}/new/${path}" || fail "Failed to prepare ownership for ${path}."
  mkdir -p "${stage_dir}/originals/${path%/*}" "${stage_dir}/rejected/${path%/*}"
done

for path in "${selected_paths[@]}"; do
  parent="${common_path_abs}/${path%/*}"
  if [[ ! -d "${parent}" ]]; then
    mkdir "${parent}"
    created_parents+=("${parent}")
    chown "${PUID}:${PGID}" "${parent}"
    chmod 0750 "${parent}"
  fi
  target="${common_path_abs}/${path}"
  attempted_paths+=("${path}")
  if [[ -e "${target}" ]]; then
    mv -- "${target}" "${stage_dir}/originals/${path}" || fail "Failed to preserve existing ${path}."
  fi
  mv -- "${stage_dir}/new/${path}" "${target}" || fail "Failed to replace ${path}; rolling back."
done
committed=1

echo "Configuration restore completed: ${ARCHIVE}"
echo "HOMARR_SECRET_ENCRYPTION_KEY and Gluetun credentials were not restored; keep the existing protected values."
