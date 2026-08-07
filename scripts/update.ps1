# CodeRaft updater (Windows / PowerShell)
#
# Self-updates from the installer repo, captures a pre-update recovery
# snapshot, pulls new images, runs a post-update healthcheck and triggers
# rollback.ps1 automatically if the dashboard API doesn't come back up.
# Mirrors the logic of update.sh (Linux) with Windows adaptations.
#
# Granular per-product update:
#   .\update.ps1 -Product falconone       (or $env:CODERAFT_PRODUCT="falconone")
# delegates to POST /api/dashboard/products/<slug>/update on dashboard-api
# (per-product snapshot, pull only that product's images, auto-deploy of
# newly declared services, auto-rollback on failure). Without -Product,
# the legacy full-platform update runs unchanged. Equivalent of clicking
# "Mettre à jour ce produit" in the dashboard, and of `update.sh --product`.
#
# HTTP calls (#183): every Invoke-RestMethod / Invoke-WebRequest below has
# an explicit -TimeoutSec — PS 5.1 defaults to infinite, which used to hang
# this script silently on a slow backend/DNS/TLS stack. New HTTP calls
# should use the Invoke-CoderaftHTTP helper (defined below, right before
# "Updating CodeRaft...") to keep the timeout+logging behavior consistent.
# Start-Process docker calls for quick health probes (compose ps, exec
# cat/test-f, inspect) also carry a WaitForExit(60000) safety net to guard
# against Docker Desktop hangs; long-running docker pull/run are untouched.

param(
    [string]$Product = ""
)

$ErrorActionPreference = "Stop"

# -Product param wins; env var fallback for `iex (irm ...)` invocations
# where parameters cannot be passed.
$PRODUCT_SLUG = if ($Product) { $Product } elseif ($env:CODERAFT_PRODUCT) { $env:CODERAFT_PRODUCT } else { "" }
if ($PRODUCT_SLUG -and ($PRODUCT_SLUG -notin @("entra-audit", "secaudit", "redfox", "mantisstrike", "falconone"))) {
    Write-Host "ERROR: unknown product slug '$PRODUCT_SLUG'" -ForegroundColor Red
    Write-Host "Valid slugs: entra-audit, secaudit, redfox, mantisstrike, falconone"
    return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
}

$DASHBOARD_API       = if ($env:DASHBOARD_API)       { $env:DASHBOARD_API }       else { "http://localhost:3000" }
$ADMIN_TOKEN         = if ($env:ADMIN_TOKEN)         { $env:ADMIN_TOKEN }         else { "" }
$BACKUP_DIR          = if ($env:BACKUP_DIR)          { $env:BACKUP_DIR }          else { ".\dashboard_data\backups" }
$HEALTHCHECK_RETRIES = if ($env:HEALTHCHECK_RETRIES) { [int]$env:HEALTHCHECK_RETRIES } else { 30 }
$HEALTHCHECK_DELAY   = if ($env:HEALTHCHECK_DELAY)   { [int]$env:HEALTHCHECK_DELAY }   else { 3 }
$INSTALL_DIR         = if ($env:INSTALL_DIR)         { $env:INSTALL_DIR }         else { (Get-Location).Path }

