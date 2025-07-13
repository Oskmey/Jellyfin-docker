#!/usr/bin/env bash
set -euo pipefail

set -a
source .env
set +a



# Ensure COMMON_PATH is set
: "${COMMON_PATH:?Environment variable COMMON_PATH must be set (e.g. export COMMON_PATH=/path/to/media)}"

# List of all host-side directories to create
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

echo "Creating directories under $COMMON_PATH…"
for d in "${dirs[@]}"; do
  if [[ -d "$d" ]]; then
    echo "  ✓ exists: $d"
  else
    mkdir -p "$d"
    echo "  + created: $d"
  fi
done

echo "Done."


KEY_FILE="$COMMON_PATH/Portainer/Data/portainer.key"

if [[ -f "$KEY_FILE" ]]; then
  echo "  ✓ Portainer key already exists at $KEY_FILE"
else
  echo "  + Generating new Portainer encryption key at $KEY_FILE"
  head -c 32 /dev/urandom | base64 > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "    → Done."
fi
