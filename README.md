# Media NAS Stack

A **self-hosted media management system** built with Docker, designed for organizing, streaming, and managing your personal media collection. This setup includes a VPN for security, automatic media discovery, and a beautiful web interface for streaming.

## What This Does

This stack automates your media workflow:

### **1. Media Management**
- **Jellyfin**: Your own self-hosted Netflix-style media server with a beautiful UI
- **Jellyseerr**: Request management system (like Ombi) for family/friends to request content

### **2. Automatic Media Discovery**
- **Sonarr**: Automatically downloads and organizes TV shows
- **Radarr**: Automatically downloads and organizes movies
- **Prowlarr**: Unified indexer management for all your sources

### **3. Secure Torrenting**
- **qBittorrent**: Private torrent client
- **Gluetun**: VPN integration (Mullvad WireGuard) to protect your identity

### **4. System Management**
- **Portainer**: Web-based Docker management GUI
- **Nginx**: Reverse proxy with WebSocket support for media streaming

## Quick Start

### Prerequisites
- Docker and Docker Compose installed
- VPN credentials (Mullvad recommended)

### Setup

1. Clone this repository
2. add `.env` and configure your settings
3. Run the setup script
   ```bash
   chmod +x folder_setup.sh
   ./folder_setup.sh
   ```
4. Start the stack
   ```bash
   docker-compose up -d
   ```

### Access Your Services
- **Jellyfin**: `http://your-server/jellyfin`
- **Jellyseerr**: `http://your-server/jellyseerr`
- **Sonarr**: `http://your-server/sonarr`
- **Radarr**: `http://your-server/radarr`
- **Prowlarr**: `http://your-server/prowlarr`
- **qBittorrent**: `http://your-server/qbittorrent`
- **Portainer**: `http://your-server/portainer`

## How It Works

### **Workflow**
1. **Request Content**: Users request TV shows/movies via Jellyseerr
2. **Search & Download**: Prowlarr searches indexers, Radarr/Sonarr find and download via qBittorrent
3. **Organize**: Files are automatically organized into proper folders
4. **Stream**: Jellyfin scans and makes media available for streaming

### **VPN Protection**
- qBittorrent runs inside the Gluetun VPN container
- All torrent traffic is routed through Mullvad WireGuard
- Your real IP remains hidden

### **Reverse Proxy**
- Nginx provides secure access to all services
- WebSocket support enables smooth media streaming
- Security headers protect against common vulnerabilities

## Directory Structure

```
${COMMON_PATH}/
├── Qbittorrent/      # Torrent client config
├── Downloads/        # Incoming downloads
├── Sonarr/           # TV show management
│   ├── Config/
│   ├── Backup/
│   └── tvshows/      # Organized TV shows
├── Radarr/           # Movie management
│   ├── Config/
│   ├── Backup/
│   └── movies/       # Organized movies
├── Prowlarr/         # Indexer management
├── Jellyfin/         # Media server
│   ├── Config/
│   └── Cache/
├── Jellyseerr/       # Request management
└── Portainer/        # Docker management
```

## Important Notes

- This setup is intended only for **personal use** with legally obtained content
- Do not use for piracy or copyright-infringing material

## Customization

Edit the `.env` file to configure:
- VPN settings (Mullvad credentials)
- Timezone
- User IDs (PUID/PGID)
- Storage paths (COMMON_PATH)

## Security Features

- VPN protection for torrenting
- Secure reverse proxy with rate limiting
- Security headers to prevent common attacks
- Private network for inter-container communication
