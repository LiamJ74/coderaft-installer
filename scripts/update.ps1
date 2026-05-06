# CodeRaft updater (Windows / PowerShell)
#
# Self-updates from the installer repo, captures a pre-update recovery
# snapshot, pulls new images, runs a post-update healthcheck and triggers
# rollback.ps1 automatically if the dashboard API doesn't come back up.
# Mirrors the logic of update.sh (Linux) with Windows adaptations.

$ErrorActionPreference = "Stop"

$DASHBOARD_API       = if ($env:DASHBOARD_API)       { $env:DASHBOARD_API }       else { "http://localhost:3000" }
$ADMIN_TOKEN         = if ($env:ADMIN_TOKEN)         { $env:ADMIN_TOKEN }         else { "" }
$BACKUP_DIR          = if ($env:BACKUP_DIR)          { $env:BACKUP_DIR }          else { ".\dashboard_data\backups" }
$HEALTHCHECK_RETRIES = if ($env:HEALTHCHECK_RETRIES) { [int]$env:HEALTHCHECK_RETRIES } else { 30 }
$HEALTHCHECK_DELAY   = if ($env:HEALTHCHECK_DELAY)   { [int]$env:HEALTHCHECK_DELAY }   else { 3 }
$INSTALL_DIR         = if ($env:INSTALL_DIR)         { $env:INSTALL_DIR }         else { (Get-Location).Path }

# ── ADMIN_TOKEN auto-discovery ────────────────────────────────────────────
# Priority order:
#   1. $env:ADMIN_TOKEN
#   2. .env files (INSTALL_DIR, C:\ProgramData\coderaft, ~/.coderaft)
#   3. Plain token files (single word)
# If nothing is found → continue; snapshot/notify are skipped with a warning.
# IMPORTANT: NEVER write the discovered token to the console.
function Find-AdminToken {
    if ($ADMIN_TOKEN) { return $ADMIN_TOKEN }

    $envCandidates = @(
        (Join-Path $INSTALL_DIR ".env"),
        "C:\ProgramData\coderaft\.env",
        (Join-Path $HOME ".coderaft\.env")
    )
    foreach ($envFile in $envCandidates) {
        if ($envFile -and (Test-Path $envFile -PathType Leaf)) {
            try {
                $lines = Get-Content -LiteralPath $envFile -ErrorAction Stop
                foreach ($line in $lines) {
                    if ($line -match '^\s*ADMIN_TOKEN\s*=\s*(.+)$') {
                        $val = $Matches[1].Trim().Trim('"').Trim("'")
                        if ($val) { return $val }
                    }
                }
            } catch { }
        }
    }

    $tokenCandidates = @(
        "C:\ProgramData\coderaft\admin_token",
        (Join-Path $HOME ".coderaft\admin_token"),
        "\\.\pipe\coderaft_admin_token"  # placeholder; ignored if absent
    )
    foreach ($tokenFile in $tokenCandidates) {
        if ($tokenFile -and (Test-Path $tokenFile -PathType Leaf)) {
            try {
                $val = (Get-Content -LiteralPath $tokenFile -Raw -ErrorAction Stop).Trim()
                if ($val) { return $val }
            } catch { }
        }
    }
    # 5. Auto-discovery from running dashboard-api container (preferred,
    #    avoids any manual setup — dashboard-api auto-generates the token
    #    at boot and persists it to /data/admin_token).
    try {
        Push-Location $INSTALL_DIR -ErrorAction SilentlyContinue
        $services = & docker compose ps --services 2>$null
        if ($services -match '(?m)^dashboard-api$') {
            $val = & docker compose exec -T dashboard-api cat /data/admin_token 2>$null
            if ($val) {
                $val = ($val -join "`n").Trim()
                if ($val) { return $val }
            }
        }
    } catch { }
    finally { Pop-Location -ErrorAction SilentlyContinue }
    $LASTEXITCODE = 0
    return ""
}

if (-not $ADMIN_TOKEN) {
    $discovered = Find-AdminToken
    if ($discovered) { $ADMIN_TOKEN = $discovered }
    Remove-Variable -Name discovered -ErrorAction SilentlyContinue
}

