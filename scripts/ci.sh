#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CI_ENV_FILE=""
TEST_ROOT=""

BASH_FILES=(
  "scripts/setup.sh"
  "scripts/doctor.sh"
  "scripts/security-check.sh"
  "scripts/backup-configs.sh"
  "scripts/restore-configs.sh"
  "scripts/sync-homepage-config.sh"
  "scripts/ci.sh"
)

YAML_FILES=(
  "docker-compose.yml"
  ".github/workflows/ci.yml"
  ".yamllint.yml"
  "homepage/bookmarks.yaml"
  "homepage/services.yaml"
  "homepage/settings.yaml"
  "homepage/widgets.yaml"
)

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${CI_ENV_FILE}" && -f "${CI_ENV_FILE}" ]]; then
    rm -f "${CI_ENV_FILE}"
  fi
  if [[ -n "${TEST_ROOT}" && -d "${TEST_ROOT}" ]]; then
    rm -rf "${TEST_ROOT}"
  fi
}

log_step() {
  echo
  echo "==> $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

check_repo_safety() {
  log_step "Repository safety checks"

  if git -C "${REPO_ROOT}" ls-files --error-unmatch .env >/dev/null 2>&1; then
    fail ".env is tracked by git. Remove it from the index and keep secrets only in your local ignored file."
  fi

  if ! git -C "${REPO_ROOT}" check-ignore -q --no-index .env; then
    fail ".env is not ignored. Add it to .gitignore."
  fi

  if grep -Eq '^WIREGUARD_(PRIVATE_KEY|PUBLIC_KEY)=[^[:space:]].*$' "${REPO_ROOT}/.env.example"; then
    fail ".env.example contains a non-empty WireGuard key."
  fi
}

lint_shell() {
  log_step "Shell validation"
  (
    cd "${REPO_ROOT}"
    for file in "${BASH_FILES[@]}"; do
      bash -n "${file}"
    done
    shellcheck "${BASH_FILES[@]}"
  )
}

lint_yaml() {
  log_step "YAML validation"
  (
    cd "${REPO_ROOT}"
    yamllint -c .yamllint.yml "${YAML_FILES[@]}"
  )
}

validate_compose() {
  log_step "Compose validation"

  CI_ENV_FILE="$(mktemp)" || fail "Failed to create temporary env file."

  cp "${REPO_ROOT}/.env.example" "${CI_ENV_FILE}"
  cat >> "${CI_ENV_FILE}" <<'EOF'
WIREGUARD_ADDRESSES=10.64.0.2/32
WIREGUARD_PRIVATE_KEY=ci-private-key
WIREGUARD_PUBLIC_KEY=ci-public-key
WIREGUARD_ENDPOINT=se-sto-wg-001.relays.mullvad.net:51820
EOF

  (
    cd "${REPO_ROOT}"
    docker compose --env-file "${CI_ENV_FILE}" -f docker-compose.yml config >/dev/null
  )
}

test_data_scripts() {
  local test_env
  local uid
  local gid

  log_step "Data and ownership script tests"
  TEST_ROOT="$(mktemp -d)" || fail "Failed to create script test directory."
  test_env="${TEST_ROOT}/test.env"
  uid="$(id -u)"
  gid="$(id -g)"

  mkdir -p "${TEST_ROOT}/media"
  cat > "${test_env}" <<EOF
COMMON_PATH=${TEST_ROOT}/media
PUID=${uid}
PGID=${gid}
EOF
  chmod 0600 "${test_env}"

  "${REPO_ROOT}/scripts/sync-homepage-config.sh" --env-file "${test_env}" --dry-run >/dev/null
  [[ ! -e "${TEST_ROOT}/media/Homepage" ]] || fail "Homepage dry run created target files."
  "${REPO_ROOT}/scripts/sync-homepage-config.sh" --env-file "${test_env}" >/dev/null
  [[ "$(stat -c '%u:%g' "${TEST_ROOT}/media/Homepage/Config/settings.yaml")" == "${uid}:${gid}" ]] || fail "Homepage config ownership is incorrect."
  [[ "$(stat -c '%a' "${TEST_ROOT}/media/Homepage/Config/settings.yaml")" == "644" ]] || fail "Homepage config mode is incorrect."

  test_restore_configs
  test_setup_env
}

test_restore_configs() {
  local restore_env="${TEST_ROOT}/restore.env"
  local source_root="${TEST_ROOT}/backup source"
  local restore_root="${TEST_ROOT}/restore target"
  local archive
  local root_metadata
  local mode
  local bad_archive
  local mode_args=()

  log_step "Backup and restore regression tests"
  mkdir -p "${source_root}/Sonarr/Config" "${source_root}/Glances" "${restore_root}"
  printf '%s\n' 'original config' > "${source_root}/Sonarr/Config/config.xml"
  printf '%s\n' '[outputs]' > "${source_root}/Glances/glances.conf"
  printf "COMMON_PATH='%s'\nPUID='%s'\nPGID='%s'\n" "${source_root}" "$(id -u)" "$(id -g)" > "${restore_env}"
  "${REPO_ROOT}/scripts/backup-configs.sh" --env-file "${restore_env}" --output-dir "${TEST_ROOT}/backups" >/dev/null 2>&1
  for archive in "${TEST_ROOT}"/backups/*.tar.gz; do
    [[ -f "${archive}" ]] || fail "Backup script did not create an archive."
  done
  printf "COMMON_PATH='%s'\nPUID='%s'\nPGID='%s'\n" "${restore_root}" "$(id -u)" "$(id -g)" > "${restore_env}"
  chmod 0770 "${restore_root}"
  root_metadata="$(stat -c '%u:%g:%a' "${restore_root}")"

  "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${archive}" --dry-run >/dev/null
  [[ -z "$(find "${restore_root}" -mindepth 1 -print -quit)" ]] || fail "Restore dry run created files."
  "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${archive}" >/dev/null
  cmp "${source_root}/Sonarr/Config/config.xml" "${restore_root}/Sonarr/Config/config.xml" || fail "Restored config contents differ."
  cmp "${source_root}/Glances/glances.conf" "${restore_root}/Glances/glances.conf" || fail "Restored Glances config contents differ."
  [[ "$(stat -c '%u:%g:%a' "${restore_root}")" == "${root_metadata}" ]] || fail "Restore changed COMMON_PATH ownership or mode."
  [[ "$(stat -c '%u:%g' "${restore_root}/Sonarr/Config/config.xml")" == "$(id -u):$(id -g)" ]] || fail "Restored config ownership is incorrect."

  printf '%s\n' 'existing config' > "${restore_root}/Sonarr/Config/config.xml"
  for mode in dry-run restore; do
    mode_args=()
    [[ "${mode}" != dry-run ]] || mode_args=(--dry-run)
    if "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${archive}" "${mode_args[@]}" >/dev/null 2>&1; then
      fail "Restore accepted a non-empty target without --force (${mode})."
    fi
  done
  [[ "$(< "${restore_root}/Sonarr/Config/config.xml")" == 'existing config' ]] || fail "Rejected restore changed existing data."

  head -c "$(( $(stat -c '%s' "${archive}") - 8 ))" "${archive}" > "${TEST_ROOT}/truncated.tar.gz"
  ln -s /etc/passwd "${source_root}/Sonarr/Config/link"
  tar -czf "${TEST_ROOT}/symlink.tar.gz" -C "${source_root}" Sonarr/Config
  rm "${source_root}/Sonarr/Config/link"
  mkfifo "${source_root}/Sonarr/Config/pipe"
  tar -czf "${TEST_ROOT}/special.tar.gz" -C "${source_root}" Sonarr/Config
  rm "${source_root}/Sonarr/Config/pipe"
  tar -czf "${TEST_ROOT}/disallowed.tar.gz" -C "${TEST_ROOT}" restore.env
  for bad_archive in truncated symlink special disallowed; do
    for mode in dry-run restore; do
      mode_args=()
      [[ "${mode}" != dry-run ]] || mode_args=(--dry-run)
      if "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${TEST_ROOT}/${bad_archive}.tar.gz" --force "${mode_args[@]}" >/dev/null 2>&1; then
        fail "Restore accepted ${bad_archive} archive (${mode})."
      fi
      [[ "$(< "${restore_root}/Sonarr/Config/config.xml")" == 'existing config' ]] || fail "Rejected ${bad_archive} restore changed existing data."
    done
  done
  "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${archive}" --force --dry-run >/dev/null
  "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${archive}" --force >/dev/null
  cmp "${source_root}/Sonarr/Config/config.xml" "${restore_root}/Sonarr/Config/config.xml" || fail "Forced restore did not replace existing config."
  [[ "$(stat -c '%u:%g:%a' "${restore_root}")" == "${root_metadata}" ]] || fail "Forced restore changed COMMON_PATH ownership or mode."
}

test_setup_env() {
  local setup_env="${TEST_ROOT}/setup.env"
  local common_path="${TEST_ROOT}/media library"
  # shellcheck disable=SC2016
  local countries='United States $literal \n "quoted" #country'
  local invalid_value
  local index
  local mode
  local key

  log_step "Setup env serialization regression tests"
  cp "${REPO_ROOT}/.env.example" "${setup_env}"
  cat >> "${setup_env}" <<EOF
COMMON_PATH='${common_path}'
PUID='$(id -u)'
PGID='$(id -g)'
SERVER_COUNTRIES='${countries}'
WIREGUARD_ADDRESSES='10.64.0.2/32'
WIREGUARD_PRIVATE_KEY='ci-private-key'
WIREGUARD_PUBLIC_KEY='ci-public-key'
WIREGUARD_ENDPOINT='se-sto-wg-001.relays.mullvad.net:51820'
EOF
  for ((index=0; index<19; index++)); do printf '\n'; done > "${TEST_ROOT}/setup.answers"
  "${REPO_ROOT}/scripts/setup.sh" --env-file "${setup_env}" --force --no-color < "${TEST_ROOT}/setup.answers" > "${TEST_ROOT}/setup.log" 2>&1 || {
    cat "${TEST_ROOT}/setup.log"
    fail "Setup failed to generate an env file with spaces and literal characters."
  }
  [[ "$(stat -c '%a' "${setup_env}")" == 600 ]] || fail "Generated env file is not mode 0600."
  (
    set -a
    # shellcheck disable=SC1090
    source "${setup_env}"
    # shellcheck disable=SC2153
    [[ "${COMMON_PATH}" == "${common_path}" && "${SERVER_COUNTRIES}" == "${countries}" ]] || fail "Generated env values did not reload literally in Bash."
  )
  env -u COMMON_PATH -u SERVER_COUNTRIES docker compose --env-file "${setup_env}" -f "${REPO_ROOT}/docker-compose.yml" config --environment > "${TEST_ROOT}/compose.env"
  grep -Fx "COMMON_PATH=${common_path}" "${TEST_ROOT}/compose.env" >/dev/null || fail "Compose changed COMMON_PATH."
  grep -Fx "SERVER_COUNTRIES=${countries}" "${TEST_ROOT}/compose.env" >/dev/null || fail "Compose changed SERVER_COUNTRIES."

  cp "${setup_env}" "${TEST_ROOT}/setup.saved"
  for invalid_value in "United 'States" $'United\nStates' $'United\rStates'; do
    cp "${TEST_ROOT}/setup.saved" "${setup_env}"
    # Double quotes let Bash load the single quote and line breaks.
    printf 'SERVER_COUNTRIES="%s"\n' "${invalid_value}" >> "${setup_env}"
    cp "${setup_env}" "${TEST_ROOT}/setup.expected"
    for mode in --force --non-interactive; do
      if "${REPO_ROOT}/scripts/setup.sh" --env-file "${setup_env}" "${mode}" --no-color < "${TEST_ROOT}/setup.answers" > "${TEST_ROOT}/setup.log" 2>&1; then
        fail "Setup accepted single quotes or line breaks (${mode})."
      fi
      cmp "${setup_env}" "${TEST_ROOT}/setup.expected" || fail "Invalid env serialization changed the existing file."
    done
  done
  cp "${TEST_ROOT}/setup.saved" "${setup_env}"
  {
    for ((index=0; index<6; index++)); do printf '\n'; done
    printf '%s\n' 'invalid-port'
    for ((index=0; index<12; index++)); do printf '\n'; done
  } > "${TEST_ROOT}/invalid.answers"
  if "${REPO_ROOT}/scripts/setup.sh" --env-file "${setup_env}" --force --no-color < "${TEST_ROOT}/invalid.answers" > "${TEST_ROOT}/setup.log" 2>&1; then
    fail "Setup accepted an invalid port."
  fi
  cmp "${setup_env}" "${TEST_ROOT}/setup.saved" || fail "Invalid settings changed the existing env file."

  cat >> "${setup_env}" <<'EOF'
NGINX_PORT='invalid-port'
HOMARR_SECRET_ENCRYPTION_KEY='GENERATE_WITH_SETUP'
GLUETUN_CONTROL_API_KEY='GENERATE_WITH_SETUP'
EOF
  cp "${setup_env}" "${TEST_ROOT}/setup.expected"
  if "${REPO_ROOT}/scripts/setup.sh" --env-file "${setup_env}" --non-interactive --no-color > "${TEST_ROOT}/setup.log" 2>&1; then
    fail "Non-interactive setup accepted an invalid port."
  fi
  cmp "${setup_env}" "${TEST_ROOT}/setup.expected" || fail "Setup stored generated secrets before validating settings."

  awk '!/^(HOMARR_BASE_URL|HOMARR_SECRET_ENCRYPTION_KEY|GLUETUN_CONTROL_API_KEY)=/' "${TEST_ROOT}/setup.saved" > "${setup_env}"
  "${REPO_ROOT}/scripts/setup.sh" --env-file "${setup_env}" --non-interactive --no-color > "${TEST_ROOT}/setup.log" 2>&1 || {
    cat "${TEST_ROOT}/setup.log"
    fail "Setup failed to upsert generated defaults and secrets."
  }
  for key in HOMARR_BASE_URL HOMARR_SECRET_ENCRYPTION_KEY GLUETUN_CONTROL_API_KEY; do
    grep -Eq "^${key}='[^']*'$" "${setup_env}" || fail "Setup did not single-quote the ${key} upsert."
  done
  [[ "$(stat -c '%a' "${setup_env}")" == 600 ]] || fail "Updated env file is not mode 0600."
  [[ -z "$(find "${TEST_ROOT}" -name 'setup.env.tmp.*' -print -quit)" ]] || fail "Setup left temporary env files behind."
}

main() {
  require_command git
  require_command bash
  require_command shellcheck
  require_command yamllint
  require_command docker

  check_repo_safety
  lint_shell
  lint_yaml
  validate_compose
  test_data_scripts

  echo
  echo "CI checks passed."
}

trap cleanup EXIT

main "$@"
