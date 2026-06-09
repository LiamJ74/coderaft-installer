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
# B20 (2026-06-08): `& docker compose ps ... 2>$null` → NativeCommandError PS 5.1
$vsPsOut = Join-Path $env:TEMP "coderaft-vsps-out-$(Get-Random).log"
$vsPsErr = Join-Path $env:TEMP "coderaft-vsps-err-$(Get-Random).log"
Start-Process -FilePath "docker" -ArgumentList @("compose","ps","coderaft-vault") `
    -NoNewWindow -Wait `
    -RedirectStandardOutput $vsPsOut `
    -RedirectStandardError  $vsPsErr `
    -ErrorAction SilentlyContinue | Out-Null
$ps = (Get-Content $vsPsOut -ErrorAction SilentlyContinue) -join " "
Remove-Item -Path $vsPsOut,$vsPsErr -ErrorAction SilentlyContinue
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
    # B20 (2026-06-08): `& docker compose exec -T ... 2>&1` → NativeCommandError PS 5.1
    $vsExecOut = Join-Path $env:TEMP "coderaft-vsexec-out-$(Get-Random).log"
    $vsExecErr = Join-Path $env:TEMP "coderaft-vsexec-err-$(Get-Random).log"
    Start-Process -FilePath "docker" -ArgumentList @("compose","exec","-T","coderaft-vault","/bin/sh","-c",$cmd) `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $vsExecOut `
        -RedirectStandardError  $vsExecErr `
        -ErrorAction SilentlyContinue | Out-Null
    $resp = (Get-Content $vsExecOut -ErrorAction SilentlyContinue) -join ""
    Remove-Item -Path $vsExecOut,$vsExecErr -ErrorAction SilentlyContinue
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
