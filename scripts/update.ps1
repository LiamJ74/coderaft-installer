# CodeRaft updater (Windows / PowerShell)
#
# Self-updates from the installer repo, then captures a pre-update recovery
# snapshot before pulling new images. If something breaks, run rollback.ps1.

$ErrorActionPreference = "Stop"

$DASHBOARD_API = if ($env:DASHBOARD_API) { $env:DASHBOARD_API } else { "http://localhost:3001" }
$ADMIN_TOKEN   = if ($env:ADMIN_TOKEN)   { $env:ADMIN_TOKEN }   else { "" }

Write-Host "  Updating CodeRaft..."

# ── Self-update update.ps1 + rollback.ps1 ──────────────────────────────────
Write-Host "  Checking for script updates..."
foreach ($name in @("update.ps1", "rollback.ps1")) {
    try {
        $url = "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/$name"
        $latest = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($latest.StatusCode -eq 200 -and $latest.Content.Length -gt 50) {
            [System.IO.File]::WriteAllText("$PWD\$name", $latest.Content, [System.Text.Encoding]::UTF8)
            Write-Host "  $name refreshed"
        }
    } catch {
        # Offline or upstream missing — keep the local copy
    }
}

# ── Pre-update recovery snapshot ───────────────────────────────────────────
Write-Host "  Capturing pre-update recovery snapshot..."
if ($ADMIN_TOKEN) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $ADMIN_TOKEN"
        }
        $body = '{"reason":"pre-update"}'
        Invoke-RestMethod -Method Post -Uri "$DASHBOARD_API/api/dashboard/recovery/snapshots" `
            -Headers $headers -Body $body -TimeoutSec 10 | Out-Null
        Write-Host "    snapshot saved"
    } catch {
        Write-Host "    snapshot failed (continuing — auto-snapshot still runs on next deploy)"
    }
} else {
    Write-Host "    skipped (set `$env:ADMIN_TOKEN to enable; auto-snapshot still runs on next deploy)"
}

# ── Pull and recreate ──────────────────────────────────────────────────────
docker compose pull
docker compose up -d --force-recreate --remove-orphans
Write-Host ""
Write-Host "  Updated! Dashboard: http://localhost:3000"
Write-Host "  If something is broken: irm https://install.coderaft.io/rollback.ps1 | iex"
