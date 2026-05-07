# vault-set.ps1 — post-install helper to write a secret into coderaft-vault.
#
# Usage:
#   .\vault-set.ps1 -Name <secret-name> -Value <secret-value>
#
# The vault is on coderaft-vault-net (internal Docker network); we reach it
# via docker exec into the running vault container.
#
# Requires: docker, a running coderaft-vault container.

param(
    [Parameter(Mandatory=$true)]  [string] $Name,
    [Parameter(Mandatory=$true)]  [string] $Value,
    [string] $InstallDir = $env:INSTALL_DIR
)

if (-not $InstallDir) { $InstallDir = (Get-Location).Path }

# Verify vault is running
$ps = & docker compose ps coderaft-vault 2>$null
if ($ps -notmatch "running") {
    Write-Host "  [!] coderaft-vault is not running." -ForegroundColor Red
    Write-Host "    Start it with: docker compose up -d coderaft-vault" -ForegroundColor Red
    exit 1
}

# Build JSON via ConvertTo-Json (PS 5.1 compatible).
$body = @{ name = $Name; value = $Value } | ConvertTo-Json -Compress
# POSIX-shell-quote the body for the wget --post-data argument.
$shellSafeBody = $body -replace "'", "'\''"

Write-Host "  Setting secret: $Name..."
$resp = ""
try {
    Push-Location $InstallDir -ErrorAction SilentlyContinue
    $cmd = "wget -qO- --post-data='$shellSafeBody' --header='Content-Type: application/json' http://localhost:8200/v1/secret/set"
    $resp = & docker compose exec -T coderaft-vault /bin/sh -c $cmd 2>&1
    Pop-Location -ErrorAction SilentlyContinue
} catch {
    Write-Host "  [!] docker exec failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($resp -match '"ok":true') {
    Write-Host "  ✓ Secret '$Name' stored in vault" -ForegroundColor Green
} else {
    Write-Host "  [!] vault set failed. Response: $resp" -ForegroundColor Red
    exit 1
}
