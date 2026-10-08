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
  "scripts/ci.sh"
)

YAML_FILES=(
  "docker-compose.yml"
  ".github/workflows/ci.yml"
  ".yamllint.yml"
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
EOF

  (
    cd "${REPO_ROOT}"
    docker compose --env-file "${CI_ENV_FILE}" -f docker-compose.yml config >/dev/null
  )
}

test_data_scripts() {
  log_step "Data and ownership script tests"
  TEST_ROOT="$(mktemp -d)" || fail "Failed to create script test directory."
  test_restore_configs
  test_backup_publication
  test_setup_env
  test_security_helpers
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
  mkdir -p "${source_root}/Sonarr/Config" "${source_root}/Glances" "${source_root}/Homepage/Config" "${restore_root}"
  printf '%s\n' 'original config' > "${source_root}/Sonarr/Config/config.xml"
  printf '%s\n' '[outputs]' > "${source_root}/Glances/glances.conf"
  printf '%s\n' 'legacy: retained' > "${source_root}/Homepage/Config/settings.yaml"
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
  cmp "${source_root}/Homepage/Config/settings.yaml" "${restore_root}/Homepage/Config/settings.yaml" || fail "Legacy Homepage archive was not restored."
  [[ "$(stat -c '%u:%g:%a' "${restore_root}")" == "${root_metadata}" ]] || fail "Restore changed COMMON_PATH ownership or mode."
  [[ "$(stat -c '%u:%g' "${restore_root}/Sonarr/Config/config.xml")" == "$(id -u):$(id -g)" ]] || fail "Restored config ownership is incorrect."

  printf '%s\n' 'existing config' > "${restore_root}/Sonarr/Config/config.xml"
  printf '%s\n' 'stale database journal' > "${restore_root}/Sonarr/Config/stale.db-wal"
  mkdir "${restore_root}/Sonarr/Cache"
  printf '%s\n' 'keep cache' > "${restore_root}/Sonarr/Cache/keep"
  chmod 0770 "${restore_root}/Sonarr"
  local parent_metadata
  parent_metadata="$(stat -c '%u:%g:%a' "${restore_root}/Sonarr")"
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
  test_restore_failures "${restore_env}" "${archive}" "${restore_root}"
  "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${archive}" --force --dry-run >/dev/null
  [[ -f "${restore_root}/Sonarr/Config/stale.db-wal" ]] || fail "Forced dry run changed files."
  "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${archive}" --force >/dev/null
  cmp "${source_root}/Sonarr/Config/config.xml" "${restore_root}/Sonarr/Config/config.xml" || fail "Forced restore did not replace existing config."
  [[ "$(stat -c '%u:%g:%a' "${restore_root}")" == "${root_metadata}" ]] || fail "Forced restore changed COMMON_PATH ownership or mode."
  [[ ! -e "${restore_root}/Sonarr/Config/stale.db-wal" ]] || fail "Forced restore retained a destination-only file."
  [[ "$(< "${restore_root}/Sonarr/Cache/keep")" == 'keep cache' ]] || fail "Forced restore changed a sibling cache."
  [[ "$(stat -c '%u:%g:%a' "${restore_root}/Sonarr")" == "${parent_metadata}" ]] || fail "Forced restore changed parent metadata."
}

test_restore_failures() {
  local restore_env="$1" archive="$2" restore_root="$3"
  local stub_dir="${TEST_ROOT}/restore-stubs" path mode link_target
  local mode_args=()

  mkdir "${stub_dir}" "${TEST_ROOT}/outside-restore"
  printf '%s\n' 'untouched' > "${TEST_ROOT}/outside-restore/keep"
  for path in Sonarr Sonarr/Config Glances/glances.conf; do
    mv "${restore_root}/${path}" "${restore_root}/${path}.ci-saved"
    link_target="${TEST_ROOT}/outside-restore"
    [[ "${path}" != Glances/glances.conf ]] || link_target="${TEST_ROOT}/missing-file"
    ln -s "${link_target}" "${restore_root}/${path}"
    for mode in dry-run restore; do
      mode_args=()
      [[ "${mode}" != dry-run ]] || mode_args=(--dry-run)
      if "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${archive}" --force "${mode_args[@]}" >/dev/null 2>&1; then
        fail "Restore accepted a symlink destination (${path}, ${mode})."
      fi
    done
    rm "${restore_root}/${path}"
    mv "${restore_root}/${path}.ci-saved" "${restore_root}/${path}"
  done
  [[ "$(< "${TEST_ROOT}/outside-restore/keep")" == untouched ]] || fail "Restore changed a symlink destination."

  cat > "${stub_dir}/mv" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  case "${argument}" in
    */.restore-configs.*/new/Glances/glances.conf) exit 41 ;;
    */.restore-configs.*/originals/Sonarr/Config)
      # Restore uses mv -- SOURCE TARGET. Fail the recovery source, not the
      # initial move whose destination is the same preserved-original path.
      if [[ "${argument}" == "$2" && "${CI_FAIL_RECOVERY:-0}" == 1 ]]; then exit 42; fi
      ;;
  esac