# Detect the current PowerShell binary (compat PS5 'powershell.exe' + PS7 'pwsh.exe')
$PSBin = (Get-Process -Id $PID).Path
if (-not $PSBin -or -not (Test-Path $PSBin)) {
    if (Get-Command pwsh -ErrorAction SilentlyContinue)       { $PSBin = "pwsh" }
    elseif (Get-Command powershell -ErrorAction SilentlyContinue) { $PSBin = "powershell" }
    else { $PSBin = "powershell" }
}

# Docker platform detection — Docker Desktop sometimes resolves strictly to
# linux/arm64/v8 or linux/amd64/v3 by default, which fails on manifests that
# only expose linux/arm64 or linux/amd64. Force the platform.
if (-not $env:DOCKER_DEFAULT_PLATFORM) {
    $hostArch = $env:PROCESSOR_ARCHITECTURE
    if ($hostArch -eq "ARM64")        { $env:DOCKER_DEFAULT_PLATFORM = "linux/arm64" }
    elseif ($hostArch -eq "AMD64")    { $env:DOCKER_DEFAULT_PLATFORM = "linux/amd64" }
}

Write-Host "  Updating CodeRaft..."

# ── Self-update update.ps1 + rollback.ps1 (with re-exec) ───────────────────
# The in-memory script keeps running with its OLD logic after we overwrite
# the file on disk. Without re-exec, the freshly downloaded fixes would only
# take effect on the NEXT run. CODERAFT_UPDATE_REEXEC guards against loops.
if (-not $env:CODERAFT_UPDATE_REEXEC) {
    Write-Host "  Checking for script updates..."
    $refreshed = $false
    foreach ($name in @("update.ps1", "rollback.ps1")) {
        try {
            $url = "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/$name"
            $latest = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($latest.StatusCode -eq 200 -and $latest.Content.Length -gt 50) {
                [System.IO.File]::WriteAllText("$PWD\$name", $latest.Content, [System.Text.Encoding]::UTF8)
                Write-Host "  $name refreshed"
                if ($name -eq "update.ps1") { $refreshed = $true }
            }
        } catch {
            # Offline or upstream down — keep the local copy
        }
    }
    if ($refreshed -and (Test-Path ".\update.ps1")) {
        Write-Host "  Re-executing the updated script..."
        $env:CODERAFT_UPDATE_REEXEC = "1"
        & $PSBin -NoProfile -ExecutionPolicy Bypass -File ".\update.ps1"
        exit $LASTEXITCODE
    }
}

# ── Self-heal compose YAML ────────────────────────────────────────────────
# Detects a broken docker-compose.override.yml (buggy YAML generator) and
# auto-recovers: timestamped backup, deletion, pull dashboard-api, restart
# postgres+redis+dashboard-api → the API regenerates a clean override.
Write-Host ""
Write-Host "  Checking compose integrity..."
$composeOK = $false
try {
    & docker compose ps 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $composeOK = $true }
} catch { }
if (-not $composeOK) {
    Write-Host "  ⚠ docker-compose.override.yml appears corrupted — auto-recovery..."
    if (Test-Path "docker-compose.override.yml") {
        $brokenBak = "docker-compose.override.yml.broken-" + (Get-Date -Format "yyyyMMdd_HHmmss")
        try { Copy-Item "docker-compose.override.yml" $brokenBak -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item "docker-compose.override.yml" -ErrorAction SilentlyContinue } catch { }
        Write-Host "    ✓ override backed up + removed"
    }
    try { & docker pull ghcr.io/liamj74/coderaft-dashboard-api:latest *>$null } catch { }
    try {
        & docker compose up -d postgres redis dashboard-api 2>&1 | Out-Null
        Start-Sleep -Seconds 6
        & docker compose ps 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    ✓ compose repaired"
        } else {
            Write-Host "  ERROR: self-heal failed. Inspect docker-compose.override.yml manually."
            exit 1
        }
    } catch {
        Write-Host "  ERROR: cannot restart dashboard-api — $($_.Exception.Message)"
        exit 1
    }
    $LASTEXITCODE = 0
} else {
    Write-Host "  ✓ compose OK"
}

