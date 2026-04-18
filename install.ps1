# =============================================================================
# CodeRaft Platform — One-line installer (PowerShell)
# Usage: irm https://install.coderaft.io/win | iex
#
# Installs the CodeRaft Dashboard. The dashboard handles everything else:
#   - License activation
#   - Product deployment (EntraGuard, Ravenscan, RedFox)
#   - Configuration & updates
# =============================================================================

$ErrorActionPreference = 'Stop'
$InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { 'coderaft' }

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗"
Write-Host "  ║     CodeRaft Platform — Installer        ║"
Write-Host "  ║   Security. Identity. Access. Unified.   ║"
Write-Host "  ╚══════════════════════════════════════════╝"
Write-Host ""

# ── Prerequisites ────────────────────────────────────────────────────────────

function Test-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Host "  ✗ $name is required but not installed." -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ $name found" -ForegroundColor Green
}

Write-Host "  Checking prerequisites..."
Test-Command docker
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ✗ 'docker compose' plugin is required." -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ docker compose found" -ForegroundColor Green
Write-Host ""

# ── Install ──────────────────────────────────────────────────────────────────

Write-Host "  Installing to: $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir

function New-HexSecret($length) {
    $bytes = New-Object byte[] $length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ''
}

if ((Test-Path '.env') -and (Select-String -Path '.env' -Pattern '^POSTGRES_PASSWORD=' -Quiet)) {
    Write-Host "  ✓ Existing config preserved" -ForegroundColor Green
} else {
    Write-Host "  Generating secrets..."
    $Env = @"
# CodeRaft Dashboard — $(Get-Date -Format 'yyyy-MM-dd')
POSTGRES_PASSWORD=$(New-HexSecret 24)
REDIS_PASSWORD=$(New-HexSecret 24)
DASHBOARD_SECRET=$(New-HexSecret 32)
"@
    Set-Content -Path '.env' -Value $Env -Encoding UTF8
    Write-Host "  ✓ Secrets generated" -ForegroundColor Green
}

# Init DB
Set-Content -Path 'init-db.sql' -Value '-- Product databases are created by the dashboard on demand' -Encoding UTF8

# Docker compose
Write-Host "  Writing docker-compose.yml..."
$Compose = @'
# CodeRaft Dashboard
# Products are deployed by the dashboard after license activation.

services:
  dashboard:
    image: ghcr.io/liamj74/coderaft-dashboard:latest
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    environment:
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - DASHBOARD_SECRET=${DASHBOARD_SECRET}
      - LICENSE_SERVER_URL=https://license.coderaft.io
      - DOCKER_HOST=unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - dashboard_data:/data
    security_opt: [no-new-privileges:true]
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: coderaft
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: coderaft
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-db.sql:/docker-entrypoint-initdb.d/10-init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coderaft"]
      interval: 5s
      timeout: 5s
      retries: 5
    security_opt: [no-new-privileges:true]
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    command: redis-server --requirepass ${REDIS_PASSWORD} --maxmemory 128mb --appendonly yes
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5
    security_opt: [no-new-privileges:true]
    restart: unless-stopped

volumes:
  postgres_data:
  dashboard_data:
'@
Set-Content -Path 'docker-compose.yml' -Value $Compose -Encoding UTF8

# Helper scripts
Set-Content -Path 'start.ps1' -Value @'
Write-Host "Starting CodeRaft..."
docker compose up -d
Write-Host "  Dashboard: http://localhost:3000"
Start-Process "http://localhost:3000"
'@ -Encoding UTF8

Set-Content -Path 'stop.ps1' -Value @'
Write-Host "Stopping CodeRaft..."
docker compose down
Write-Host "Done."
'@ -Encoding UTF8

Set-Content -Path 'update.ps1' -Value @'
Write-Host "Updating CodeRaft..."
docker compose pull
docker compose up -d --remove-orphans
Write-Host "  Updated! Dashboard: http://localhost:3000"
'@ -Encoding UTF8

# ── Pull & Start ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  Pulling dashboard image..."
docker compose pull

Write-Host ""
Write-Host "  Starting dashboard..."
docker compose up -d

Write-Host ""
Write-Host "  Waiting for dashboard to be ready..."
Start-Sleep -Seconds 10

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║            Installation complete!                    ║" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║   Dashboard: http://localhost:3000                   ║" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║   Open the dashboard to activate your license        ║" -ForegroundColor Green
Write-Host "  ║   and deploy your products.                          ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Commands:  .\start.ps1  .\stop.ps1  .\update.ps1"
Write-Host ""

Start-Process "http://localhost:3000"
