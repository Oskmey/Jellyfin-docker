@echo off
setlocal
cd /d %~dp0

if "%1"=="stop" goto stop
if "%1"=="restart" goto restart
if "%1"=="logs" goto logs
if "%1"=="status" goto status
if "%1"=="help" goto help
if "%1"=="--help" goto help

:start
echo Starting services with Docker Compose...
docker compose up -d
if %errorlevel% neq 0 (
    echo Failed to start services.
    exit /b 1
)
echo Services started.
exit /b 0

:stop
echo Stopping services...
docker compose down
exit /b %errorlevel%

:restart
echo Restarting services...
docker compose down
docker compose up -d
exit /b %errorlevel%

:logs
docker compose logs -f
exit /b %errorlevel%

:status
docker compose ps
exit /b %errorlevel%

:help
echo Usage: Jellyfin.bat [start^|stop^|restart^|logs^|status]
echo Default command is start.
exit /b 0