# ── install-config.env: install-time / public config, NEVER encrypted ──────
# Task #150 (2026-07-31): HOST_PROJECT_DIR / CODERAFT_HOST_OS / CODERAFT_HOST_ARCH
# are not secrets. They used to be written straight into .env (then swept into
# .env.enc by SOPS) — this file is now their canonical home, plaintext, NEVER
# passed to SOPS. Defined this early so every `docker compose` call in this
# script can pass `--env-file install-config.env --env-file .env` (mirrors
# $ComposeEnvArgs in install.ps1). Created empty here if this is the first run
# of a #150-aware update.ps1 on an older install; self-heal blocks further
# down backfill its actual content.
$INSTALL_CONFIG_PATH = Join-Path $INSTALL_DIR "install-config.env"
if (-not (Test-Path $INSTALL_CONFIG_PATH)) {
    [System.IO.File]::WriteAllText($INSTALL_CONFIG_PATH, "", [System.Text.UTF8Encoding]::new($false))
}
# BUG FIX (2026-08-05, found live on Liam's Windows test machine — CODERAFT_HOST_OS
# read back as "windowscoderaft_host_arch=amd64host_project_dir=c:\..." repeated
# 4x with zero separators): `$text -split "..." | Where-Object {...}` UNWRAPS to a
# plain scalar string (not a 1-element array) whenever exactly ONE line survives the
# filter — a well-known PowerShell pipeline-collapsing gotcha. The next line,
# `$lines += "$Key=$Value"`, is then STRING CONCATENATION (not array-append) because
# its LHS is a string, silently gluing the new pair onto the previous line with no
# newline. This reproduced 100% with real pwsh (multi-run simulation, see commit) —
# it fires the very first time two keys are set back-to-back while the file holds
# exactly one line (e.g. CODERAFT_HOST_OS then CODERAFT_HOST_ARCH in the self-heal
# block below), and then self-reinforces: once a key's own "^KEY=" line-start marker
# is buried mid-line, Get-InstallConfigVar can no longer find it, so its self-heal
# re-fires and re-appends on every subsequent update.ps1 run. Wrapping the
# Where-Object result in `@(...)` forces it to always be a real array (0, 1, or many
# elements), so `+=` is always array-append. Get-InstallConfigVar is hardened the
# same way (take the first match only) in case a file is already corrupted with
# duplicate lines for the same key.
function Set-InstallConfigVar($Key, $Value) {
    $text = [System.IO.File]::ReadAllText($script:INSTALL_CONFIG_PATH, [System.Text.UTF8Encoding]::new($false))
    $lines = @($text -split "`r?`n" | Where-Object { $_ -notmatch "^$Key=" -and $_ -ne "" })
    $lines += "$Key=$Value"
    [System.IO.File]::WriteAllText($script:INSTALL_CONFIG_PATH, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}
function Get-InstallConfigVar($Key) {
    if (-not (Test-Path $script:INSTALL_CONFIG_PATH)) { return $null }
    $m = @(Select-String -Path $script:INSTALL_CONFIG_PATH -Pattern "^$Key=(.+)$")
    if ($m.Count -ge 1) { return $m[0].Matches.Groups[1].Value }
    return $null
}

# ── Self-heal: repair an ALREADY-corrupted install-config.env ──────────────
# (2026-08-05) Fixes the file in place for installs that hit the bug described
# above before this fix shipped (confirmed live on Liam's machine). Detects any
# physical line containing 2+ of our known "KEY=" markers (the corruption
# signature — legitimate lines only ever contain one) and splits it back into
# one clean line per key, keeping the LAST value seen for each key (in case a
# value like HOST_PROJECT_DIR genuinely changed across the corrupted appends).
# Runs once, right here, before ANY other Get-/Set-InstallConfigVar call.
function Repair-InstallConfigCorruption {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return }
    # Extend this list if install-config.env ever grows more keys.
    $knownKeys = @("HOST_PROJECT_DIR", "CODERAFT_HOST_OS", "CODERAFT_HOST_ARCH")
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    if (-not $text) { return }
    $rawLines = @($text -split "`r?`n" | Where-Object { $_ -ne "" })
    $markerPattern = "(?:" + (($knownKeys | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")="
    $corruptedFound = $false
    $clean = [ordered]@{}
    foreach ($line in $rawLines) {
        $markerMatches = @([regex]::Matches($line, $markerPattern))
        if ($markerMatches.Count -le 1) {
            $eq = $line.IndexOf('=')
            if ($eq -gt 0) { $clean[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
            continue
        }
        $corruptedFound = $true
        for ($i = 0; $i -lt $markerMatches.Count; $i++) {
            $start = $markerMatches[$i].Index
            $end = if ($i + 1 -lt $markerMatches.Count) { $markerMatches[$i + 1].Index } else { $line.Length }
            $segment = $line.Substring($start, $end - $start)
            $eq = $segment.IndexOf('=')
            if ($eq -gt 0) { $clean[$segment.Substring(0, $eq)] = $segment.Substring($eq + 1) }
        }
    }
    if (-not $corruptedFound) { return }
    $ts = Get-Date -Format "yyyyMMddTHHmmssZ"
    Copy-Item -LiteralPath $Path -Destination "$Path.bak-corrupt-$ts" -ErrorAction SilentlyContinue
    $newLines = @($clean.Keys | ForEach-Object { "$_=$($clean[$_])" })
    [System.IO.File]::WriteAllText($Path, (($newLines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ⚠ install-config.env was corrupted (concatenated values from a known PowerShell array/string bug, now fixed) — repaired automatically." -ForegroundColor Yellow
    Write-Host "    Backup of the corrupted file: $Path.bak-corrupt-$ts"
}
Repair-InstallConfigCorruption -Path $INSTALL_CONFIG_PATH

# ── Detail log file (2026-08-05) ────────────────────────────────────────────
# Liam's feedback on a live run: the console printed developer-grade internal
# detail on every single update — per-product ACL self-heal internals, PKI SAN
# strings, vault-ACL live-reconciliation results — that a real customer has no
# use for ("le client n'a pas besoin de voir ça mais dans un fichier logs oui").
# All of that now goes to this file via Write-DetailLog instead of Write-Host;
# the console keeps ONE concise line per phase. The log path is printed once
# at the end of the run so an operator (or Liam, debugging remotely) can find
# the detail. Kept under the install dir (not $env:TEMP) so it survives and is
# easy to locate; only the last 10 runs are kept.
$LOG_DIR = Join-Path $INSTALL_DIR "logs"
try { New-Item -ItemType Directory -Force -Path $LOG_DIR -ErrorAction Stop | Out-Null } catch { $LOG_DIR = $env:TEMP }
$UPDATE_LOG = Join-Path $LOG_DIR ("update-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
try {
    [System.IO.File]::WriteAllText($UPDATE_LOG, "[$(Get-Date -Format o)] update.ps1 started`n", [System.Text.UTF8Encoding]::new($false))
} catch { }
function Write-DetailLog {
    param([Parameter(ValueFromPipeline = $true)][string]$Message)
    process {
        try { Add-Content -LiteralPath $script:UPDATE_LOG -Value "[$(Get-Date -Format o)] $Message" -Encoding utf8 -ErrorAction SilentlyContinue } catch { }
    }
}
try {
    Get-ChildItem -LiteralPath $LOG_DIR -Filter "update-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

# ── Backup rotation (security hardening, 2026-07-31) ────────────────────────
# Every self-heal path below does Copy-Item $X "$X.bak-<tag>-<timestamp>"
# before touching $X — acl.yaml, docker-compose.yml, docker-compose.override.yml
# (plus one "docker-compose.override.yml.broken-<timestamp>" corruption
# backup with a different separator). On a deployment that runs unattended
# for months/years across many update.ps1 runs, these accumulate without
# bound. Keep only the $Keep most recent (default 5) matching $GlobSuffix
# under $BasePath's name; delete anything older. Safe/idempotent: a no-op
# when there are $Keep or fewer, or none at all.
function Invoke-RotateBackups {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [int]$Keep = 5,
        [string]$GlobSuffix = "bak-*"
    )
    $dir = Split-Path -Path $BasePath -Parent
    if ([string]::IsNullOrEmpty($dir)) { $dir = "." }
    $leaf = Split-Path -Path $BasePath -Leaf
    $backups = Get-ChildItem -LiteralPath $dir -Filter "$leaf.$GlobSuffix" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($backups -and $backups.Count -gt $Keep) {
        $backups | Select-Object -Skip $Keep | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}
function Remove-FromMainEnv($Key) {
    $envPath = Join-Path $INSTALL_DIR ".env"
    if (Test-Path $envPath) {
        $text = [System.IO.File]::ReadAllText($envPath, [System.Text.UTF8Encoding]::new($false))
        if ($text -match "(?m)^$Key=") {
            $lines = $text -split "`r?`n" | Where-Object { $_ -notmatch "^$Key=" }
            [System.IO.File]::WriteAllText($envPath, (($lines -join "`n").TrimEnd() + "`n"), [System.Text.UTF8Encoding]::new($false))
        }
    }
}
$ComposeEnvArgs = @("--env-file", $INSTALL_CONFIG_PATH, "--env-file", (Join-Path $INSTALL_DIR ".env"))

# ── Windows Defender exclusion ───────────────────────────────────────────
# `docker compose pull` writes fresh signed binaries into the install dir
# on every update. Defender can quarantine a just-pulled executable mid-
# recreate, leaving the stack half-deployed. Re-asserting the exclusion at
# each update run keeps it in effect (Defender occasionally clears manual
# exclusions on cumulative updates). Requires elevation — silent-skip if
# absent (Server Core, 3rd-party AV, or non-admin re-run).
try {
    Add-MpPreference -ExclusionPath $INSTALL_DIR -ErrorAction Stop 2>$null
} catch {
    # Defender missing / not elevated / already excluded — ignore.
}

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
        # B20 (2026-06-08): `& docker compose ps ... 2>$null` surfaces stderr
        # as NativeCommandError in PS 5.1. Use Start-Process + temp files.
        $svcStdout = Join-Path $env:TEMP "coderaft-svc-out-$(Get-Random).log"
        $svcStderr = Join-Path $env:TEMP "coderaft-svc-err-$(Get-Random).log"
        $svcProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("ps","--services")) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $svcStdout `
            -RedirectStandardError  $svcStderr `
            -ErrorAction SilentlyContinue
        if ($svcProc -and -not $svcProc.WaitForExit(60000)) {   # 60s — Docker Desktop can hang on `compose ps`
            Write-Host "  ⚠  Docker command timed out after 60s: docker compose ps --services" -ForegroundColor Yellow
            try { $svcProc.Kill() } catch {}
        }
        $services = (Get-Content $svcStdout -ErrorAction SilentlyContinue) -join "`n"
        Remove-Item -Path $svcStdout,$svcStderr -ErrorAction SilentlyContinue
        if ($services -match '(?m)^dashboard-api$') {
            $catStdout = Join-Path $env:TEMP "coderaft-cat-out-$(Get-Random).log"
            $catStderr = Join-Path $env:TEMP "coderaft-cat-err-$(Get-Random).log"
            $catProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("exec","-T","dashboard-api","cat","/data/admin_token")) `
                -NoNewWindow -PassThru `
                -RedirectStandardOutput $catStdout `
                -RedirectStandardError  $catStderr `
                -ErrorAction SilentlyContinue
            if ($catProc -and -not $catProc.WaitForExit(60000)) {   # 60s
                Write-Host "  ⚠  Docker command timed out after 60s: docker compose exec dashboard-api cat /data/admin_token" -ForegroundColor Yellow
                try { $catProc.Kill() } catch {}
            }
            $val = ((Get-Content $catStdout -ErrorAction SilentlyContinue) -join "`n").Trim()
            Remove-Item -Path $catStdout,$catStderr -ErrorAction SilentlyContinue
            if ($val) { return $val }
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

# ── Granular per-product update (-Product <slug>) ──────────────────────────
# Delegates the whole operation to dashboard-api, then polls the status.
# Shared infra (postgres/redis/vault) is never touched by this path.
if ($PRODUCT_SLUG) {
    Write-Host ""
    Write-Host "  Granular update: product '$PRODUCT_SLUG' only"

    if (-not $ADMIN_TOKEN) {
        Write-Host "  ERROR: ADMIN_TOKEN not found - the per-product update needs the dashboard API." -ForegroundColor Red
        Write-Host "  Set `$env:ADMIN_TOKEN, or ensure the dashboard-api container is running."
        return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
    }

    $headers = @{ Authorization = "Bearer $ADMIN_TOKEN"; "Content-Type" = "application/json" }
    try {
        Invoke-RestMethod -Method Post `
            -Uri "$DASHBOARD_API/api/dashboard/products/$PRODUCT_SLUG/update" `
            -Headers $headers `
            -Body '{"backup_data":true}' `
            -TimeoutSec 30 | Out-Null
    } catch {
        Write-Host "  ERROR: failed to start the update: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  (409 = another operation is already running; 403 = product not licensed)"
        return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
    }
    Write-Host "  Update started. Waiting for completion (snapshot -> backup -> pull -> recreate -> health)..."

    $status = "in_progress"
    $lastPhase = ""
    for ($i = 0; $i -lt 200; $i++) {   # 200 x 3s = 10 min max
        Start-Sleep -Seconds 3
        try {
            $op = Invoke-RestMethod -Method Get `
                -Uri "$DASHBOARD_API/api/dashboard/products/$PRODUCT_SLUG/update-status" `
                -Headers @{ Authorization = "Bearer $ADMIN_TOKEN" } `
                -TimeoutSec 10
            $status = $op.status
            if ($op.phase -and $op.phase -ne $lastPhase) {
                Write-Host "    phase: $($op.phase)"
                $lastPhase = $op.phase
            }
            if ($status -ne "in_progress") { break }
        } catch { }
    }

    switch ($status) {
        "healthy" {
            Write-Host ""
            Write-Host "  [OK] $PRODUCT_SLUG updated successfully - all services healthy." -ForegroundColor Green
            return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
        }
        "rolled_back" {
            Write-Host ""
            Write-Host "  [FAIL] Update failed - automatic rollback restored the previous version." -ForegroundColor Red
            return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
        }
        "rollback_failed" {
            Write-Host ""
            Write-Host "  [CRITICAL] Update AND rollback failed - manual intervention required." -ForegroundColor Red
            Write-Host "  Snapshots: GET $DASHBOARD_API/api/dashboard/products/$PRODUCT_SLUG/snapshots"
            return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
        }
        "failed" {
            Write-Host ""
            Write-Host "  [FAIL] Update failed before any service was modified (e.g. backup failure)." -ForegroundColor Red
            return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
        }
        default {
            Write-Host ""
            Write-Host "  [?] Update still running after 10 min - check the dashboard for live status." -ForegroundColor Yellow
            return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
        }
    }
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

# ── Invoke-CoderaftHTTP — timeout enforcé + logging cohérent (#183) ──────
# Windows PowerShell 5.1's Invoke-RestMethod/Invoke-WebRequest default to an
# INFINITE timeout. A slow backend, a stalled DNS resolver, or a hung TLS
# handshake can therefore block this script forever with no log line to
# explain why (confirmed live 2026-07-24). Every Invoke-RestMethod /
# Invoke-WebRequest call in this script now passes an explicit -TimeoutSec.
# This wrapper is not yet used by the existing calls (too much churn for
# this change) but is available for any NEW call added going forward —
# prefer it over a bare Invoke-RestMethod so the timeout can never be
# forgotten again.
function Invoke-CoderaftHTTP {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Uri,
        [hashtable]$Headers,
        [string]$Body,
        [int]$TimeoutSec = 15,
        [switch]$UseBasicParsing,
        [switch]$SuppressErrors
    )
    Write-Verbose "HTTP $Method $Uri (timeout ${TimeoutSec}s)"
    $params = @{
        Method = $Method
        Uri = $Uri
        TimeoutSec = $TimeoutSec
    }
    if ($Headers) { $params['Headers'] = $Headers }
    if ($Body) { $params['Body'] = $Body }
    if ($UseBasicParsing) { $params['UseBasicParsing'] = $true }
    try {
        return Invoke-RestMethod @params -ErrorAction Stop
    } catch {
        if ($SuppressErrors) { return $null }
        throw
    }
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
        Write-Host ""
        Write-Host "  ╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║  ⓘ  Updater script itself was refreshed.                    ║" -ForegroundColor Cyan
        Write-Host "  ║                                                            ║" -ForegroundColor Cyan
        Write-Host "  ║     Re-running update with the latest version — this is    ║" -ForegroundColor Cyan
        Write-Host "  ║     normal, not a crash. The same update continues below.  ║" -ForegroundColor Cyan
        Write-Host "  ╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
        Start-Sleep -Seconds 1
        $env:CODERAFT_UPDATE_REEXEC = "1"
        & $PSBin -NoProfile -ExecutionPolicy Bypass -File ".\update.ps1"
        return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
    }
}

# ── Self-heal CODERAFT_HOST_OS in install-config.env (B25) ────────────────
# Les installs antérieures préservaient .env sans ajouter CODERAFT_HOST_OS
# (seul le path "fresh secrets" l'écrivait). Dashboard-api lit cette valeur
# pour décider du mode capture daemon (native Windows Service vs Docker
# sidecar Linux). Sans CODERAFT_HOST_OS, le setup wizard affiche
# "CODERAFT_HOST_OS configured: ✗ not set" et capture ne fonctionne pas.
# Migration #150 : si une valeur existe encore dans l'ancien .env (installs
# pré-#150), on la déplace vers install-config.env plutôt que de la dupliquer.
if (-not (Get-InstallConfigVar "CODERAFT_HOST_OS")) {
    $envPathForHostOS = Join-Path $INSTALL_DIR ".env"
    $legacyHostOS = $null
    if (Test-Path $envPathForHostOS) {
        $envTextHO = [System.IO.File]::ReadAllText($envPathForHostOS, [System.Text.UTF8Encoding]::new($false))
        if ($envTextHO -match '(?m)^\s*CODERAFT_HOST_OS\s*=(.+)$') { $legacyHostOS = $Matches[1].Trim().Trim('"').Trim("'") }
    }
    $hostOSValue = if ($legacyHostOS) { $legacyHostOS } else { "windows" }  # update.ps1 ne tourne que sur Windows
    Set-InstallConfigVar "CODERAFT_HOST_OS" $hostOSValue
    if ($legacyHostOS) {
        Write-Host "  ✓ CODERAFT_HOST_OS migré .env → install-config.env ($hostOSValue)"
    } else {
        Write-Host "  ✓ Self-heal install-config.env — CODERAFT_HOST_OS=$hostOSValue ajouté"
    }
}
if (-not (Get-InstallConfigVar "CODERAFT_HOST_ARCH")) {
    Set-InstallConfigVar "CODERAFT_HOST_ARCH" "amd64"
}
Remove-FromMainEnv "CODERAFT_HOST_OS"
Remove-FromMainEnv "CODERAFT_HOST_ARCH"

# ── Self-heal: docker-compose.yml drift (B24 — depends_on coderaft-vault) ──
# Les installs antérieures déclaraient coderaft-vault avec
# `condition: service_healthy`. Le healthcheck binary du vault est buggé
# (pas de cert client pour le mTLS handshake) → vault toujours unhealthy →
# dashboard-api bloqué. Workaround validé : passer en service_started.
$composePath = Join-Path $INSTALL_DIR "docker-compose.yml"
if (Test-Path $composePath) {
    $composeText = [System.IO.File]::ReadAllText($composePath, [System.Text.UTF8Encoding]::new($false))
    $oldDep = 'coderaft-vault: { condition: service_healthy }'
    $newDep = 'coderaft-vault: { condition: service_started }'
    if ($composeText.Contains($oldDep)) {
        $bak = "$composePath.bak-" + (Get-Date -Format "yyyyMMdd_HHmmss")
        try { Copy-Item -LiteralPath $composePath -Destination $bak -Force -ErrorAction SilentlyContinue } catch {}
        Invoke-RotateBackups -BasePath $composePath
        $composeText = $composeText.Replace($oldDep, $newDep)
        [System.IO.File]::WriteAllText($composePath, $composeText, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  ✓ Self-heal docker-compose.yml — coderaft-vault: service_healthy → service_started"
    }
}

# ── Self-heal: NODE_OPTIONS=ipv4first dans dashboard-api (B15) ────────────
# Node.js IPv6-first par défaut, container Docker n'a pas d'IPv6 → ENETUNREACH
# sur appels sortants (license.coderaft.io, login.microsoftonline.com).
# Manifestation : 'Authentication failed: server_error' lors du callback Entra,
# 'Internal server error' lors de l'activation licence. Patch in-place :
# insère NODE_OPTIONS=--dns-result-order=ipv4first dans la section environment:
# du dashboard-api.
#
# B-NODE-OPTIONS-FALLBACK (2026-06-11): the previous literal marker
# `      - LICENSE_SERVER_URL=...` missed older compose files where the
# line had different indentation or had been edited. Fall back to a regex
# match on the `dashboard-api:` service block + its `environment:` key.
$composePathB15 = Join-Path $INSTALL_DIR "docker-compose.yml"
if (Test-Path $composePathB15) {
    $composeTextB15 = [System.IO.File]::ReadAllText($composePathB15, [System.Text.UTF8Encoding]::new($false))
    if ($composeTextB15 -notmatch 'NODE_OPTIONS=--dns-result-order=ipv4first') {
        $bakB15 = "$composePathB15.bak-" + (Get-Date -Format "yyyyMMddHHmmss")
        $patched = $false

        # Path A — literal marker (fast path, works on stock installs)
        $marker = '      - LICENSE_SERVER_URL=https://license.coderaft.io'
        if ($composeTextB15.Contains($marker)) {
            try { Copy-Item -LiteralPath $composePathB15 -Destination $bakB15 -Force -ErrorAction SilentlyContinue } catch {}
            Invoke-RotateBackups -BasePath $composePathB15
            $replacement = '      - NODE_OPTIONS=--dns-result-order=ipv4first' + "`n" + $marker
            $idx = $composeTextB15.IndexOf($marker)
            $composeTextB15 = $composeTextB15.Substring(0, $idx) + $replacement + $composeTextB15.Substring($idx + $marker.Length)
            $idx2 = $composeTextB15.IndexOf($marker, $idx + $replacement.Length)
            if ($idx2 -ge 0) {
                $composeTextB15 = $composeTextB15.Substring(0, $idx2) + $replacement + $composeTextB15.Substring($idx2 + $marker.Length)
            }
            $patched = $true
        }

        # Path B — generic: find `dashboard-api:` then its `environment:` key
        # and inject a `- NODE_OPTIONS=...` line preserving the local indent.
        if (-not $patched) {
            $pattern = '(?ms)^(\s*)dashboard-api:\s*\r?\n(?:\1\s+.*\r?\n)*?\1(\s+)environment:\s*\r?\n'
            $m = [regex]::Match($composeTextB15, $pattern)
            if ($m.Success) {
                try { Copy-Item -LiteralPath $composePathB15 -Destination $bakB15 -Force -ErrorAction SilentlyContinue } catch {}
                Invoke-RotateBackups -BasePath $composePathB15
                $envIndent = $m.Groups[1].Value + $m.Groups[2].Value
                $insertion = $envIndent + '  - NODE_OPTIONS=--dns-result-order=ipv4first' + "`n"
                $endOfEnvLine = $m.Index + $m.Length
                $composeTextB15 = $composeTextB15.Substring(0, $endOfEnvLine) + $insertion + $composeTextB15.Substring($endOfEnvLine)
                $patched = $true
            }
        }

        if ($patched) {
            [System.IO.File]::WriteAllText($composePathB15, $composeTextB15, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  ✓ Self-heal docker-compose.yml — NODE_OPTIONS=ipv4first ajouté à dashboard-api (B15)"
        } elseif ($composeTextB15 -match '(?m)^\s*dashboard-api:') {
            # dashboard-api is declared but we couldn't safely inject. Warn so the
            # operator knows OIDC + license validation will hit ENETUNREACH.
            Write-Host "  ⚠ Could not patch NODE_OPTIONS for dashboard-api in docker-compose.yml — Entra ID callback may fail with ENETUNREACH (B15). Re-run install.ps1 to regenerate." -ForegroundColor Yellow
        }
    }

    # B-IPV6-KILL-SELFHEAL (2026-07-23): NODE_OPTIONS=ipv4first is honored
    # only for Node's own resolver — some libs (openid-client, passport-*)
    # still surface AAAA records to Microsoft Entra endpoints and fail with
    # ENETUNREACH. Kill IPv6 at the sysctl level so the container has no
    # v6 stack at all. Idempotent — skips if `sysctls:` already present in
    # the dashboard-api block. Line-based state machine so any indent style
    # (2-space, 4-space, tab) is handled the same way — regex flavour of
    # PowerShell is finicky with multi-line lookaheads.
    #
    # B-REGEX-CATASTROPHIC-BACKTRACK (2026-07-24): the original multiline
    # regex above (?ms)dashboard-api:...sysctls: hangs indefinitely on
    # PowerShell 5.1 for large compose files with catastrophic backtracking
    # (confirmed live at Liam's node, task #183). Switched to a cheap
    # substring probe: scan line-by-line for "dashboard-api:" then look for
    # BOTH "sysctls:" AND "disable_ipv6=1" in the next 40 lines. Checking
    # for the actual disable_ipv6 value (not just the sysctls: key) means
    # a compose with sysctls declared for another reason won't silently
    # skip the IPv6 kill — the IPv6 issue was the whole point of this
    # self-heal, so we verify the value, not the container's presence.
    $needsSysctls = $true
    $probeLines = $composeTextB15 -split "`r?`n"
    for ($p = 0; $p -lt $probeLines.Count; $p++) {
        if ($probeLines[$p] -match '^\s+dashboard-api:\s*$') {
            $probeIndent = ($probeLines[$p] -replace '\S.*$','').Length
            $seenSysctls = $false
            $seenDisableIpv6 = $false
            for ($q = $p + 1; $q -lt [Math]::Min($p + 40, $probeLines.Count); $q++) {
                # Left a sibling service block (same indent, starts with letter)
                if ($probeLines[$q] -match "^\s{$probeIndent}[a-zA-Z]") { break }
                if ($probeLines[$q] -match '^\s+sysctls:\s*$')                { $seenSysctls = $true }
                if ($probeLines[$q] -match 'net\.ipv6\.conf\.all\.disable_ipv6\s*=\s*1') { $seenDisableIpv6 = $true }
            }
            if ($seenSysctls -and $seenDisableIpv6) { $needsSysctls = $false }
            break
        }
    }
    if ($needsSysctls) {
        $lines = $composeTextB15 -split "`r?`n"
        $out = New-Object System.Collections.ArrayList
        $inDashApi = $false
        $sysAdded = $false
        $svcIndent = $null
        foreach ($ln in $lines) {
            if ($ln -match '^(\s+)dashboard-api:\s*$') {
                $inDashApi = $true
                $svcIndent = $matches[1]
                [void]$out.Add($ln)
                continue
            }
            # Leaving dashboard-api when a sibling service (same indent) starts.
            if ($inDashApi -and $svcIndent -and $ln -match "^$svcIndent[a-zA-Z]") {
                $inDashApi = $false
            }
            # Inject sysctls right before the environment: key of dashboard-api.
            if ($inDashApi -and -not $sysAdded -and $ln -match '^(\s+)environment:\s*$') {
                $keyIndent = $matches[1]
                $itemIndent = $keyIndent + "  "
                [void]$out.Add("$($keyIndent)sysctls:")
                [void]$out.Add("$($itemIndent)- net.ipv6.conf.all.disable_ipv6=1")
                [void]$out.Add("$($itemIndent)- net.ipv6.conf.default.disable_ipv6=1")
                $sysAdded = $true
            }
            [void]$out.Add($ln)
        }
        if ($sysAdded) {
            $bakIP6 = "$composePathB15.bak-ipv6-" + (Get-Date -Format "yyyyMMddHHmmss")
            try { Copy-Item -LiteralPath $composePathB15 -Destination $bakIP6 -Force -ErrorAction SilentlyContinue } catch {}
            Invoke-RotateBackups -BasePath $composePathB15
            [System.IO.File]::WriteAllLines($composePathB15, $out, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  ✓ Self-heal docker-compose.yml — sysctls IPv6 kill ajouté à dashboard-api"
        }
    }
}

# ── Self-heal: dashboard-api tmpfs for the ephemeral working .env (#148) ───
# Banking-grade runtime exposure reduction (PowerShell parity with
# update.sh's task #148 Phase 3 self-heal): the *working* .env (resolved
# secret VALUES, passed to `docker compose --env-file`) moves off the
# persistent bind-mounted install dir onto a tmpfs private to the
# dashboard-api container — proven safe experimentally on macOS/Linux
# (--env-file is interpolated client-side by the `docker compose` CLI
# process running INSIDE that same container, never resolved by the Docker
# daemon). Docker Desktop on Windows runs the Linux daemon in a VM, so
# `tmpfs:` behaves identically here.
$ComposePathTmpfs = Join-Path $INSTALL_DIR "docker-compose.yml"
if (Test-Path $ComposePathTmpfs) {
    $ComposeTextTmpfs = [System.IO.File]::ReadAllText($ComposePathTmpfs, [System.Text.UTF8Encoding]::new($false))
    $TmpfsMarker = "      - ./vault-tls/dashboard-api-client.key:/vault-tls/dashboard-api-client.key:ro"
    if (($ComposeTextTmpfs -notmatch [regex]::Escape('/run/coderaft-env')) -and $ComposeTextTmpfs.Contains($TmpfsMarker)) {
        $BakTmpfs = "$ComposePathTmpfs.bak-tmpfsenv-" + (Get-Date -Format "yyyyMMddHHmmss")
        try { Copy-Item -LiteralPath $ComposePathTmpfs -Destination $BakTmpfs -Force -ErrorAction SilentlyContinue } catch {}
        Invoke-RotateBackups -BasePath $ComposePathTmpfs
        $TmpfsReplacement = $TmpfsMarker + "`n    tmpfs:`n      - /run/coderaft-env:size=1m,mode=0700,uid=0"
        $idxTmpfs = $ComposeTextTmpfs.IndexOf($TmpfsMarker)
        $ComposeTextTmpfs = $ComposeTextTmpfs.Substring(0, $idxTmpfs) + $TmpfsReplacement + $ComposeTextTmpfs.Substring($idxTmpfs + $TmpfsMarker.Length)
        [System.IO.File]::WriteAllText($ComposePathTmpfs, $ComposeTextTmpfs, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  ✓ Self-heal docker-compose.yml — dashboard-api tmpfs /run/coderaft-env ajouté (#148)"
    }
}

# ── Self-heal: postgres → Docker native secrets:/POSTGRES_PASSWORD_FILE (#148) ──
# The official postgres image already supports POSTGRES_PASSWORD_FILE — this
# removes the resolved password from `docker inspect`/Config.Env (PowerShell
# parity with update.sh's task #148 Phase 3 self-heal). Unlike --env-file
# (client-side, see the tmpfs self-heal above), a compose `secrets: file:`
# source IS resolved by the actual Docker daemon as a literal bind-mount
# source, so the file MUST exist on real host disk BEFORE the next
# `docker compose up`. Backfill it from the CURRENTLY ACTIVE .env value first
# (not a fresh random one) so the already-initialized postgres cluster's real
# credential keeps matching — postgres only reads POSTGRES_PASSWORD* at its
# very first initdb, so a mismatched value here would silently break every
# product's DB connection after this same update.
$ComposePathPgSecret = Join-Path $INSTALL_DIR "docker-compose.yml"
if (Test-Path $ComposePathPgSecret) {
    $ComposeTextPgSecret = [System.IO.File]::ReadAllText($ComposePathPgSecret, [System.Text.UTF8Encoding]::new($false))
    $PgPwMarker = '      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}'
    if ($ComposeTextPgSecret.Contains($PgPwMarker) -and ($ComposeTextPgSecret -notmatch [regex]::Escape('POSTGRES_PASSWORD_FILE'))) {
        $BakPgSecret = "$ComposePathPgSecret.bak-pgsecret-" + (Get-Date -Format "yyyyMMddHHmmss")
        try { Copy-Item -LiteralPath $ComposePathPgSecret -Destination $BakPgSecret -Force -ErrorAction SilentlyContinue } catch {}
        Invoke-RotateBackups -BasePath $ComposePathPgSecret

        $SecretsDirPg = Join-Path $INSTALL_DIR "secrets"
        New-Item -ItemType Directory -Force -Path $SecretsDirPg | Out-Null
        $envPathPg = Join-Path $INSTALL_DIR ".env"
        $currentPgPwMatch = Select-String -Path $envPathPg -Pattern '^POSTGRES_PASSWORD=(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($currentPgPwMatch) {
            $currentPgPw = $currentPgPwMatch.Matches.Groups[1].Value
            $secretFilePg = Join-Path $SecretsDirPg "postgres_password"
            [System.IO.File]::WriteAllText($secretFilePg, $currentPgPw, [System.Text.UTF8Encoding]::new($false))
            try {
                $aclPg = Get-Acl $secretFilePg
                $rulePg = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                    "Read", "Allow")
                $aclPg.AddAccessRule($rulePg)
                Set-Acl $secretFilePg $aclPg -ErrorAction Stop
            } catch { }

            $ComposeTextPgSecret = $ComposeTextPgSecret.Replace(
                $PgPwMarker,
                "      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password"
            )
            # Insert `secrets:` right after the (postgres-only)
            # POSTGRES_INITDB_ARGS line, i.e. right before postgres's own
            # `volumes:` key — mirrors update.sh's awk insertion point
            # exactly (inserting before the `- postgres_data:...` list ITEM
            # instead would nest `secrets:` inside `volumes:` and break the YAML).
            $initdbMarker = '      POSTGRES_INITDB_ARGS: "--data-checksums"'
            if ($ComposeTextPgSecret.Contains($initdbMarker)) {
                $ComposeTextPgSecret = $ComposeTextPgSecret.Replace(
                    $initdbMarker,
                    $initdbMarker + "`n    secrets:`n      - postgres_password"
                )
            }
            if ($ComposeTextPgSecret -notmatch '(?m)^secrets:\s*$') {
                $ComposeTextPgSecret = $ComposeTextPgSecret.TrimEnd() + "`n`nsecrets:`n  postgres_password:`n    file: ./secrets/postgres_password`n"
            }
            [System.IO.File]::WriteAllText($ComposePathPgSecret, $ComposeTextPgSecret, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  ✓ Self-heal docker-compose.yml — postgres migrated to secrets:/POSTGRES_PASSWORD_FILE (#148)"
        } else {
            Write-Host "  ⚠ Self-heal skipped — could not read current POSTGRES_PASSWORD from .env (postgres secrets: migration deferred to next update run)"
        }
    }
}

# ── Self-heal: docker-compose.override.yml neo4j port (B26) ───────────────
# Bind 127.0.0.1 + port paramétrable (NEO4J_BOLT_PORT). Banking-grade :
# pas d'exposition 0.0.0.0 par défaut. Côté prod, NEO4J_BOLT_PORT n'est
# pas set → 7687 utilisé (cohérent avec l'existant).
$overridePath = Join-Path $INSTALL_DIR "docker-compose.override.yml"
if (Test-Path $overridePath) {
    $overrideText = [System.IO.File]::ReadAllText($overridePath, [System.Text.UTF8Encoding]::new($false))
    if ($overrideText -match '"7687:7687"|- 7687:7687') {
        $bak2 = "$overridePath.bak-" + (Get-Date -Format "yyyyMMdd_HHmmss")
        try { Copy-Item -LiteralPath $overridePath -Destination $bak2 -Force -ErrorAction SilentlyContinue } catch {}
        Invoke-RotateBackups -BasePath $overridePath
        $overrideText = $overrideText -replace '"7687:7687"', '"127.0.0.1:${NEO4J_BOLT_PORT:-7687}:7687"'
        $overrideText = $overrideText -replace '- 7687:7687', '- "127.0.0.1:${NEO4J_BOLT_PORT:-7687}:7687"'
        [System.IO.File]::WriteAllText($overridePath, $overrideText, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  ✓ Self-heal docker-compose.override.yml — neo4j 127.0.0.1 only + paramétrable"
    }
}

# ── Self-heal: docker-compose.yml missing coderaft-cve-proxy service ──────
# coderaft-cve-proxy (sidecar in front of the shared coderaft-cve-engine,
# cve.coderaft.io) is a platform-level service like coderaft-vault — added
# here, not via the per-product PRODUCT_SERVICES update mechanism, so it
# reaches every existing install regardless of which products are licensed.
# Line-based scan (not multiline regex) — see B-REGEX-CATASTROPHIC-BACKTRACK
# above for why large compose files must not be matched with (?ms) regex.
$composePathCveProxy = Join-Path $INSTALL_DIR "docker-compose.yml"
if (Test-Path $composePathCveProxy) {
    $cveProxyLines = [System.IO.File]::ReadAllText($composePathCveProxy, [System.Text.UTF8Encoding]::new($false)) -split "`r?`n"
    $hasCveProxy = $cveProxyLines | Where-Object { $_ -match '^\s*coderaft-cve-proxy:\s*$' }
    $postgresLineIdx = -1
    for ($i = 0; $i -lt $cveProxyLines.Count; $i++) {
        if ($cveProxyLines[$i] -match '^\s*postgres:\s*$') { $postgresLineIdx = $i; break }
    }
    if (-not $hasCveProxy -and $postgresLineIdx -ge 0) {
        $bakCveProxy = "$composePathCveProxy.bak-cveproxy-" + (Get-Date -Format "yyyyMMddHHmmss")
        try { Copy-Item -LiteralPath $composePathCveProxy -Destination $bakCveProxy -Force -ErrorAction SilentlyContinue } catch {}
        Invoke-RotateBackups -BasePath $composePathCveProxy
        $cveProxyBlock = @(
            "  # ── coderaft-cve-proxy ───────────────────────────────────────────────────"
            "  # Internal sidecar in front of the shared coderaft-cve-engine"
            "  # (cve.coderaft.io): holds the ONE bearer key for this deployment (read"
            "  # from vault at boot) and forwards CVE/KEV/EPSS/MSRC lookups from any"
            "  # product on coderaft-backend. No host port published."
            "  coderaft-cve-proxy:"
            "    image: ghcr.io/liamj74/coderaft-cve-proxy:latest"
            "    networks:"
            "      - coderaft-vault-net"
            "      - coderaft-backend"
            "      - coderaft-frontend"
            "    depends_on:"
            "      coderaft-vault: { condition: service_started }"
            "    environment:"
            "      - CODERAFT_VAULT_URL=https://coderaft-vault:8200"
            "      - CODERAFT_VAULT_CA=/vault-tls/client-ca.crt"
            "      - CODERAFT_VAULT_CLIENT_CERT=/vault-tls/cve-proxy-client.crt"
            "      - CODERAFT_VAULT_CLIENT_KEY=/vault-tls/cve-proxy-client.key"
            "      # ACCEPTED RESIDUAL RISK (security hardening 2026-07-31) — see"
            "      # install.sh for the full rationale: coderaft-cve-proxy's source"
            "      # isn't in this monorepo and it's a distroless static image (no"
            "      # shell), so unlike every other secret in this deployment"
            "      # (migrated to a Docker secrets: file), this one deliberately"
            "      # could not be."
            "      - XPRODUCT_INTERNAL_TOKEN=`${XPRODUCT_INTERNAL_TOKEN}"
            "    volumes:"
            "      - ./vault-tls/client-ca.crt:/vault-tls/client-ca.crt:ro"
            "      - ./vault-tls/cve-proxy-client.crt:/vault-tls/cve-proxy-client.crt:ro"
            "      - ./vault-tls/cve-proxy-client.key:/vault-tls/cve-proxy-client.key:ro"
            "    healthcheck:"
            '      test: ["CMD", "/coderaft-cve-proxy", "-healthcheck"]'
            "      interval: 30s"
            "      timeout: 5s"
            "      retries: 3"
            "    security_opt: [no-new-privileges:true]"
            "    cap_drop: [ALL]"
            "    restart: unless-stopped"
            ""
        )
        $before = if ($postgresLineIdx -gt 0) { $cveProxyLines[0..($postgresLineIdx - 1)] } else { @() }
        $after  = $cveProxyLines[$postgresLineIdx..($cveProxyLines.Count - 1)]
        $merged = @($before + $cveProxyBlock + $after)
        [System.IO.File]::WriteAllText($composePathCveProxy, ($merged -join "`n"), [System.Text.UTF8Encoding]::new($false))
        Write-Host "  ✓ Self-heal docker-compose.yml — coderaft-cve-proxy service added"
    }
}

# ── Self-heal HOST_PROJECT_DIR in install-config.env ──────────────────────
# Older oneliners (and any install where the dir was renamed/moved) leave
# it without HOST_PROJECT_DIR, which causes:
#   - docker compose warning "HOST_PROJECT_DIR not set" on every command
#   - dashboard-api boots with empty HOST_PROJECT_DIR → cannot reach
#     /host-compose paths → license.json invisible → fake "first run" UX
# Always (re)write the line with the resolved current install dir. Task #150:
# canonical home is install-config.env, not .env — strip any legacy copy.
$absoluteInstallDir = (Resolve-Path -LiteralPath $INSTALL_DIR).Path
if ($absoluteInstallDir) {
    if ((Get-InstallConfigVar "HOST_PROJECT_DIR") -ne $absoluteInstallDir) {
        Set-InstallConfigVar "HOST_PROJECT_DIR" $absoluteInstallDir
        Write-Host "  ✓ HOST_PROJECT_DIR refreshed in install-config.env ($absoluteInstallDir)"
    }
    Remove-FromMainEnv "HOST_PROJECT_DIR"
}

# ── Self-heal compose YAML ────────────────────────────────────────────────
# Detects a broken docker-compose.override.yml (buggy YAML generator) and
# auto-recovers: timestamped backup, deletion, pull dashboard-api, restart
# postgres+redis+dashboard-api → the API regenerates a clean override.
Write-Host ""
Write-Host "  Checking compose integrity..."
$composeOK = $false
try {
    # B20 (2026-06-08): `& docker compose ps 2>&1 | Out-Null` surfaces docker
    # stderr as NativeCommandError in PS 5.1. Use Start-Process + temp files.
    $psCheckOut = Join-Path $env:TEMP "coderaft-pscheck-out-$(Get-Random).log"
    $psCheckErr = Join-Path $env:TEMP "coderaft-pscheck-err-$(Get-Random).log"
    $psCheckProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("ps")) `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $psCheckOut `
        -RedirectStandardError  $psCheckErr `
        -ErrorAction SilentlyContinue
    if ($psCheckProc -and -not $psCheckProc.WaitForExit(60000)) {   # 60s
        Write-Host "  ⚠  Docker command timed out after 60s: docker compose ps" -ForegroundColor Yellow
        try { $psCheckProc.Kill() } catch {}
    }
    Remove-Item -Path $psCheckOut,$psCheckErr -ErrorAction SilentlyContinue
    if ($psCheckProc.ExitCode -eq 0) { $composeOK = $true }
} catch { }
if (-not $composeOK) {
    Write-Host "  ⚠ docker-compose.override.yml appears corrupted — auto-recovery..."
    if (Test-Path "docker-compose.override.yml") {
        $brokenBak = "docker-compose.override.yml.broken-" + (Get-Date -Format "yyyyMMdd_HHmmss")
        try { Copy-Item "docker-compose.override.yml" $brokenBak -ErrorAction SilentlyContinue } catch { }
        Invoke-RotateBackups -BasePath "docker-compose.override.yml" -GlobSuffix "broken-*"
        try { Remove-Item "docker-compose.override.yml" -ErrorAction SilentlyContinue } catch { }
        Write-Host "    ✓ override backed up + removed"
    }
    try {
        $pullOut  = Join-Path $env:TEMP "coderaft-pull-out-$(Get-Random).log"
        $pullErr  = Join-Path $env:TEMP "coderaft-pull-err-$(Get-Random).log"
        Start-Process -FilePath "docker" -ArgumentList @("pull","ghcr.io/liamj74/coderaft-dashboard-api:latest") `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $pullOut `
            -RedirectStandardError  $pullErr `
            -ErrorAction SilentlyContinue | Out-Null
        Remove-Item -Path $pullOut,$pullErr -ErrorAction SilentlyContinue
    } catch { }
    try {
        # docker compose up -d: its stdout is desired output, but stderr
        # surfaces as NativeCommandError in PS 5.1. Redirect stderr only.
        $upHealErr = Join-Path $env:TEMP "coderaft-upheal-err-$(Get-Random).log"
        $upHealOut = Join-Path $env:TEMP "coderaft-upheal-out-$(Get-Random).log"
        $upHealProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("up","-d","postgres","redis","dashboard-api")) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $upHealOut `
            -RedirectStandardError  $upHealErr `
            -ErrorAction SilentlyContinue
        if (Test-Path $upHealOut) { Get-Content $upHealOut -ErrorAction SilentlyContinue | Out-Host }
        Remove-Item -Path $upHealOut,$upHealErr -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 6
        $psHealOut = Join-Path $env:TEMP "coderaft-psheal-out-$(Get-Random).log"
        $psHealErr = Join-Path $env:TEMP "coderaft-psheal-err-$(Get-Random).log"
        $psHealProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("ps")) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $psHealOut `
            -RedirectStandardError  $psHealErr `
            -ErrorAction SilentlyContinue
        if ($psHealProc -and -not $psHealProc.WaitForExit(60000)) {   # 60s
            Write-Host "  ⚠  Docker command timed out after 60s: docker compose ps" -ForegroundColor Yellow
            try { $psHealProc.Kill() } catch {}
        }
        Remove-Item -Path $psHealOut,$psHealErr -ErrorAction SilentlyContinue
        if ($psHealProc.ExitCode -eq 0) {
            Write-Host "    ✓ compose repaired"
        } else {
            Write-Host "  ERROR: self-heal failed. Inspect docker-compose.override.yml manually."
            return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
        }
    } catch {
        Write-Host "  ERROR: cannot restart dashboard-api — $($_.Exception.Message)"
        return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
    }
    $LASTEXITCODE = 0
} else {
    Write-Host "  ✓ compose OK"
}

# ── FalconOne agents mTLS PKI (#170) ─────────────────────────────────────────
# Distinct CA/leaf from the vault client PKI: falconone-tls\agents-ca.crt is
# the pool of ClientCAs falconone-api trusts for inbound agent mTLS, and
# falconone-tls\server.crt is the leaf falconone-api presents on :8443 to its
# own Windows agents. Bug #170: server.crt's SAN only ever had
# [localhost, falconone-api] — remote agents connecting via
# https://<public-hostname>:8443/agent/v1 failed hostname verification.
# Self-healing: the CA is preserved if it already exists (regenerating it
# would break trust for any agent already enrolled); only the leaf is
# regenerated, and only when it's missing the "coderaft.local" SAN.
#
# Defined here (and called both inside the one-time migration block below
# AND unconditionally after it) because the migration block only ever runs
# ONCE per install — already-migrated installs would otherwise never get
# this SAN fix or a falconone-tls dir that didn't exist on an older version.
function Invoke-FalconOneTlsBootstrap {
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $foTlsDir = Join-Path $InstallDir "falconone-tls"
    New-Item -ItemType Directory -Force -Path $foTlsDir | Out-Null

    $foSanList = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @("DNS:localhost", "DNS:falconone-api", "DNS:coderaft.local")) { $foSanList.Add($s) }
    if ($env:COMPUTERNAME) { $foSanList.Add("DNS:$($env:COMPUTERNAME)") }
    if ($env:CODERAFT_EXTRA_HOSTS) {
        foreach ($h in ($env:CODERAFT_EXTRA_HOSTS -split ",")) {
            $trimmed = $h.Trim()
            if ($trimmed) { $foSanList.Add("DNS:$trimmed") }
        }
    }
    $foSanList.Add("IP:127.0.0.1")
    $foSanString = (($foSanList | Select-Object -Unique) -join ",")

    $foScript = @'
set -e
apk add --no-cache openssl >/dev/null
cd /work
# Bug fix (2026-07-27, live outage): regeneration used to gate ONLY on
# agents-ca.crt missing. If agents-ca.crt existed but agents-ca.key had been
# lost/never written (any partial failure of a prior run), this block was
# skipped, agents-ca.key stayed absent, and the server.crt (re)signing step
# below silently failed (its stderr was redirected to /dev/null) — leaving
# server.crt EMPTY while the script still exited 0 and the caller printed a
# fake "PKI written" success. falconone-api then fatal-crashed at boot with
# "load server keypair: ... failed to find any PEM data" (full 502 outage).
# Now regenerates the CA pair whenever EITHER half is missing.
if [ ! -f agents-ca.crt ] || [ ! -f agents-ca.key ]; then
    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
        -keyout agents-ca.key -out agents-ca.crt \
        -subj "/CN=falconone-agents-ca" \
        -addext "basicConstraints=critical,CA:TRUE"
fi
NEED_REGEN=1
if [ -f server.crt ] && [ -s server.crt ] && openssl x509 -in server.crt -noout -text 2>/dev/null | grep -q "coderaft.local"; then
    NEED_REGEN=0
fi
if [ "$NEED_REGEN" = "1" ]; then
    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout server.key -out server.csr \
        -subj "/CN=falconone-agents"
    cat > /tmp/server.ext <<EOF
subjectAltName=__FO_SAN_LIST__
basicConstraints=CA:FALSE
EOF
    openssl x509 -req -days 3650 -sha256 \
        -in server.csr -CA agents-ca.crt -CAkey agents-ca.key -CAcreateserial \
        -out server.crt -extfile /tmp/server.ext
    rm -f server.csr /tmp/server.ext
fi
chmod 644 *.crt *.key 2>/dev/null || true
# Final sanity check: fail loudly (non-zero exit) rather than let an empty
# file pass silently as "success" to the PowerShell caller.
[ -s server.crt ] && [ -s server.key ] && [ -s agents-ca.crt ]
'@
    $foScript = $foScript.Replace("__FO_SAN_LIST__", $foSanString)
    $foScriptFile = Join-Path $env:TEMP "coderaft-fo-tls-$(Get-Random).sh"
    $foScriptLF = $foScript -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($foScriptFile, $foScriptLF, [System.Text.UTF8Encoding]::new($false))
    $absFoTlsDir = (Resolve-Path -LiteralPath $foTlsDir).Path

    $foProc = Start-Process -FilePath "docker" -ArgumentList @(
        "run", "--rm",
        "-v", "${foScriptFile}:/script.sh:ro",
        "-v", "${absFoTlsDir}:/work",
        "alpine:3.20", "sh", "/script.sh"
    ) -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
    Remove-Item -Path $foScriptFile -ErrorAction SilentlyContinue
    # Bug fix (2026-07-27): this used to print success unconditionally,
    # regardless of whether the container/script actually succeeded.
    if ($foProc -and $foProc.ExitCode -eq 0) {
        Write-DetailLog "FalconOne agents PKI written (SAN: $foSanString)"
    } else {
        Write-Host "  ✗ FalconOne agents PKI bootstrap FAILED (exit code $($foProc.ExitCode)) — falconone-api will fatal-crash at boot (empty/missing cert in $foTlsDir). Re-run the update, or manually delete $foTlsDir and re-run to force a clean regeneration." -ForegroundColor Red
    }
}

# ── ACL self-heal: falconone entry/permissions (#172) ────────────────────────
# The acl.yaml rewrite below only runs once, inside the migration block (its
# caller is gated by $vaultNeedsMigration). That means any install that
# already migrated to vault before this fix shipped would never get the
# falconone entry/permissions rewritten. This self-heal is additive-only,
# idempotent, and safe to call on every install/update run: if the
# "falconone" client entry is missing, it appends the full canonical block;
# if present, it appends only whichever required permissions are missing,
# leaving everything else in the file untouched. Backs up acl.yaml before
# any modification.
function Invoke-FalconOneAclSelfHeal {
    param([Parameter(Mandatory = $true)][string]$AclPath)

    if (-not (Test-Path $AclPath)) {
        Write-DetailLog "[install] ACL self-heal: $AclPath not found — skipping (vault not provisioned yet)"
        return
    }

    $requiredPerms = @(
        "read:license_key",
        "read:falconone_*",
        "read:platform/identity/oidc",
        "sign:falconone_agent_cert",
        "read:falconone/nvd_api_key",
        "read:falconone/audit_hmac_key",
        "write:falconone/audit_hmac_key",
        "read:falconone/pki/agents-ca/cert",
        "read:pki/falconone-agents-ca*",
        "write:pki/falconone-agents-ca*",
        "read:falconone/scripts_ca*",
        "write:falconone/scripts_ca*"
    )

    $lines = @(Get-Content -LiteralPath $AclPath)
    $blockStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-\s*name:\s*falconone\s*$') { $blockStart = $i; break }
    }

    $ts = Get-Date -Format "yyyyMMddTHHmmssZ"

    if ($blockStart -eq -1) {
        Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"
        $newBlock = @'

  - name: falconone
    cert_san: "falconone.coderaft.local"
    permissions:
      - "read:license_key"
      - "read:falconone_*"
      - "read:platform/identity/oidc"
      - "sign:falconone_agent_cert"
      - "read:falconone/nvd_api_key"
      - "read:falconone/audit_hmac_key"
      - "write:falconone/audit_hmac_key"
      - "read:falconone/pki/agents-ca/cert"
      - "read:pki/falconone-agents-ca*"
      - "write:pki/falconone-agents-ca*"
      - "read:falconone/scripts_ca*"
      - "write:falconone/scripts_ca*"
'@
        Add-Content -LiteralPath $AclPath -Value $newBlock
        Write-DetailLog "[install] Self-heal ACL: falconone permissions updated (+$($requiredPerms.Count) added, entry created)"
        return
    }

    $blockEnd = $lines.Count
    for ($j = $blockStart + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*-\s*name:\s*\S') { $blockEnd = $j; break }
    }
    $blockText = ($lines[$blockStart..($blockEnd - 1)]) -join "`n"

    $missing = @($requiredPerms | Where-Object { $blockText -notmatch [regex]::Escape("`"$_`"") })

    if ($missing.Count -eq 0) {
        Write-DetailLog "[install] ACL falconone already up-to-date"
        return
    }

    Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"

    $permsLineIdx = -1
    for ($k = $blockStart; $k -lt $blockEnd; $k++) {
        if ($lines[$k] -match '^\s*permissions:\s*\[.*\]\s*$') { $permsLineIdx = $k; break }
    }

    if ($permsLineIdx -ge 0) {
        $additions = ($missing | ForEach-Object { "`"$_`"" }) -join ","
        $lines[$permsLineIdx] = $lines[$permsLineIdx] -replace '\]\s*$', ",$additions]"
        $lines | Set-Content -LiteralPath $AclPath -Encoding UTF8
    } else {
        $insertLines = @($missing | ForEach-Object { "      - `"$_`"" })
        $before = if ($blockEnd -gt 0) { $lines[0..($blockEnd - 1)] } else { @() }
        $after  = if ($blockEnd -le $lines.Count - 1) { $lines[$blockEnd..($lines.Count - 1)] } else { @() }
        $merged = @($before + $insertLines + $after)
        $merged | Set-Content -LiteralPath $AclPath -Encoding UTF8
    }

    Write-DetailLog "[install] Self-heal ACL: falconone permissions updated (+$($missing.Count) added)"
}

# ── ACL self-heal: redfox connections/k8s vault-backed credentials ──────────
# Zero-Knowledge Credential Architecture Palier 1
# (coderaft-platform/docs/redfox-zero-knowledge-scoping.md): target
# connection credentials and k8s cluster auth data move from RedFox's own
# Postgres into this vault, under redfox/connections/* and redfox/k8s/*.
# Same additive-only, idempotent merge-into-existing-entry pattern as
# Invoke-FalconOneAclSelfHeal above — any install already has a "redfox"
# entry (it existed for platform/identity/oidc), so without this it would
# never gain the new permissions.
function Invoke-RedfoxAclSelfHeal {
    param([Parameter(Mandatory = $true)][string]$AclPath)

    if (-not (Test-Path $AclPath)) {
        Write-DetailLog "[update] ACL self-heal: $AclPath not found — skipping (vault not provisioned yet)"
        return
    }

    $requiredPerms = @(
        "read:license_key",
        "read:redfox_*",
        "read:platform/identity/oidc",
        "read:platform/identity/graph-tools",
        "read:redfox/connections/*",
        "write:redfox/connections/*",
        "delete:redfox/connections/*",
        "read:redfox/k8s/*",
        "write:redfox/k8s/*",
        "delete:redfox/k8s/*"
    )

    $lines = @(Get-Content -LiteralPath $AclPath)
    $blockStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-\s*name:\s*redfox\s*$') { $blockStart = $i; break }
    }

    $ts = Get-Date -Format "yyyyMMddTHHmmssZ"

    if ($blockStart -eq -1) {
        Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"
        $newBlock = @'

  - name: redfox
    cert_san: "redfox.coderaft.local"
    permissions:
      - "read:license_key"
      - "read:redfox_*"
      - "read:platform/identity/oidc"
      - "read:platform/identity/graph-tools"
      - "read:redfox/connections/*"
      - "write:redfox/connections/*"
      - "delete:redfox/connections/*"
      - "read:redfox/k8s/*"
      - "write:redfox/k8s/*"
      - "delete:redfox/k8s/*"
'@
        Add-Content -LiteralPath $AclPath -Value $newBlock
        Write-DetailLog "[update] Self-heal ACL: redfox permissions updated (+$($requiredPerms.Count) added, entry created)"
        return
    }

    $blockEnd = $lines.Count
    for ($j = $blockStart + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*-\s*name:\s*\S') { $blockEnd = $j; break }
    }
    $blockText = ($lines[$blockStart..($blockEnd - 1)]) -join "`n"

    $missing = @($requiredPerms | Where-Object { $blockText -notmatch [regex]::Escape("`"$_`"") })

    if ($missing.Count -eq 0) {
        Write-DetailLog "[update] ACL redfox already up-to-date"
        return
    }

    Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"

    $permsLineIdx = -1
    for ($k = $blockStart; $k -lt $blockEnd; $k++) {
        if ($lines[$k] -match '^\s*permissions:\s*\[.*\]\s*$') { $permsLineIdx = $k; break }
    }

    if ($permsLineIdx -ge 0) {
        $additions = ($missing | ForEach-Object { "`"$_`"" }) -join ","
        $lines[$permsLineIdx] = $lines[$permsLineIdx] -replace '\]\s*$', ",$additions]"
        $lines | Set-Content -LiteralPath $AclPath -Encoding UTF8
    } else {
        $insertLines = @($missing | ForEach-Object { "      - `"$_`"" })
        $before = if ($blockEnd -gt 0) { $lines[0..($blockEnd - 1)] } else { @() }
        $after  = if ($blockEnd -le $lines.Count - 1) { $lines[$blockEnd..($lines.Count - 1)] } else { @() }
        $merged = @($before + $insertLines + $after)
        $merged | Set-Content -LiteralPath $AclPath -Encoding UTF8
    }

    Write-DetailLog "[update] Self-heal ACL: redfox permissions updated (+$($missing.Count) added)"
}

# ── ACL self-heal: cve-proxy entry (coderaft-cve-engine sidecar) ────────────
# Same additive-only, idempotent pattern as Invoke-FalconOneAclSelfHeal above.
function Invoke-CveProxyAclSelfHeal {
    param([Parameter(Mandatory = $true)][string]$AclPath)

    if (-not (Test-Path $AclPath)) {
        Write-DetailLog "[update] ACL self-heal: $AclPath not found — skipping (vault not provisioned yet)"
        return
    }

    $lines = @(Get-Content -LiteralPath $AclPath)
    $already = $lines | Where-Object { $_ -match '^\s*-\s*name:\s*cve-proxy\s*$' }
    if ($already) {
        Write-DetailLog "[update] ACL cve-proxy already present"
        return
    }

    $ts = Get-Date -Format "yyyyMMddTHHmmssZ"
    Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"
    $newBlock = @'

  - name: cve-proxy
    cert_san: "cve-proxy.coderaft.local"
    permissions:
      - "read:cve-proxy/*"
      - "write:cve-proxy/*"
'@
    Add-Content -LiteralPath $AclPath -Value $newBlock
    Write-DetailLog "[update] Self-heal ACL: cve-proxy entry created"
}

# ── Live vault ACL reconciliation (post-bootstrap installs) ─────────────────
# Invoke-FalconOneAclSelfHeal/Invoke-CveProxyAclSelfHeal above only patch the
# STATIC acl.yaml file. coderaft-vault's loadOrBootstrapACL (cmd/coderaft-
# vault/main.go) reads that file ONLY on a vault's very first-ever boot —
# every later boot loads the ACL from its own persisted, encrypted store,
# and acl.yaml is "never consulted again" (see internal/api/acl_handlers.go's
# own header comment: dynamic ACL management replaces a static acl.yaml
# edit, invisible to the audit trail, with an authenticated admin-API call —
# by design, not a bug to fix in coderaft-vault). On any vault that already
# went through its first boot before a given client existed — i.e. every
# already-provisioned install, since falconone/cve-proxy both shipped well
# after vault Phase 0 — patching the file alone is therefore a NO-OP against
# the live, running vault: it keeps rejecting that client (this is exactly
# what surfaced as a 401 on `set cve-proxy/cve_engine_api_key`, previously
# worked around with a manual `PUT /v1/admin/acl/cve-proxy` curl) until the
# persisted ACL is reconciled through the vault's own authenticated admin
# API. This closes that gap so update.ps1 does it itself instead of
# requiring a manual live patch — additive-only (only ever touches the ONE
# named client's entry, via the same admin endpoint's existing safety
# checks), idempotent (no-ops once the live vault already has every
# required permission), and non-fatal if the vault is absent/sealed/
# unreachable (the acl.yaml seed above still covers a genuine fresh install).
#
# MERGE, NOT JUST CREATE (fixed alongside the redfox Zero-Knowledge
# Credential Architecture Palier 1 self-heal above, mirroring the identical
# fix in the bash update.sh sibling): the original version of this function
# treated "the client name already exists on the live vault" as fully done
# and returned early — correct the first time a NEW client (falconone,
# cve-proxy) was self-healed onto an existing vault, but wrong for adding
# NEW permissions to an ALREADY-provisioned client, e.g. redfox (which has
# had a live "redfox" entry since platform/identity/oidc shipped, long
# before redfox/connections/* existed) or falconone's own #226 scripts_ca*
# grant. Now it fetches the entry's current live permissions and PUTs the
# union with the required set — a true no-op if nothing is missing, a merge
# (never a destructive overwrite of unrelated permissions) if something is.
function Invoke-VaultAclLiveSelfHeal {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$San,
        [Parameter(Mandatory = $true)][string[]]$Permissions
    )

    $tlsDir   = Join-Path $InstallDir "vault-tls"
    $certFile = Join-Path $tlsDir "dashboard-api-client.crt"
    $keyFile  = Join-Path $tlsDir "dashboard-api-client.key"
    $caFile   = Join-Path $tlsDir "client-ca.crt"
    if (-not (Test-Path $certFile) -or -not (Test-Path $keyFile) -or -not (Test-Path $caFile)) { return }

    $inspOut = Join-Path $env:TEMP "coderaft-acl-insp-$(Get-Random).log"
    $inspErr = Join-Path $env:TEMP "coderaft-acl-insp-err-$(Get-Random).log"
    $inspProc = Start-Process -FilePath "docker" -ArgumentList @("inspect", "coderaft-coderaft-vault-1") `
        -NoNewWindow -PassThru -RedirectStandardOutput $inspOut -RedirectStandardError $inspErr -ErrorAction SilentlyContinue
    if ($inspProc -and -not $inspProc.WaitForExit(15000)) { try { $inspProc.Kill() } catch {} }
    $vaultUp = (Test-Path $inspOut) -and (((Get-Content $inspOut -Raw -ErrorAction SilentlyContinue)) -match '"Id"')
    Remove-Item -Path $inspOut, $inspErr -ErrorAction SilentlyContinue
    if (-not $vaultUp) { return }

    $projOut = Join-Path $env:TEMP "coderaft-acl-proj-$(Get-Random).log"
    $projErr = Join-Path $env:TEMP "coderaft-acl-proj-err-$(Get-Random).log"
    $projProc = Start-Process -FilePath "docker" -ArgumentList @("inspect", "coderaft-coderaft-vault-1", "--format", '{{ index .Config.Labels "com.docker.compose.project" }}') `
        -NoNewWindow -PassThru -RedirectStandardOutput $projOut -RedirectStandardError $projErr -ErrorAction SilentlyContinue
    if ($projProc -and -not $projProc.WaitForExit(15000)) { try { $projProc.Kill() } catch {} }
    $project = ((Get-Content $projOut -ErrorAction SilentlyContinue) -join "").Trim()
    Remove-Item -Path $projOut, $projErr -ErrorAction SilentlyContinue
    if (-not $project) { $project = "coderaft" }
    $network  = "${project}_coderaft-vault-net"
    $absTlsDir = (Resolve-Path -LiteralPath $tlsDir).Path

    function _AclLiveCurl {
        param([string]$Method, [string]$Path, [string]$JsonBody = "")
        $dockerArgs = @("run", "--rm")
        if ($JsonBody) { $dockerArgs += @("-i") }
        $dockerArgs += @(
            "--user", "0:0", "--network", $network,
            "-v", "${absTlsDir}:/tls:ro",
            "curlimages/curl:latest",
            "--cert", "/tls/dashboard-api-client.crt",
            "--key", "/tls/dashboard-api-client.key",
            "--cacert", "/tls/client-ca.crt",
            "-sS", "-m", "10", "-X", $Method,
            "https://coderaft-vault:8200$Path"
        )
        $bodyFile = $null
        if ($JsonBody) {
            $bodyFile = Join-Path $env:TEMP "coderaft-acl-body-$(Get-Random).json"
            [System.IO.File]::WriteAllText($bodyFile, $JsonBody, [System.Text.UTF8Encoding]::new($false))
            $dockerArgs += @("-H", "Content-Type: application/json", "--data-binary", "@-")
        }
        $curlOut = Join-Path $env:TEMP "coderaft-acl-out-$(Get-Random).log"
        $curlErr = Join-Path $env:TEMP "coderaft-acl-err-$(Get-Random).log"
        $spArgs = @{
            FilePath = "docker"; ArgumentList = $dockerArgs; NoNewWindow = $true; Wait = $true
            RedirectStandardOutput = $curlOut; RedirectStandardError = $curlErr; ErrorAction = "SilentlyContinue"
        }
        if ($bodyFile) { $spArgs['RedirectStandardInput'] = $bodyFile }
        Start-Process @spArgs | Out-Null
        $result = ""
        if (Test-Path $curlOut) { $result = ((Get-Content $curlOut -ErrorAction SilentlyContinue) -join "") }
        Remove-Item -Path $curlOut, $curlErr -ErrorAction SilentlyContinue
        if ($bodyFile) { Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue }
        return $result
    }

    $health = _AclLiveCurl -Method "GET" -Path "/v1/health"
    if ($health -notmatch '"sealed":false') {
        Write-DetailLog "[update] Vault ACL live self-heal ($Name): vault sealed/unreachable — skipped, will apply on the vault's next real bootstrap"
        return
    }

    $current = _AclLiveCurl -Method "GET" -Path "/v1/admin/acl"

    # Isolate this client's own object out of {"clients":[{...},{...}]} — the
    # response is single-line JSON (json.Encoder does not indent), so a
    # non-greedy "stop at the first }" match is safe. No jq/ConvertFrom-Json
    # dependency assumed — same regex approach as the bash sibling.
    $entryMatch = [regex]::Match($current, "\{`"name`":`"$([regex]::Escape($Name))`"[^}]*\}")
    $existingPerms = $null
    if ($entryMatch.Success) {
        $permsMatch = [regex]::Match($entryMatch.Value, '"permissions":\[([^\]]*)\]')
        if ($permsMatch.Success) { $existingPerms = $permsMatch.Groups[1].Value }
    }

    $permsJson = $null
    if ($null -ne $existingPerms) {
        $merged = $existingPerms
        foreach ($p in $Permissions) {
            if ($merged -notmatch [regex]::Escape("`"$p`"")) {
                $merged = "$merged,`"$p`""
            }
        }
        if ($merged -eq $existingPerms) {
            Write-DetailLog "[update] Vault ACL live self-heal: $Name already up-to-date on the running vault"
            return
        }
        $permsJson = "[" + $merged.TrimStart(',') + "]"
    } else {
        $permsJson = "[" + (($Permissions | ForEach-Object { "`"$_`"" }) -join ",") + "]"
    }

    $body = "{`"cert_san`":`"$San`",`"permissions`":$permsJson}"
    $resp = _AclLiveCurl -Method "PUT" -Path "/v1/admin/acl/$Name" -JsonBody $body
    if ($resp -match '"ok":true') {
        if ($null -ne $existingPerms) {
            Write-DetailLog "[update] Vault ACL live self-heal: $Name permissions merged on the RUNNING vault (acl.yaml alone would not have reached it)"
        } else {
            Write-DetailLog "[update] Vault ACL live self-heal: $Name granted on the RUNNING vault (acl.yaml alone would not have reached it)"
        }
    } else {
        Write-DetailLog "[update] Vault ACL live self-heal: PUT /v1/admin/acl/$Name failed — will retry on next update: $resp"
    }
}

# ── Vault client cert self-heal (any product whose cert was never
# generated, e.g. cve-proxy on installs migrated before it shipped) ─────────
# Additive-only, requires client-ca.key to still be present.
function Invoke-VaultClientCertSelfHeal {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$San
    )

    $tlsDir = Join-Path $InstallDir "vault-tls"
    $certPath = Join-Path $tlsDir "$Name-client.crt"
    $keyPath = Join-Path $tlsDir "$Name-client.key"
    # BUG FIX (2026-08-04, found live): plain Test-Path matches directories
    # too. If dashboard-api's bind mount for this cert ever ran once with the
    # file missing, Docker silently creates an EMPTY DIRECTORY at that host
    # path instead of erroring — Test-Path then reports "exists" forever,
    # this self-heal never regenerates the real cert, and falconone-api
    # fatals with "load client cert: read .../falconone-client.crt: is a
    # directory" on every boot. -PathType Leaf requires a real file; if a
    # stale directory is squatting on either path, remove it first so the
    # generation step below can actually create the file.
    if ((Test-Path $certPath) -and -not (Test-Path $certPath -PathType Leaf)) {
        Write-DetailLog "[update] Cert self-heal: $certPath is a directory (stale empty bind-mount artifact), not a cert — removing so it can be regenerated"
        Remove-Item -LiteralPath $certPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ((Test-Path $keyPath) -and -not (Test-Path $keyPath -PathType Leaf)) {
        Remove-Item -LiteralPath $keyPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $certPath -PathType Leaf) { return }

    $caKey = Join-Path $tlsDir "client-ca.key"
    $caCrt = Join-Path $tlsDir "client-ca.crt"
    if (-not (Test-Path $caKey) -or -not (Test-Path $caCrt)) {
        Write-Host "  [update] Cert self-heal: vault-tls\client-ca.key missing — cannot mint $Name-client cert (needs a full CA rotation, not a self-heal)"
        return
    }

    Write-DetailLog "[update] Cert self-heal: generating vault-tls\$Name-client (was missing)"
    $chmodExtra = if ($Name -eq "falconone" -or $Name -eq "cve-proxy") {
        "chmod 644 '$Name-client.key' '$Name-client.crt'"
    } else {
        "chmod 600 '$Name-client.key' '$Name-client.crt'"
    }
    $script = @"
set -e
apk add --no-cache openssl >/dev/null
cd /work
openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout '$Name-client.key' -out '$Name-client.csr' \
    -subj '/CN=$San' 2>/dev/null
printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE' '$San' > /tmp/client.ext
openssl x509 -req -days 3650 -sha256 \
    -in '$Name-client.csr' -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
    -out '$Name-client.crt' -extfile /tmp/client.ext 2>/dev/null
rm -f '$Name-client.csr' /tmp/client.ext
$chmodExtra
"@
    $scriptFile = Join-Path $env:TEMP "coderaft-cert-selfheal-$(Get-Random).sh"
    $scriptLF = $script -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($scriptFile, $scriptLF, [System.Text.UTF8Encoding]::new($false))

    $runStdout = Join-Path $env:TEMP "coderaft-cert-selfheal-out-$(Get-Random).log"
    $runStderr = Join-Path $env:TEMP "coderaft-cert-selfheal-err-$(Get-Random).log"
    $absTlsDir = (Resolve-Path -LiteralPath $tlsDir).Path
    $proc = Start-Process -FilePath "docker" -ArgumentList @(
        "run","--rm",
        "-v","${scriptFile}:/script.sh:ro",
        "-v","${absTlsDir}:/work",
        "alpine:3.20","sh","/script.sh"
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $runStdout `
        -RedirectStandardError $runStderr `
        -ErrorAction SilentlyContinue
    Remove-Item -Path $runStdout, $runStderr, $scriptFile -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.ExitCode -ne 0 -or -not (Test-Path $certPath)) {
        Write-DetailLog "[update] Cert self-heal: $Name-client generation failed (non-fatal, retried next run)"
    }
}

# ── Vault migration (D4) ─────────────────────────────────────────────────
# Runs ONCE when the vault container is absent from the compose stack.
Write-Host ""
Write-Host "  Checking vault migration status..."

$vaultMigrationSentinel = Join-Path $INSTALL_DIR "vault-data\.migrated"
$vaultAgeKey = Join-Path $INSTALL_DIR "vault-keys\age.key"
$vaultRunning = $false
try {
    # B20 (2026-06-08): `& docker compose ps ... 2>$null` → NativeCommandError PS 5.1
    $vaultPsOut = Join-Path $env:TEMP "coderaft-vaultps-out-$(Get-Random).log"
    $vaultPsErr = Join-Path $env:TEMP "coderaft-vaultps-err-$(Get-Random).log"
    $vaultPsProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("ps","coderaft-vault")) `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $vaultPsOut `
        -RedirectStandardError  $vaultPsErr `
        -ErrorAction SilentlyContinue
    if ($vaultPsProc -and -not $vaultPsProc.WaitForExit(60000)) {   # 60s
        Write-Host "  ⚠  Docker command timed out after 60s: docker compose ps coderaft-vault" -ForegroundColor Yellow
        try { $vaultPsProc.Kill() } catch {}
    }
    $ps = (Get-Content $vaultPsOut -ErrorAction SilentlyContinue) -join " "
    Remove-Item -Path $vaultPsOut,$vaultPsErr -ErrorAction SilentlyContinue
    if ($ps -match "running") { $vaultRunning = $true }
} catch { }

# AUDIT-SECU-2026-08-04 (Vault H1): used to ALSO require -not $vaultRunning —
# that assumption dates from when the vault auto-unsealed itself at boot, so
# "running" implied "usable". It no longer does: the vault now ALWAYS boots
# sealed and requires a real human Shamir ceremony that no script can
# complete unattended. A container can be "running" for a long time while
# sealed with secrets NOT yet migrated (steps below never got to run) —
# treating that as "done" would silently strand the host on legacy stores
# forever. Only the migration sentinel (written at the END of a successful
# run) means the migration itself is actually complete.
$vaultNeedsMigration = $false
if (-not (Test-Path $vaultMigrationSentinel)) {
    $vaultNeedsMigration = $true
}

if ($vaultNeedsMigration) {
    Write-Host "  Running vault migration..."

    # ── 4b Pre-flight backup ──────────────────────────────────────────────
    $vaultTs  = (Get-Date -Format "yyyyMMddTHHmmssZ")
    $vaultBak = Join-Path $INSTALL_DIR "backups\migrate-vault-$vaultTs"
    New-Item -ItemType Directory -Force -Path $vaultBak | Out-Null
    Write-Host "  Backup directory: $vaultBak"

    $envPath = Join-Path $INSTALL_DIR ".env"
    if (Test-Path $envPath) {
        Copy-Item $envPath (Join-Path $vaultBak "env") -ErrorAction Stop
    } else {
        Write-Host "  ✗ .env not found — cannot backup. Vault migration aborted." -ForegroundColor Red
        return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
    }
    $envEncPath = Join-Path $INSTALL_DIR ".env.enc"
    if (Test-Path $envEncPath) { Copy-Item $envEncPath (Join-Path $vaultBak "env.enc") -ErrorAction SilentlyContinue }
    $ageKeyPath = Join-Path $INSTALL_DIR ".coderaft-age.key"
    if (Test-Path $ageKeyPath) { Copy-Item $ageKeyPath (Join-Path $vaultBak "age.key") -ErrorAction SilentlyContinue }

    # Postgres dump
    try {
        # B20 (2026-06-08): `& docker compose ps ... 2>$null` → NativeCommandError PS 5.1
        $pgPsOut = Join-Path $env:TEMP "coderaft-pgps-out-$(Get-Random).log"
        $pgPsErr = Join-Path $env:TEMP "coderaft-pgps-err-$(Get-Random).log"
        $pgPsProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("ps","postgres")) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $pgPsOut `
            -RedirectStandardError  $pgPsErr `
            -ErrorAction SilentlyContinue
        if ($pgPsProc -and -not $pgPsProc.WaitForExit(60000)) {   # 60s
            Write-Host "  ⚠  Docker command timed out after 60s: docker compose ps postgres" -ForegroundColor Yellow
            try { $pgPsProc.Kill() } catch {}
        }
        $pgPsText = (Get-Content $pgPsOut -ErrorAction SilentlyContinue) -join " "
        Remove-Item -Path $pgPsOut,$pgPsErr -ErrorAction SilentlyContinue
        $pgRunning = $pgPsText -match "running"
        if ($pgRunning) {
            $bakSql = Join-Path $vaultBak "auth_config.sql"
            $proc = Start-Process -FilePath "docker" `
                -ArgumentList (@("compose") + $ComposeEnvArgs + @("exec","-T","postgres","pg_dump","-U","coderaft","-t","auth_config","coderaft")) `
                -RedirectStandardOutput $bakSql -NoNewWindow -PassThru -Wait
            if ($proc.ExitCode -ne 0) { Remove-Item $bakSql -ErrorAction SilentlyContinue }
        }
    } catch { }

    # Container-side files
    try {
        $rvPsOut = Join-Path $env:TEMP "coderaft-rvps-out-$(Get-Random).log"
        $rvPsErr = Join-Path $env:TEMP "coderaft-rvps-err-$(Get-Random).log"
        $rvPsProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("ps","ravenscan")) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $rvPsOut `
            -RedirectStandardError  $rvPsErr `
            -ErrorAction SilentlyContinue
        if ($rvPsProc -and -not $rvPsProc.WaitForExit(60000)) {   # 60s
            Write-Host "  ⚠  Docker command timed out after 60s: docker compose ps ravenscan" -ForegroundColor Yellow
            try { $rvPsProc.Kill() } catch {}
        }
        $rvRunning = ((Get-Content $rvPsOut -ErrorAction SilentlyContinue) -join " ") -match "running"
        Remove-Item -Path $rvPsOut,$rvPsErr -ErrorAction SilentlyContinue
        if ($rvRunning) {
            $rvCpErr = Join-Path $env:TEMP "coderaft-rvcp-err-$(Get-Random).log"
            $rvCpOut = Join-Path $env:TEMP "coderaft-rvcp-out-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("cp","ravenscan:.ravenscan/ravenscan.db",(Join-Path $vaultBak "ravenscan.db"))) `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $rvCpOut `
                -RedirectStandardError  $rvCpErr `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -Path $rvCpOut,$rvCpErr -ErrorAction SilentlyContinue
        }
    } catch { }
    try {
        $apiPsOut = Join-Path $env:TEMP "coderaft-apips-out-$(Get-Random).log"
        $apiPsErr = Join-Path $env:TEMP "coderaft-apips-err-$(Get-Random).log"
        $apiPsProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("ps","dashboard-api")) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $apiPsOut `
            -RedirectStandardError  $apiPsErr `
            -ErrorAction SilentlyContinue
        if ($apiPsProc -and -not $apiPsProc.WaitForExit(60000)) {   # 60s
            Write-Host "  ⚠  Docker command timed out after 60s: docker compose ps dashboard-api" -ForegroundColor Yellow
            try { $apiPsProc.Kill() } catch {}
        }
        $apiRunning = ((Get-Content $apiPsOut -ErrorAction SilentlyContinue) -join " ") -match "running"
        Remove-Item -Path $apiPsOut,$apiPsErr -ErrorAction SilentlyContinue
        if ($apiRunning) {
            $cp1Out = Join-Path $env:TEMP "coderaft-cp1-out-$(Get-Random).log"
            $cp1Err = Join-Path $env:TEMP "coderaft-cp1-err-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("cp","dashboard-api:/data/vault.enc",(Join-Path $vaultBak "dashboard-vault.enc"))) `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $cp1Out `
                -RedirectStandardError  $cp1Err `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -Path $cp1Out,$cp1Err -ErrorAction SilentlyContinue
            $cp2Out = Join-Path $env:TEMP "coderaft-cp2-out-$(Get-Random).log"
            $cp2Err = Join-Path $env:TEMP "coderaft-cp2-err-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("cp","dashboard-api:/data/admin_token",(Join-Path $vaultBak "admin_token"))) `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $cp2Out `
                -RedirectStandardError  $cp2Err `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -Path $cp2Out,$cp2Err -ErrorAction SilentlyContinue
        }
    } catch { }
    Write-Host "  ✓ Pre-flight backup complete"

    # Migration log (used by all phases — captures docker / openssl stdout+stderr).
    $migrationLog = Join-Path $vaultBak "migration.log"
    "[$(Get-Date -Format o)] migration started" | Out-File -FilePath $migrationLog -Encoding utf8

    # Rollback helper
    function Invoke-VaultMigrationRollback {
        param([string]$Reason)
        Write-Host "  ✗ Vault migration failed: $Reason — rolling back..." -ForegroundColor Red
        try {
            # B20 (2026-06-08): all docker commands in rollback helper → Start-Process
            $rbDownOut = Join-Path $env:TEMP "coderaft-rbdown-out-$(Get-Random).log"
            $rbDownErr = Join-Path $env:TEMP "coderaft-rbdown-err-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("down")) `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $rbDownOut `
                -RedirectStandardError  $rbDownErr `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -Path $rbDownOut,$rbDownErr -ErrorAction SilentlyContinue
        } catch { }
        if (Test-Path (Join-Path $vaultBak "env"))   { Copy-Item (Join-Path $vaultBak "env") $envPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path (Join-Path $vaultBak "env.enc")) { Copy-Item (Join-Path $vaultBak "env.enc") $envEncPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path (Join-Path $vaultBak "age.key")) { Copy-Item (Join-Path $vaultBak "age.key") $ageKeyPath -Force -ErrorAction SilentlyContinue }
        $authSql = Join-Path $vaultBak "auth_config.sql"
        if (Test-Path $authSql) {
            try {
                $rbPgOut = Join-Path $env:TEMP "coderaft-rbpg-out-$(Get-Random).log"
                $rbPgErr = Join-Path $env:TEMP "coderaft-rbpg-err-$(Get-Random).log"
                Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("up","-d","postgres")) `
                    -NoNewWindow -Wait `
                    -RedirectStandardOutput $rbPgOut `
                    -RedirectStandardError  $rbPgErr `
                    -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path $rbPgOut,$rbPgErr -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
                # pipe SQL into psql via Start-Process stdin redirect
                $rbPsqlOut = Join-Path $env:TEMP "coderaft-rbpsql-out-$(Get-Random).log"
                $rbPsqlErr = Join-Path $env:TEMP "coderaft-rbpsql-err-$(Get-Random).log"
                Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("exec","-T","postgres","psql","-U","coderaft","coderaft")) `
                    -NoNewWindow -Wait `
                    -RedirectStandardInput  $authSql `
                    -RedirectStandardOutput $rbPsqlOut `
                    -RedirectStandardError  $rbPsqlErr `
                    -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path $rbPsqlOut,$rbPsqlErr -ErrorAction SilentlyContinue
            } catch { }
        }
        try {
            $rbUpOut = Join-Path $env:TEMP "coderaft-rbup-out-$(Get-Random).log"
            $rbUpErr = Join-Path $env:TEMP "coderaft-rbup-err-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("up","-d")) `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $rbUpOut `
                -RedirectStandardError  $rbUpErr `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -Path $rbUpOut,$rbUpErr -ErrorAction SilentlyContinue
        } catch { }
        Write-Host ""
        Write-Host ""
        Write-Host "  Rollback complete. Backup directory: $vaultBak" -ForegroundColor Yellow
        Write-Host "  Legacy secret stores are intact." -ForegroundColor Yellow
        $log = Join-Path $vaultBak "migration.log"
        if (Test-Path $log) {
            Write-Host ""
            Write-Host "  Last 20 lines of migration log:" -ForegroundColor Yellow
            Get-Content -Path $log -Tail 20 | ForEach-Object { Write-Host "    $_" }
            Write-Host ""
            Write-Host "  Full log: $log" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Press any key to acknowledge..." -ForegroundColor Yellow
        if (-not $env:CODERAFT_TEST_MODE) {
            try { [void][System.Console]::ReadKey($true) } catch { Start-Sleep -Seconds 30 }
        }
        return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
    }

    # ── 4c Vault directories (always) ─────────────────────────────────────
    New-Item -ItemType Directory -Force -Path (Join-Path $INSTALL_DIR "vault-keys")   | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $INSTALL_DIR "vault-tls")    | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $INSTALL_DIR "vault-config") | Out-Null

    # AUDIT-SECU-2026-08-04 (Vault H1 follow-up): tracks whether THIS run
    # actually generated fresh vault-keys/vault-tls/vault-config material —
    # used below to decide whether the running container genuinely needs to
    # reload bind-mounted files, instead of always recreating it.
    $vaultFreshBootstrap = $false

    # ── 4c.1 Age master key (ONCE — rotating it would orphan vault.db) ────
    if (-not (Test-Path $vaultAgeKey)) {
        $vaultFreshBootstrap = $true
        Write-Host "  Generating vault master key..."
        $ageKeygen = Get-Command age-keygen -ErrorAction SilentlyContinue
        if (-not $ageKeygen) {
            Write-Host "    age-keygen not on PATH — downloading from GitHub releases..."
            $ageVersion = "v1.2.1"
            $ageArch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
            $ageTmp = Join-Path $env:TEMP "coderaft-age-$(Get-Random)"
            New-Item -ItemType Directory -Force -Path $ageTmp | Out-Null
            $ageZip = Join-Path $ageTmp "age.zip"
            $ageUrl = "https://github.com/FiloSottile/age/releases/download/$ageVersion/age-$ageVersion-windows-$ageArch.zip"
            try {
                Invoke-WebRequest -Uri $ageUrl -OutFile $ageZip -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                Expand-Archive -Path $ageZip -DestinationPath $ageTmp -Force -ErrorAction Stop
                $ageKeygenExe = Get-ChildItem -Path $ageTmp -Filter "age-keygen.exe" -Recurse | Select-Object -First 1
                if (-not $ageKeygenExe) { Invoke-VaultMigrationRollback "age-keygen.exe missing in downloaded archive"; return }
                $ageKeygen = [pscustomobject]@{ Path = $ageKeygenExe.FullName }
                Write-Host "    ✓ age-keygen downloaded to $($ageKeygen.Path)"
            } catch {
                Invoke-VaultMigrationRollback "age-keygen download failed: $($_.Exception.Message)"; return
            }
        }

        # B20 (2026-06-08): `& age-keygen -o ... 2>$null` → NativeCommandError PS 5.1
        $ageGenStderr = Join-Path $env:TEMP "coderaft-agegen-err-$(Get-Random).txt"
        $ageGenProc = Start-Process -FilePath $ageKeygen.Path `
            -ArgumentList @("-o", $vaultAgeKey) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardError $ageGenStderr `
            -ErrorAction SilentlyContinue
        Remove-Item -Path $ageGenStderr -ErrorAction SilentlyContinue
        if (-not (Test-Path $vaultAgeKey)) { Invoke-VaultMigrationRollback "age-keygen failed"; return }

        $recoveryPhrase = ""
        if ($env:CODERAFT_TEST_MODE -ne "1") {
            $privKey = (Get-Content $vaultAgeKey | Where-Object { $_ -match '^AGE-SECRET-KEY-' } | Select-Object -First 1)
            if ($privKey) {
                try {
                    # B20 (2026-06-08): `& docker run --rm -i ... 2>$null` pipes stdin
                    # AND surfaces docker stderr as NativeCommandError in PS 5.1.
                    $mnKeyFile  = Join-Path $env:TEMP "coderaft-mn-key-$(Get-Random).txt"
                    $mnOut      = Join-Path $env:TEMP "coderaft-mn-out-$(Get-Random).txt"
                    $mnErr      = Join-Path $env:TEMP "coderaft-mn-err-$(Get-Random).txt"
                    [System.IO.File]::WriteAllText($mnKeyFile, "$privKey`n", [System.Text.UTF8Encoding]::new($false))
                    Start-Process -FilePath "docker" -ArgumentList @(
                        "run","--rm",
                        "-v","${mnKeyFile}:/input.key:ro",
                        "ghcr.io/liamj74/coderaft-vault:latest",
                        "-mnemonic-from-key","/input.key"
                    ) -NoNewWindow -Wait `
                        -RedirectStandardOutput $mnOut `
                        -RedirectStandardError  $mnErr `
                        -ErrorAction SilentlyContinue | Out-Null
                    if (Test-Path $mnOut) {
                        $recoveryPhrase = ((Get-Content $mnOut -ErrorAction SilentlyContinue) -join "").Trim()
                    }
                    Remove-Item -Path $mnKeyFile,$mnOut,$mnErr -ErrorAction SilentlyContinue
                } catch { $recoveryPhrase = "" }
            }
        }
        if (-not $recoveryPhrase) {
            $pubKey = (Get-Content $vaultAgeKey | Where-Object { $_ -match '# public key:' } | Select-Object -First 1) -replace '.*# public key:\s*', ''
            $recoveryPhrase = "[FALLBACK] fingerprint: $pubKey"
        }

        Write-Host ""
        Write-Host "  +==================================================================+" -ForegroundColor Cyan
        Write-Host "  | *** VAULT RECOVERY PHRASE — WRITE THIS DOWN NOW ***             |" -ForegroundColor Cyan
        Write-Host "  +==================================================================+" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    $recoveryPhrase" -ForegroundColor White
        Write-Host ""

        if ($env:CODERAFT_TEST_MODE -eq "1") {
            $reply = "CONFIRMED"
        } else {
            $reply = Read-Host "  Type CONFIRMED (all caps) once you have securely stored the phrase"
        }
        if ($reply -ne "CONFIRMED") { Invoke-VaultMigrationRollback "operator did not confirm recovery phrase"; return }
        Write-Host "  ✓ Recovery phrase confirmed" -ForegroundColor Green
    } else {
        Write-Host "  ✓ Vault age key already exists — reusing"
    }

    # ── 4c.2 mTLS PKI + config.yaml + acl.yaml (ALWAYS — idempotent) ──────
    # These artefacts cost <1s to regenerate and are always overwritten so a
    # half-bootstrapped vault from a previous failed run is healed on next try.
    # PKI generation runs inside a one-shot alpine container (always has openssl
    # baked in) — no host dependency on openssl/Git for Windows.
    Write-Host "  Bootstrapping vault TLS PKI + config (via alpine container)..."
    $tlsDir = Join-Path $INSTALL_DIR "vault-tls"
    $cfgDir = Join-Path $INSTALL_DIR "vault-config"

    # Single shell script run inside alpine that produces all certs at once.
    # Uses /work as the bind-mounted vault-tls directory.
    $opensslScript = @'
set -e
apk add --no-cache openssl >/dev/null
cd /work
# CA
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
    -keyout client-ca.key -out client-ca.crt \
    -subj "/CN=coderaft-vault-ca" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
# Server cert
openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout vault.key -out vault.csr \
    -subj "/CN=coderaft-vault" 2>/dev/null
cat > /tmp/server.ext <<EOF
subjectAltName=DNS:coderaft-vault,DNS:localhost,IP:127.0.0.1
basicConstraints=CA:FALSE
EOF
openssl x509 -req -days 3650 -sha256 \
    -in vault.csr -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
    -out vault.crt -extfile /tmp/server.ext 2>/dev/null
rm -f vault.csr /tmp/server.ext
# Per-product client certs
for pair in "dashboard-api:dashboard-api.coderaft.local" \
            "entraguard:entraguard.coderaft.local" \
            "ravenscan:ravenscan.coderaft.local" \
            "redfox:redfox.coderaft.local" \
            "falconone:falconone.coderaft.local" \
            "cve-proxy:cve-proxy.coderaft.local"; do
    name="${pair%%:*}"
    san="${pair##*:}"
    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout "${name}-client.key" -out "${name}-client.csr" \
        -subj "/CN=${san}" 2>/dev/null
    cat > /tmp/client.ext <<EOF
subjectAltName=DNS:${san}
basicConstraints=CA:FALSE
EOF
    openssl x509 -req -days 3650 -sha256 \
        -in "${name}-client.csr" -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
        -out "${name}-client.crt" -extfile /tmp/client.ext 2>/dev/null
    rm -f "${name}-client.csr" /tmp/client.ext
done
chmod 600 *.key 2>/dev/null || true
# falconone-api / coderaft-cve-proxy run distroless nonroot (uid 65532) —
# they CAN'T read files owned by root with mode 600. Loosen to 644 so the
# bind-mounted certs are world-readable inside the container. The private
# key lives on a chmod 700 vault-tls dir anyway, and Docker Desktop's
# Windows/Mac bind-mount already strips POSIX perms, so this only affects
# Linux hosts.
chmod 644 falconone-client.key falconone-client.crt 2>/dev/null || true
chmod 644 cve-proxy-client.key cve-proxy-client.crt 2>/dev/null || true
'@
    # Bind-mount tlsDir into the alpine container at /work and run the script.
    # Use --user to keep file ownership readable on Linux hosts; on Windows/Mac
    # Docker Desktop handles UID translation transparently.
    $absTlsDir = (Resolve-Path -LiteralPath $tlsDir).Path
    # B20 (2026-06-08): `$opensslScript | & docker run --rm -i ... 2>&1` pipes
    # stdin AND surfaces docker stderr as NativeCommandError in PS 5.1.
    # Write the script to a temp file, mount it, run sh against it.
    $opensslScriptFile2 = Join-Path $env:TEMP "coderaft-openssl2-$(Get-Random).sh"
    $opensslScriptLF2 = $opensslScript -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($opensslScriptFile2, $opensslScriptLF2, [System.Text.UTF8Encoding]::new($false))

    # Pre-pull alpine silently
    $mPullOut = Join-Path $env:TEMP "coderaft-mpull-out-$(Get-Random).log"
    $mPullErr = Join-Path $env:TEMP "coderaft-mpull-err-$(Get-Random).log"
    Start-Process -FilePath "docker" -ArgumentList @("pull","alpine:3.20") `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $mPullOut `
        -RedirectStandardError  $mPullErr `
        -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path $mPullOut,$mPullErr -ErrorAction SilentlyContinue

    $mRunOut = Join-Path $env:TEMP "coderaft-mrun-out-$(Get-Random).log"
    $mRunErr = Join-Path $env:TEMP "coderaft-mrun-err-$(Get-Random).log"
    $mRunProc = Start-Process -FilePath "docker" -ArgumentList @(
        "run","--rm",
        "-v","${opensslScriptFile2}:/script.sh:ro",
        "-v","${absTlsDir}:/work",
        "alpine:3.20","sh","/script.sh"
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $mRunOut `
        -RedirectStandardError  $mRunErr `
        -ErrorAction Stop
    if (Test-Path $mRunOut) {
        $mRunContent = Get-Content $mRunOut -ErrorAction SilentlyContinue
        if ($mRunContent) {
            $mRunContent | Tee-Object -FilePath $migrationLog -Append | Out-Host
        }
    }
    Remove-Item -Path $mRunOut,$mRunErr,$opensslScriptFile2 -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $tlsDir "vault.crt"))) {
        Invoke-VaultMigrationRollback "openssl-in-alpine cert generation failed (see $migrationLog)"; return
    }
    $configYaml = @'
server:
  addr: "0.0.0.0:8200"
  tls_cert: "/tls/vault.crt"
  tls_key:  "/tls/vault.key"
  client_ca: "/tls/client-ca.crt"
storage:
  path: "/data/vault.db"
keys:
  age_key_path: "/keys/age.key"
audit:
  log_path: "/data/audit.log"
acl_path: "/etc/coderaft-vault/acl.yaml"
'@
    [System.IO.File]::WriteAllText((Join-Path $cfgDir "config.yaml"), $configYaml, [System.Text.UTF8Encoding]::new($false))
    $aclYaml = @'
clients:
  - name: dashboard-api
    cert_san: "dashboard-api.coderaft.local"
    permissions: ["*"]
  - name: entraguard
    cert_san: "entraguard.coderaft.local"
    permissions: ["read:azure_*","read:license_key","read:entraguard_*","read:platform/identity/oidc"]
  - name: ravenscan
    cert_san: "ravenscan.coderaft.local"
    permissions: ["read:ravenscan_*","read:neo4j_*","read:license_key","read:platform/identity/oidc"]
  - name: redfox
    cert_san: "redfox.coderaft.local"
    permissions: ["read:redfox_*","read:license_key","read:platform/identity/oidc","read:platform/identity/graph-tools","read:redfox/connections/*","write:redfox/connections/*","delete:redfox/connections/*","read:redfox/k8s/*","write:redfox/k8s/*","delete:redfox/k8s/*"]
  - name: falconone
    cert_san: "falconone.coderaft.local"
    permissions: ["read:license_key","read:falconone_*","read:platform/identity/oidc","sign:falconone_agent_cert","read:falconone/nvd_api_key","read:falconone/audit_hmac_key","write:falconone/audit_hmac_key","read:falconone/pki/agents-ca/cert","read:pki/falconone-agents-ca*","write:pki/falconone-agents-ca*","read:falconone/scripts_ca*","write:falconone/scripts_ca*"]
  - name: cve-proxy
    cert_san: "cve-proxy.coderaft.local"
    permissions: ["read:cve-proxy/*", "write:cve-proxy/*"]
'@
    [System.IO.File]::WriteAllText((Join-Path $cfgDir "acl.yaml"), $aclYaml, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Vault TLS PKI + config written"

    # ── FalconOne relay signal-server key (mint-on-boot pattern) ──────────
    # falconone-relay expects /keys/signal-server.key mounted from
    # certs/falconone-signal-server.key on the host. If the host path is
    # absent, Docker creates a DIRECTORY at the mount source → the relay
    # reads it as a directory → fatal "signal server key: is a directory".
    # Pre-create an empty file so Docker mounts it as a regular file and
    # the relay can mint the Ed25519 key inline on first boot (per its
    # own commentary in server.js line 1515).
    $foCertsDir = Join-Path $INSTALL_DIR "certs"
    New-Item -ItemType Directory -Force -Path $foCertsDir | Out-Null
    $foSignalKey = Join-Path $foCertsDir "falconone-signal-server.key"
    if (Test-Path $foSignalKey -PathType Container) {
        Remove-Item -LiteralPath $foSignalKey -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $foSignalKey -PathType Leaf)) {
        New-Item -ItemType File -Force -Path $foSignalKey | Out-Null
    }

    # ── FalconOne agents mTLS PKI (falconone-tls/) — bug #170 ──────────────
    # Distinct CA from the vault client PKI: the "agents-ca" here signs the
    # cert presented by falconone-api on :8443 to its own Windows agents,
    # NOT vault clients. See Invoke-FalconOneTlsBootstrap definition above
    # for the extended-SAN + self-heal logic (this call covers first-time
    # provisioning; the unconditional call after this migration block covers
    # already-migrated installs).
    Write-Host "  Bootstrapping FalconOne agents PKI (via alpine container)..."
    Invoke-FalconOneTlsBootstrap -InstallDir $INSTALL_DIR

    # ── 4d Pull and start vault ────────────────────────────────────────────
    if ($env:CODERAFT_TEST_FAIL -eq "4d") { Invoke-VaultMigrationRollback "injected test failure at 4d"; return }

    # All docker output (stdout + stderr) is logged to migration.log inside the
    # backup dir AND streamed to the console. No more silent failures.
    "[$(Get-Date -Format o)] Phase 4d — pull + start vault" | Out-File -FilePath $migrationLog -Append -Encoding utf8

    # ── 4d.1 — Compose patch ───────────────────────────────────────────────
    # Existing installs were generated by an older install.{sh,ps1} that did
    # not know about the vault service. We add it via a sidecar override file
    # docker-compose.vault.yml. This way we never rewrite the user's main
    # docker-compose.yml; compose loads main + override additively.
    $vaultOverride = Join-Path $INSTALL_DIR "docker-compose.vault.yml"

    # B-VAULT-OVERRIDE-DUP (2026-06-10): install.ps1 already writes the full
    # `coderaft-vault:` service in the main docker-compose.yml. If we also load
    # a second file that *redefines* the same service, compose v2 merges the
    # two and concatenates `security_opt` → `[no-new-privileges:true,
    # no-new-privileges:true]` → validation error "items at 0 and 1 are equal".
    # Detect this case and avoid loading the override entirely.
    $mainCompose = Join-Path $INSTALL_DIR "docker-compose.yml"
    $vaultInMain = $false
    if (Test-Path $mainCompose) {
        $vaultInMain = (Select-String -Path $mainCompose -Pattern '^\s*coderaft-vault:\s*$' -Quiet -ErrorAction SilentlyContinue)
    }

    if ($vaultInMain) {
        # Stale override from older script versions still hangs around and
        # causes the duplicate-merge bug above. Back it up out of the way so
        # `docker compose` no longer auto-picks it up.
        if (Test-Path $vaultOverride) {
            $vaultOverrideBak = "$vaultOverride.bak"
            Move-Item -Force -LiteralPath $vaultOverride -Destination $vaultOverrideBak -ErrorAction SilentlyContinue
            "[$(Get-Date -Format o)] coderaft-vault is in docker-compose.yml — moved override to $vaultOverrideBak" | Out-File -FilePath $migrationLog -Append -Encoding utf8
        }
    } elseif (-not (Test-Path $vaultOverride)) {
        Write-Host "  Writing docker-compose.vault.yml override..."
        $vaultYaml = @'
# Generated by update.ps1 vault migration. Do not edit by hand — re-running
# the oneliner overwrites this file.
networks:
  coderaft-vault-net:
    internal: true

volumes:
  vault_data:

services:
  coderaft-vault:
    image: ghcr.io/liamj74/coderaft-vault:latest
    # Run as root so the container can:
    #   - write to the Docker-managed /data volume (SQLite + audit log)
    #   - read /tls/*.key files (mode 0600 from openssl)
    # Effective security stays equivalent to nonroot because we drop ALL
    # capabilities AND set no-new-privileges. This is a standard hardening
    # pattern (root-with-no-caps), not a security regression.
    user: "0:0"
    networks:
      - coderaft-vault-net
    volumes:
      - vault_data:/data
      - ./vault-keys:/keys:ro
      - ./vault-tls:/tls:ro
      - ./vault-config:/etc/coderaft-vault:ro
    healthcheck:
      test: ["CMD", "/coderaft-vault", "-health-check"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    restart: unless-stopped
'@
        [System.IO.File]::WriteAllText($vaultOverride, $vaultYaml, [System.Text.UTF8Encoding]::new($false))
        "[$(Get-Date -Format o)] wrote $vaultOverride" | Out-File -FilePath $migrationLog -Append -Encoding utf8
    }

    # Compose args used for vault-related calls. If `coderaft-vault:` is
    # already defined in the main file (current install.ps1 always does this),
    # we MUST NOT load the override too — see B-VAULT-OVERRIDE-DUP above.
    if ($vaultInMain) {
        $vaultComposeArgs = @("-f", "docker-compose.yml")
    } else {
        $vaultComposeArgs = @("-f", "docker-compose.yml", "-f", "docker-compose.vault.yml")
    }
    # Task #150: both env files, always explicit (see $ComposeEnvArgs above).
    $vaultComposeArgs = $vaultComposeArgs + $ComposeEnvArgs

    if ($env:CODERAFT_TEST_MODE -ne "1") {
        Write-Host "  Pulling vault image..."
        # B20 (2026-06-08): `& docker pull ... 2>&1` → NativeCommandError PS 5.1
        $vPullOut = Join-Path $env:TEMP "coderaft-vpull-out-$(Get-Random).log"
        $vPullErr = Join-Path $env:TEMP "coderaft-vpull-err-$(Get-Random).log"
        $vPullProc = Start-Process -FilePath "docker" -ArgumentList @("pull","ghcr.io/liamj74/coderaft-vault:latest") `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $vPullOut `
            -RedirectStandardError  $vPullErr `
            -ErrorAction SilentlyContinue
        if (Test-Path $vPullOut) { Get-Content $vPullOut -ErrorAction SilentlyContinue | Tee-Object -FilePath $migrationLog -Append | Out-Host }
        Remove-Item -Path $vPullOut,$vPullErr -ErrorAction SilentlyContinue
        if ($vPullProc.ExitCode -ne 0) { Invoke-VaultMigrationRollback "docker pull failed (see $migrationLog)"; return }
    }

    Write-Host "  Starting vault container..."
    Push-Location $INSTALL_DIR -ErrorAction Stop

    # AUDIT-SECU-2026-08-04 (Vault H1 follow-up — reseal-on-rerun bug): the
    # stop+rm+up dance below exists so a genuinely NEW image or
    # freshly-bootstrapped cert/config (4c above) gets loaded — --force-recreate
    # alone has been observed to leave the container "Running" on Docker
    # Desktop Windows with stale certs in memory. It used to run
    # UNCONDITIONALLY every time this block executed (i.e. every re-run of
    # update.ps1 while the .migrated sentinel is missing). Since the vault's
    # seal state lives ONLY in the running process's memory (no persistent
    # "unsealed" flag — the whole point of the H1 model), recreating an
    # already-running, already-unsealed container reseals it as a pure side
    # effect, BEFORE the seal-state check below ever runs — an operator who
    # dutifully runs the real unseal ceremony and re-runs this script would
    # see it reseal itself and never converge. Recreate ONLY when there is an
    # actual reason to: it isn't running yet, this run just bootstrapped
    # fresh keys/certs/config, or the just-pulled image differs from the one
    # the running container was started from. Otherwise leave a running
    # vault exactly as it is — it may already have been unsealed since the
    # last run.
    # B20 (2026-06-08): all docker calls via Start-Process to avoid NativeCommandError PS 5.1
    function _VaultDockerCapture {
        param([string[]]$ArgList)
        $o = Join-Path $env:TEMP "coderaft-vdc-out-$(Get-Random).log"
        $e = Join-Path $env:TEMP "coderaft-vdc-err-$(Get-Random).log"
        Start-Process -FilePath "docker" -ArgumentList $ArgList `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $o -RedirectStandardError $e `
            -ErrorAction SilentlyContinue | Out-Null
        $result = ""
        if (Test-Path $o) { $result = ((Get-Content $o -ErrorAction SilentlyContinue) | Select-Object -First 1) }
        Remove-Item -Path $o,$e -ErrorAction SilentlyContinue
        if ($result) { return $result.Trim() }
        return ""
    }

    $vaultImageRef = "ghcr.io/liamj74/coderaft-vault:latest"
    $vaultCid = _VaultDockerCapture (@("compose") + $vaultComposeArgs + @("ps","-q","coderaft-vault"))
    $vaultAlreadyRunning = $false
    $vaultRunningImageId = ""
    if ($vaultCid) {
        $runState = _VaultDockerCapture @("inspect", $vaultCid, "--format", "{{.State.Running}}")
        if ($runState -eq "true") { $vaultAlreadyRunning = $true }
        $vaultRunningImageId = _VaultDockerCapture @("inspect", $vaultCid, "--format", "{{.Image}}")
    }
    $vaultPulledImageId = _VaultDockerCapture @("image", "inspect", $vaultImageRef, "--format", "{{.Id}}")

    $vaultNeedsRecreate = $true
    if ($vaultAlreadyRunning -and (-not $vaultFreshBootstrap) -and $vaultRunningImageId -and $vaultPulledImageId -and ($vaultRunningImageId -eq $vaultPulledImageId)) {
        $vaultNeedsRecreate = $false
    }
    "[$(Get-Date -Format o)] recreate decision: alreadyRunning=$vaultAlreadyRunning freshBootstrap=$vaultFreshBootstrap runningImage=$vaultRunningImageId pulledImage=$vaultPulledImageId needsRecreate=$vaultNeedsRecreate" | Out-File -FilePath $migrationLog -Append -Encoding utf8

    $upExit = 0
    if ($vaultNeedsRecreate) {
        $vStopOut = Join-Path $env:TEMP "coderaft-vstop-out-$(Get-Random).log"
        $vStopErr = Join-Path $env:TEMP "coderaft-vstop-err-$(Get-Random).log"
        Start-Process -FilePath "docker" -ArgumentList (@("compose") + $vaultComposeArgs + @("stop","coderaft-vault")) `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $vStopOut `
            -RedirectStandardError  $vStopErr `
            -ErrorAction SilentlyContinue | Out-Null
        if (Test-Path $vStopOut) { Get-Content $vStopOut -ErrorAction SilentlyContinue | Tee-Object -FilePath $migrationLog -Append | Out-Null }
        Remove-Item -Path $vStopOut,$vStopErr -ErrorAction SilentlyContinue

        $vRmOut = Join-Path $env:TEMP "coderaft-vrm-out-$(Get-Random).log"
        $vRmErr = Join-Path $env:TEMP "coderaft-vrm-err-$(Get-Random).log"
        Start-Process -FilePath "docker" -ArgumentList (@("compose") + $vaultComposeArgs + @("rm","-f","coderaft-vault")) `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $vRmOut `
            -RedirectStandardError  $vRmErr `
            -ErrorAction SilentlyContinue | Out-Null
        if (Test-Path $vRmOut) { Get-Content $vRmOut -ErrorAction SilentlyContinue | Tee-Object -FilePath $migrationLog -Append | Out-Null }
        Remove-Item -Path $vRmOut,$vRmErr -ErrorAction SilentlyContinue

        $vUpOut = Join-Path $env:TEMP "coderaft-vup-out-$(Get-Random).log"
        $vUpErr = Join-Path $env:TEMP "coderaft-vup-err-$(Get-Random).log"
        $vUpProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $vaultComposeArgs + @("up","-d","coderaft-vault")) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $vUpOut `
            -RedirectStandardError  $vUpErr `
            -ErrorAction Stop
        if (Test-Path $vUpOut) { Get-Content $vUpOut -ErrorAction SilentlyContinue | Tee-Object -FilePath $migrationLog -Append | Out-Host }
        $upExit = $vUpProc.ExitCode
        if ($upExit -ne 0 -and (Test-Path $vUpErr)) {
            "[$(Get-Date -Format o)] docker compose up STDERR:" | Out-File -FilePath $migrationLog -Append -Encoding utf8
            Get-Content $vUpErr -ErrorAction SilentlyContinue | Tee-Object -FilePath $migrationLog -Append | Out-Host
            $logsOut = Join-Path $env:TEMP "coderaft-vlogs-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList @("logs","--tail","80","coderaft-vault") `
                -NoNewWindow -Wait -RedirectStandardOutput $logsOut -RedirectStandardError $logsOut `
                -ErrorAction SilentlyContinue | Out-Null
            if (Test-Path $logsOut) {
                "[$(Get-Date -Format o)] coderaft-vault container logs (last 80):" | Out-File -FilePath $migrationLog -Append -Encoding utf8
                Get-Content $logsOut -ErrorAction SilentlyContinue | Tee-Object -FilePath $migrationLog -Append | Out-Host
                Remove-Item -Path $logsOut -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -Path $vUpOut,$vUpErr -ErrorAction SilentlyContinue
    } else {
        Write-Host "  ✓ coderaft-vault already running with the current image — leaving it untouched (avoids resealing an already-unsealed vault)"
    }
    Pop-Location -ErrorAction SilentlyContinue
    if ($upExit -ne 0) { Invoke-VaultMigrationRollback "docker compose up coderaft-vault failed (see $migrationLog)"; return }

    # The vault image is distroless — no shell, no wget. We can't `docker
    # compose exec coderaft-vault sh ...`. Use a curlimages/curl sidecar on
    # the same docker network with the dashboard-api client cert mounted.
    $absTlsDir = (Resolve-Path -LiteralPath $tlsDir).Path
    # Detect compose project name from the running vault container — it
    # determines the network name (<project>_coderaft-vault-net).
    # B20-inspect (2026-06-08): `--format '{{ index ... "..." }}'` → quote mangling in PS 5.1
    $inspFmt2   = '{{ index .Config.Labels "com.docker.compose.project" }}'
    $inspOut2   = Join-Path $env:TEMP "coderaft-insp2-out-$(Get-Random).log"
    $inspErr2   = Join-Path $env:TEMP "coderaft-insp2-err-$(Get-Random).log"
    $inspProc2 = Start-Process -FilePath "docker" -ArgumentList @("inspect","coderaft-coderaft-vault-1","--format",$inspFmt2) `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $inspOut2 `
        -RedirectStandardError  $inspErr2 `
        -ErrorAction SilentlyContinue
    if ($inspProc2 -and -not $inspProc2.WaitForExit(60000)) {   # 60s
        Write-Host "  ⚠  Docker command timed out after 60s: docker inspect coderaft-coderaft-vault-1" -ForegroundColor Yellow
        try { $inspProc2.Kill() } catch {}
    }
    $vaultProject = ((Get-Content $inspOut2 -ErrorAction SilentlyContinue) -join "").Trim()
    Remove-Item -Path $inspOut2,$inspErr2 -ErrorAction SilentlyContinue
    if (-not $vaultProject) { $vaultProject = "coderaft" }
    $vaultNetwork = "${vaultProject}_coderaft-vault-net"

    function Invoke-VaultCurl {
        param([string]$Method, [string]$Path, [string]$JsonBody = "")
        # B20 (2026-06-08): `& docker @dockerArgs 2>&1` surfaces stderr as
        # NativeCommandError in PS 5.1. Use Start-Process + split temp files.
        #
        # B-UNSEAL-BODY (2026-06-09): passing the JSON body inline via
        # `-d $JsonBody` argument got mangled by the PS → docker.exe → curl
        # arg chain — the {, ", } in the JSON were either stripped or
        # double-escaped, and vault replied {"error":"invalid request body"}.
        # Write the body to a temp file and feed it via stdin (--data-binary @-
        # in curl), routed through Start-Process -RedirectStandardInput. This
        # is quote-safe for any JSON payload. (Patched in install.ps1 the same
        # day; never propagated here — bug surfaced again on 2026-06-11.)
        $dockerArgs = @("run", "--rm")
        if ($JsonBody) { $dockerArgs += @("-i") }
        $dockerArgs += @(
            "--user", "0:0",
            "--network", $vaultNetwork,
            "-v", "${absTlsDir}:/tls:ro",
            "curlimages/curl:latest",
            "--cert", "/tls/dashboard-api-client.crt",
            "--key",  "/tls/dashboard-api-client.key",
            "--cacert", "/tls/client-ca.crt",
            "-sS", "-X", $Method,
            "https://coderaft-vault:8200$Path"
        )
        $bodyFile = $null
        if ($JsonBody) {
            $bodyFile = Join-Path $env:TEMP "coderaft-vc-body-$(Get-Random).json"
            [System.IO.File]::WriteAllText($bodyFile, $JsonBody, [System.Text.UTF8Encoding]::new($false))
            $dockerArgs += @("-H", "Content-Type: application/json", "--data-binary", "@-")
        }
        $curlOut = Join-Path $env:TEMP "coderaft-vc-out-$(Get-Random).log"
        $curlErr = Join-Path $env:TEMP "coderaft-vc-err-$(Get-Random).log"
        $spArgs = @{
            FilePath               = "docker"
            ArgumentList           = $dockerArgs
            NoNewWindow            = $true
            Wait                   = $true
            RedirectStandardOutput = $curlOut
            RedirectStandardError  = $curlErr
            ErrorAction            = "SilentlyContinue"
        }
        if ($bodyFile) { $spArgs['RedirectStandardInput'] = $bodyFile }
        Start-Process @spArgs | Out-Null
        $body = ""
        if (Test-Path $curlOut) { $body = ((Get-Content $curlOut -ErrorAction SilentlyContinue) -join "") }
        Remove-Item -Path $curlOut,$curlErr -ErrorAction SilentlyContinue
        if ($bodyFile) { Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue }
        return $body
    }

    # Wait for vault to be reachable (any TLS handshake completes, even sealed)
    Write-Host "  Waiting for vault to be reachable..."
    $vaultReachable = $false
    $lastSealed = $null
    for ($vi = 1; $vi -le 20; $vi++) {
        try {
            $health = Invoke-VaultCurl -Method "GET" -Path "/v1/health"
            "[$(Get-Date -Format o)] reachability attempt $vi → $health" | Out-File -FilePath $migrationLog -Append -Encoding utf8
            if ($health -match '"sealed":(true|false)') {
                $vaultReachable = $true
                $lastSealed = $Matches[1]
                break
            }
        } catch {
            "[$(Get-Date -Format o)] reachability attempt $vi → exception: $($_.Exception.Message)" | Out-File -FilePath $migrationLog -Append -Encoding utf8
        }
        if ($vi % 3 -eq 0) { Write-Host "    ... still waiting (attempt $vi/20)" }
        Start-Sleep -Seconds 3
    }
    if (-not $vaultReachable) {
        Write-Host "  Last health probe output (see $migrationLog for full log):" -ForegroundColor Yellow
        Get-Content -Path $migrationLog -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        Invoke-VaultMigrationRollback "coderaft-vault did not respond to TLS probes"; return
    }

    # AUDIT-SECU-2026-08-04 (Vault H1): coderaft-vault no longer auto-unseals
    # and no longer treats vault-keys\age.key as a submittable "share" — it
    # requires a REAL Shamir ceremony (POST /v1/init once, then POST
    # /v1/unseal with a threshold of the returned shares) that NO unattended
    # script can complete, by design. A sealed vault at this point is
    # EXPECTED, not a migration failure — it must NOT roll back (that would
    # tear down a perfectly good, already-backed-up-for, in-progress
    # migration just because a human hasn't run the ceremony yet). Secret
    # migration (below) genuinely cannot proceed while sealed (every
    # /v1/secret/set call would fail), so this run stops here — no
    # .migrated sentinel is written, so a future update.ps1 run retries once
    # an operator has unsealed it.
    if ($lastSealed -eq "true") {
        Write-Host ""
        Write-Host "  ────────────────────────────────────────────────────────────────" -ForegroundColor Yellow
        Write-Host "  Vault is SEALED. This is expected — Coderaft Vault requires a" -ForegroundColor Yellow
        Write-Host "  real, human, multi-operator Shamir ceremony (default: 3 of 5" -ForegroundColor Yellow
        Write-Host "  shares) before it will hold or serve ANY secret. No script can" -ForegroundColor Yellow
        Write-Host "  complete this unattended, by design." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Legacy secrets have NOT been migrated yet (this requires an"
        Write-Host "  unsealed vault) — they remain safely in their existing stores"
        Write-Host "  (.env / postgres / etc.), untouched. An operator must run:"
        Write-Host ""
        Write-Host "    # 1) ONE TIME ONLY per vault (skip if already run before):"
        Write-Host "    docker run --rm --user 0:0 --network $vaultNetwork ``"
        Write-Host "      -v `"$absTlsDir`:/tls:ro`" curlimages/curl:latest ``"
        Write-Host "      --cert /tls/dashboard-api-client.crt --key /tls/dashboard-api-client.key ``"
        Write-Host "      --cacert /tls/client-ca.crt -sS -X POST https://coderaft-vault:8200/v1/init"
        Write-Host "    # -> WRITE DOWN the returned shares, one per operator, then:"
        Write-Host ""
        Write-Host "    # 2) EVERY time the vault starts sealed (every restart/reboot):"
        Write-Host "    docker run --rm --user 0:0 --network $vaultNetwork ``"
        Write-Host "      -v `"$absTlsDir`:/tls:ro`" curlimages/curl:latest ``"
        Write-Host "      --cert /tls/dashboard-api-client.crt --key /tls/dashboard-api-client.key ``"
        Write-Host "      --cacert /tls/client-ca.crt -sS -X POST https://coderaft-vault:8200/v1/unseal ``"
        Write-Host "      -H 'Content-Type: application/json' -d '{`"shares`":[`"<share1>`",`"<share2>`",`"<share3>`"]}'"
        Write-Host ""
        Write-Host "  Then re-run this update script to finish migrating secrets into it."
        Write-Host "  ────────────────────────────────────────────────────────────────" -ForegroundColor Yellow
        Write-Host ""
        "[$(Get-Date -Format o)] vault sealed after start — stopping migration here (no rollback), operator ceremony required" | Out-File -FilePath $migrationLog -Append -Encoding utf8
        return
    }
    Write-Host "  ✓ coderaft-vault is already unsealed"

    # ── 4e Migrate secrets ────────────────────────────────────────────────
    if ($env:CODERAFT_TEST_FAIL -eq "4e") { Invoke-VaultMigrationRollback "injected test failure at 4e"; return }

    function Set-VaultSecret {
        param([string]$Name, [string]$Value)
        if (-not $Value) { return $true }
        $body = @{ name = $Name; value = $Value } | ConvertTo-Json -Compress
        $resp = Invoke-VaultCurl -Method "POST" -Path "/v1/secret/set" -JsonBody $body
        return ($resp -match '"ok"\s*:\s*true')
    }
    function Get-VaultSecret {
        param([string]$Name)
        $body = @{ name = $Name } | ConvertTo-Json -Compress
        $resp = Invoke-VaultCurl -Method "POST" -Path "/v1/secret/get" -JsonBody $body
        if ($resp -match '"value"\s*:\s*"([^"]*)"') { return $Matches[1] }
        return ""
    }
    function Get-EnvVal {
        param([string]$Key)
        $line = (Get-Content $envPath -ErrorAction SilentlyContinue | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))=(.+)$" } | Select-Object -First 1)
        if ($line -match "^\s*$([regex]::Escape($Key))=(.+)$") { return $Matches[1].Trim().Trim('"').Trim("'") }
        return ""
    }

    Write-Host "  Migrating secrets to vault..."
    $migrationOk = $true

    # Task #150 (2026-07-31): LICENSE_KEY / REDFOX_LICENSE_KEY / RAVENSCAN_LICENSE_KEY
    # migration removed. All three are dead since #166 (2026-07-28): the license
    # no longer lives in .env/docker-compose at all — dashboard-api reads it
    # exclusively from Coderaft Vault (hydrateLicenseFromVault()), and each
    # product now pulls the resolved key live from dashboard-api's internal
    # endpoint instead of a boot-time env var (confirmed for Ravenscan in
    # /Users/liam/secaudit/internal/license/dashboard_client.go +
    # internal/cli/serve.go). Migrating an already-dead value serves no purpose.
    # Task #149 (2026-07-31): 7 keys added to close the gap identified in
    # SECRETS-FILE-MOUNTS-PLAN-2026-07-31.md §5.6 — real secrets that were NOT
    # migrated here, i.e. NOT protected by dashboard-api's regeneration path
    # (generateOverrideToDir(), now Coderaft-Vault-backed via #149), only ever
    # preserved verbatim if a copy already existed on disk.
    $secretMap = @(
        @("POSTGRES_PASSWORD",        "postgres_password"),
        @("REDIS_PASSWORD",           "redis_password"),
        @("DASHBOARD_SECRET",         "dashboard_secret"),
        @("NEO4J_PASSWORD",           "neo4j_password"),
        @("RAVENSCAN_SECRET_KEY",     "ravenscan_secret_key"),
        @("RAVENSCAN_CAPTURE_TOKEN",  "ravenscan_capture_token"),
        @("REDFOX_MASTER_PASSPHRASE", "redfox_master_passphrase"),
        @("REDFOX_JWT_PRIVATE_KEY",   "redfox_jwt_private_key"),
        @("REDFOX_JWT_PUBLIC_KEY",    "redfox_jwt_public_key"),
        @("REDFOX_GW_SESSION_SECRET", "redfox_gw_session_secret"),
        @("TENANT_ENCRYPTION_KEY",     "tenant_encryption_key"),
        @("AZURE_CLIENT_SECRET",       "azure_client_secret"),
        @("REDFOX_JWT_SECRET",         "redfox_jwt_secret"),
        @("REDFOX_OIDC_CLIENT_SECRET", "redfox_oidc_client_secret"),
        @("XPRODUCT_INTERNAL_TOKEN",   "xproduct_internal_token"),
        @("ADMIN_TOKEN",               "admin_token"),
        @("CLOUDFLARE_TUNNEL_TOKEN",   "cloudflare_tunnel_token")
    )
    foreach ($pair in $secretMap) {
        $envKey = $pair[0]; $vaultKey = $pair[1]
        $val = Get-EnvVal -Key $envKey
        if ($val) {
            if (Set-VaultSecret -Name $vaultKey -Value $val) {
                $rb = Get-VaultSecret -Name $vaultKey
                if ($rb -ne $val) {
                    $migrationOk = $false
                    Write-Host "  ✗ Round-trip verify failed: $vaultKey" -ForegroundColor Red
                }
            } else {
                $migrationOk = $false
                Write-Host "  ✗ Failed to migrate: $vaultKey" -ForegroundColor Red
            }
        }
    }
    if (-not $migrationOk) { Invoke-VaultMigrationRollback "secret migration verify failed"; return }
    Write-Host "  ✓ Secrets migrated and verified"

    # ── 4g Sentinel ───────────────────────────────────────────────────────
    # Distroless vault has no shell, so we can't touch /data/.migrated from inside.
    # The host-side sentinel below is sufficient — the migration block's idempotency
    # check uses it (see _vault_migration_needed at top of vault block).
    $hostSentinelDir = Join-Path $INSTALL_DIR "vault-data"
    New-Item -ItemType Directory -Force -Path $hostSentinelDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $hostSentinelDir ".migrated"), (Get-Date -Format o)) | Out-Null
    Write-Host "  ✓ Migration sentinel written"

    # ── 4h Write CODERAFT_VAULT_* vars ───────────────────────────────────
    $envText = [System.IO.File]::ReadAllText($envPath, [System.Text.UTF8Encoding]::new($false))
    foreach ($kv in @(
        "CODERAFT_VAULT_URL=https://coderaft-vault:8200",
        "CODERAFT_VAULT_AZURE=0",
        "CODERAFT_VAULT_LICENSE=0",
        "CODERAFT_VAULT_PRODUCTS=0",
        "CODERAFT_VAULT_JWT=0"
    )) {
        $k = $kv.Split('=')[0]
        if ($envText -notmatch "(?m)^$k=") { $envText = $envText.TrimEnd() + "`n$kv`n" }
    }
    [System.IO.File]::WriteAllText($envPath, $envText, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ CODERAFT_VAULT_* vars written to .env"
    Write-Host ""
    Write-Host "  Vault migration complete."
    Write-Host "  Legacy stores retained for 7-day grace period."
    Write-Host ""
} else {
    Write-Host "  ✓ Vault migration not needed (already done or vault running)"
}

# ── FalconOne mTLS PKI + ACL self-heal (#170 / #172) ─────────────────────────
# Runs unconditionally on EVERY update, independent of the one-time vault
# migration gate above, so already-migrated installs (vaultNeedsMigration =
# $false) still get the extended-SAN falconone-tls cert and any missing ACL
# permissions healed. (2026-08-05) Console only gets one concise phase line —
# every per-product ACL/PKI/cert self-heal detail below goes to $UPDATE_LOG via
# Write-DetailLog instead (see the log-file setup near the top of this script).
Write-Host ""
Write-Host "  Checking vault ACL / PKI provisioning..."
Invoke-FalconOneTlsBootstrap -InstallDir $INSTALL_DIR
Invoke-FalconOneAclSelfHeal -AclPath (Join-Path $INSTALL_DIR "vault-config\acl.yaml")
Invoke-VaultAclLiveSelfHeal -InstallDir $INSTALL_DIR -Name "falconone" -San "falconone.coderaft.local" -Permissions @(
    "read:license_key", "read:falconone_*", "read:platform/identity/oidc",
    "sign:falconone_agent_cert", "read:falconone/nvd_api_key",
    "read:falconone/audit_hmac_key", "write:falconone/audit_hmac_key",
    "read:falconone/pki/agents-ca/cert", "read:pki/falconone-agents-ca*",
    "write:pki/falconone-agents-ca*", "read:falconone/scripts_ca*",
    "write:falconone/scripts_ca*"
)

# ── RedFox connections/k8s vault-backed credentials ACL self-heal ───────────
# Zero-Knowledge Credential Architecture Palier 1 — see Invoke-RedfoxAclSelfHeal
# above. redfox's client cert already exists (provisioned for
# platform/identity/oidc), so no Invoke-VaultClientCertSelfHeal call is needed.
Invoke-RedfoxAclSelfHeal -AclPath (Join-Path $INSTALL_DIR "vault-config\acl.yaml")
Invoke-VaultAclLiveSelfHeal -InstallDir $INSTALL_DIR -Name "redfox" -San "redfox.coderaft.local" -Permissions @(
    "read:license_key", "read:redfox_*", "read:platform/identity/oidc",
    "read:platform/identity/graph-tools", "read:redfox/connections/*",
    "write:redfox/connections/*", "delete:redfox/connections/*",
    "read:redfox/k8s/*", "write:redfox/k8s/*", "delete:redfox/k8s/*"
)

# ── cve-proxy vault client cert + ACL self-heal ──────────────────────────────
# coderaft-cve-proxy is a shared platform sidecar (in front of the central
# coderaft-cve-engine), not tied to any single product license.
Invoke-VaultClientCertSelfHeal -InstallDir $INSTALL_DIR -Name "falconone" -San "falconone.coderaft.local"
Invoke-VaultClientCertSelfHeal -InstallDir $INSTALL_DIR -Name "cve-proxy" -San "cve-proxy.coderaft.local"
Invoke-CveProxyAclSelfHeal -AclPath (Join-Path $INSTALL_DIR "vault-config\acl.yaml")
Invoke-VaultAclLiveSelfHeal -InstallDir $INSTALL_DIR -Name "cve-proxy" -San "cve-proxy.coderaft.local" -Permissions @(
    "read:cve-proxy/*", "write:cve-proxy/*"
)
Write-Host "  ✓ Vault ACL / PKI provisioning OK (detail: $UPDATE_LOG)"

# ── Banking-grade plaintext .env handling ─────────────────────────────────
# B-PLAINTEXT-PURGE (2026-08-04, porting update.sh's 2026-06-14 fix — never
# applied here): this block used to DELETE the plaintext .env once .env.enc
# was confirmed to match. Looks "banking-grade" but breaks the platform:
# $ComposeArgs (defined near the top of this script) has NO --env-file at
# all — docker compose pull/up below rely ENTIRELY on Docker Compose's own
# default auto-load of a plaintext .env in the current directory, which
# does NOT understand .env.enc. Purging it here left POSTGRES_PASSWORD /
# REDIS_PASSWORD / DASHBOARD_SECRET / HOST_PROJECT_DIR empty for the deploy
# steps further down — redis's `--requirepass ${REDIS_PASSWORD} --maxmemory
# 128mb` collapsed into a single malformed `--requirepass --maxmemory
# 128mb` directive and refused to start, taking every dependent service
# down with it. Confirmed live on Liam's Windows deployment 2026-08-04;
# update.sh hit and fixed the IDENTICAL bug on 2026-06-14 but update.ps1
# never got the same fix. The real "no plaintext at rest" goal needs an
# init container or a vault-backed secrets driver (planned in #16 audit
# bancaire). Until that ships, .env stays on disk — ACL-restricted to the
# current user where possible — and .env.enc remains the authoritative
# audit-trail copy.
Write-Host ""
Write-Host "  Banking-grade secret check..."
$envPlain = Join-Path $INSTALL_DIR ".env"
$envEnc   = Join-Path $INSTALL_DIR ".env.enc"
if (Test-Path $envPlain) {
    try {
        $envAcl = Get-Acl $envPlain
        $envAcl.SetAccessRuleProtection($true, $false)
        $envRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            "FullControl", "Allow")
        $envAcl.ResetAccessRule($envRule)
        Set-Acl $envPlain $envAcl -ErrorAction Stop
    } catch {}
    if (Test-Path $envEnc) {
        # ── Auto-finalize (2026-08-05): actually FIX the sops-missing gap ────
        # instead of only proposing it as a manual choice. Previously, when
        # sops was unavailable, this block just printed two options (Dashboard
        # -> Migrate secrets, or `migrate.ps1 -Finalize`) and left the
        # plaintext .env in place forever unless an operator acted. Liam's
        # direction: "il faut vraiment le fixer lors de l'update et pas le
        # proposer." The caution that used to gate this (see the
        # B-PLAINTEXT-PURGE comment above / commit daac49d) was specifically
        # about the PURGE breaking `docker compose` because $ComposeArgs had
        # no --env-file — that is now a solved, separate problem: the "Ensure
        # .env is present + fresh before ANY docker compose call" block further
        # below regenerates .env from .env.enc via sops right before every
        # docker compose invocation, so purging .env here is safe again. This
        # only ever auto-installs sops.exe (same release/URL migrate-to-sops.ps1's
        # documented CLI option B already downloads) and only purges after
        # verifying the decrypted .env.enc byte-for-byte matches (normalized)
        # the plaintext .env — never a blind overwrite in either direction.
        # Age key generation is intentionally NOT auto-healed here: if it's
        # missing, .env.enc was encrypted with a key we no longer have, and
        # generating a NEW one would not decrypt the existing file — that is a
        # real, human-needed recovery scenario, not something safe to script.
        $ageKeyFinalize = if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $INSTALL_DIR ".coderaft-age.key" }
        if (-not (Test-Path $ageKeyFinalize) -and (Test-Path "C:\ProgramData\coderaft\age.key")) {
            $ageKeyFinalize = "C:\ProgramData\coderaft\age.key"
        }
        $sopsFinalizeCmd = Get-Command sops -ErrorAction SilentlyContinue
        if (-not $sopsFinalizeCmd -and (Test-Path $ageKeyFinalize)) {
            try {
                # BUG (2026-08-07, found live on Liam's machine): v3.8.1 was
                # never a real Windows arch fallback — the old
                # Is64BitOperatingSystem check mapped "not 64-bit" to
                # "arm64", which is incoherent (ARM64 IS 64-bit; a genuine
                # 32-bit host would need "386", not arm64) — and v3.8.1 itself
                # is long gone from GitHub releases (404), while the rest of
                # this codebase already standardized on v3.13.1 (F-024,
                # 2026-06-21, newer Go stdlib). Reuse the arch this script
                # already resolved into install-config.env instead of
                # re-deriving it with a separate, wrong heuristic.
                Write-DetailLog "[sops-finalize] sops.exe not found on host — downloading v3.13.1 to finalize automatically"
                $finalizeArch = Get-InstallConfigVar "CODERAFT_HOST_ARCH"
                if ($finalizeArch -notin @("amd64", "arm64")) { $finalizeArch = "amd64" }
                # Verified directly against the real GitHub release assets
                # (2026-08-07): sops's Windows .exe assets have NO ".windows."
                # segment in the filename for this version (unlike the Linux
                # assets, which do) — sops-v3.13.1.amd64.exe /
                # sops-v3.13.1.arm64.exe, confirmed both return HTTP 200.
                $sopsFinalizeUrl = "https://github.com/getsops/sops/releases/download/v3.13.1/sops-v3.13.1.$finalizeArch.exe"
                $sopsFinalizeDst = "C:\Windows\System32\sops.exe"
                Invoke-WebRequest -Uri $sopsFinalizeUrl -OutFile $sopsFinalizeDst -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                $sopsFinalizeCmd = Get-Command sops -ErrorAction SilentlyContinue
                Write-DetailLog "[sops-finalize] sops.exe downloaded to $sopsFinalizeDst (found: $([bool]$sopsFinalizeCmd))"
            } catch {
                Write-Host "  [!] Could not auto-download sops.exe ($($_.Exception.Message.Trim())) — plaintext .env left in place." -ForegroundColor Yellow
                Write-DetailLog "[sops-finalize] sops.exe download failed: $($_.Exception.Message)"
            }
        }
        if ($sopsFinalizeCmd -and (Test-Path $ageKeyFinalize)) {
            $env:SOPS_AGE_KEY_FILE = $ageKeyFinalize
            $decryptedFinalize = & $sopsFinalizeCmd.Path --decrypt --input-type dotenv --output-type dotenv $envEnc 2>$null
            if ($decryptedFinalize) {
                $plainNormFinalize   = (Get-Content $envPlain | Where-Object { $_ -notmatch '^\s*(#|$)' } | Sort-Object) -join "`n"
                $decryptNormFinalize = ($decryptedFinalize | Where-Object { $_ -notmatch '^\s*(#|$)' } | Sort-Object) -join "`n"
                if ($plainNormFinalize -eq $decryptNormFinalize) {
                    $finBakDir = Join-Path $INSTALL_DIR "dashboard_data"
                    New-Item -ItemType Directory -Force -Path $finBakDir | Out-Null
                    $finBakFile = Join-Path $finBakDir ("env-pre-finalize-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak")
                    Copy-Item $envPlain $finBakFile -ErrorAction SilentlyContinue
                    try {
                        Get-ChildItem -LiteralPath $finBakDir -Filter "env-pre-finalize-*.bak" -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-24) } |
                            Remove-Item -Force -ErrorAction SilentlyContinue
                    } catch {}
                    Remove-Item $envPlain -Force
                    Write-Host "  ✓ Plaintext .env purged automatically (verified against .env.enc; backup: $finBakFile)"
                    Write-DetailLog "[sops-finalize] .env purged after verified match, backup=$finBakFile"
                } else {
                    Write-Host "  [!] .env and .env.enc differ — refusing to purge automatically." -ForegroundColor Yellow
                    Write-Host "      Reconcile via Dashboard -> Settings -> Migrate secrets, or run migrate.ps1." -ForegroundColor Yellow
                    Write-DetailLog "[sops-finalize] .env / .env.enc content mismatch — left plaintext in place"
                }
            } else {
                Write-DetailLog "[sops-finalize] sops decrypt of .env.enc returned empty — left plaintext in place"
            }
        } elseif (-not (Test-Path $ageKeyFinalize)) {
            Write-Host "  [!] .env.enc present but no age key found at $ageKeyFinalize — cannot verify it, plaintext .env left in place." -ForegroundColor Yellow
            Write-DetailLog "[sops-finalize] age key not found at $ageKeyFinalize — cannot auto-finalize"
        }

        if (Test-Path $envPlain) {
            # Belt-and-braces: keep a daily snapshot of the plaintext so an
            # operator-side mistake can be reverted within 7 days (mirrors
            # update.sh's env-snapshot-<date>.bak retention). Still runs even
            # when auto-finalize above didn't purge (missing sops/age key, or
            # a genuine content mismatch it correctly refused to touch).
            $bakDir = Join-Path $INSTALL_DIR "dashboard_data"
            New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
            $bakFile = Join-Path $bakDir ("env-snapshot-" + (Get-Date -Format "yyyyMMdd") + ".bak")
            if (-not (Test-Path $bakFile)) {
                Copy-Item $envPlain $bakFile -ErrorAction SilentlyContinue
            }
            try {
                Get-ChildItem -LiteralPath $bakDir -Filter "env-snapshot-*.bak" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            } catch {}
            Write-Host "  ✓ .env protected (ACL-restricted) + .env.enc audit copy + daily snapshot in $bakDir"
        }
    } else {
        Write-Host "  ✓ .env protected (ACL-restricted)"
    }
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
$hostOsFromConfig = Get-InstallConfigVar "CODERAFT_HOST_OS"
if ($hostOsFromConfig) {
    $hostOsValue = $hostOsFromConfig.Trim().Trim('"').Trim("'").ToLower()
}
switch ($hostOsValue) {
    { @("windows", "macos") -contains $_ } {
        try {
            # B20 (2026-06-08): `& docker run ... 2>&1 | Out-Null` → NativeCommandError PS 5.1
            $capOut = Join-Path $env:TEMP "coderaft-cap-out-$(Get-Random).log"
            $capErr = Join-Path $env:TEMP "coderaft-cap-err-$(Get-Random).log"
            $capProc = Start-Process -FilePath "docker" -ArgumentList @(
                "run","--rm","--add-host=host.docker.internal:host-gateway",
                "curlimages/curl:8.10.1","-fsS","--connect-timeout","3","--max-time","4",
                "http://host.docker.internal:7777/health"
            ) -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $capOut `
                -RedirectStandardError  $capErr `
                -ErrorAction SilentlyContinue
            Remove-Item -Path $capOut,$capErr -ErrorAction SilentlyContinue
            if ($capProc.ExitCode -eq 0) {
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
    # B20 (2026-06-08): `& docker compose ps ... 2>$null` → NativeCommandError PS 5.1
    $pgQOut = Join-Path $env:TEMP "coderaft-pgq-out-$(Get-Random).log"
    $pgQErr = Join-Path $env:TEMP "coderaft-pgq-err-$(Get-Random).log"
    $pgQProc = Start-Process -FilePath "docker" -ArgumentList (@("compose") + $ComposeEnvArgs + @("ps","postgres","--quiet")) `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $pgQOut `
        -RedirectStandardError  $pgQErr `
        -ErrorAction SilentlyContinue
    if ($pgQProc -and -not $pgQProc.WaitForExit(60000)) {   # 60s
        Write-Host "  ⚠  Docker command timed out after 60s: docker compose ps postgres --quiet" -ForegroundColor Yellow
        try { $pgQProc.Kill() } catch {}
    }
    $psOutput = (Get-Content $pgQOut -ErrorAction SilentlyContinue) -join ""
    Remove-Item -Path $pgQOut,$pgQErr -ErrorAction SilentlyContinue
    if ($psOutput) { $postgresRunning = $true }
} catch { }

if ($postgresRunning) {
    try {
        # Start-Process redirects stdout cleanly (no PS encoding issues)
        $proc = Start-Process -FilePath "docker" `
            -ArgumentList (@("compose") + $ComposeEnvArgs + @("exec", "-T", "postgres", "pg_dumpall", "-U", "coderaft")) `
            -RedirectStandardOutput $BACKUP_FILE `
            -NoNewWindow -PassThru -Wait

        if ($proc.ExitCode -eq 0 -and (Get-Item $BACKUP_FILE).Length -gt 0) {
            Write-Host "  Backup saved: $BACKUP_FILE"
        } else {
            Write-Host "  ERROR: pg_dumpall failed (exit $($proc.ExitCode)). Update cancelled."
            Write-Host "  Check that the postgres container is healthy: docker compose ps"
            return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
        }
    } catch {
        Write-Host "  ERROR: pg_dumpall failed — $($_.Exception.Message)"
        return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
    }
} else {
    Write-Host "  PostgreSQL not detected — backup skipped (dashboard without DB)."
}

# ── Capture recovery snapshot via dashboard-api ───────────────────────────
# BUG FIX (2026-08-05): Find-AdminToken was previously only ever attempted
# ONCE, at the very top of the script, before any of the self-heal / ACL /
# image-cache work below has run. On an already-configured, already-running
# install — exactly the case this snapshot exists to protect — discovery
# should succeed via the "docker compose exec dashboard-api cat
# /data/admin_token" fallback inside Find-AdminToken: dashboard-api persists
# its own long-lived CLI token there (server.js's ensureCliAdminToken(), in a
# named Docker volume) and NOTHING ever writes it to the 3 static host file
# paths the old warning suggested as manual fallbacks. A single early attempt
# could hit a transient state (Docker Desktop still settling right as the
# script starts, dashboard-api mid-restart from a previous run) and never
# retry even though the stack is fully healthy by the time we get here. Retry
# right where the token is actually needed instead of only once at the top.
if (-not $ADMIN_TOKEN) {
    $retriedAdminToken = Find-AdminToken
    if ($retriedAdminToken) { $ADMIN_TOKEN = $retriedAdminToken }
    Remove-Variable -Name retriedAdminToken -ErrorAction SilentlyContinue
}
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
    Write-Host "    This is normally auto-discovered from the running dashboard-api container;"
    Write-Host "    if you see this warning, dashboard-api may not be reachable via 'docker compose exec'."
    Write-Host "    Manual overrides: set `$env:ADMIN_TOKEN, or place the token in $INSTALL_DIR\.env,"
    Write-Host "    C:\ProgramData\coderaft\admin_token, or ~/.coderaft/admin_token."
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
# Include vault override if a migration has been run (sentinel) OR the file
# is simply present on disk. Without this, the later `up -d --remove-orphans`
# treats coderaft-vault as orphan and silently removes it after migration.
# B-VAULT-OVERRIDE-DUP (2026-06-11): if `coderaft-vault:` is already defined
# in the main docker-compose.yml (current install.ps1 always does), do NOT
# load the override — and never reference the .vault.yml path if the file
# is missing (we move it to .bak when not needed, which used to break
# `docker compose pull` because the sentinel still existed).
$vaultInMainTop = $false
if (Test-Path ".\docker-compose.yml") {
    $vaultInMainTop = (Select-String -Path ".\docker-compose.yml" -Pattern '^\s*coderaft-vault:\s*$' -Quiet -ErrorAction SilentlyContinue)
}
if (-not $vaultInMainTop -and (Test-Path ".\docker-compose.vault.yml")) {
    if ($ComposeArgs -notcontains ".\docker-compose.yml") {
        $ComposeArgs += @("-f", ".\docker-compose.yml")
    }
    $ComposeArgs += @("-f", ".\docker-compose.vault.yml")
}
# Task #150: both env files, always explicit (see $ComposeEnvArgs above).
$ComposeArgs += $ComposeEnvArgs

# ── License key drift refresh: REMOVED (2026-07-31) ───────────────────────
# Update-License/Update-AllLicenses used to POST the local
# LICENSE_KEY/RAVENSCAN_LICENSE_KEY/REDFOX_LICENSE_KEY (baked into
# docker-compose.override.yml + .env) to the License Server's public
# /api/licenses/validate before `docker compose up`, so a resigned/rotated
# key baked into a product container's env didn't 403 with "superseded by a
# newer version". That whole problem class is gone since #166
# (2026-07-28): products no longer take their license via a boot-time env
# var at all — they fetch the resolved license live from dashboard-api's
# GET /api/dashboard/internal/license (which itself reads Coderaft Vault,
# not .env). dashboard-api's removeLicenseKeyFromHostEnv() also actively
# strips any stray LICENSE_KEY= line from .env/.env.enc on every boot, so
# this function's writes were already being erased by the very next
# dashboard-api start — and install.ps1/templates no longer write these
# vars into docker-compose.override.yml in the first place, so
# $currentKey resolved empty (silent no-op) on every install that had
# booted a post-#166 dashboard-api even once. Confirmed dead via
# exhaustive grep for live env reads (not just comments) in all four
# product repos: Audit_Entra (WolfGuard), secaudit (Ravenscan), Redfox,
# falconone — zero hits. See scripts/update.sh/update.ps1's vault-migration
# D4 comment (task #150) for the matching removal on the secrets-migration
# side, and scripts/update.sh for the bash equivalent of this comment.

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
# B20 (2026-06-08): all `& docker ... 2>$null` / `2>&1 | Out-Null` → NativeCommandError PS 5.1
# Use Start-Process + split temp files throughout this block.
$ciOut = Join-Path $env:TEMP "coderaft-ci-out-$(Get-Random).log"
$ciErr = Join-Path $env:TEMP "coderaft-ci-err-$(Get-Random).log"
Start-Process -FilePath "docker" -ArgumentList (@() + $ComposeArgs + @("config","--images")) `
    -NoNewWindow -Wait `
    -RedirectStandardOutput $ciOut `
    -RedirectStandardError  $ciErr `
    -ErrorAction SilentlyContinue | Out-Null
$ComposeImages = Get-Content $ciOut -ErrorAction SilentlyContinue
Remove-Item -Path $ciOut,$ciErr -ErrorAction SilentlyContinue

foreach ($img in $ComposeImages) {
    if ($img -like "ghcr.io/liamj74/*") {
        # 1. Stop containers running on this image
        $psqOut = Join-Path $env:TEMP "coderaft-psq-out-$(Get-Random).log"
        $psqErr = Join-Path $env:TEMP "coderaft-psq-err-$(Get-Random).log"
        Start-Process -FilePath "docker" -ArgumentList @("ps","-q","--filter","ancestor=$img") `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $psqOut `
            -RedirectStandardError  $psqErr `
            -ErrorAction SilentlyContinue | Out-Null
        $containerIds = (Get-Content $psqOut -ErrorAction SilentlyContinue) | Where-Object { $_ }
        Remove-Item -Path $psqOut,$psqErr -ErrorAction SilentlyContinue
        if ($containerIds) {
            $stopOut = Join-Path $env:TEMP "coderaft-stop-out-$(Get-Random).log"
            $stopErr = Join-Path $env:TEMP "coderaft-stop-err-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList (@("stop") + $containerIds) `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $stopOut `
                -RedirectStandardError  $stopErr `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -Path $stopOut,$stopErr -ErrorAction SilentlyContinue
            $rmcOut = Join-Path $env:TEMP "coderaft-rmc-out-$(Get-Random).log"
            $rmcErr = Join-Path $env:TEMP "coderaft-rmc-err-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList (@("rm","-f") + $containerIds) `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $rmcOut `
                -RedirectStandardError  $rmcErr `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -Path $rmcOut,$rmcErr -ErrorAction SilentlyContinue
        }
        # 2. Untag (silent if the image doesn't exist locally — first update)
        try {
            $inspCiOut = Join-Path $env:TEMP "coderaft-inspci-out-$(Get-Random).log"
            $inspCiErr = Join-Path $env:TEMP "coderaft-inspci-err-$(Get-Random).log"
            $inspCiProc = Start-Process -FilePath "docker" -ArgumentList @("image","inspect",$img) `
                -NoNewWindow -PassThru `
                -RedirectStandardOutput $inspCiOut `
                -RedirectStandardError  $inspCiErr `
                -ErrorAction SilentlyContinue
            if ($inspCiProc -and -not $inspCiProc.WaitForExit(60000)) {   # 60s
                Write-Host "  ⚠  Docker command timed out after 60s: docker image inspect $img" -ForegroundColor Yellow
                try { $inspCiProc.Kill() } catch {}
            }
            Remove-Item -Path $inspCiOut,$inspCiErr -ErrorAction SilentlyContinue
            if ($inspCiProc.ExitCode -eq 0) {
                $rmiOut = Join-Path $env:TEMP "coderaft-rmi-out-$(Get-Random).log"
                $rmiErr = Join-Path $env:TEMP "coderaft-rmi-err-$(Get-Random).log"
                Start-Process -FilePath "docker" -ArgumentList @("rmi","-f",$img) `
                    -NoNewWindow -Wait `
                    -RedirectStandardOutput $rmiOut `
                    -RedirectStandardError  $rmiErr `
                    -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path $rmiOut,$rmiErr -ErrorAction SilentlyContinue
            }
        } catch {
            # Image not in local cache — skip silently
        }
        $LASTEXITCODE = 0
        # 3. Remove by ID (in case the image survives untagged)
        $imgIdOut = Join-Path $env:TEMP "coderaft-imgid-out-$(Get-Random).log"
        $imgIdErr = Join-Path $env:TEMP "coderaft-imgid-err-$(Get-Random).log"
        Start-Process -FilePath "docker" -ArgumentList @("images","--format","{{.ID}}",$img) `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $imgIdOut `
            -RedirectStandardError  $imgIdErr `
            -ErrorAction SilentlyContinue | Out-Null
        $imageIds = (Get-Content $imgIdOut -ErrorAction SilentlyContinue) | Where-Object { $_ }
        Remove-Item -Path $imgIdOut,$imgIdErr -ErrorAction SilentlyContinue
        if ($imageIds) {
            foreach ($iid in $imageIds) {
                if ($iid) {
                    $rmiIdOut = Join-Path $env:TEMP "coderaft-rmiid-out-$(Get-Random).log"
                    $rmiIdErr = Join-Path $env:TEMP "coderaft-rmiid-err-$(Get-Random).log"
                    Start-Process -FilePath "docker" -ArgumentList @("rmi","-f",$iid) `
                        -NoNewWindow -Wait `
                        -RedirectStandardOutput $rmiIdOut `
                        -RedirectStandardError  $rmiIdErr `
                        -ErrorAction SilentlyContinue | Out-Null
                    Remove-Item -Path $rmiIdOut,$rmiIdErr -ErrorAction SilentlyContinue
                }
            }
        }
        $LASTEXITCODE = 0
    }
}

# ── Ensure .env is present + fresh before ANY docker compose call below ───
# BUG (found live 2026-08-04, Liam's Windows deployment): `$ComposeArgs`
# above is just @("compose") — no --env-file — so `docker compose pull`/
# `up` rely ENTIRELY on Docker Compose's own default auto-load of a plain
# `.env` file in the current directory. But the "Banking-grade plaintext
# purge" block earlier in this script (and dashboard-api's own task #148
# hardening, which deletes its host-visible copy once its internal tmpfs
# copy is authoritative) can both legitimately have already REMOVED that
# file by the time we get here — the purge block's own job is exactly to
# delete it once .env.enc is confirmed authoritative. Result: every
# `${POSTGRES_PASSWORD}`/`${REDIS_PASSWORD}`/etc. reference below silently
# resolves to an empty string, and redis's `--requirepass ${REDIS_PASSWORD}
# --maxmemory 128mb` collapses into `--requirepass --maxmemory 128mb` —
# redis reads that as ONE malformed directive and refuses to start
# ("wrong number of arguments"). Confirmed live: this had never surfaced
# before because dashboard-api's own crash-loop (missing vault-secret-
# resolve.js in its Dockerfile, fixed 2026-08-04) meant .env.enc was never
# reliably refreshed either, so the purge block's `if (Test-Path $envEnc)`
# guard rarely fired. Fix: always regenerate a fresh, correct .env from
# .env.enc right before the commands that need it — never trust that a
# plaintext copy still happens to be lying around from an earlier step.
$envPlainPreDeploy = Join-Path $INSTALL_DIR ".env"
$envEncPreDeploy   = Join-Path $INSTALL_DIR ".env.enc"
if (Test-Path $envEncPreDeploy) {
    $ageKeyPreDeploy = if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $INSTALL_DIR ".coderaft-age.key" }
    if (-not (Test-Path $ageKeyPreDeploy) -and (Test-Path "C:\ProgramData\coderaft\age.key")) {
        $ageKeyPreDeploy = "C:\ProgramData\coderaft\age.key"
    }
    $sopsPreDeployCmd = Get-Command sops -ErrorAction SilentlyContinue
    if ((Test-Path $ageKeyPreDeploy) -and $sopsPreDeployCmd) {
        $env:SOPS_AGE_KEY_FILE = $ageKeyPreDeploy
        $decryptedPreDeploy = & $sopsPreDeployCmd.Path --decrypt --input-type dotenv --output-type dotenv $envEncPreDeploy 2>$null
        if ($decryptedPreDeploy) {
            [System.IO.File]::WriteAllText($envPlainPreDeploy, (($decryptedPreDeploy -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
            Write-Host "  ✓ .env refreshed from .env.enc (ensures docker compose sees real secrets)"
        } elseif (-not (Test-Path $envPlainPreDeploy)) {
            Write-Host "  [!] sops decrypt of .env.enc returned empty and no .env exists — docker compose calls below will likely fail." -ForegroundColor Yellow
        }
    } elseif (-not (Test-Path $envPlainPreDeploy)) {
        Write-Host "  [!] .env is missing and .env.enc cannot be decrypted here (sops or age key unavailable) — docker compose calls below will likely fail." -ForegroundColor Yellow
        Write-Host "      Install sops (https://github.com/getsops/sops) or restore $ageKeyPreDeploy" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "  Downloading new images..."
& docker @ComposeArgs pull
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: docker compose pull failed."
    return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
}

# Note: `--pull always` retried a per-service GHCR manifest check at redeploy
# time (intermittent timeout on slow connections). The Docker Desktop tag-cache
# bug is already covered by `docker rmi -f` + `docker compose pull` above, so
# we let `up` reuse the freshly pulled local images.
& docker @ComposeArgs up -d --force-recreate --remove-orphans
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: docker compose up failed."
    return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
}

# ── #137 fix: refresh certs/server-ca.pem — Caddy TLS mode-aware (#187) ──
# entraguard-api mounts certs/server-ca.pem into the container and hands
# it to endpoint agents at /register (as `ca_cert`) so agents can verify
# the front cert on their report loop. Caddy can be configured in 3 modes
# (task #133 Setup Wizard TLS): (1) `tls internal` → PKI root at
# /data/caddy/pki/authorities/local/root.crt ; (2) `tls /certs/...`
# (mkcert / self-signed / setup-wizard-generated) → leaf cert already on
# host under ./certs/, serves as its own trust anchor ; (3) `tls email`
# (Let's Encrypt) → globally trusted, no export needed. Detect the mode
# from the running Caddyfile and adapt.
Write-Host "  Refreshing certs\server-ca.pem (mode-aware)..."
try {
    New-Item -ItemType Directory -Force -Path (Join-Path (Get-Location) "certs") | Out-Null
    $caLocal = Join-Path (Get-Location) "certs\server-ca.pem"

    # Read the actual Caddyfile inside the running caddy container.
    $caddyfileOut = Join-Path $env:TEMP "coderaft-caddyfile-$(Get-Random).log"
    $caddyfileErr = Join-Path $env:TEMP "coderaft-caddyfile-err-$(Get-Random).log"
    $cfProc = Start-Process -FilePath "docker" -ArgumentList (@() + $ComposeArgs + @("exec","-T","caddy","cat","/etc/caddy/Caddyfile")) `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $caddyfileOut `
        -RedirectStandardError  $caddyfileErr
    if (-not $cfProc.WaitForExit(15000)) { try { $cfProc.Kill() } catch {} }
    $caddyfile = ""
    if (Test-Path $caddyfileOut) { $caddyfile = (Get-Content $caddyfileOut -Raw -ErrorAction SilentlyContinue) }
    Remove-Item -Path $caddyfileOut, $caddyfileErr -ErrorAction SilentlyContinue

    $tlsMode = "unknown"
    if ($caddyfile -match '(?m)^\s*tls\s+internal\s*$')                 { $tlsMode = "internal" }
    elseif ($caddyfile -match '(?m)^\s*tls\s+/certs/\S+\.pem\s+\S+')    { $tlsMode = "file" }
    elseif ($caddyfile -match '(?m)^\s*tls\s+[a-zA-Z0-9._+-]+@\S+')     { $tlsMode = "letsencrypt" }

    switch ($tlsMode) {
        "internal" {
            $caContainerPath = "/data/caddy/pki/authorities/local/root.crt"
            $ok = $false
            for ($i = 0; $i -lt 20; $i++) {
                & docker @ComposeArgs exec -T caddy test -f $caContainerPath 2>$null
                if ($LASTEXITCODE -eq 0) { $ok = $true; break }
                Start-Sleep -Seconds 2
            }
            if ($ok) {
                & docker @ComposeArgs cp "caddy:$caContainerPath" $caLocal 2>$null
                if ($LASTEXITCODE -eq 0 -and (Test-Path $caLocal) -and (Get-Item $caLocal).Length -gt 0) {
                    Write-Host "  ✓ certs\server-ca.pem refreshed from Caddy internal PKI"
                    & docker @ComposeArgs restart entraguard-api 2>$null | Out-Null
                } else {
                    Write-Host "  ⚠ docker cp for Caddy internal CA failed (exit $LASTEXITCODE)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  ⚠ Caddy internal CA not initialized after 40s — endpoint agents may see x509 errors." -ForegroundColor Yellow
            }
        }
        "file" {
            # Caddy serves file-based certs (mkcert / setup-wizard signed).
            # The leaf cert IS the trust anchor for agents (self-contained
            # chain). Copy the active leaf as server-ca.pem — agents pin
            # the leaf via /register response `ca_cert` field.
            $leafCandidates = @("certs\coderaft.local.pem", "certs\coderaft.pem", "certs\server.pem")
            $leafSrc = $null
            foreach ($cand in $leafCandidates) {
                $candPath = Join-Path (Get-Location) $cand
                if (Test-Path $candPath -PathType Leaf) { $leafSrc = $candPath; break }
            }
            if ($leafSrc) {
                Copy-Item -LiteralPath $leafSrc -Destination $caLocal -Force
                Write-Host "  ✓ certs\server-ca.pem refreshed (from active TLS file cert: $(Split-Path $leafSrc -Leaf))"
                & docker @ComposeArgs restart entraguard-api 2>$null | Out-Null
            } else {
                Write-Host "  ⚠ TLS mode 'file' detected but no active leaf cert found under .\certs\ — agents may fail x509 verify." -ForegroundColor Yellow
            }
        }
        "letsencrypt" {
            # LE certs are chained to publicly-trusted roots — nothing to
            # export. Ensure server-ca.pem is either absent or empty so
            # agents fall back to system trust store.
            if (Test-Path $caLocal) { Remove-Item -Path $caLocal -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType File -Path $caLocal -Force | Out-Null
            Write-Host "  ✓ TLS mode 'letsencrypt' — server-ca.pem cleared (agents use system trust)"
        }
        default {
            Write-Host "  ⚠ Could not detect Caddy TLS mode from Caddyfile — skipping CA refresh." -ForegroundColor Yellow
            Write-Host "     (task #187: help improve detection by opening a support ticket with your Caddyfile)"
        }
    }
} catch {
    Write-Host "  ⚠ CA refresh skipped: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ── B-NETWORK-HEAL (2026-06-24) ───────────────────────────────────────────
# install.ps1 PR #11/#13 added coderaft-backend + coderaft-frontend networks
# and attached postgres / redis / dashboard to them. Pre-existing installs
# created before those PRs keep using coderaft_default — every product
# deployed dynamically by dashboard-api ends up unable to resolve the
# "postgres" / "redis" / "entraguard-api" hostnames, surfacing as 500
# errors at sign-in and product setup time.
#
# update.ps1 does NOT rewrite the user's docker-compose.yml (intentional —
# we don't want to clobber operator-tuned configs). Instead we self-heal
# by ensuring the networks exist and attaching the long-running data
# containers to them. Idempotent: re-running this block is a no-op when
# the connections are already in place.
Write-Host ""
Write-Host "  Self-healing data-service networks..."
# B-PS51 (2026-07-17): PowerShell 5.1 (Windows PowerShell — default on
# older Windows installs) does not support the `? :` ternary operator
# (that syntax landed in PowerShell 7). Use an if/else expression which
# parses on both 5.1 and 7+. Symptom before this fix:
#   Unexpected token '?' in expression or statement.
$projectPrefix = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { "coderaft" }
$backendNet  = "${projectPrefix}_coderaft-backend"
$frontendNet = "${projectPrefix}_coderaft-frontend"

function Ensure-Network {
    param([string]$name)
    & docker network inspect $name *> $null
    if ($LASTEXITCODE -ne 0) {
        & docker network create $name *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    + created $name"
        }
    }
}

function Ensure-Attached {
    param(
        [string]$network,
        [string]$container,
        [string]$alias = ""
    )
    # Already attached? `docker inspect` returns the network name when present.
    $attached = & docker inspect $container --format "{{range `$k,`$v := .NetworkSettings.Networks}}{{`$k}} {{end}}" 2>$null
    if ($LASTEXITCODE -ne 0) { return }   # container doesn't exist
    if ($attached -match [regex]::Escape($network)) { return }
    if ($alias) {
        & docker network connect --alias $alias $network $container 2>$null | Out-Null
    } else {
        & docker network connect $network $container 2>$null | Out-Null
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    + ${container} -> ${network}$( if ($alias) { ' (alias=' + $alias + ')' } )"
    }
}

Ensure-Network $backendNet
Ensure-Network $frontendNet

# Postgres + Redis MUST keep their service-name aliases so the products
# can resolve `postgres:5432` / `redis:6379` after dashboard-api hot-deploys
# them. `docker network connect` without --alias only registers the full
# container name (coderaft-postgres-1), not the short one.
Ensure-Attached -network $backendNet  -container "${projectPrefix}-postgres-1" -alias "postgres"
Ensure-Attached -network $backendNet  -container "${projectPrefix}-redis-1"    -alias "redis"
Ensure-Attached -network $frontendNet -container "${projectPrefix}-dashboard-1"
Ensure-Attached -network $backendNet  -container "${projectPrefix}-dashboard-1"

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
    Write-Host "  Full update log: $UPDATE_LOG"
    return  # not 'exit' — irm|iex runs this in the caller's own scope, so exit would close their whole shell
}

# ── B-IPV6-KILL-VERIFY (2026-07-24) ───────────────────────────────────────
# Confirm at RUNTIME that dashboard-api actually has IPv6 disabled in its
# network namespace. The self-heal above writes sysctls into compose, but
# Docker only applies them on container (re)creation — a partial update
# path could leave a running container without the kill. If /proc says v6
# is still up, warn loudly so Liam catches it before OIDC login re-fails
# with ENETUNREACH.
Write-Host "  Verifying IPv6 disabled in dashboard-api container..."
$v6Out = Join-Path $env:TEMP "coderaft-ipv6-verify-$(Get-Random).log"
$v6Err = Join-Path $env:TEMP "coderaft-ipv6-verify-err-$(Get-Random).log"
$v6Proc = Start-Process -FilePath "docker" -ArgumentList @(
        "exec", "coderaft-dashboard-api-1",
        "cat", "/proc/sys/net/ipv6/conf/all/disable_ipv6"
    ) -NoNewWindow -PassThru `
      -RedirectStandardOutput $v6Out `
      -RedirectStandardError  $v6Err `
      -ErrorAction SilentlyContinue
if ($v6Proc -and -not $v6Proc.WaitForExit(60000)) {   # 60s
    Write-Host "  ⚠  Docker command timed out after 60s: docker exec coderaft-dashboard-api-1 cat .../disable_ipv6" -ForegroundColor Yellow
    try { $v6Proc.Kill() } catch {}
}
$v6Value = ((Get-Content $v6Out -ErrorAction SilentlyContinue) -join "").Trim()
Remove-Item -Path $v6Out, $v6Err -ErrorAction SilentlyContinue
if ($v6Value -eq "1") {
    Write-Host "  ✓ IPv6 disabled in dashboard-api (/proc value = 1)" -ForegroundColor Green
} elseif ($v6Value -eq "0") {
    Write-Host "  ⚠  IPv6 still ENABLED in dashboard-api — Entra login will ENETUNREACH." -ForegroundColor Yellow
    Write-Host "     The sysctls block was likely NOT applied on container recreation." -ForegroundColor Yellow
    Write-Host "     Fix: docker compose stop dashboard-api ; docker compose up -d --force-recreate dashboard-api"
} else {
    Write-Host "  ⚠  Could not read /proc/sys/net/ipv6/conf/all/disable_ipv6 (empty or non-Linux). Skipping IPv6 verify." -ForegroundColor Yellow
}

# ── B-OVERRIDE-RACE reconciliation pass (live incident 2026-08-07) ───────
# ROOT CAUSE: the `docker compose up -d --force-recreate --remove-orphans`
# call above computes its ENTIRE "what should exist" plan by reading
# docker-compose.override.yml AS IT EXISTS ON DISK the instant the command
# starts. dashboard-api — one of the containers THAT SAME command
# (re)creates — regenerates that override file fresh on every boot
# (server.js bootstrap()'s `app.listen(...)` callback, logging
# "[dashboard-api] override.yml refreshed for products: ...") specifically
# as a self-heal for stale overrides. But that regen only starts once the
# new container's Node process is up — strictly AFTER this same
# `docker compose up` invocation already read the OLD override, computed
# its plan and executed it. With --remove-orphans, any product container
# absent from that stale plan is removed, and nothing re-runs
# `docker compose up` afterward to reconcile against the now-correct file.
# CONFIRMED LIVE 2026-08-07 (Liam's Windows test machine): every product
# container (entraguard-*, redfox-*, ravenscan*, falconone-*, neo4j) was
# removed and never recreated after update.ps1; a second manual
# `docker compose up -d` fixed it instantly — full recovery.
#
# Fix: wait for dashboard-api's own log line confirming its override.yml
# regen has actually completed (bounded poll, not an assumption — the
# HTTP health check above can return 200 before this async work in the
# listen() callback finishes), then run `docker compose up -d` again
# WITHOUT --force-recreate so it only creates/starts whatever the
# corrected override adds, without needlessly recreating containers that
# are already correctly running.
Write-Host ""
Write-Host "  Reconciliation pass: waiting for dashboard-api override.yml self-heal..."
$overrideRefreshed = $false
$reconcileTimeoutSec = 60
$reconcilePollSec = 2
$reconcileElapsed = 0
while ($reconcileElapsed -lt $reconcileTimeoutSec) {
    $logOut = Join-Path $env:TEMP "coderaft-reconcile-log-$(Get-Random).log"
    $logErr = Join-Path $env:TEMP "coderaft-reconcile-log-err-$(Get-Random).log"
    # `docker compose logs <service>` (not `docker logs <container>`) so this
    # resolves the container purely from the service name — independent of
    # $projectPrefix / COMPOSE_PROJECT_NAME naming, and consistent with
    # update.sh's equivalent poll.
    $logProc = Start-Process -FilePath "docker" -ArgumentList (@() + $ComposeArgs + @("logs", "dashboard-api")) `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $logOut `
        -RedirectStandardError  $logErr `
        -ErrorAction SilentlyContinue
    if ($logProc -and -not $logProc.WaitForExit(15000)) {   # 15s
        try { $logProc.Kill() } catch {}
    }
    # `docker logs` writes container stdout/stderr to BOTH our stdout and
    # stderr redirection depending on how the app wrote it — console.log
    # goes to the container's stdout, but check both temp files regardless.
    $logContent = ""
    if (Test-Path $logOut) { $logContent += (Get-Content $logOut -Raw -ErrorAction SilentlyContinue) }
    if (Test-Path $logErr) { $logContent += (Get-Content $logErr -Raw -ErrorAction SilentlyContinue) }
    Remove-Item -Path $logOut, $logErr -ErrorAction SilentlyContinue
    if ($logContent -and $logContent.Contains("override.yml refreshed for products:")) {
        $overrideRefreshed = $true
        break
    }
    Start-Sleep -Seconds $reconcilePollSec
    $reconcileElapsed += $reconcilePollSec
}

if ($overrideRefreshed) {
    Write-Host "  ✓ dashboard-api override.yml self-heal confirmed."
} else {
    Write-Host "  ⚠  Timed out after ${reconcileTimeoutSec}s waiting for dashboard-api's override.yml self-heal log line." -ForegroundColor Yellow
    Write-Host "     This is EXPECTED if no license/products are configured yet (nothing to regenerate)." -ForegroundColor Yellow
    Write-Host "     Otherwise, product containers may still be down — proceeding with reconciliation anyway." -ForegroundColor Yellow
}

# Snapshot running services before reconciling so we only report what
# actually changed, instead of spamming already-healthy installs.
$preReconcileOut = Join-Path $env:TEMP "coderaft-prerec-out-$(Get-Random).log"
$preReconcileErr = Join-Path $env:TEMP "coderaft-prerec-err-$(Get-Random).log"
$preProc = Start-Process -FilePath "docker" -ArgumentList (@() + $ComposeArgs + @("ps","--services","--filter","status=running")) `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $preReconcileOut `
    -RedirectStandardError  $preReconcileErr `
    -ErrorAction SilentlyContinue
if ($preProc -and -not $preProc.WaitForExit(30000)) { try { $preProc.Kill() } catch {} }
$preRunning = @((Get-Content $preReconcileOut -ErrorAction SilentlyContinue) | Where-Object { $_ })
Remove-Item -Path $preReconcileOut, $preReconcileErr -ErrorAction SilentlyContinue

Write-Host "  Reconciliation pass: docker compose up -d (no --force-recreate)..."
$reconcileUpOut = Join-Path $env:TEMP "coderaft-reconcile-up-out-$(Get-Random).log"
$reconcileUpErr = Join-Path $env:TEMP "coderaft-reconcile-up-err-$(Get-Random).log"
$reconcileUpProc = Start-Process -FilePath "docker" -ArgumentList (@() + $ComposeArgs + @("up","-d")) `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $reconcileUpOut `
    -RedirectStandardError  $reconcileUpErr `
    -ErrorAction SilentlyContinue
if ($reconcileUpProc -and -not $reconcileUpProc.WaitForExit(180000)) {   # 3min
    Write-Host "  ⚠  Reconciliation 'docker compose up -d' timed out after 180s." -ForegroundColor Yellow
    try { $reconcileUpProc.Kill() } catch {}
}
$reconcileExit = if ($reconcileUpProc) { $reconcileUpProc.ExitCode } else { -1 }
$reconcileUpLog = ""
if (Test-Path $reconcileUpErr) { $reconcileUpLog = (Get-Content $reconcileUpErr -Raw -ErrorAction SilentlyContinue) }
Remove-Item -Path $reconcileUpOut, $reconcileUpErr -ErrorAction SilentlyContinue

if ($reconcileExit -ne 0) {
    Write-Host "  ⚠  Reconciliation 'docker compose up -d' exited with code $reconcileExit." -ForegroundColor Yellow
    if ($reconcileUpLog) { Write-Host "     $reconcileUpLog" -ForegroundColor Yellow }
    Write-Host "     Manual fix: cd `"$INSTALL_DIR`" ; docker compose up -d" -ForegroundColor Yellow
} else {
    $postReconcileOut = Join-Path $env:TEMP "coderaft-postrec-out-$(Get-Random).log"
    $postReconcileErr = Join-Path $env:TEMP "coderaft-postrec-err-$(Get-Random).log"
    $postProc = Start-Process -FilePath "docker" -ArgumentList (@() + $ComposeArgs + @("ps","--services","--filter","status=running")) `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $postReconcileOut `
        -RedirectStandardError  $postReconcileErr `
        -ErrorAction SilentlyContinue
    if ($postProc -and -not $postProc.WaitForExit(30000)) { try { $postProc.Kill() } catch {} }
    $postRunning = @((Get-Content $postReconcileOut -ErrorAction SilentlyContinue) | Where-Object { $_ })
    Remove-Item -Path $postReconcileOut, $postReconcileErr -ErrorAction SilentlyContinue

    $newlyStarted = @($postRunning | Where-Object { $preRunning -notcontains $_ })
    if ($newlyStarted.Count -gt 0) {
        Write-Host "  ✓ Reconciliation pass started $($newlyStarted.Count) additional container(s): $($newlyStarted -join ', ')" -ForegroundColor Green
    } else {
        Write-Host "  ✓ Reconciliation pass: nothing to reconcile, all services already up to date."
    }
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
Write-Host "  Full update log: $UPDATE_LOG"
