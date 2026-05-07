# vault-recover.ps1 — recovery-phrase path: reconstruct vault-keys\age.key
#                     from the 24-word BIP39 mnemonic, then restart the vault.
#
# Usage:
#   .\vault-recover.ps1
#
# TODO (Phase 1 follow-up): verify the -mnemonic-to-key sub-command is
# implemented in coderaft-vault before production use.

param(
    [string] $InstallDir = $env:INSTALL_DIR
)

if (-not $InstallDir) { $InstallDir = (Get-Location).Path }

Write-Host ""
Write-Host "  +==================================================================+" -ForegroundColor Cyan
Write-Host "  |          coderaft-vault — Recovery Mode                         |" -ForegroundColor Cyan
Write-Host "  +==================================================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This procedure reconstructs vault-keys\age.key from your 24-word"
Write-Host "  recovery phrase and restarts the vault container."
Write-Host ""
Write-Host "  IMPORTANT: This replaces the existing vault-keys\age.key file."
Write-Host "  Make sure you have a recent backup before continuing."
Write-Host ""

$recoveryPhrase = Read-Host -AsSecureString "  Enter your 24-word recovery phrase"
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($recoveryPhrase)
try { $phraseText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

if (-not $phraseText) {
    Write-Host "  [!] No phrase entered. Aborting." -ForegroundColor Red
    exit 1
}

$wordCount = ($phraseText.Trim() -split '\s+').Count
if ($wordCount -lt 12) {
    Write-Host "  [!] Recovery phrase looks too short ($wordCount words)." -ForegroundColor Red
    exit 1
}

Write-Host "  Reconstructing age key from recovery phrase..."

# Backup existing key
$vaultAgeKey = Join-Path $InstallDir "vault-keys\age.key"
if (Test-Path $vaultAgeKey) {
    $ts = Get-Date -Format "yyyyMMddTHHmmssZ"
    Copy-Item $vaultAgeKey "$vaultAgeKey.bak-$ts" -ErrorAction SilentlyContinue
    Write-Host "  Existing key backed up to: vault-keys\age.key.bak-$ts"
}

# Reconstruct via vault container CLI sub-command
# TODO (Phase 1 follow-up): verify -mnemonic-to-key exists in coderaft-vault image
$reconstructedKey = ""
try {
    $reconstructedKey = ($phraseText | & docker run --rm -i `
        ghcr.io/liamj74/coderaft-vault:latest -mnemonic-to-key /dev/stdin 2>$null) -join ""
} catch { $reconstructedKey = "" }

if (-not $reconstructedKey) {
    Write-Host ""
    Write-Host "  [!] -mnemonic-to-key sub-command not available (Phase 1 TODO)." -ForegroundColor Yellow
    Write-Host "    Restore vault-keys\age.key from a secure backup (USB / 1Password)." -ForegroundColor Yellow
    exit 1
}

if ($reconstructedKey -notmatch '^AGE-SECRET-KEY-') {
    Write-Host "  [!] Reconstructed key does not look like an age private key." -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "vault-keys") | Out-Null
[System.IO.File]::WriteAllText($vaultAgeKey, "$reconstructedKey`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "  ✓ vault-keys\age.key restored" -ForegroundColor Green

# Restart vault
Write-Host "  Restarting coderaft-vault..."
try {
    Push-Location $InstallDir -ErrorAction SilentlyContinue
    & docker compose restart coderaft-vault 2>$null
    Pop-Location -ErrorAction SilentlyContinue
} catch {
    Push-Location $InstallDir -ErrorAction SilentlyContinue
    & docker compose up -d coderaft-vault 2>$null
    Pop-Location -ErrorAction SilentlyContinue
}

$vaultHealthy = $false
for ($vi = 1; $vi -le 20; $vi++) {
    try {
        $health = & docker compose exec -T coderaft-vault /bin/sh -c 'wget -qO- http://localhost:8200/v1/health 2>/dev/null' 2>$null
        if ($health -match '"sealed":false') { $vaultHealthy = $true; break }
    } catch { }
    Start-Sleep -Seconds 3
}

if ($vaultHealthy) {
    Write-Host "  ✓ coderaft-vault is healthy and unsealed" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Recovery complete."
} else {
    Write-Host ""
    Write-Host "  [!] Vault restarted but did not become healthy within 60s." -ForegroundColor Yellow
    Write-Host "    Check logs: docker compose logs coderaft-vault" -ForegroundColor Yellow
    exit 1
}
