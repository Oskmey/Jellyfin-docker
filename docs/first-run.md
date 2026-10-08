# First-Run Wiring Checklist

Use this order for a clean first setup:

1. Open Jellyfin and complete admin wizard
- Wizard URL: `http://<host>:<NGINX_PORT>/jellyfin/web/index.html`
- Leave Jellyfin's **Networking -> Base URL** empty. nginx strips `/jellyfin/` before forwarding; internal integrations use the root URL. Setting `/jellyfin` in the app requires a coordinated proxy migration and is not part of this setup.
- Add libraries:
  - TV: `/data/tvshows`
  - Movies: `/data/movies`
- On Intel TerraMaster systems, enable hardware acceleration after the wizard:
  - Jellyfin Dashboard -> Playback -> Transcoding
  - Prefer Intel Quick Sync when available. Use VA-API as the fallback.
  - VA-API device: `/dev/dri/renderD128`
  - If transcoding fails, run `./scripts/doctor.sh` and verify `JELLYFIN_RENDER_GID`

2. Configure qBittorrent
- URL: `http://<host>:<NGINX_PORT>/qbittorrent/`
- Log in with the temporary password shown in the qBittorrent container logs, then change it immediately
- Set default save path to `/data/downloads`
- In Settings -> Advanced, set **Network Interface** to `tun0`
- Set **Optional IP address to bind to** to `All IPv4 addresses`
- Keep DHT and PeX enabled, apply the settings, and restart only qBittorrent
- Run `./scripts/security-check.sh` and confirm qBittorrent has TCP and UDP listeners on `tun0` and a nonzero DHT node count
- Do not expose the qBittorrent WebUI publicly. It should stay reachable only through the LAN nginx route.

3. Configure Prowlarr
- URL: `http://<host>:<NGINX_PORT>/prowlarr/`
- Add your indexers
- Add applications:
  - Sonarr: `http://sonarr:8989/sonarr`
  - Radarr: `http://radarr:7878/radarr`
- Set the Prowlarr server URL used by those applications to `http://prowlarr:9696/prowlarr`.
- For indexers that need Cloudflare assistance, add an indexer proxy at `http://flaresolverr:8191`, then assign the same tag to the proxy and affected indexers. An untagged FlareSolverr proxy is disabled. See [Prowlarr proxy settings](https://wiki.servarr.com/prowlarr/settings).

4. Configure Sonarr
- URL: `http://<host>:<NGINX_PORT>/sonarr/`
- Root folder: `/data/tvshows`
- Enable **Use Hardlinks instead of Copy** in advanced Media Management when the host download/library folders share one filesystem.
- Download client:
  - qBittorrent host: `gluetun`
  - Port: `8080`
  - Category: `tv`
- Copy API key (Settings -> General -> Security) for Bazarr

5. Configure Radarr
- URL: `http://<host>:<NGINX_PORT>/radarr/`
- Root folder: `/data/movies`
- Enable **Use Hardlinks instead of Copy** under the same filesystem condition.
- Download client:
  - qBittorrent host: `gluetun`
  - Port: `8080`
  - Category: `movies`
- Copy API key (Settings -> General -> Security) for Bazarr

6. Configure Bazarr
- URL: `http://<host>:<NGINX_PORT>/bazarr/`
- Add Sonarr:
  - URL: `http://sonarr:8989/sonarr`
  - API key: Sonarr API key
- Add Radarr:
  - URL: `http://radarr:7878/radarr`
  - API key: Radarr API key
- Create subtitle language profiles and enable automatic subtitle search

7. Configure Seerr
- URL: `http://<host>:5055/` unless you changed the Seerr port in `.env`
- Connect to Jellyfin at `http://jellyfin:8096`, Sonarr at `http://sonarr:8989/sonarr`, and Radarr at `http://radarr:7878/radarr`, using the credentials/API keys each integration requests.
- Seerr runs as `PUID:PGID`; existing config files must be writable by that identity. Setup reuses existing folders without automatically changing their ownership.

8. Configure Homarr
- URL: `http://<host>:<NGINX_PORT>/`
- Create the owner account and keep the NAS Control Room board private
- Create the public Home Cinema board and connect the internal integrations
- Apply the exact board, privacy, responsive-layout, and appearance recipe in [`homarr.md`](homarr.md)
- Export a Homarr backup after configuration and store the encryption key separately

9. Install Jellyfin Intro Skipper plugin
- Install a stable Intro Skipper release compatible with your Jellyfin major version; follow the compatibility gate in [`updating.md`](updating.md).
- Restart Jellyfin after install
- Run the intro detection scheduled task in Jellyfin (Dashboard -> Scheduled Tasks)

10. Trigger library scans
- In Jellyfin, rescan libraries
- Validate playback for at least one movie and one TV episode
- Validate subtitle auto-download from Bazarr on one new import
