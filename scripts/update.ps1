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
    exit 1
}

$DASHBOARD_API       = if ($env:DASHBOARD_API)       { $env:DASHBOARD_API }       else { "http://localhost:3000" }
$ADMIN_TOKEN         = if ($env:ADMIN_TOKEN)         { $env:ADMIN_TOKEN }         else { "" }
$BACKUP_DIR          = if ($env:BACKUP_DIR)          { $env:BACKUP_DIR }          else { ".\dashboard_data\backups" }
$HEALTHCHECK_RETRIES = if ($env:HEALTHCHECK_RETRIES) { [int]$env:HEALTHCHECK_RETRIES } else { 30 }
$HEALTHCHECK_DELAY   = if ($env:HEALTHCHECK_DELAY)   { [int]$env:HEALTHCHECK_DELAY }   else { 3 }
$INSTALL_DIR         = if ($env:INSTALL_DIR)         { $env:INSTALL_DIR }         else { (Get-Location).Path }

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
        Start-Process -FilePath "docker" -ArgumentList @("compose","ps","--services") `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $svcStdout `
            -RedirectStandardError  $svcStderr `
            -ErrorAction SilentlyContinue | Out-Null
        $services = (Get-Content $svcStdout -ErrorAction SilentlyContinue) -join "`n"
        Remove-Item -Path $svcStdout,$svcStderr -ErrorAction SilentlyContinue
        if ($services -match '(?m)^dashboard-api$') {
            $catStdout = Join-Path $env:TEMP "coderaft-cat-out-$(Get-Random).log"
            $catStderr = Join-Path $env:TEMP "coderaft-cat-err-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList @("compose","exec","-T","dashboard-api","cat","/data/admin_token") `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $catStdout `
                -RedirectStandardError  $catStderr `
                -ErrorAction SilentlyContinue | Out-Null
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
        exit 1
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
        exit 1
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
            exit 0
        }
        "rolled_back" {
            Write-Host ""
            Write-Host "  [FAIL] Update failed - automatic rollback restored the previous version." -ForegroundColor Red
            exit 1
        }
        "rollback_failed" {
            Write-Host ""
            Write-Host "  [CRITICAL] Update AND rollback failed - manual intervention required." -ForegroundColor Red
            Write-Host "  Snapshots: GET $DASHBOARD_API/api/dashboard/products/$PRODUCT_SLUG/snapshots"
            exit 2
        }
        "failed" {
            Write-Host ""
            Write-Host "  [FAIL] Update failed before any service was modified (e.g. backup failure)." -ForegroundColor Red
            exit 1
        }
        default {
            Write-Host ""
            Write-Host "  [?] Update still running after 10 min - check the dashboard for live status." -ForegroundColor Yellow
            exit 1
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
        exit $LASTEXITCODE
    }
}

# ── Self-heal CODERAFT_HOST_OS in .env (B25) ──────────────────────────────
# Les installs antérieures préservaient .env sans ajouter CODERAFT_HOST_OS
# (seul le path "fresh secrets" l'écrivait). Dashboard-api lit cette valeur
# pour décider du mode capture daemon (native Windows Service vs Docker
# sidecar Linux). Sans CODERAFT_HOST_OS, le setup wizard affiche
# "CODERAFT_HOST_OS configured: ✗ not set" et capture ne fonctionne pas.
$envPathForHostOS = Join-Path $INSTALL_DIR ".env"
if (Test-Path $envPathForHostOS) {
    $envTextHO = [System.IO.File]::ReadAllText($envPathForHostOS, [System.Text.UTF8Encoding]::new($false))
    if ($envTextHO -notmatch '(?m)^\s*CODERAFT_HOST_OS\s*=') {
        $hostOSValue = "windows"  # update.ps1 ne tourne que sur Windows
        $envTextHO = $envTextHO.TrimEnd() + "`nCODERAFT_HOST_OS=$hostOSValue`n"
        [System.IO.File]::WriteAllText($envPathForHostOS, $envTextHO, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  ✓ Self-heal .env — CODERAFT_HOST_OS=$hostOSValue ajouté"
    }
}

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
            [System.IO.File]::WriteAllLines($composePathB15, $out, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  ✓ Self-heal docker-compose.yml — sysctls IPv6 kill ajouté à dashboard-api"
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
        $overrideText = $overrideText -replace '"7687:7687"', '"127.0.0.1:${NEO4J_BOLT_PORT:-7687}:7687"'
        $overrideText = $overrideText -replace '- 7687:7687', '- "127.0.0.1:${NEO4J_BOLT_PORT:-7687}:7687"'
        [System.IO.File]::WriteAllText($overridePath, $overrideText, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  ✓ Self-heal docker-compose.override.yml — neo4j 127.0.0.1 only + paramétrable"
    }
}

# ── Self-heal HOST_PROJECT_DIR in .env ────────────────────────────────────
# Older oneliners (and any install where the dir was renamed/moved) leave
# .env without HOST_PROJECT_DIR, which causes:
#   - docker compose warning "HOST_PROJECT_DIR not set" on every command
#   - dashboard-api boots with empty HOST_PROJECT_DIR → cannot reach
#     /host-compose paths → license.json invisible → fake "first run" UX
# Always (re)write the line with the resolved current install dir.
$envPath = Join-Path $INSTALL_DIR ".env"
if (Test-Path $envPath) {
    $absoluteInstallDir = (Resolve-Path -LiteralPath $INSTALL_DIR).Path
    if ($absoluteInstallDir) {
        $envText = [System.IO.File]::ReadAllText($envPath, [System.Text.UTF8Encoding]::new($false))
        $existingMatch = [regex]::Match($envText, '(?m)^HOST_PROJECT_DIR=(.*)$')
        $needsRewrite = $false
        if ($existingMatch.Success) {
            if ($existingMatch.Groups[1].Value -ne $absoluteInstallDir) { $needsRewrite = $true }
        } else {
            $needsRewrite = $true
        }
        if ($needsRewrite) {
            $lines = $envText -split "`r?`n" | Where-Object { $_ -notmatch '^HOST_PROJECT_DIR=' }
            $newText = (($lines -join "`n").TrimEnd()) + "`nHOST_PROJECT_DIR=$absoluteInstallDir`n"
            [System.IO.File]::WriteAllText($envPath, $newText, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  ✓ HOST_PROJECT_DIR refreshed ($absoluteInstallDir)"
        }
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
    # B20 (2026-06-08): `& docker compose ps 2>&1 | Out-Null` surfaces docker
    # stderr as NativeCommandError in PS 5.1. Use Start-Process + temp files.
    $psCheckOut = Join-Path $env:TEMP "coderaft-pscheck-out-$(Get-Random).log"
    $psCheckErr = Join-Path $env:TEMP "coderaft-pscheck-err-$(Get-Random).log"
    $psCheckProc = Start-Process -FilePath "docker" -ArgumentList @("compose","ps") `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $psCheckOut `
        -RedirectStandardError  $psCheckErr `
        -ErrorAction SilentlyContinue
    Remove-Item -Path $psCheckOut,$psCheckErr -ErrorAction SilentlyContinue
    if ($psCheckProc.ExitCode -eq 0) { $composeOK = $true }
} catch { }
if (-not $composeOK) {
    Write-Host "  ⚠ docker-compose.override.yml appears corrupted — auto-recovery..."
    if (Test-Path "docker-compose.override.yml") {
        $brokenBak = "docker-compose.override.yml.broken-" + (Get-Date -Format "yyyyMMdd_HHmmss")
        try { Copy-Item "docker-compose.override.yml" $brokenBak -ErrorAction SilentlyContinue } catch { }
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
        $upHealProc = Start-Process -FilePath "docker" -ArgumentList @("compose","up","-d","postgres","redis","dashboard-api") `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $upHealOut `
            -RedirectStandardError  $upHealErr `
            -ErrorAction SilentlyContinue
        if (Test-Path $upHealOut) { Get-Content $upHealOut -ErrorAction SilentlyContinue | Out-Host }
        Remove-Item -Path $upHealOut,$upHealErr -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 6
        $psHealOut = Join-Path $env:TEMP "coderaft-psheal-out-$(Get-Random).log"
        $psHealErr = Join-Path $env:TEMP "coderaft-psheal-err-$(Get-Random).log"
        $psHealProc = Start-Process -FilePath "docker" -ArgumentList @("compose","ps") `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $psHealOut `
            -RedirectStandardError  $psHealErr `
            -ErrorAction SilentlyContinue
        Remove-Item -Path $psHealOut,$psHealErr -ErrorAction SilentlyContinue
        if ($psHealProc.ExitCode -eq 0) {
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
if [ ! -f agents-ca.crt ]; then
    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
        -keyout agents-ca.key -out agents-ca.crt \
        -subj "/CN=falconone-agents-ca" \
        -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
fi
NEED_REGEN=1
if [ -f server.crt ] && openssl x509 -in server.crt -noout -text 2>/dev/null | grep -q "coderaft.local"; then
    NEED_REGEN=0
fi
if [ "$NEED_REGEN" = "1" ]; then
    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout server.key -out server.csr \
        -subj "/CN=falconone-agents" 2>/dev/null
    cat > /tmp/server.ext <<EOF
subjectAltName=__FO_SAN_LIST__
basicConstraints=CA:FALSE
EOF
    openssl x509 -req -days 3650 -sha256 \
        -in server.csr -CA agents-ca.crt -CAkey agents-ca.key -CAcreateserial \
        -out server.crt -extfile /tmp/server.ext 2>/dev/null
    rm -f server.csr
fi
chmod 644 *.crt *.key 2>/dev/null || true
'@
    $foScript = $foScript.Replace("__FO_SAN_LIST__", $foSanString)
    $foScriptFile = Join-Path $env:TEMP "coderaft-fo-tls-$(Get-Random).sh"
    $foScriptLF = $foScript -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($foScriptFile, $foScriptLF, [System.Text.UTF8Encoding]::new($false))
    $absFoTlsDir = (Resolve-Path -LiteralPath $foTlsDir).Path

    Start-Process -FilePath "docker" -ArgumentList @(
        "run", "--rm",
        "-v", "${foScriptFile}:/script.sh:ro",
        "-v", "${absFoTlsDir}:/work",
        "alpine:3.20", "sh", "/script.sh"
    ) -NoNewWindow -Wait -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path $foScriptFile -ErrorAction SilentlyContinue
    Write-Host "  ✓ FalconOne agents PKI written (SAN: $foSanString)"
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
        Write-Host "  [install] ACL self-heal: $AclPath not found — skipping (vault not provisioned yet)"
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
        "read:falconone/pki/agents-ca/cert"
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
'@
        Add-Content -LiteralPath $AclPath -Value $newBlock
        Write-Host "  [install] Self-heal ACL: falconone permissions updated (+$($requiredPerms.Count) added, entry created)"
        return
    }

    $blockEnd = $lines.Count
    for ($j = $blockStart + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*-\s*name:\s*\S') { $blockEnd = $j; break }
    }
    $blockText = ($lines[$blockStart..($blockEnd - 1)]) -join "`n"

    $missing = @($requiredPerms | Where-Object { $blockText -notmatch [regex]::Escape("`"$_`"") })

    if ($missing.Count -eq 0) {
        Write-Host "  [install] ACL falconone already up-to-date"
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

    Write-Host "  [install] Self-heal ACL: falconone permissions updated (+$($missing.Count) added)"
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
    Start-Process -FilePath "docker" -ArgumentList @("compose","ps","coderaft-vault") `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $vaultPsOut `
        -RedirectStandardError  $vaultPsErr `
        -ErrorAction SilentlyContinue | Out-Null
    $ps = (Get-Content $vaultPsOut -ErrorAction SilentlyContinue) -join " "
    Remove-Item -Path $vaultPsOut,$vaultPsErr -ErrorAction SilentlyContinue
    if ($ps -match "running") { $vaultRunning = $true }
} catch { }

$vaultNeedsMigration = $false
if (-not (Test-Path $vaultMigrationSentinel) -and -not $vaultRunning) {
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
        exit 1
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
        Start-Process -FilePath "docker" -ArgumentList @("compose","ps","postgres") `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $pgPsOut `
            -RedirectStandardError  $pgPsErr `
            -ErrorAction SilentlyContinue | Out-Null
        $pgPsText = (Get-Content $pgPsOut -ErrorAction SilentlyContinue) -join " "
        Remove-Item -Path $pgPsOut,$pgPsErr -ErrorAction SilentlyContinue
        $pgRunning = $pgPsText -match "running"
        if ($pgRunning) {
            $bakSql = Join-Path $vaultBak "auth_config.sql"
            $proc = Start-Process -FilePath "docker" `
                -ArgumentList @("compose","exec","-T","postgres","pg_dump","-U","coderaft","-t","auth_config","coderaft") `
                -RedirectStandardOutput $bakSql -NoNewWindow -PassThru -Wait
            if ($proc.ExitCode -ne 0) { Remove-Item $bakSql -ErrorAction SilentlyContinue }
        }
    } catch { }

    # Container-side files
    try {
        $rvPsOut = Join-Path $env:TEMP "coderaft-rvps-out-$(Get-Random).log"
        $rvPsErr = Join-Path $env:TEMP "coderaft-rvps-err-$(Get-Random).log"
        Start-Process -FilePath "docker" -ArgumentList @("compose","ps","ravenscan") `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $rvPsOut `
            -RedirectStandardError  $rvPsErr `
            -ErrorAction SilentlyContinue | Out-Null
        $rvRunning = ((Get-Content $rvPsOut -ErrorAction SilentlyContinue) -join " ") -match "running"
        Remove-Item -Path $rvPsOut,$rvPsErr -ErrorAction SilentlyContinue
        if ($rvRunning) {
            $rvCpErr = Join-Path $env:TEMP "coderaft-rvcp-err-$(Get-Random).log"
            $rvCpOut = Join-Path $env:TEMP "coderaft-rvcp-out-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList @("compose","cp","ravenscan:.ravenscan/ravenscan.db",(Join-Path $vaultBak "ravenscan.db")) `
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
        Start-Process -FilePath "docker" -ArgumentList @("compose","ps","dashboard-api") `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $apiPsOut `
            -RedirectStandardError  $apiPsErr `
            -ErrorAction SilentlyContinue | Out-Null
        $apiRunning = ((Get-Content $apiPsOut -ErrorAction SilentlyContinue) -join " ") -match "running"
        Remove-Item -Path $apiPsOut,$apiPsErr -ErrorAction SilentlyContinue
        if ($apiRunning) {
            $cp1Out = Join-Path $env:TEMP "coderaft-cp1-out-$(Get-Random).log"
            $cp1Err = Join-Path $env:TEMP "coderaft-cp1-err-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList @("compose","cp","dashboard-api:/data/vault.enc",(Join-Path $vaultBak "dashboard-vault.enc")) `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $cp1Out `
                -RedirectStandardError  $cp1Err `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -Path $cp1Out,$cp1Err -ErrorAction SilentlyContinue
            $cp2Out = Join-Path $env:TEMP "coderaft-cp2-out-$(Get-Random).log"
            $cp2Err = Join-Path $env:TEMP "coderaft-cp2-err-$(Get-Random).log"
            Start-Process -FilePath "docker" -ArgumentList @("compose","cp","dashboard-api:/data/admin_token",(Join-Path $vaultBak "admin_token")) `
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
            Start-Process -FilePath "docker" -ArgumentList @("compose","down") `
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
                Start-Process -FilePath "docker" -ArgumentList @("compose","up","-d","postgres") `
                    -NoNewWindow -Wait `
                    -RedirectStandardOutput $rbPgOut `
                    -RedirectStandardError  $rbPgErr `
                    -ErrorAction SilentlyContinue | Out-Null
                Remove-Item -Path $rbPgOut,$rbPgErr -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
                # pipe SQL into psql via Start-Process stdin redirect
                $rbPsqlOut = Join-Path $env:TEMP "coderaft-rbpsql-out-$(Get-Random).log"
                $rbPsqlErr = Join-Path $env:TEMP "coderaft-rbpsql-err-$(Get-Random).log"
                Start-Process -FilePath "docker" -ArgumentList @("compose","exec","-T","postgres","psql","-U","coderaft","coderaft") `
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
            Start-Process -FilePath "docker" -ArgumentList @("compose","up","-d") `
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
        Write-Host "  Press any key to acknowledge before the window closes..." -ForegroundColor Yellow
        if (-not $env:CODERAFT_TEST_MODE) {
            try { [void][System.Console]::ReadKey($true) } catch { Start-Sleep -Seconds 30 }
        }
        exit 1
    }

    # ── 4c Vault directories (always) ─────────────────────────────────────
    New-Item -ItemType Directory -Force -Path (Join-Path $INSTALL_DIR "vault-keys")   | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $INSTALL_DIR "vault-tls")    | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $INSTALL_DIR "vault-config") | Out-Null

    # ── 4c.1 Age master key (ONCE — rotating it would orphan vault.db) ────
    if (-not (Test-Path $vaultAgeKey)) {
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
                if (-not $ageKeygenExe) { Invoke-VaultMigrationRollback "age-keygen.exe missing in downloaded archive" }
                $ageKeygen = [pscustomobject]@{ Path = $ageKeygenExe.FullName }
                Write-Host "    ✓ age-keygen downloaded to $($ageKeygen.Path)"
            } catch {
                Invoke-VaultMigrationRollback "age-keygen download failed: $($_.Exception.Message)"
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
        if (-not (Test-Path $vaultAgeKey)) { Invoke-VaultMigrationRollback "age-keygen failed" }

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
        if ($reply -ne "CONFIRMED") { Invoke-VaultMigrationRollback "operator did not confirm recovery phrase" }
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
rm -f vault.csr
# Per-product client certs
for pair in "dashboard-api:dashboard-api.coderaft.local" \
            "entraguard:entraguard.coderaft.local" \
            "ravenscan:ravenscan.coderaft.local" \
            "redfox:redfox.coderaft.local" \
            "falconone:falconone.coderaft.local"; do
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
    rm -f "${name}-client.csr"
done
chmod 600 *.key 2>/dev/null || true
# falconone-api runs distroless nonroot (uid 65532) — it CAN'T read files
# owned by root with mode 600. Loosen to 644 so the bind-mounted certs are
# world-readable inside the container. The private key lives on a chmod 700
# vault-tls dir anyway, and Docker Desktop's Windows/Mac bind-mount already
# strips POSIX perms, so this only affects Linux hosts.
chmod 644 falconone-client.key falconone-client.crt 2>/dev/null || true
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
        Invoke-VaultMigrationRollback "openssl-in-alpine cert generation failed (see $migrationLog)"
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
    permissions: ["read:redfox_*","read:license_key","read:platform/identity/oidc"]
  - name: falconone
    cert_san: "falconone.coderaft.local"
    permissions: ["read:license_key","read:falconone_*","read:platform/identity/oidc","sign:falconone_agent_cert","read:falconone/nvd_api_key","read:falconone/audit_hmac_key","write:falconone/audit_hmac_key","read:falconone/pki/agents-ca/cert"]
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
    if ($env:CODERAFT_TEST_FAIL -eq "4d") { Invoke-VaultMigrationRollback "injected test failure at 4d" }

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
        if ($vPullProc.ExitCode -ne 0) { Invoke-VaultMigrationRollback "docker pull failed (see $migrationLog)" }
    }

    Write-Host "  Starting vault container..."
    Push-Location $INSTALL_DIR -ErrorAction Stop
    # Explicit stop+rm to guarantee the container reloads cert/config files
    # from the host bind mounts (the TLS PKI bootstrap regenerated them this
    # run). --force-recreate alone has been observed to leave the container
    # in "Running" state on Docker Desktop Windows, with stale certs in mem.
    # B20 (2026-06-08): all docker calls via Start-Process to avoid NativeCommandError PS 5.1
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
    Pop-Location -ErrorAction SilentlyContinue
    if ($upExit -ne 0) { Invoke-VaultMigrationRollback "docker compose up coderaft-vault failed (see $migrationLog)" }

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
    Start-Process -FilePath "docker" -ArgumentList @("inspect","coderaft-coderaft-vault-1","--format",$inspFmt2) `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $inspOut2 `
        -RedirectStandardError  $inspErr2 `
        -ErrorAction SilentlyContinue | Out-Null
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
        Invoke-VaultMigrationRollback "coderaft-vault did not respond to TLS probes"
    }

    # Unseal if sealed (PassphraseSealer = 1 share = the age private key bytes)
    if ($lastSealed -eq "true") {
        Write-Host "  Vault is sealed — sending unseal request..."
        $ageKeyBytes = [System.IO.File]::ReadAllBytes($vaultAgeKey)
        $shareB64 = [Convert]::ToBase64String($ageKeyBytes)
        $unsealBody = @{ shares = @($shareB64) } | ConvertTo-Json -Compress
        $unsealResp = Invoke-VaultCurl -Method "POST" -Path "/v1/unseal" -JsonBody $unsealBody
        "[$(Get-Date -Format o)] unseal response → $unsealResp" | Out-File -FilePath $migrationLog -Append -Encoding utf8
        if ($unsealResp -notmatch '"ok"\s*:\s*true|"sealed"\s*:\s*false') {
            Write-Host "  Unseal response: $unsealResp" -ForegroundColor Yellow
            Invoke-VaultMigrationRollback "vault unseal failed (see $migrationLog)"
        }
        Write-Host "  ✓ Vault unsealed"
    }

    # Final health check — must say sealed:false now
    $finalHealth = Invoke-VaultCurl -Method "GET" -Path "/v1/health"
    "[$(Get-Date -Format o)] final health → $finalHealth" | Out-File -FilePath $migrationLog -Append -Encoding utf8
    if ($finalHealth -notmatch '"sealed"\s*:\s*false') {
        Write-Host "  Final health: $finalHealth" -ForegroundColor Yellow
        Invoke-VaultMigrationRollback "vault still sealed after unseal call"
    }
    Write-Host "  ✓ coderaft-vault is healthy"

    # ── 4e Migrate secrets ────────────────────────────────────────────────
    if ($env:CODERAFT_TEST_FAIL -eq "4e") { Invoke-VaultMigrationRollback "injected test failure at 4e" }

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

    $secretMap = @(
        @("LICENSE_KEY",              "license_key"),
        @("POSTGRES_PASSWORD",        "postgres_password"),
        @("REDIS_PASSWORD",           "redis_password"),
        @("DASHBOARD_SECRET",         "dashboard_secret_legacy"),
        @("NEO4J_PASSWORD",           "neo4j_password"),
        @("RAVENSCAN_SECRET_KEY",     "ravenscan_secret_key"),
        @("RAVENSCAN_CAPTURE_TOKEN",  "ravenscan_capture_token"),
        @("RAVENSCAN_LICENSE_KEY",    "ravenscan_license_key"),
        @("REDFOX_MASTER_PASSPHRASE", "redfox_master_passphrase"),
        @("REDFOX_JWT_PRIVATE_KEY",   "redfox_jwt_private_key"),
        @("REDFOX_JWT_PUBLIC_KEY",    "redfox_jwt_public_key"),
        @("REDFOX_GW_SESSION_SECRET", "redfox_gw_session_secret"),
        @("REDFOX_LICENSE_KEY",       "redfox_license_key")
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
    if (-not $migrationOk) { Invoke-VaultMigrationRollback "secret migration verify failed" }
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
# permissions healed.
Invoke-FalconOneTlsBootstrap -InstallDir $INSTALL_DIR
Invoke-FalconOneAclSelfHeal -AclPath (Join-Path $INSTALL_DIR "vault-config\acl.yaml")

# ── Banking-grade plaintext purge (auto) ──────────────────────────────────
# When .env.enc exists, the plaintext .env MUST be purged. The oneliner
# does the finalize itself: verifies decryption matches plaintext, keeps a
# 24h .bak, then deletes plaintext. Falls back to a warning otherwise.
Write-Host ""
Write-Host "  Banking-grade secret check..."
$envPlain = Join-Path $INSTALL_DIR ".env"
$envEnc   = Join-Path $INSTALL_DIR ".env.enc"
if ((Test-Path $envEnc) -and (Test-Path $envPlain)) {
    $ageKey = if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $INSTALL_DIR ".coderaft-age.key" }
    if (-not (Test-Path $ageKey) -and (Test-Path "C:\ProgramData\coderaft\age.key")) {
        $ageKey = "C:\ProgramData\coderaft\age.key"
    }
    $sopsCmd = Get-Command sops -ErrorAction SilentlyContinue
    $sops = if ($sopsCmd) { $sopsCmd.Path } else { $null }
    if (-not (Test-Path $ageKey)) {
        Write-Host "  [!] .env + .env.enc coexist but age key not found at $ageKey" -ForegroundColor Yellow
        Write-Host "      Plaintext .env left in place; investigate before next run." -ForegroundColor Yellow
    } elseif (-not $sops) {
        Write-Host "  [i] sops missing on host — update.ps1 skips the automatic finalize." -ForegroundColor Yellow
        Write-Host "      Choose one method to purge the plaintext .env:" -ForegroundColor Yellow
        Write-Host "        A) Dashboard  →  Settings → Migrate secrets  (runs inside dashboard-api)" -ForegroundColor Yellow
        Write-Host "        B) CLI        →  iex (irm https://install.coderaft.io/migrate.ps1) -Finalize" -ForegroundColor Yellow
        Write-Host "                          (auto-downloads sops.exe + age-keygen.exe)" -ForegroundColor Yellow
    } else {
        $env:SOPS_AGE_KEY_FILE = $ageKey
        $decrypted = & $sops --decrypt --input-type dotenv --output-type dotenv $envEnc 2>$null
        if (-not $decrypted) {
            Write-Host "  [!] sops decrypt of .env.enc returned empty — leaving plaintext" -ForegroundColor Yellow
        } else {
            $bakDir = Join-Path $INSTALL_DIR "dashboard_data"
            New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
            $bakFile = Join-Path $bakDir ("env-pre-finalize-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak")
            Copy-Item $envPlain $bakFile -ErrorAction SilentlyContinue
            $plainNorm   = (Get-Content $envPlain | Where-Object { $_ -notmatch '^\s*(#|$)' } | Sort-Object) -join "`n"
            $decryptNorm = ($decrypted | Where-Object { $_ -notmatch '^\s*(#|$)' } | Sort-Object) -join "`n"
            if ($plainNorm -eq $decryptNorm) {
                Remove-Item $envPlain -Force
                Write-Host "  ✓ plaintext .env purged (backup: $bakFile, kept 24h)"
            } else {
                Write-Host "  [!] .env and .env.enc differ — refusing to purge plaintext." -ForegroundColor Yellow
                Write-Host "      Choose one method to reconcile + purge:" -ForegroundColor Yellow
                Write-Host "        A) Dashboard  →  Settings → Migrate secrets" -ForegroundColor Yellow
                Write-Host "        B) CLI        →  iex (irm https://install.coderaft.io/migrate.ps1)" -ForegroundColor Yellow
                Write-Host "      Backup written to $bakFile" -ForegroundColor Yellow
            }
        }
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
if (Test-Path ".env") {
    $envLine = Get-Content ".env" | Where-Object { $_ -match '^\s*CODERAFT_HOST_OS\s*=' } | Select-Object -Last 1
    if ($envLine) {
        $hostOsValue = ($envLine -replace '^\s*CODERAFT_HOST_OS\s*=', '').Trim().Trim('"').Trim("'").ToLower()
    }
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
    Start-Process -FilePath "docker" -ArgumentList @("compose","ps","postgres","--quiet") `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $pgQOut `
        -RedirectStandardError  $pgQErr `
        -ErrorAction SilentlyContinue | Out-Null
    $psOutput = (Get-Content $pgQOut -ErrorAction SilentlyContinue) -join ""
    Remove-Item -Path $pgQOut,$pgQErr -ErrorAction SilentlyContinue
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

    $content = if (Test-Path $OverrideFile -PathType Leaf) {
        Get-Content -LiteralPath $OverrideFile -ErrorAction SilentlyContinue
    } else { @() }

    # Read current key from .env first (source of truth read by
    # dashboard-api), fall back to override.yml. Ensures we always validate
    # the OLDEST stale key still on disk and propagate the refreshed value
    # to all stores — even when override.yml was rotated by a previous run
    # but .env wasn't.
    $currentKey = $null
    $envFile = Join-Path $INSTALL_DIR ".env"
    if (Test-Path $envFile -PathType Leaf) {
        $envLines = Get-Content -LiteralPath $envFile
        foreach ($line in $envLines) {
            if ($line -match "^\s*$([Regex]::Escape($EnvVar))=(.+)$") {
                $currentKey = $Matches[1].Trim().Trim('"').Trim("'")
                break
            }
        }
    }
    if (-not $currentKey) {
        $regex = "^\s*-?\s*$([Regex]::Escape($EnvVar))=(.+)$"
        foreach ($line in $content) {
            if ($line -match $regex) {
                $currentKey = $Matches[1].Trim().Trim('"').Trim("'")
                break
            }
        }
    }
    $regex = "^\s*-?\s*$([Regex]::Escape($EnvVar))=(.+)$"
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
        # 1. override.yml — replace ALL occurrences (worker + api may share)
        Copy-Item -LiteralPath $OverrideFile -Destination "$OverrideFile.bak" -Force
        $newContent = foreach ($line in $content) {
            if ($line -match $regex) {
                $padMatch = [Regex]::Match($line, "^(\s*-?\s*)")
                $pad = $padMatch.Groups[1].Value
                "$pad$EnvVar=$latest"
            } else { $line }
        }
        [System.IO.File]::WriteAllLines($OverrideFile, $newContent, (New-Object System.Text.UTF8Encoding($false)))

        # 2. .env (host) — dashboard-api reads this directly. Without this
        #    sync, override.yml has the new key but dashboard-api keeps
        #    seeing the old one and license.json never refreshes.
        $envFile = Join-Path $INSTALL_DIR ".env"
        if (Test-Path $envFile) {
            $envLines = Get-Content -LiteralPath $envFile
            $envRegex = "^\s*${EnvVar}="
            if ($envLines -match $envRegex) {
                Copy-Item -LiteralPath $envFile -Destination "$envFile.bak.$(Get-Date -UFormat %s)" -Force -ErrorAction SilentlyContinue
                $newEnv = foreach ($l in $envLines) {
                    if ($l -match $envRegex) { "$EnvVar=$latest" } else { $l }
                }
                [System.IO.File]::WriteAllLines($envFile, $newEnv, (New-Object System.Text.UTF8Encoding($false)))
            }
        }

        # 3. .env.enc — re-encrypt so next dashboard-api boot reads fresh
        $envEnc = Join-Path $INSTALL_DIR ".env.enc"
        $sopsCmd = Get-Command sops -ErrorAction SilentlyContinue
        if ((Test-Path $envEnc) -and $sopsCmd -and (Test-Path $envFile)) {
            $ageKey = if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $INSTALL_DIR ".coderaft-age.key" }
            if (-not (Test-Path $ageKey) -and (Test-Path "C:\ProgramData\coderaft\age.key")) {
                $ageKey = "C:\ProgramData\coderaft\age.key"
            }
            if (Test-Path $ageKey) {
                $env:SOPS_AGE_KEY_FILE = $ageKey
                try {
                    # B20 (2026-06-08): `& $sopsCmd.Path ... > file 2>$null` → NativeCommandError PS 5.1
                    $sopsEncTmp = "$envEnc.tmp"
                    $sopsEncErr = Join-Path $env:TEMP "coderaft-sopsenc-err-$(Get-Random).log"
                    $sopsProc = Start-Process -FilePath $sopsCmd.Path `
                        -ArgumentList @("--encrypt","--input-type","dotenv","--output-type","dotenv",$envFile) `
                        -NoNewWindow -Wait -PassThru `
                        -RedirectStandardOutput $sopsEncTmp `
                        -RedirectStandardError  $sopsEncErr `
                        -ErrorAction SilentlyContinue
                    Remove-Item -Path $sopsEncErr -ErrorAction SilentlyContinue
                    if ($sopsProc.ExitCode -eq 0) { Move-Item -Force $sopsEncTmp $envEnc } else { Remove-Item -Force $sopsEncTmp -ErrorAction SilentlyContinue }
                } catch { }
            }
        }

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
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $inspCiOut `
                -RedirectStandardError  $inspCiErr `
                -ErrorAction SilentlyContinue
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