done
exec "${CI_REAL_MV}" "$@"
EOF
  chmod +x "${stub_dir}/mv"
  printf '%s\n' 'old glances' > "${restore_root}/Glances/glances.conf"
  if CI_REAL_MV="$(command -v mv)" PATH="${stub_dir}:${PATH}" \
    "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${restore_env}" --archive "${archive}" --force >/dev/null 2>&1; then
    fail "Restore succeeded despite an injected replacement failure."
  fi
  [[ "$(< "${restore_root}/Sonarr/Config/config.xml")" == 'existing config' ]] || fail "Failed restore did not roll back an earlier replacement."
  [[ -f "${restore_root}/Sonarr/Config/stale.db-wal" ]] || fail "Failed restore lost the original journal."
  [[ "$(< "${restore_root}/Glances/glances.conf")" == 'old glances' ]] || fail "Failed restore did not restore a displaced file."
  [[ -z "$(find "${restore_root}" -maxdepth 1 -name '.restore-configs.*' -print -quit)" ]] || fail "Successful recovery left restore staging files."

  local fresh_root="${TEST_ROOT}/fresh restore" failure_root="${TEST_ROOT}/recovery failure" original
  local failure_env="${TEST_ROOT}/failure.env"
  mkdir -p "${fresh_root}/Glances"
  printf '%s\n' 'old glances' > "${fresh_root}/Glances/glances.conf"
  printf "COMMON_PATH='%s'\nPUID='%s'\nPGID='%s'\n" "${fresh_root}" "$(id -u)" "$(id -g)" > "${failure_env}"
  if CI_REAL_MV="$(command -v mv)" PATH="${stub_dir}:${PATH}" \
    "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${failure_env}" --archive "${archive}" --force >/dev/null 2>&1; then
    fail "Fresh restore succeeded despite an injected failure."
  fi
  [[ ! -e "${fresh_root}/Sonarr" ]] || fail "Failed restore left a previously absent target installed."
  [[ "$(< "${fresh_root}/Glances/glances.conf")" == 'old glances' ]] || fail "Fresh restore lost the existing config."

  cp -a "${restore_root}" "${failure_root}"
  printf "COMMON_PATH='%s'\nPUID='%s'\nPGID='%s'\n" "${failure_root}" "$(id -u)" "$(id -g)" > "${failure_env}"
  if CI_FAIL_RECOVERY=1 CI_REAL_MV="$(command -v mv)" PATH="${stub_dir}:${PATH}" \
    "${REPO_ROOT}/scripts/restore-configs.sh" --env-file "${failure_env}" --archive "${archive}" --force > "${TEST_ROOT}/recovery.log" 2>&1; then
    fail "Restore succeeded despite failed recovery."
  fi
  original="$(find "${failure_root}" -path '*/originals/Sonarr/Config/config.xml' -print -quit)"
  [[ -n "${original}" && "$(< "${original}")" == 'existing config' ]] || fail "Failed recovery removed the preserved original."
  grep -q 'originals retained' "${TEST_ROOT}/recovery.log" || fail "Failed recovery did not report its recovery path."
}

