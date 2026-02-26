# First-Run Wiring Checklist

Use this order for a clean first setup:

1. Open Jellyfin and complete admin wizard
- URL: `http://<host>:<NGINX_PORT>/jellyfin/`
- Add libraries:
  - TV: `/data/tvshows`
  - Movies: `/data/movies`

2. Configure qBittorrent
- URL: `http://<host>:<NGINX_PORT>/qbittorrent/`
- Set default save path to `/data/downloads`

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
- Copy API key (Settings -> General -> Security) for Unpackerr and Bazarr

5. Configure Radarr
- URL: `http://<host>:<NGINX_PORT>/radarr/`
- Root folder: `/data/movies`
- Download client:
  - qBittorrent host: `gluetun`
  - Port: `8080`
  - Category: `movies`
- Copy API key (Settings -> General -> Security) for Unpackerr and Bazarr

6. Configure Bazarr
- URL: `http://<host>:<NGINX_PORT>/bazarr/`
- Add Sonarr:
  - URL: `http://sonarr:8989/sonarr`
  - API key: Sonarr API key
- Add Radarr:
  - URL: `http://radarr:7878/radarr`
  - API key: Radarr API key
- Create subtitle language profiles and enable automatic subtitle search

7. Configure Jellyseerr
- URL: `http://<host>:<JELLYSEERR_PORT>/`
- Connect to Jellyfin, Sonarr, and Radarr using API keys

8. Verify Unpackerr
- Unpackerr starts automatically from `.env` values
- Check logs and confirm both apps are connected:
```bash
docker compose logs -f unpackerr
```

9. Configure Homepage dashboard
- URL: `http://<host>:<NGINX_PORT>/homepage/`
- Edit files in `${COMMON_PATH}/Homepage/Config` (for example `services.yaml`)
- Add cards/links for Jellyfin, Jellyseerr, Sonarr, Radarr, Prowlarr, qBittorrent, and Bazarr

10. Install Jellyfin Intro Skipper plugin
- In Jellyfin: Dashboard -> Plugins -> Catalog -> install `Intro Skipper`
- Restart Jellyfin after install
- Run the intro detection scheduled task in Jellyfin (Dashboard -> Scheduled Tasks)

11. Trigger library scans
- In Jellyfin, rescan libraries
- Validate playback for at least one movie and one TV episode
- Validate subtitle auto-download from Bazarr on one new import
