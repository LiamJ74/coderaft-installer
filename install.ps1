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

# ── OS detection ─────────────────────────────────────────────────────────────
# Coderaft itself runs in Docker on every OS. The native capture daemon
# (Ravenscan live packet inspection) is the exception: on Docker Desktop
# (Windows here) containers cannot see the host's real NICs, so we
# install a Windows Service on the host instead. On Linux servers the
# Docker sidecar with network_mode: host works natively.
$CoderaftOS   = "windows"
$CoderaftArch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
$CoderaftNeedsNativeCapture = $true
Write-Host "  Detected: $CoderaftOS/$CoderaftArch"
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

$AbsoluteInstallDir = (Get-Location).Path

if ((Test-Path '.env') -and (Select-String -Path '.env' -Pattern '^POSTGRES_PASSWORD=' -Quiet)) {
    # Fix UTF-8 BOM if present (older installers wrote BOM which breaks Docker Compose)
    $envBytes = [System.IO.File]::ReadAllBytes("$(Get-Location)\.env")
    if ($envBytes.Length -ge 3 -and $envBytes[0] -eq 0xEF -and $envBytes[1] -eq 0xBB -and $envBytes[2] -eq 0xBF) {
        Write-Host "  ⚠ Fixing UTF-8 BOM in .env..." -ForegroundColor Yellow
        $envContent = [System.Text.Encoding]::UTF8.GetString($envBytes, 3, $envBytes.Length - 3)
        [System.IO.File]::WriteAllText("$(Get-Location)\.env", $envContent, [System.Text.UTF8Encoding]::new($false))
    }
    if (-not (Select-String -Path '.env' -Pattern '^HOST_PROJECT_DIR=' -Quiet)) {
        $line = "`nHOST_PROJECT_DIR=$AbsoluteInstallDir"
        [System.IO.File]::AppendAllText("$(Get-Location)\.env", $line, [System.Text.UTF8Encoding]::new($false))
    }
    Write-Host "  ✓ Existing config preserved" -ForegroundColor Green
} else {
    Write-Host "  Generating secrets..."
    $Env = @"
# CodeRaft Dashboard — $(Get-Date -Format 'yyyy-MM-dd')
POSTGRES_PASSWORD=$(New-HexSecret 24)
REDIS_PASSWORD=$(New-HexSecret 24)
DASHBOARD_SECRET=$(New-HexSecret 32)
HOST_PROJECT_DIR=$AbsoluteInstallDir
RAVENSCAN_CAPTURE_TOKEN=$(New-HexSecret 32)
CODERAFT_HOST_OS=$CoderaftOS
CODERAFT_HOST_ARCH=$CoderaftArch
"@
    # Write without BOM — Docker Compose .env parser chokes on UTF-8 BOM
    [System.IO.File]::WriteAllText("$(Get-Location)\.env", $Env, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Secrets generated" -ForegroundColor Green
}

# Read the capture token back so we can hand it to the native daemon installer.
$RavenscanCaptureToken = (Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_TOKEN=' -Quiet) `
    | ForEach-Object { (Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_TOKEN=(.+)$').Matches.Groups[1].Value }
if (-not $RavenscanCaptureToken) {
    $match = Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_TOKEN=(.+)$'
    if ($match) { $RavenscanCaptureToken = $match.Matches.Groups[1].Value }
}

# Init DB
[System.IO.File]::WriteAllText("$(Get-Location)\init-db.sql", '-- Product databases are created by the dashboard on demand', [System.Text.UTF8Encoding]::new($false))

# Docker compose
Write-Host "  Writing docker-compose.yml..."
$Compose = @'
# CodeRaft Dashboard
# Products are deployed by the dashboard after license activation.

services:
  # Caddy local HTTPS reverse proxy.
  # Terminates TLS using mkcert-generated certs (trusted locally) and forwards
  # to the nginx SPA inside the `dashboard` container. Falls back to plain
  # HTTP on :3000 if no certs are mounted (compat retrograde).
  caddy:
    image: caddy:2-alpine
    depends_on:
      dashboard: { condition: service_started }
    ports:
      - "127.0.0.1:443:443"
      - "127.0.0.1:80:80"
    volumes:
      - ./caddy_certs:/certs:ro
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    security_opt: [no-new-privileges:true]
    restart: unless-stopped

  dashboard:
    image: ghcr.io/liamj74/coderaft-dashboard:latest
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
      dashboard-api: { condition: service_started }
    environment:
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - DASHBOARD_SECRET=${DASHBOARD_SECRET}
      - LICENSE_SERVER_URL=https://license.coderaft.io
    security_opt: [no-new-privileges:true]
    restart: unless-stopped

  dashboard-api:
    image: ghcr.io/liamj74/coderaft-dashboard-api:latest
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    environment:
      - LICENSE_SERVER_URL=https://license.coderaft.io
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - DASHBOARD_SECRET=${DASHBOARD_SECRET}
      - CONTAINER_COMPOSE_DIR=/host-compose
      - HOST_PROJECT_DIR=${HOST_PROJECT_DIR}
      - COMPOSE_PROJECT_NAME=coderaft
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - dashboard_data:/data
      - .:/host-compose
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
      # init-db.sql is intentionally NOT bind-mounted — when the
      # dashboard-api spawns docker-compose from inside a Linux container
      # against a Windows host, the resolved Windows path contains a
      # drive-letter colon that the daemon rejects ("too many colons").
      # The script was a no-op anyway (just a comment); product databases
      # are created on demand by the dashboard.
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coderaft"]
      interval: 5s
      timeout: 5s
      retries: 5
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    command: redis-server --requirepass ${REDIS_PASSWORD} --maxmemory 128mb
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  postgres_data:
  dashboard_data:
  caddy_data:
  caddy_config:
'@
[System.IO.File]::WriteAllText("$(Get-Location)\docker-compose.yml", $Compose, [System.Text.UTF8Encoding]::new($false))

# ── Caddyfile (local HTTPS) ──────────────────────────────────────────────────
$Caddyfile = @'
{
    auto_https off
    admin off
}

(coderaft_tls) {
    tls /certs/coderaft.local.pem /certs/coderaft.local-key.pem
}

https://coderaft.local, https://*.coderaft.local {
    import coderaft_tls
    reverse_proxy dashboard:3000 {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
    }
}

http://coderaft.local, http://*.coderaft.local {
    redir https://{host}{uri} permanent
}

:80 {
    reverse_proxy dashboard:3000
}
'@
if (-not (Test-Path "$(Get-Location)\Caddyfile")) {
    [System.IO.File]::WriteAllText("$(Get-Location)\Caddyfile", $Caddyfile, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Caddyfile generated"
}

# ── Local HTTPS via mkcert ───────────────────────────────────────────────────
function Setup-LocalHttps {
    if ($env:CODERAFT_SKIP_HTTPS -eq "1") {
        Write-Host "  CODERAFT_SKIP_HTTPS=1 — skipping local HTTPS setup"
        return $false
    }

    New-Item -ItemType Directory -Force -Path "caddy_certs" | Out-Null

    $certPath = "caddy_certs\coderaft.local.pem"
    $keyPath  = "caddy_certs\coderaft.local-key.pem"
    if ((Test-Path $certPath) -and (Test-Path $keyPath)) {
        $age = (Get-Date) - (Get-Item $certPath).LastWriteTime
        if ($age.TotalDays -lt 80) {
            Write-Host "  ✓ Local HTTPS certs already present (caddy_certs\)" -ForegroundColor Green
            return $true
        }
        Write-Host "  Local HTTPS certs older than 80 days — regenerating"
    }

    if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
        Write-Host "  mkcert not found."
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "  Installing mkcert via Chocolatey (choco install mkcert)…"
            try {
                choco install mkcert -y --no-progress *> $null
            } catch {
                Write-Host "  ⚠ choco install mkcert failed — fallback to http://localhost:3000" -ForegroundColor Yellow
                return $false
            }
        } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
            Write-Host "  Installing mkcert via Scoop (scoop install mkcert)…"
            try {
                scoop install mkcert *> $null
            } catch {
                Write-Host "  ⚠ scoop install mkcert failed — fallback to http://localhost:3000" -ForegroundColor Yellow
                return $false
            }
        } else {
            Write-Host "  ⚠ Neither Chocolatey nor Scoop found — install mkcert manually:" -ForegroundColor Yellow
            Write-Host "      https://github.com/FiloSottile/mkcert#installation"
            Write-Host "    Continuing in HTTP-only mode (http://localhost:3000)."
            return $false
        }
    }

    Write-Host "  Installing mkcert local CA (one-time)…"
    try {
        & mkcert -install *> $null
    } catch {
        Write-Host "  ⚠ mkcert -install failed — local HTTPS will not be trusted." -ForegroundColor Yellow
    }

    Write-Host "  Generating local cert for coderaft.local…"
    try {
        & mkcert -cert-file $certPath -key-file $keyPath `
            "coderaft.local" "*.coderaft.local" "localhost" "127.0.0.1" "::1" *> $null
    } catch {
        Write-Host "  ⚠ mkcert cert generation failed — fallback to http://localhost:3000" -ForegroundColor Yellow
        Remove-Item -ErrorAction SilentlyContinue $certPath, $keyPath
        return $false
    }
    Write-Host "  ✓ Local HTTPS cert generated (valid 825d)" -ForegroundColor Green
    return $true
}

# ── hosts file entries ──────────────────────────────────────────────────────
function Ensure-HostsEntry {
    $hostsFile = "$env:WINDIR\System32\drivers\etc\hosts"
    $marker    = "# coderaft-platform"
    $entry     = "127.0.0.1 coderaft.local entraguard.coderaft.local ravenscan.coderaft.local redfox.coderaft.local $marker"

    if (Test-Path $hostsFile) {
        $existing = Get-Content $hostsFile -ErrorAction SilentlyContinue
        if ($existing -match "coderaft\.local") {
            Write-Host "  ✓ hosts file already contains coderaft.local"
            return
        }
    }

    if ($env:CODERAFT_SKIP_HOSTS -eq "1") {
        Write-Host "  CODERAFT_SKIP_HOSTS=1 — skipping hosts update"
        return
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        try {
            Add-Content -Path $hostsFile -Value $entry -ErrorAction Stop
            Write-Host "  ✓ hosts file updated"
        } catch {
            Write-Host "  ⚠ Could not update hosts file: $_" -ForegroundColor Yellow
            Write-Host "    Add manually to ${hostsFile}:"
            Write-Host "      $entry"
        }
    } else {
        Write-Host "  ⚠ Not running as Administrator — cannot update hosts file." -ForegroundColor Yellow
        Write-Host "    Add the following line to ${hostsFile} (run as admin):"
        Write-Host "      $entry"
    }
}

$httpsReady = Setup-LocalHttps
if ($httpsReady) {
    Ensure-HostsEntry
}

# Helper scripts
Set-Content -Path 'start.ps1' -Value @'
Write-Host "Starting CodeRaft..."
docker compose up -d
$Url = "http://localhost:3000"
if ((Test-Path "caddy_certs\coderaft.local.pem") -and `
    ((Get-Content "$env:WINDIR\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue) -match "coderaft\.local")) {
    $Url = "https://coderaft.local"
}
Write-Host "  Dashboard: $Url"
Start-Process $Url
'@ -Encoding UTF8

Set-Content -Path 'stop.ps1' -Value @'
Write-Host "Stopping CodeRaft..."
docker compose down
Write-Host "Done."
'@ -Encoding UTF8

try {
    $u = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/update.ps1" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    [System.IO.File]::WriteAllText("$PWD\update.ps1", $u.Content, [System.Text.Encoding]::UTF8)
} catch {
    Set-Content -Path 'update.ps1' -Value @'
Write-Host "Updating CodeRaft..."
docker compose pull
docker compose up -d --force-recreate --remove-orphans
Write-Host "  Updated! Dashboard: http://localhost:3000"
'@ -Encoding UTF8
}

try {
    $r = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/rollback.ps1" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    [System.IO.File]::WriteAllText("$PWD\rollback.ps1", $r.Content, [System.Text.Encoding]::UTF8)
} catch {
    Set-Content -Path 'rollback.ps1' -Value @'
Write-Host "rollback.ps1 placeholder — fetch the real one from https://install.coderaft.io/rollback.ps1"
Write-Host "or run: irm https://install.coderaft.io/rollback.ps1 -OutFile rollback.ps1"
exit 1
'@ -Encoding UTF8
}

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


# ── Native capture daemon (Windows Service) ───────────────────────────────────
if ($CoderaftNeedsNativeCapture -and $env:SKIP_NATIVE_CAPTURE -ne "1") {
    Write-Host ""
    Write-Host "  ── Live capture daemon (native Windows Service) ────"
    Write-Host "  Coderaft runs in Docker but live packet capture needs"
    Write-Host "  a native service that can see your real Wi-Fi and"
    Write-Host "  Ethernet interfaces (Docker Desktop hides them)."
    Write-Host ""

    # Public ravenscan-installer repo — same pattern as the other
    # Coderaft products (private source repo, public installer repo
    # holds release artifacts). Pinned to a deliberate tag.
    $CaptureBaseUrl = if ($env:CAPTURE_BASE_URL) { $env:CAPTURE_BASE_URL } `
                      else { "https://github.com/LiamJ74/ravenscan-installer/releases/download/capture-v0.1.0" }
    $CaptureBin     = "ravenscan-capture-host-windows-$CoderaftArch.exe"
    $CaptureTmp     = Join-Path $env:TEMP ("coderaft-capture-{0}" -f (Get-Random))
    New-Item -ItemType Directory -Force -Path $CaptureTmp | Out-Null

    try {
        Write-Host "  Downloading $CaptureBin from $CaptureBaseUrl…"
        $files = @($CaptureBin, "install-windows.ps1", "uninstall-windows.ps1", "SHA256SUMS")
        foreach ($f in $files) {
            try {
                Invoke-WebRequest -Uri "$CaptureBaseUrl/$f" `
                    -OutFile (Join-Path $CaptureTmp $f) -UseBasicParsing
            } catch {
                if ($f -eq "SHA256SUMS") { continue }  # optional
                throw
            }
        }

        # Optional checksum verification.
        $sumsPath = Join-Path $CaptureTmp "SHA256SUMS"
        if (Test-Path $sumsPath) {
            foreach ($line in Get-Content $sumsPath) {
                if ($line -match '^([0-9a-f]{64})\s+(\S+)$') {
                    $expected = $Matches[1]
                    $name     = $Matches[2]
                    $localPath = Join-Path $CaptureTmp $name
                    if (Test-Path $localPath) {
                        $actual = (Get-FileHash -Algorithm SHA256 $localPath).Hash.ToLower()
                        if ($actual -ne $expected) {
                            throw "Checksum mismatch for ${name}: expected $expected, got $actual"
                        }
                    }
                }
            }
            Write-Host "  ✓ Checksums verified"
        }

        # Self-elevate to install the Windows Service if not already admin.
        $isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)

        $installScript = Join-Path $CaptureTmp "install-windows.ps1"
        if ($isAdmin) {
            Write-Host "  Running install-windows.ps1 as administrator…"
            & $installScript -Token $RavenscanCaptureToken
        } else {
            Write-Host "  Re-launching capture installer with elevated privileges…"
            $args = "-NoProfile -ExecutionPolicy Bypass -File `"$installScript`" -Token `"$RavenscanCaptureToken`""
            Start-Process powershell -ArgumentList $args -Verb RunAs -Wait
        }

        # Tell the platform to talk to the host daemon instead of the
        # Docker sidecar (Docker Desktop on Windows can only see the
        # bridge network from inside containers).
        if (-not (Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_SIDECAR_URL=' -Quiet)) {
            $line = "`nRAVENSCAN_CAPTURE_SIDECAR_URL=http://host.docker.internal:7777"
            [System.IO.File]::AppendAllText("$(Get-Location)\.env", $line, [System.Text.UTF8Encoding]::new($false))
        }
        Write-Host "  ✓ Native capture daemon installed and running on 127.0.0.1:7777" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Could not install the native capture daemon: $_" -ForegroundColor Yellow
        Write-Host "    Live capture will be limited to the Docker bridge until you"
        Write-Host "    install the daemon manually from the Settings page."
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $CaptureTmp
    }
    Write-Host ""
}

$DashboardUrl = "http://localhost:3000"
if ((Test-Path "caddy_certs\coderaft.local.pem") -and `
    ((Get-Content "$env:WINDIR\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue) -match "coderaft\.local")) {
    $DashboardUrl = "https://coderaft.local"
}

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║            Installation complete!                    ║" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host ("  ║   Dashboard: {0,-39} ║" -f $DashboardUrl) -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║   Open the dashboard to activate your license        ║" -ForegroundColor Green
Write-Host "  ║   and deploy your products.                          ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Commands:  .\start.ps1  .\stop.ps1  .\update.ps1  .\rollback.ps1"
Write-Host ""

Start-Process $DashboardUrl