# ── Host capture sanity check (Live Capture / Frame Analyzer) ─────────────
# Mirrors update.sh: when CODERAFT_HOST_OS=windows|macos the Frame Analyzer
# expects a native daemon on 127.0.0.1:7777. We probe via an alpine curl
# image (Docker Desktop maps host.docker.internal automatically). Failure is
# a *warning* — the host may be unreachable during the update window, or
# the operator may not have run the Setup Wizard's Live Capture step yet.
Write-Host ""
Write-Host "  Live Capture sanity check..."
$hostOsValue = ""
if (Test-Path ".env") {
    $envLine = Get-Content ".env" | Where-Object { $_ -match '^\s*CODERAFT_HOST_OS\s*=' } | Select-Object -Last 1
    if ($envLine) {
        $hostOsValue = ($envLine -replace '^\s*CODERAFT_HOST_OS\s*=', '').Trim().Trim('"').Trim("'").ToLower()
    }
}
switch ($hostOsValue) {
    { @("windows", "macos") -contains $_ } {
        try {
            & docker run --rm --add-host=host.docker.internal:host-gateway `
                curlimages/curl:8.10.1 -fsS --connect-timeout 3 --max-time 4 `
                "http://host.docker.internal:7777/health" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Native capture daemon reachable (CODERAFT_HOST_OS=$hostOsValue)"
            } else {
                Write-Host "  ⚠ CODERAFT_HOST_OS=$hostOsValue but the native daemon is not answering on 127.0.0.1:7777."
                Write-Host "     Frame Analyzer may show empty captures. Open the dashboard → Setup → Live Capture"
                Write-Host "     to (re)install the host daemon. Continuing the update."
            }
        } catch {
            Write-Host "  ⚠ Could not probe the native capture daemon ($($_.Exception.Message)). Continuing."
        }
        $LASTEXITCODE = 0
    }
    { @("linux", "") -contains $_ } {
        # No-op: Linux uses the in-Docker sidecar; missing var = default behaviour.
    }
    default {
        Write-Host "  ⚠ CODERAFT_HOST_OS='$hostOsValue' is not a recognised value (windows|macos|linux). Ignored."
    }
}

# ── Mandatory pre-update backup ───────────────────────────────────────────
# If pg_dumpall fails → block the update (no backup = no update).
Write-Host ""
Write-Host "  Pre-update backup..."
New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
$timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$BACKUP_FILE = Join-Path $BACKUP_DIR "preupdate-$timestamp.sql"

$postgresRunning = $false
try {
    $psOutput = & docker compose ps postgres --quiet 2>$null
    if ($psOutput) { $postgresRunning = $true }
} catch { }

if ($postgresRunning) {
    try {
        # Start-Process redirects stdout cleanly (no PS encoding issues)
        $proc = Start-Process -FilePath "docker" `
            -ArgumentList @("compose", "exec", "-T", "postgres", "pg_dumpall", "-U", "coderaft") `
            -RedirectStandardOutput $BACKUP_FILE `
            -NoNewWindow -PassThru -Wait

        if ($proc.ExitCode -eq 0 -and (Get-Item $BACKUP_FILE).Length -gt 0) {
            Write-Host "  Backup saved: $BACKUP_FILE"
        } else {
            Write-Host "  ERROR: pg_dumpall failed (exit $($proc.ExitCode)). Update cancelled."
            Write-Host "  Check that the postgres container is healthy: docker compose ps"
            exit 1
        }
    } catch {
        Write-Host "  ERROR: pg_dumpall failed — $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-Host "  PostgreSQL not detected — backup skipped (dashboard without DB)."
}

# ── Capture recovery snapshot via dashboard-api ───────────────────────────
Write-Host "  Capturing recovery snapshot..."
if ($ADMIN_TOKEN) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $ADMIN_TOKEN"
        }
        Invoke-RestMethod -Method Post -Uri "$DASHBOARD_API/api/dashboard/recovery/snapshots" `
            -Headers $headers -Body '{"reason":"pre-update"}' -TimeoutSec 10 | Out-Null
        Write-Host "    Snapshot saved."
    } catch {
        Write-Host "    Snapshot failed (auto-snapshot will run again at next deploy)."
    }
} else {
    Write-Host "    [warn] ADMIN_TOKEN not found — snapshot skipped."
    Write-Host "    (set `$env:ADMIN_TOKEN, or place token in $INSTALL_DIR\.env, C:\ProgramData\coderaft\admin_token, or ~/.coderaft/admin_token)"
}

# ── Pull and recreate ─────────────────────────────────────────────────────
# Include docker-compose.override.yml when it exists so product containers
# (entraguard-*, neo4j, ravenscan, redfox-*) are within scope. Without it,
# `--remove-orphans` treats every product as an orphan and silently nukes
# them, which is exactly what broke scans for users who had previously
# activated a Suite license.
$ComposeArgs = @("compose")
if (Test-Path ".\docker-compose.override.yml") {
    $ComposeArgs += @("-f", ".\docker-compose.yml", "-f", ".\docker-compose.override.yml")
}

