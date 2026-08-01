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
  "scripts/sync-homepage-config.sh"
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
    bash -n "${BASH_FILES[@]}"
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
