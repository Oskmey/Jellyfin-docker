# Homarr Dashboard

Homarr is the LAN homepage for this stack. nginx serves it at `http://<host>:<NGINX_PORT>/`. The old `/homepage` URL redirects there.

Homarr keeps users, boards, integrations, and appearance settings in `${COMMON_PATH}/Homarr/AppData`. They are intentionally not committed to Git because the database contains user data and encrypted credentials.

## First login

1. Open `http://<host>:<NGINX_PORT>/` from the LAN.
2. Create the owner account with a unique password.
3. Keep credential authentication enabled. Do not make the owner account available to family users.
4. Create the two boards below. Set **Home Cinema** as the public global desktop and mobile home board. Set **NAS Control Room** as the owner's private desktop and mobile home board.

The dashboard does not protect the linked applications. Jellyfin, Seerr, qBittorrent, and the automation applications need their own passwords and must remain behind the LAN firewall.

## Integrations

Add credentials in Homarr's integration settings, not in board notes or Git. Use these Docker-network URLs for integrations and the nginx URLs for application launch links.

| Application | Integration URL | Browser link |
| --- | --- | --- |
| Jellyfin | `http://jellyfin:8096` | `/jellyfin/` |
| Seerr | `http://jellyseerr:5055` | the browser-facing Seerr URL from `.env` |
| Sonarr | `http://sonarr:8989/sonarr` | `/sonarr/` |
| Radarr | `http://radarr:7878/radarr` | `/radarr/` |
| Prowlarr | `http://prowlarr:9696/prowlarr` | `/prowlarr/` |
| Bazarr | `http://bazarr:6767/bazarr` | `/bazarr/` |
| qBittorrent | `http://gluetun:8080` | `/qbittorrent/` |
| Gluetun | `http://gluetun:8000` | none |
| Glances | `http://glances:61208` | none |
| Docker | `http://docker-socket-proxy:2375` | none |

Docker statistics are read-only: Homarr has no Docker socket mount, and the proxy rejects write requests. Glances and the Gluetun control server have no published host ports.

## Home Cinema board

Create a public board named `Home Cinema`. Anonymous access is intentional for trusted LAN clients.

Add only:

- Jellyfin application tile: **Watch movies & TV**
- Seerr application tile: **Request something new**
- System Resources from Glances: CPU and memory percentages only
- Date and time: `Europe/Stockholm`, 24-hour clock, no seconds
- Media Releases from Jellyfin: backdrop layout with media badge
- Calendar from Sonarr and Radarr: monitored titles and digital releases, two months backward and forward

Desktop uses 12 columns: four `3×2` top tiles, Media Releases `8×5`, and Calendar `4×5`. Tablet uses 8 columns with paired top tiles and full-width media widgets. Mobile uses 4 columns with the two application tiles side by side and all information widgets full width.

Never place streams, usernames, requesters, request controls, download names, indexers, subtitles, VPN/IP details, filesystems, container details, internal URLs, logs, or raw errors on this board. If an upgrade makes a widget expose any of these fields, remove the widget until the behavior is corrected.

## NAS Control Room board

Create a private board named `NAS Control Room`, visible only to the owner.

Add these widgets in order:

1. Glances System Health: CPU, memory, uptime, `/host-data` capacity, and temperature when available
2. Glances System Resources with CPU and memory. Omit bridge-network throughput.
3. Gluetun status: VPN tunnel, DNS status, and public egress IP
4. Read-only Docker Stats
5. Launch tiles: Jellyfin, Seerr, Sonarr, Radarr, Bazarr, Prowlarr, qBittorrent, and `/health`
6. Jellyfin active streams
7. Seerr request statistics and recent pending or failed requests
8. Sonarr/Radarr missing-media and queue widgets
9. qBittorrent active downloads: name, category, progress, state, speed, and remaining time only
10. Prowlarr indexer status and Bazarr subtitle status

Do not add Docker lifecycle controls or qBittorrent pause/delete controls. Never display API keys, WireGuard values, VPN endpoints, torrent hashes, trackers, peer IPs, filesystem paths, process commands, logs, or tokenized URLs.

On desktop, place host health across the first row, Docker Stats across the second row, two rows of four launch tiles, paired media/request widgets, then paired queue/download widgets. Tablet and mobile preserve that order while stacking complex widgets full width.

## Appearance and accessibility

Use dark mode with:

- background image: `/assets/nas-cinema-bg.webp`
- background: `#070A12`
- card surface: `#121827`
- primary violet: `#8B5CF6`
- secondary cyan: `#22D3EE`
- warning/focus amber: `#F59E0B`
- text: `#F8FAFC`
- muted text: `#CBD5E1`
- rounded cards around 16 px with restrained blur

Prefer Homarr's built-in appearance controls over custom CSS. Keep targets at least 44 px, preserve visible keyboard focus, disable decorative motion for reduced-motion clients, and pair status colors with text such as **Available**, **Unavailable**, or **Unknown**.

An empty queue is healthy, a missing sensor is **Not reported**, and VPN status is healthy only when the Gluetun integration confirms a live tunnel. Public errors must remain generic.

## Backup and recovery

Use Homarr's built-in backup export after creating the boards and after material dashboard changes. Store the ZIP with mode `0600` outside Git and outside the live AppData folder.

The backup still depends on `HOMARR_SECRET_ENCRYPTION_KEY`. Keep that value in a password manager or another separate secret backup. `scripts/backup-configs.sh` also archives Homarr AppData, but a live SQLite copy is only a secondary recovery measure. Prefer the Homarr export for consistent restores.

Before deleting the legacy `${COMMON_PATH}/Homepage/Config`, restore the Homarr export into a temporary Homarr instance and verify users, boards, integrations, and appearance.