# ── Refresh license keys (drift "superseded") ─────────────────────────────
# When the License Server resigns a license (e.g. feature added, key
# rotation), it returns 403 "License has been superseded by a newer version"
# for any request using the old key. So we refresh the key in
# docker-compose.override.yml BEFORE `docker compose up`. Backup is .bak.
# If the License Server is unreachable, we continue silently.
function Update-License {
    param(
        [Parameter(Mandatory=$true)] [string] $EnvVar,
        [Parameter(Mandatory=$true)] [string] $OverrideFile
    )
    if (-not (Test-Path $OverrideFile -PathType Leaf)) { return $false }

    $content = Get-Content -LiteralPath $OverrideFile -ErrorAction SilentlyContinue
    if (-not $content) { return $false }

    # Look for the first occurrence of "<EnvVar>=<value>" (with or without YAML dash).
    $regex = "^\s*-?\s*$([Regex]::Escape($EnvVar))=(.+)$"
    $currentKey = $null
    foreach ($line in $content) {
        if ($line -match $regex) {
            $currentKey = $Matches[1].Trim().Trim('"').Trim("'")
            break
        }
    }
    if (-not $currentKey -or $currentKey -eq "UNCONFIGURED") { return $false }

    $server = if ($env:LICENSE_SERVER_URL) { $env:LICENSE_SERVER_URL } else { "https://license.coderaft.io" }
    $latest = $null
    try {
        $body = @{ license_key = $currentKey } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Method Post -Uri "$server/api/licenses/validate" `
            -ContentType "application/json" -Body $body -TimeoutSec 10 -ErrorAction Stop
        if ($resp.latest_license_key) { $latest = [string]$resp.latest_license_key }
    } catch {
        # License Server unreachable or network error → silent
        return $false
    }

    if ($latest -and $latest -ne $currentKey) {
        Copy-Item -LiteralPath $OverrideFile -Destination "$OverrideFile.bak" -Force
        # Replace ALL occurrences (worker + api may share the key)
        $newContent = foreach ($line in $content) {
            if ($line -match $regex) {
                $padMatch = [Regex]::Match($line, "^(\s*-?\s*)")
                $pad = $padMatch.Groups[1].Value
                "$pad$EnvVar=$latest"
            } else {
                $line
            }
        }
        # Preserve the absence of BOM and use Unix LF (compose tolerates CRLF but we avoid pollution)
        [System.IO.File]::WriteAllLines($OverrideFile, $newContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  🔄 License refreshed for $EnvVar"
        return $true
    }
    return $false
}

function Update-AllLicenses {
    $overrideFile = Join-Path $INSTALL_DIR "docker-compose.override.yml"
    Write-Host ""
    Write-Host "  ▶ Checking for license drift..."
    $any = $false
    foreach ($var in @("LICENSE_KEY", "RAVENSCAN_LICENSE_KEY", "REDFOX_LICENSE_KEY")) {
        try {
            if (Update-License -EnvVar $var -OverrideFile $overrideFile) { $any = $true }
        } catch {
            # Never fail the update because of a refresh
        }
    }
    if ($any) {
        Write-Host "  ⚠️  At least one license was refreshed; services will be restarted"
    } else {
        Write-Host "  ✅ All licenses are up to date"
    }
}

try { Update-AllLicenses } catch { }

# ── Renew local HTTPS certs if older than 80 days ─────────────────────────
# Preserve user-provided certs untouched. Only auto-renew the ones we
# generated (mkcert) before they hit mkcert's 825d expiry. Failure is
# non-fatal — the dashboard remains reachable on http://localhost:3000.
function Update-LocalHttpsCerts {
    $cert = Join-Path $INSTALL_DIR "caddy_certs\coderaft.local.pem"
    $key  = Join-Path $INSTALL_DIR "caddy_certs\coderaft.local-key.pem"
    if (-not (Test-Path $cert) -or -not (Test-Path $key)) { return }
    $age = (Get-Date) - (Get-Item $cert).LastWriteTime
    if ($age.TotalDays -lt 80) { return }
    if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
        Write-Host "  ⚠ mkcert absent — cannot renew local HTTPS certs (still valid until mkcert default 825d)."
        return
    }
    Write-Host "  Renewing local HTTPS cert (>80d old)…"
    try {
        & mkcert -cert-file $cert -key-file $key `
            "coderaft.local" "*.coderaft.local" "localhost" "127.0.0.1" "::1" *> $null
        Write-Host "  ✓ Local HTTPS cert renewed"
    } catch {
        Write-Host "  ⚠ Cert renewal failed — keeping previous cert"
    }
}

