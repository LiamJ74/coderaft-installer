# CodeRaft rollback (Windows / PowerShell)
#
# Restores a previous deployment by re-running containers with the image IDs
# recorded in a recovery snapshot. Volumes are preserved so client data
# (audits, scans, sessions, encrypted secrets vault) is untouched.
#
# Usage:
#   $env:ADMIN_TOKEN="<token>"; .\rollback.ps1                  # interactive
#   $env:ADMIN_TOKEN="<token>"; .\rollback.ps1 <snapshot-id>    # non-interactive
#   .\rollback.ps1                                              # auto-discovers
#                                                                # a token (see
#                                                                # Find-AdminToken
#                                                                # below) — this
#                                                                # is the path
#                                                                # update.ps1's
#                                                                # automatic
#                                                                # rollback uses.
#
# To get an ADMIN_TOKEN manually: sign in to the dashboard (http://localhost:3000),
# open the browser dev tools, copy the value of the 'coderaft_token' cookie.

$ErrorActionPreference = "Stop"

$DASHBOARD_API = if ($env:DASHBOARD_API) { $env:DASHBOARD_API } else { "http://localhost:3000" }
$ADMIN_TOKEN   = if ($env:ADMIN_TOKEN)   { $env:ADMIN_TOKEN }   else { "" }
$INSTALL_DIR   = if ($env:INSTALL_DIR)   { $env:INSTALL_DIR }   else { (Get-Location).Path }

# install-config.env: same host-level interpolation file update.ps1 uses (see
# its own comment for the full rationale) — needed here too because the
# auto-discovery step below runs `docker compose exec`, which requires every
# ${VAR:?...} in docker-compose.yml to resolve even for a read-only exec.
$INSTALL_CONFIG_PATH = Join-Path $INSTALL_DIR "install-config.env"
if (-not (Test-Path $INSTALL_CONFIG_PATH -PathType Leaf)) {
    try { New-Item -ItemType File -Path $INSTALL_CONFIG_PATH -ErrorAction Stop | Out-Null } catch {}
}
$ComposeEnvArgs = @("--env-file", $INSTALL_CONFIG_PATH, "--env-file", (Join-Path $INSTALL_DIR ".env"))

# ── ADMIN_TOKEN auto-discovery ────────────────────────────────────────────
# Mirrors update.ps1's Find-AdminToken() (kept in sync manually — see that
# script for the identical, authoritative version of this comment).
#
# Root cause fix (2026-09, live incident): update.ps1 already auto-discovers
# an ADMIN_TOKEN (this same function) before running, but only stored it in
# its own *script variable* — never wrote it to $env:ADMIN_TOKEN — so when it
# launched `& $PSBin -File .\rollback.ps1` on a failed post-update
# healthcheck, the child process started with an empty environment and
# rollback.ps1 (which back then had no discovery logic of its own) failed
# immediately with "$env:ADMIN_TOKEN is required", meaning the "automatic"
# rollback could never actually run unattended. update.ps1/update.sh now also
# export/propagate the token they resolved into the rollback child process
# (defense in depth) — but rollback.ps1 is made self-sufficient here too, so
# it authenticates on its own whether it's invoked by update.ps1's
# auto-rollback path or run standalone by an operator.
#
# Auto-read /data/admin_token from the running dashboard-api container is the
# "CLI admin token": a long-lived (365d) global_admin JWT that dashboard-api
# mints for itself at boot specifically for this kind of local automation
# (see server.js's ensureCliAdminToken() — "a host-trusted maintenance
# credential used by update.sh/install.sh, never a browser session"). Only
# reachable via `docker compose exec` on THIS host — it is never served over
# HTTP or otherwise exposed to the network, so this discovery path cannot be
# triggered remotely.
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
        (Join-Path $HOME ".coderaft\admin_token")
    )
    foreach ($tokenFile in $tokenCandidates) {
        if ($tokenFile -and (Test-Path $tokenFile -PathType Leaf)) {
            try {
                $val = (Get-Content -LiteralPath $tokenFile -Raw -ErrorAction Stop).Trim()
                if ($val) { return $val }
            } catch { }
        }
    }

    # Auto-discovery from the running dashboard-api container (preferred,
    # avoids any manual setup — see the comment above this function).
    try {
        Push-Location $INSTALL_DIR -ErrorAction SilentlyContinue
        # B20 (2026-06-08) pattern reused: `& docker compose ps ... 2>$null`
        # surfaces stderr as NativeCommandError in PS 5.1 — use Start-Process
        # + temp files instead, same as update.ps1's Find-AdminToken.
        $svcStdout = Join-Path $env:TEMP "coderaft-rollback-svc-out-$(Get-Random).log"
        $svcStderr = Join-Path $env:TEMP "coderaft-rollback-svc-err-$(Get-Random).log"
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
            $catStdout = Join-Path $env:TEMP "coderaft-rollback-cat-out-$(Get-Random).log"
            $catStderr = Join-Path $env:TEMP "coderaft-rollback-cat-err-$(Get-Random).log"
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

if (-not $ADMIN_TOKEN) {
    Write-Host "ERROR: `$env:ADMIN_TOKEN is required."
    Write-Host ""
    Write-Host "Auto-discovery also failed (no .env, no token file, and either the"
    Write-Host "dashboard-api container isn't running or /data/admin_token wasn't"
    Write-Host "readable yet)."
    Write-Host ""
    Write-Host "Sign in to the dashboard (http://localhost:3000), open the browser"
    Write-Host "dev tools, copy the value of the 'coderaft_token' cookie, then run:"
    Write-Host ""
    Write-Host "    `$env:ADMIN_TOKEN='<your-token>'; .\rollback.ps1"
    exit 1
}

$headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer $ADMIN_TOKEN"
}

