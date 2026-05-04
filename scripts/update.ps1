# CodeRaft updater (Windows / PowerShell)
#
# Self-updates from the installer repo, captures a pre-update recovery
# snapshot, pulls new images, runs a post-update healthcheck and triggers
# rollback.ps1 automatically if the dashboard API doesn't come back up.
# Mirror logique du update.sh (Linux) avec adaptations Windows.

$ErrorActionPreference = "Stop"

$DASHBOARD_API       = if ($env:DASHBOARD_API)       { $env:DASHBOARD_API }       else { "http://localhost:3000" }
$ADMIN_TOKEN         = if ($env:ADMIN_TOKEN)         { $env:ADMIN_TOKEN }         else { "" }
$BACKUP_DIR          = if ($env:BACKUP_DIR)          { $env:BACKUP_DIR }          else { ".\dashboard_data\backups" }
$HEALTHCHECK_RETRIES = if ($env:HEALTHCHECK_RETRIES) { [int]$env:HEALTHCHECK_RETRIES } else { 30 }
$HEALTHCHECK_DELAY   = if ($env:HEALTHCHECK_DELAY)   { [int]$env:HEALTHCHECK_DELAY }   else { 3 }

# Détection du binaire PowerShell courant (compat PS5 'powershell.exe' + PS7 'pwsh.exe')
$PSBin = (Get-Process -Id $PID).Path
if (-not $PSBin -or -not (Test-Path $PSBin)) {
    if (Get-Command pwsh -ErrorAction SilentlyContinue)       { $PSBin = "pwsh" }
    elseif (Get-Command powershell -ErrorAction SilentlyContinue) { $PSBin = "powershell" }
    else { $PSBin = "powershell" }
}

# Détection plateforme Docker — Docker Desktop résout parfois strictement
# linux/arm64/v8 ou linux/amd64/v3 par défaut, ce qui échoue sur les manifests
# qui exposent juste linux/arm64 ou linux/amd64. On force la plateforme.
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
    Write-Host "  Vérification des mises à jour du script..."
    $refreshed = $false
    foreach ($name in @("update.ps1", "rollback.ps1")) {
        try {
            $url = "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/$name"
            $latest = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($latest.StatusCode -eq 200 -and $latest.Content.Length -gt 50) {
                [System.IO.File]::WriteAllText("$PWD\$name", $latest.Content, [System.Text.Encoding]::UTF8)
                Write-Host "  $name rafraîchi"
                if ($name -eq "update.ps1") { $refreshed = $true }
            }
        } catch {
            # Offline ou upstream KO — on garde la copie locale
        }
    }
    if ($refreshed -and (Test-Path ".\update.ps1")) {
        Write-Host "  Re-exec du script mis à jour..."
        $env:CODERAFT_UPDATE_REEXEC = "1"
        & $PSBin -NoProfile -ExecutionPolicy Bypass -File ".\update.ps1"
        exit $LASTEXITCODE
    }
}

# ── Backup pré-update obligatoire ─────────────────────────────────────────
# Si pg_dumpall échoue → on bloque l'update (pas de backup = pas d'update).
Write-Host ""
Write-Host "  Sauvegarde pré-update..."
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
        # Start-Process redirige stdout proprement (sans encoding issues PS)
        $proc = Start-Process -FilePath "docker" `
            -ArgumentList @("compose", "exec", "-T", "postgres", "pg_dumpall", "-U", "coderaft") `
            -RedirectStandardOutput $BACKUP_FILE `
            -NoNewWindow -PassThru -Wait

        if ($proc.ExitCode -eq 0 -and (Get-Item $BACKUP_FILE).Length -gt 0) {
            Write-Host "  Backup enregistré : $BACKUP_FILE"
        } else {
            Write-Host "  ERREUR : pg_dumpall échoué (exit $($proc.ExitCode)). Mise à jour annulée."
            Write-Host "  Vérifiez que le container postgres est sain : docker compose ps"
            exit 1
        }
    } catch {
        Write-Host "  ERREUR : pg_dumpall échoué — $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-Host "  PostgreSQL non détecté — backup ignoré (dashboard sans DB)."
}

# ── Capture du snapshot de recovery via dashboard-api ─────────────────────
Write-Host "  Capture du snapshot de recovery..."
if ($ADMIN_TOKEN) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $ADMIN_TOKEN"
        }
        Invoke-RestMethod -Method Post -Uri "$DASHBOARD_API/api/dashboard/recovery/snapshots" `
            -Headers $headers -Body '{"reason":"pre-update"}' -TimeoutSec 10 | Out-Null
        Write-Host "    Snapshot sauvegardé."
    } catch {
        Write-Host "    Snapshot échoué (l'auto-snapshot reste actif au prochain deploy)."
    }
} else {
    Write-Host "    Ignoré (définir `$env:ADMIN_TOKEN pour activer)."
}

