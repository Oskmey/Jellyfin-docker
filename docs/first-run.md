# First-Run Wiring Checklist

Use this order for a clean first setup:

1. Open Jellyfin and complete admin wizard
- URL: `http://<host>:<NGINX_PORT>/jellyfin/`
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
- Do not expose the qBittorrent WebUI publicly. It should stay reachable only through the LAN nginx route.

3. Configure Prowlarr
- URL: `http://<host>:<NGINX_PORT>/prowlarr/`
- Add your indexers
- Add applications:
  - Sonarr: `http://sonarr:8989/sonarr`
  - Radarr: `http://radarr:7878/radarr`

4. Configure Sonarr
- URL: `http://<host>:<NGINX_PORT>/sonarr/`
- Root folder: `/data/tvshows`
- Download client:
  - qBittorrent host: `gluetun`
  - Port: `8080`
  - Category: `tv`
- Copy API key (Settings -> General -> Security) for Bazarr

5. Configure Radarr
- URL: `http://<host>:<NGINX_PORT>/radarr/`
- Root folder: `/data/movies`
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
- Connect to Jellyfin, Sonarr, and Radarr using API keys

8. Configure Homarr
- URL: `http://<host>:<NGINX_PORT>/`
- Create the owner account and keep the NAS Control Room board private
- Create the public Home Cinema board and connect the internal integrations
- Apply the exact board, privacy, responsive-layout, and appearance recipe in [`homarr.md`](homarr.md)
- Export a Homarr backup after configuration and store the encryption key separately

9. Install Jellyfin Intro Skipper plugin
- In Jellyfin: Dashboard -> Plugins -> Catalog -> install `Intro Skipper`
- Restart Jellyfin after install
- Run the intro detection scheduled task in Jellyfin (Dashboard -> Scheduled Tasks)

10. Trigger library scans
- In Jellyfin, rescan libraries
- Validate playback for at least one movie and one TV episode
- Validate subtitle auto-download from Bazarr on one new import