try { Update-LocalHttpsCerts } catch { }

# ── AGGRESSIVE Docker image cache invalidation ────────────────────────────
# Docker Desktop multi-arch bug: `docker pull` may say "Image is up to date"
# while the local and remote digests differ (tag→digest resolution cache).
# Force full removal: containers, tag, image-by-ID.
Write-Host ""
Write-Host "  Aggressive Coderaft image cache invalidation..."
$ComposeImages = & docker @ComposeArgs config --images 2>$null
foreach ($img in $ComposeImages) {
    if ($img -like "ghcr.io/liamj74/*") {
        # 1. Stop containers running on this image
        $containerIds = & docker ps -q --filter "ancestor=$img" 2>$null
        if ($containerIds) {
            & docker stop $containerIds 2>&1 | Out-Null
            & docker rm -f $containerIds 2>&1 | Out-Null
        }
        # 2. Untag (silent if the image doesn't exist locally — first update)
        & docker image inspect $img 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & docker rmi -f $img 2>&1 | Out-Null
        }
        $LASTEXITCODE = 0
        # 3. Remove by ID (in case the image survives untagged)
        $imageIds = & docker images --format "{{.ID}}" $img 2>$null
        if ($imageIds) {
            foreach ($iid in $imageIds) {
                if ($iid) { & docker rmi -f $iid 2>&1 | Out-Null }
            }
        }
        $LASTEXITCODE = 0
    }
}

Write-Host ""
Write-Host "  Downloading new images..."
& docker @ComposeArgs pull
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: docker compose pull failed."
    exit 1
}

# Note: `--pull always` retried a per-service GHCR manifest check at redeploy
# time (intermittent timeout on slow connections). The Docker Desktop tag-cache
# bug is already covered by `docker rmi -f` + `docker compose pull` above, so
# we let `up` reuse the freshly pulled local images.
& docker @ComposeArgs up -d --force-recreate --remove-orphans
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: docker compose up failed."
    exit 1
}

# ── Post-update healthcheck ───────────────────────────────────────────────
Write-Host ""
Write-Host "  Post-update health check..."
$healthOk  = $false
$healthUrl = "$DASHBOARD_API/api/health"

for ($i = 1; $i -le $HEALTHCHECK_RETRIES; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($resp.StatusCode -lt 500 -and $resp.StatusCode -ne 0) {
            Write-Host "  Dashboard API healthy (HTTP $($resp.StatusCode)) after $i attempt(s)."
            $healthOk = $true
            break
        }
    } catch {
        # Continue retry
    }
    Write-Host "  Attempt $i/$HEALTHCHECK_RETRIES — waiting ${HEALTHCHECK_DELAY}s..."
    Start-Sleep -Seconds $HEALTHCHECK_DELAY
}

if (-not $healthOk) {
    Write-Host ""
    Write-Host "  ERROR: healthcheck failed after $HEALTHCHECK_RETRIES attempts."
    Write-Host "  Triggering automatic rollback..."
    if (Test-Path ".\rollback.ps1") {
        & $PSBin -NoProfile -ExecutionPolicy Bypass -File ".\rollback.ps1"
    } else {
        Write-Host "  rollback.ps1 not found. Manual rollback required."
        Write-Host "  Command: docker compose down; docker compose up -d"
    }
    exit 1
}

# ── Post-update notification ──────────────────────────────────────────────
if ($ADMIN_TOKEN) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $ADMIN_TOKEN"
        }
        Invoke-RestMethod -Method Post -Uri "$DASHBOARD_API/api/platform/update/notify" `
            -Headers $headers -Body '{"status":"done","source":"update.ps1"}' -TimeoutSec 5 | Out-Null
    } catch {
        # Non-critical
    }
}

Write-Host ""
Write-Host "  Update successful! Dashboard: http://localhost:3000"
Write-Host "  If something went wrong: .\rollback.ps1"
Write-Host "  (or: irm https://install.coderaft.io/rollback.ps1 | iex)"