# ── Pull et récréation ────────────────────────────────────────────────────
# Include docker-compose.override.yml when it exists so product containers
# (entraguard-*, neo4j, ravenscan, redfox-*) are within scope. Without it,
# `--remove-orphans` treats every product as an orphan and silently nukes
# them, which is exactly what broke scans for users who had previously
# activated a Suite license.
$ComposeArgs = @("compose")
if (Test-Path ".\docker-compose.override.yml") {
    $ComposeArgs += @("-f", ".\docker-compose.yml", "-f", ".\docker-compose.override.yml")
}

# ── Invalidation AGRESSIVE du cache d'image Docker ────────────────────────
# Bug Docker Desktop multi-arch : `docker pull` peut dire "Image is up to date"
# alors que le digest local et distant diffèrent (cache de résolution
# tag→digest). On force la suppression complète : containers, tag, image-by-ID.
Write-Host ""
Write-Host "  Invalidation agressive du cache d'image Coderaft..."
$ComposeImages = & docker @ComposeArgs config --images 2>$null
foreach ($img in $ComposeImages) {
    if ($img -like "ghcr.io/liamj74/*") {
        # 1. Stopper les containers qui tournent sur cette image
        $containerIds = & docker ps -q --filter "ancestor=$img" 2>$null
        if ($containerIds) {
            & docker stop $containerIds 2>$null | Out-Null
            & docker rm -f $containerIds 2>$null | Out-Null
        }
        # 2. Untag
        & docker rmi -f $img 2>$null | Out-Null
        # 3. Supprimer par ID (au cas où l'image survit untagged)
        $imageIds = & docker images --format "{{.ID}}" $img 2>$null
        if ($imageIds) {
            foreach ($iid in $imageIds) {
                if ($iid) { & docker rmi -f $iid 2>$null | Out-Null }
            }
        }
    }
}

Write-Host ""
Write-Host "  Téléchargement des nouvelles images..."
& docker @ComposeArgs pull
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERREUR : docker compose pull échoué."
    exit 1
}

# NB : `--pull always` retentait un manifest check GHCR par service au moment
# du redéploiement (timeout intermittent sur connexions lentes). Le bug Docker
# Desktop tag-cache est déjà couvert par le `docker rmi -f` + `docker compose
# pull` ci-dessus, donc on laisse `up` réutiliser les images locales fraîches.
& docker @ComposeArgs up -d --force-recreate --remove-orphans
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERREUR : docker compose up échoué."
    exit 1
}

# ── Healthcheck post-update ───────────────────────────────────────────────
Write-Host ""
Write-Host "  Vérification de santé post-update..."
$healthOk  = $false
$healthUrl = "$DASHBOARD_API/api/health"

for ($i = 1; $i -le $HEALTHCHECK_RETRIES; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($resp.StatusCode -lt 500 -and $resp.StatusCode -ne 0) {
            Write-Host "  Dashboard API healthy (HTTP $($resp.StatusCode)) après $i tentative(s)."
            $healthOk = $true
            break
        }
    } catch {
        # Continue retry
    }
    Write-Host "  Tentative $i/$HEALTHCHECK_RETRIES — attente ${HEALTHCHECK_DELAY}s..."
    Start-Sleep -Seconds $HEALTHCHECK_DELAY
}

if (-not $healthOk) {
    Write-Host ""
    Write-Host "  ERREUR : healthcheck échoué après $HEALTHCHECK_RETRIES tentatives."
    Write-Host "  Déclenchement du rollback automatique..."
    if (Test-Path ".\rollback.ps1") {
        & $PSBin -NoProfile -ExecutionPolicy Bypass -File ".\rollback.ps1"
    } else {
        Write-Host "  rollback.ps1 introuvable. Rollback manuel requis."
        Write-Host "  Commande : docker compose down; docker compose up -d"
    }
    exit 1
}

# ── Notification post-update ──────────────────────────────────────────────
if ($ADMIN_TOKEN) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $ADMIN_TOKEN"
        }
        Invoke-RestMethod -Method Post -Uri "$DASHBOARD_API/api/platform/update/notify" `
            -Headers $headers -Body '{"status":"done","source":"update.ps1"}' -TimeoutSec 5 | Out-Null
    } catch {
        # Non-critique
    }
}

Write-Host ""
Write-Host "  Mise à jour réussie ! Dashboard : http://localhost:3000"
Write-Host "  En cas de problème : .\rollback.ps1"
Write-Host "  (ou : irm https://install.coderaft.io/rollback.ps1 | iex)"