test_backup_publication() {
  local stub_dir="${TEST_ROOT}/backup-stubs" backup_env="${TEST_ROOT}/publication.env"
  local output_dir="${TEST_ROOT}/publication archives" archive
  local archives=()

  log_step "Backup publication regression tests"
  mkdir "${stub_dir}"
  printf "COMMON_PATH='%s'\n" "${TEST_ROOT}/backup source" > "${backup_env}"
  cat > "${stub_dir}/date" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 20260101-000000
EOF
  chmod +x "${stub_dir}/date"
  PATH="${stub_dir}:${PATH}" "${REPO_ROOT}/scripts/backup-configs.sh" --env-file "${backup_env}" --output-dir "${output_dir}" >/dev/null 2>&1
  PATH="${stub_dir}:${PATH}" "${REPO_ROOT}/scripts/backup-configs.sh" --env-file "${backup_env}" --output-dir "${output_dir}" >/dev/null 2>&1
  archives=("${output_dir}"/*.tar.gz)
  [[ "${#archives[@]}" -eq 2 ]] || fail "Same-second backups overwrote each other."
  for archive in "${archives[@]}"; do
    tar -tzf "${archive}" >/dev/null || fail "Published backup is not a valid archive."
    [[ "$(stat -c '%a' "${archive}")" == 600 ]] || fail "Published backup permissions are not restricted."
  done
  [[ -z "$(find "${output_dir}" -name '.media-stack-configs-*' -print -quit)" ]] || fail "Backup left a temporary archive."
  cat > "${stub_dir}/tar" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'partial archive' > "$2"
exit 23
EOF
  chmod +x "${stub_dir}/tar"
  if PATH="${stub_dir}:${PATH}" "${REPO_ROOT}/scripts/backup-configs.sh" --env-file "${backup_env}" \
    --output-dir "${TEST_ROOT}/failed archives" >/dev/null 2>&1; then
    fail "Backup succeeded despite an injected tar failure."
  fi
  [[ -z "$(find "${TEST_ROOT}/failed archives" -type f -print -quit)" ]] || fail "Failed backup left a partial archive."
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
EOF
  for ((index=0; index<17; index++)); do printf '\n'; done > "${TEST_ROOT}/setup.answers"
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

  awk '!/^(HOMARR_BASE_URL|HOMARR_SECRET_ENCRYPTION_KEY|GLUETUN_CONTROL_API_KEY|JELLYFIN_RENDER_GID|WIREGUARD_ALLOWED_IPS)=/' \
    "${TEST_ROOT}/setup.saved" > "${setup_env}"
  "${REPO_ROOT}/scripts/setup.sh" --env-file "${setup_env}" --non-interactive --no-color > "${TEST_ROOT}/setup.log" 2>&1 || {
    cat "${TEST_ROOT}/setup.log"
    fail "Setup failed to upsert generated defaults and secrets."
  }
  for key in HOMARR_BASE_URL HOMARR_SECRET_ENCRYPTION_KEY GLUETUN_CONTROL_API_KEY JELLYFIN_RENDER_GID; do
    grep -Eq "^${key}='[^']*'$" "${setup_env}" || fail "Setup did not single-quote the ${key} upsert."
  done
  [[ "$(stat -c '%a' "${setup_env}")" == 600 ]] || fail "Updated env file is not mode 0600."
  [[ -z "$(find "${TEST_ROOT}" -name 'setup.env.tmp.*' -print -quit)" ]] || fail "Setup left temporary env files behind."
  test_setup_preflight "${setup_env}"
}

test_setup_preflight() {
  local setup_env="$1" failing_env="${TEST_ROOT}/preflight.env"
  local stub="${TEST_ROOT}/failing-compose" expected_gid

  if [[ -e /dev/dri/renderD128 ]]; then
    expected_gid="$(stat -c '%g' /dev/dri/renderD128)"
  elif command -v getent >/dev/null && getent group render >/dev/null; then
    expected_gid="$(getent group render | awk -F: '{print $3}')"
  else
    expected_gid=109
  fi
  grep -Fx "JELLYFIN_RENDER_GID='${expected_gid}'" "${setup_env}" >/dev/null || fail "Setup did not persist the detected render GID."
  cat >> "${setup_env}" <<'EOF'
WIREGUARD_PUBLIC_KEY='legacy-unused-key'
WIREGUARD_ENDPOINT='legacy-unused-endpoint'
EOF
  "${REPO_ROOT}/scripts/setup.sh" --env-file "${setup_env}" --non-interactive --no-color > "${TEST_ROOT}/setup.log" 2>&1 || fail "Setup rejected legacy unused VPN keys."
  grep -Fx "WIREGUARD_ENDPOINT='legacy-unused-endpoint'" "${setup_env}" >/dev/null || fail "Setup rewrote a legacy key during reuse."
  grep -Fx "WIREGUARD_PUBLIC_KEY='legacy-unused-key'" "${setup_env}" >/dev/null || fail "Setup rewrote a legacy public key during reuse."

  cp "${setup_env}" "${failing_env}"
  printf "%s\n" "HOMARR_BASE_URL='http://localhost:8090/unsupported-path'" >> "${failing_env}"
  cp "${failing_env}" "${TEST_ROOT}/invalid-origin.expected"
  if "${REPO_ROOT}/scripts/setup.sh" --env-file "${failing_env}" --non-interactive --no-color > "${TEST_ROOT}/setup.log" 2>&1; then
    fail "Setup accepted a Homarr base URL with a path."
  fi
  cmp "${failing_env}" "${TEST_ROOT}/invalid-origin.expected" || fail "Invalid Homarr origin changed the env file."

  awk '!/^COMMON_PATH=/' "${setup_env}" > "${failing_env}"
  printf "COMMON_PATH='%s'\n" "${TEST_ROOT}/unprovisioned" >> "${failing_env}"
  cat > "${stub}" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${stub}"
  if DOCKER_COMPOSE_BIN="${stub}" "${REPO_ROOT}/scripts/setup.sh" --env-file "${failing_env}" --non-interactive --no-color > "${TEST_ROOT}/setup.log" 2>&1; then
    fail "Setup ignored a failing Compose preflight."
  fi
  [[ ! -e "${TEST_ROOT}/unprovisioned" ]] || fail "Setup provisioned directories before failing preflight."
}

test_security_helpers() {
  local helpers="${TEST_ROOT}/security-helpers.sh" expected_repo="${REPO_ROOT}"
  log_step "Diagnostic regression tests"
  # Load definitions only, so stubs can exercise policy checks without Docker
  # daemon access, live configuration, or real network requests.
  sed '/^while \[\[ \$# -gt 0 \]\]; do/,$d' "${REPO_ROOT}/scripts/security-check.sh" > "${helpers}"
  (
    # shellcheck disable=SC1090
    source "${helpers}"
    REPO_ROOT="${expected_repo}"
    # shellcheck disable=SC2329 # Called indirectly through COMPOSE_CMD.
    compose_stub() {
      [[ "${PWD}" == "${expected_repo}" ]] || return 1
      printf '%s\n' fixture-container
    }
    # shellcheck disable=SC2034 # Read by the sourced run_compose function.
    COMPOSE_CMD=(compose_stub)
    cd "${TEST_ROOT}"
    [[ "$(get_service_container sonarr)" == fixture-container ]] || fail "Diagnostics resolved Compose from the caller directory."

    # shellcheck disable=SC2329 # Called by the sourced HTTP probe.
    curl() {
      [[ "$*" == *'--connect-timeout 5'* && "$*" == *'--max-time 15'* ]] || fail "HTTP probe has no timeout."
      printf '%s' 000
      return 28
    }
    if http_status http://example.invalid >/dev/null; then fail "HTTP probe swallowed a transport failure."; fi

    # shellcheck disable=SC2329 # Called indirectly through DOCKER_BIN.
    fake_docker() {
      if [[ "$1" == inspect ]]; then
        printf '%s\n' POST=0 CONTAINERS=1 INFO=1 PING=1 VERSION=1
        local option
        for option in ARCHIVE CHANGES EXPORT LOGS TOP PAUSE UNPAUSE START STOP RESTARTS; do printf 'ALLOW_%s=0\n' "${option}"; done
      else
        [[ "$*" == *'AbortSignal.timeout(10000)'* ]] || return 1
        [[ "$*" != *'/_ping'* ]] || return 0
        printf '%s\n' "${fixture_status}"
      fi
    }
    # shellcheck disable=SC2034 # Read by the sourced policy checks.
    DOCKER_BIN=fake_docker
    fixture_status=403
    check_docker_proxy_policy fixture-homarr fixture-proxy >/dev/null
    fixture_status=404
    if (check_docker_proxy_policy fixture-homarr fixture-proxy) >/dev/null 2>&1; then
      fail "Diagnostics accepted an unblocked proxy endpoint."
    fi
  )
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
