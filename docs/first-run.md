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

5. Configure Radarr
- URL: `http://<host>:<NGINX_PORT>/radarr/`
- Root folder: `/data/movies`
- Download client:
  - qBittorrent host: `gluetun`
  - Port: `8080`
  - Category: `movies`

6. Configure Jellyseerr
- URL: `http://<host>:<NGINX_PORT>/jellyseerr/`
- Connect to Jellyfin, Sonarr, and Radarr using API keys

7. Trigger library scans
- In Jellyfin, rescan libraries
- Validate playback for at least one movie and one TV episode
