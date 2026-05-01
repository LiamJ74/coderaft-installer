# CodeRaft rollback (Windows / PowerShell)
#
# Restores a previous deployment by re-running containers with the image IDs
# recorded in a recovery snapshot. Volumes are preserved so client data
# (audits, scans, sessions, encrypted secrets vault) is untouched.
#
# Usage:
#   $env:ADMIN_TOKEN="<token>"; .\rollback.ps1                  # interactive
#   $env:ADMIN_TOKEN="<token>"; .\rollback.ps1 <snapshot-id>    # non-interactive
#
# To get an ADMIN_TOKEN: sign in to the dashboard (http://localhost:3000),
# open the browser dev tools, copy the value of the 'coderaft_token' cookie.

$ErrorActionPreference = "Stop"

$DASHBOARD_API = if ($env:DASHBOARD_API) { $env:DASHBOARD_API } else { "http://localhost:3000" }
$ADMIN_TOKEN   = if ($env:ADMIN_TOKEN)   { $env:ADMIN_TOKEN }   else { "" }

if (-not $ADMIN_TOKEN) {
    Write-Host "ERROR: `$env:ADMIN_TOKEN is required."
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
    $body = "{`"id`":`"$TARGET_ID`"}"
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
