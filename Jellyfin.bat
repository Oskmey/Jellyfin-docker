@echo off
echo Starting Jellyfin server...
cd /d %~dp0
REM Check if Docker is installed and running
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo Docker is not installed, not running, or you don't have permission.
    exit /b 1
)

REM Check if Docker Compose is available
docker-compose --version >nul 2>&1
if %errorlevel% neq 0 (
    echo Docker Compose is not installed or not in PATH.
    exit /b 1
)

REM Check if Jellyfin container is running
docker ps | findstr jellyfin >nul 2>&1
if %errorlevel% equ 0 (
    echo Jellyfin is already running. Stopping and cleaning up...
    
    REM Stop containers and remove orphans
    docker-compose down --remove-orphans
    
    REM Prune unused volumes
    echo Cleaning unused volumes...
    docker volume prune -f
    
    REM Prune unused images
    echo Cleaning unused images...
    docker image prune -f
    
    echo Cleanup completed.
)

REM Start Docker Compose
echo Starting Jellyfin with Docker Compose...
docker-compose up -d

REM Verify if Jellyfin is running
docker ps | findstr jellyfin >nul 2>&1
if %errorlevel% equ 0 (
    echo Jellyfin has been started successfully.
) else (
    echo Failed to start Jellyfin. Please check the logs:
    docker-compose logs
)