#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
TEMPLATE_DIR="${REPO_ROOT}/homepage"
DRY_RUN=0
BACKUP=0
SKIP_EXISTING=0

usage() {
  cat <<'USAGE'
Usage: scripts/sync-homepage-config.sh [--env-file PATH] [--dry-run] [--backup] [--skip-existing]

Syncs the repo-managed Homepage config templates into
${COMMON_PATH}/Homepage/Config.

Options:
  --dry-run        Show planned actions without writing files.
  --backup         Create .bak copies before overwriting existing files.
  --skip-existing  Leave existing target files untouched.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
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
  fi
}

log_action() {
  echo "$*"
}

resolve_path() {
  local path_value="$1"
  if [[ "${path_value}" = /* ]]; then
    printf '%s' "${path_value}"
  else
    printf '%s' "${REPO_ROOT}/${path_value}"
  fi
}

copy_template() {
  local file_name="$1"
  local source_file="${TEMPLATE_DIR}/${file_name}"
  local target_file="${TARGET_DIR}/${file_name}"
  local temp_file

  if [[ -f "${target_file}" && "${SKIP_EXISTING}" -eq 1 ]]; then
    log_action "Skipped ${file_name} (target exists)"
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    if [[ -f "${target_file}" ]]; then
      if [[ "${BACKUP}" -eq 1 ]]; then
        log_action "Would back up ${target_file} to ${target_file}.bak"
      fi
      log_action "Would overwrite ${file_name}"
    else
      log_action "Would create ${file_name}"
    fi
    return 0
  fi

  if [[ -f "${target_file}" && "${BACKUP}" -eq 1 ]]; then
    cp "${target_file}" "${target_file}.bak" || fail "Failed to back up ${target_file}."
    log_action "Backed up ${file_name} to ${file_name}.bak"
  fi

  temp_file="$(mktemp "${target_file}.tmp.XXXXXX")"

  if [[ -z "${temp_file}" ]]; then
    fail "Failed to create temp file for ${target_file}."
  fi

  if ! cp "${source_file}" "${temp_file}"; then
    rm -f "${temp_file}"
    fail "Failed to copy ${source_file} to ${target_file}."
  fi

  if ! chmod 0644 "${temp_file}"; then
    rm -f "${temp_file}"
    fail "Failed to set permissions on ${target_file}."
  fi

  if ! mv "${temp_file}" "${target_file}"; then
    rm -f "${temp_file}"
    fail "Failed to replace ${target_file}."
  fi

  log_action "Synced ${file_name}"
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
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --backup)
      BACKUP=1
      shift
      ;;
    --skip-existing)
      SKIP_EXISTING=1
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

if [[ "${ENV_FILE}" != /* ]]; then
  ENV_FILE="${REPO_ROOT}/${ENV_FILE}"
fi

[[ -d "${TEMPLATE_DIR}" ]] || fail "Missing Homepage template directory: ${TEMPLATE_DIR}"
[[ -f "${ENV_FILE}" ]] || fail "Missing env file: ${ENV_FILE}"

normalize_env_file_line_endings "${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

[[ -n "${COMMON_PATH:-}" ]] || fail "COMMON_PATH is missing in ${ENV_FILE}"

TARGET_DIR="$(resolve_path "${COMMON_PATH}")/Homepage/Config"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_action "Would ensure target directory exists: ${TARGET_DIR}"
else
  mkdir -p "${TARGET_DIR}"
fi

copy_template "services.yaml"
copy_template "settings.yaml"
copy_template "bookmarks.yaml"
copy_template "widgets.yaml"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_action "Dry run complete for ${TARGET_DIR}"
else
  log_action "Homepage config synced to ${TARGET_DIR}"
fi