$TARGET_ID = if ($args.Count -gt 0) { $args[0] } else { "" }

if (-not $TARGET_ID) {
    Write-Host "  Available snapshots (newest first):"
    try {
        $list = Invoke-RestMethod -Uri "$DASHBOARD_API/api/dashboard/recovery/snapshots" `
            -Headers $headers -TimeoutSec 10
    } catch {
        Write-Host "  ERROR: could not reach $DASHBOARD_API ($_)"
        exit 1
    }

    if (-not $list.snapshots -or $list.snapshots.Count -eq 0) {
        Write-Host "  No snapshots available."
        exit 2
    }

    $i = 1
    foreach ($s in $list.snapshots) {
        $products = ($s.products -join ',')
        Write-Host ("  {0}. {1}  reason={2}  products=[{3}]  services={4}" -f $i, $s.id, $s.reason, $products, $s.service_count)
        $i++
    }
    Write-Host ""
    $TARGET_ID = Read-Host "  Snapshot id to roll back to"
}

if (-not $TARGET_ID) {
    Write-Host "  ERROR: no snapshot id provided."
    exit 1
}

Write-Host ""
Write-Host "  Rolling back to snapshot $TARGET_ID ..."

try {
    # C14 fix: use ConvertTo-Json instead of hand-escaped double-quoted string.
    # The backtick-escape form ("{`"id`":`"$TARGET_ID`"}") cascade-fails in PS 5.1
    # when TARGET_ID contains characters that interact with the PS parser.
    $body = @{ id = $TARGET_ID } | ConvertTo-Json -Compress
    $result = Invoke-RestMethod -Method Post -Uri "$DASHBOARD_API/api/dashboard/recovery/rollback" `
        -Headers $headers -Body $body -TimeoutSec 60
} catch {
    Write-Host "  Rollback failed: $_"
    exit 1
}

if ($result.ok) {
    $restored = if ($result.restored) { $result.restored.Count } else { 0 }
    $skipped  = if ($result.skipped)  { $result.skipped.Count }  else { 0 }
    Write-Host "  Rollback OK — $restored container(s) restored, $skipped skipped."
    foreach ($x in $result.skipped) {
        Write-Host "    skipped $($x.service): $($x.reason)"
    }
} else {
    Write-Host "  Rollback failed: $($result.error)"
    exit 1
}

Write-Host ""
Write-Host "  Check container state with: docker compose ps"
