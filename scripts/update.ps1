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
$INSTALL_DIR         = if ($env:INSTALL_DIR)         { $env:INSTALL_DIR }         else { (Get-Location).Path }

# ── Auto-discovery du ADMIN_TOKEN ─────────────────────────────────────────
# Ordre de priorité :
#   1. $env:ADMIN_TOKEN
#   2. Fichiers .env (INSTALL_DIR, C:\ProgramData\coderaft, ~/.coderaft)
#   3. Token files plain (un seul mot)
# Si rien trouvé → continue, snapshot/notify skip avec warning.
# IMPORTANT : ne JAMAIS écrire le token découvert dans la console.
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
    return ""
}

if (-not $ADMIN_TOKEN) {
    $discovered = Find-AdminToken
    if ($discovered) { $ADMIN_TOKEN = $discovered }
    Remove-Variable -Name discovered -ErrorAction SilentlyContinue
}

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
    Write-Host "    [warn] ADMIN_TOKEN introuvable — snapshot skipped."
    Write-Host "    (set `$env:ADMIN_TOKEN, or place token in $INSTALL_DIR\.env, C:\ProgramData\coderaft\admin_token, ou ~/.coderaft/admin_token)"
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

# ── Refresh des clés de licence (drift "superseded") ──────────────────────
# Quand le License Server resigne une licence (ex: ajout de feature, rotation
# de clé), il retourne 403 "License has been superseded by a newer version"
# pour toute requête utilisant l'ancienne clé. On rafraîchit donc la clé dans
# docker-compose.override.yml AVANT le `docker compose up`. Backup .bak.
# Si le License Server est injoignable, on continue silencieusement.
function Update-License {
    param(
        [Parameter(Mandatory=$true)] [string] $EnvVar,
        [Parameter(Mandatory=$true)] [string] $OverrideFile
    )
    if (-not (Test-Path $OverrideFile -PathType Leaf)) { return $false }

    $content = Get-Content -LiteralPath $OverrideFile -ErrorAction SilentlyContinue
    if (-not $content) { return $false }

    # Cherche la première occurrence de "<EnvVar>=<value>" (avec ou sans tiret YAML).
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
        # License Server injoignable ou erreur réseau → silencieux
        return $false
    }

    if ($latest -and $latest -ne $currentKey) {
        Copy-Item -LiteralPath $OverrideFile -Destination "$OverrideFile.bak" -Force
        # Remplace TOUTES les occurrences (worker + api peuvent partager la clé)
        $newContent = foreach ($line in $content) {
            if ($line -match $regex) {
                $padMatch = [Regex]::Match($line, "^(\s*-?\s*)")
                $pad = $padMatch.Groups[1].Value
                "$pad$EnvVar=$latest"
            } else {
                $line
            }
        }
        # Préserve l'absence de BOM et utilise LF Unix (compose tolère CRLF mais on évite la pollution)
        [System.IO.File]::WriteAllLines($OverrideFile, $newContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  🔄 Licence rafraîchie pour $EnvVar"
        return $true
    }
    return $false
}

function Update-AllLicenses {
    $overrideFile = Join-Path $INSTALL_DIR "docker-compose.override.yml"
    Write-Host ""
    Write-Host "  ▶ Vérification de la dérive de licence..."
    $any = $false
    foreach ($var in @("LICENSE_KEY", "RAVENSCAN_LICENSE_KEY", "REDFOX_LICENSE_KEY")) {
        try {
            if (Update-License -EnvVar $var -OverrideFile $overrideFile) { $any = $true }
        } catch {
            # On ne fail jamais le update à cause d'un refresh
        }
    }
    if ($any) {
        Write-Host "  ⚠️  Au moins une licence a été rafraîchie ; les services seront redémarrés"
    } else {
        Write-Host "  ✅ Toutes les licences sont à jour"
    }
}

try { Update-AllLicenses } catch { }

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