# ── #137 fix: refresh certs/server-ca.pem from Caddy internal CA ─────────
# entraguard-api mounts certs/server-ca.pem into the container and hands
# it to endpoint agents at /register (as `ca_cert`) so agents can verify
# the Caddy front cert on their report loop. Any operator that ran an
# install BEFORE this fix landed has no server-ca.pem — refresh it every
# update so the file exists (idempotent, non-fatal on failure).
Write-Host "  Refreshing certs\server-ca.pem from Caddy internal CA…"
try {
    New-Item -ItemType Directory -Force -Path (Join-Path (Get-Location) "certs") | Out-Null
    $caContainerPath = "/data/caddy/pki/authorities/local/root.crt"
    $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
        & docker @ComposeArgs exec -T caddy test -f $caContainerPath 2>$null
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        Start-Sleep -Seconds 2
    }
    if ($ok) {
        $caLocal = Join-Path (Get-Location) "certs\server-ca.pem"
        & docker @ComposeArgs cp "caddy:$caContainerPath" $caLocal 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $caLocal)) {
            Write-Host "  ✓ certs\server-ca.pem refreshed (entraguard-api will pick it up on next call)"
            # Restart entraguard-api so the (bind-mounted) new CA is
            # visible without waiting for the next container recreate.
            & docker @ComposeArgs restart entraguard-api 2>$null | Out-Null
        } else {
            Write-Host "  ⚠ docker cp for Caddy CA failed (exit $LASTEXITCODE)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠ Caddy CA not found after 40s — endpoint agents may see x509 errors until it's exported." -ForegroundColor Yellow
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
    exit 1
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
Start-Process -FilePath "docker" -ArgumentList @(
        "exec", "coderaft-dashboard-api-1",
        "cat", "/proc/sys/net/ipv6/conf/all/disable_ipv6"
    ) -NoNewWindow -Wait `
      -RedirectStandardOutput $v6Out `
      -RedirectStandardError  $v6Err `
      -ErrorAction SilentlyContinue | Out-Null
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
