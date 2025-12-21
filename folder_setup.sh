#!/usr/bin/env bash
set -euo pipefail

NC=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'

if [[ -t 1 ]]; then
  USE_COLOR=1
else
  USE_COLOR=0
fi

c() {
  local color="$1"; shift
  if [[ "$USE_COLOR" == "1" ]]; then
    printf "%b%s%b" "$color" "$*" "$NC"
  else
    printf "%s" "$*"
  fi
}

banner() {
  cat <<'EOF'
 _______  _______  _        _______  _______          
(  ___  )(  ____ \| \    /\(       )(  ____ \|\     /|
| (   ) || (    \/|  \  / /| () () || (    \/( \   / )
| |   | || (_____ |  (_/ / | || || || (__     \ (_) / 
| |   | |(_____  )|   _ (  | |(_)| ||  __)     \   /  
| |   | |      ) ||  ( \ \ | |   | || (         ) (   
| (___) |/\____) ||  /  \ \| )   ( || (____/\   | |   
(_______)\_______)|_/    \/|/     \|(_______/   \_/   
                                                      
EOF
  printf "%s\n" "$(c "$MAGENTA$BOLD" "insetup of docker")"
  echo
}

log_info() { printf "%s %s\n" "$(c "$CYAN$BOLD" "ℹ️")" "$*"; }
log_ok()   { printf "%s %s\n" "$(c "$GREEN$BOLD" "✅")" "$*"; }
log_warn() { printf "%s %s\n" "$(c "$YELLOW$BOLD" "⚠️")" "$*"; }
log_err()  { printf "%s %s\n" "$(c "$RED$BOLD" "❌")" "$*" >&2; }

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}
  log_err "Failed (exit $(c "$RED$BOLD" "$exit_code")) at line $(c "$YELLOW$BOLD" "$line_no"): $(c "$DIM" "$cmd")"
  exit "$exit_code"
}
trap on_error ERR

banner

if [[ "${OSKMEY_DEBUG:-0}" == "1" ]]; then
  log_warn "OSKMEY_DEBUG=1 → enabling shell trace (set -x)"
  set -x
fi

log_info "Loading environment from $(c "$BLUE$BOLD" ".env")…"
if [[ ! -f ".env" ]]; then
  log_err "Missing $(c "$BLUE$BOLD" ".env") in: $(c "$MAGENTA" "$(pwd)")"
  log_err "Create a $(c "$BLUE$BOLD" ".env") file or run this script from the directory that contains it."
  exit 1
fi

set -a
source .env
set +a
log_ok "Environment loaded."

: "${COMMON_PATH:?Environment variable COMMON_PATH must be set (e.g. export COMMON_PATH=/path/to/media)}"

dirs=(
  "$COMMON_PATH/Qbittorrent/Config"
  "$COMMON_PATH/Downloads"
  "$COMMON_PATH/Sonarr/Config"
  "$COMMON_PATH/Sonarr/Backup"
  "$COMMON_PATH/Sonarr/tvshows"
  "$COMMON_PATH/Radarr/Config"
  "$COMMON_PATH/Radarr/Backup"
  "$COMMON_PATH/Radarr/movies"
  "$COMMON_PATH/Prowlarr/Config"
  "$COMMON_PATH/Prowlarr/Backup"
  "$COMMON_PATH/Jellyfin/Config"
  "$COMMON_PATH/Jellyfin/Cache"
  "$COMMON_PATH/Jellyseerr/Config"
  "$COMMON_PATH/Portainer/Data"
)

KEY_FILE="$COMMON_PATH/Portainer/Data/portainer.key"

echo
log_info "$(c "$BOLD" "Plan:")"
printf "  %s %s\n" "$(c "$CYAN$BOLD" "•")" "COMMON_PATH: $(c "$MAGENTA$BOLD" "$COMMON_PATH")"
printf "  %s %s\n" "$(c "$CYAN$BOLD" "•")" "Directories to ensure: $(c "$MAGENTA$BOLD" "${#dirs[@]}")"
printf "  %s %s\n" "$(c "$CYAN$BOLD" "•")" "Portainer key file: $(c "$MAGENTA$BOLD" "$KEY_FILE")"
echo

printf "%s " "$(c "$YELLOW$BOLD" "Proceed with setup/install? [y/N]:")"
read -r confirm
case "${confirm:-}" in
  y|Y|yes|YES)
    log_ok "Confirmed. Continuing…"
    ;;
  *)
    log_info "Aborted. No changes were made."
    exit 0
    ;;
esac

echo
log_info "Creating directories under $(c "$MAGENTA$BOLD" "$COMMON_PATH")…"
for d in "${dirs[@]}"; do
  if [[ -d "$d" ]]; then
    printf "  %s %s\n" "$(c "$GREEN$BOLD" "✓")" "exists: $(c "$DIM" "$d")"
  else
    mkdir -p "$d"
    printf "  %s %s\n" "$(c "$GREEN$BOLD" "+")" "created: $(c "$DIM" "$d")"
  fi
done
log_ok "Directory setup done."

echo
if [[ -f "$KEY_FILE" ]]; then
  printf "  %s %s\n" "$(c "$GREEN$BOLD" "✓")" "Portainer key already exists at $(c "$DIM" "$KEY_FILE")"
else
  printf "  %s %s\n" "$(c "$GREEN$BOLD" "+")" "Generating new Portainer encryption key at $(c "$DIM" "$KEY_FILE")"
  (
    umask 177
    head -c 32 /dev/urandom | base64 > "$KEY_FILE"
  )
  chmod 600 "$KEY_FILE"
  printf "    %s %s\n" "$(c "$GREEN$BOLD" "→")" "$(c "$GREEN$BOLD" "Done.")"
fi

echo
log_ok "$(c "$BOLD" "All done.")"
