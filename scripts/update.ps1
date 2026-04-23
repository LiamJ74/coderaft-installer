Write-Host "  Updating CodeRaft..."

# Self-update: download latest update script
Write-Host "  Checking for script updates..."
try {
    $latest = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/update.ps1" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    if ($latest.StatusCode -eq 200 -and $latest.Content.Length -gt 50) {
        [System.IO.File]::WriteAllText("$PWD\update.ps1", $latest.Content, [System.Text.Encoding]::UTF8)
        Write-Host "  Update script refreshed"
    }
} catch {
    # Offline or not available - continue with current version
}

# Pull latest images and recreate containers
docker compose pull
docker compose up -d --force-recreate --remove-orphans
Write-Host "  Updated! Dashboard: http://localhost:3000"
