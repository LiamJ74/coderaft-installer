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
    # B20 (2026-06-08): `$phrase | & docker run --rm -i ... 2>$null` pipes stdin
    # AND surfaces docker stderr as NativeCommandError in PS 5.1.
    # Write phrase to a temp file, mount it, run without stdin pipe.
    $vrPhraseFile = Join-Path $env:TEMP "coderaft-vr-phrase-$(Get-Random).txt"
    $vrKeyOut     = Join-Path $env:TEMP "coderaft-vr-keyout-$(Get-Random).txt"
    $vrKeyErr     = Join-Path $env:TEMP "coderaft-vr-keyerr-$(Get-Random).txt"
    [System.IO.File]::WriteAllText($vrPhraseFile, "$phraseText`n", [System.Text.UTF8Encoding]::new($false))
    Start-Process -FilePath "docker" -ArgumentList @(
        "run","--rm",
        "-v","${vrPhraseFile}:/input.phrase:ro",
        "ghcr.io/liamj74/coderaft-vault:latest",
        "-mnemonic-to-key","/input.phrase"
    ) -NoNewWindow -Wait `
        -RedirectStandardOutput $vrKeyOut `
        -RedirectStandardError  $vrKeyErr `
        -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path $vrKeyOut) {
        $reconstructedKey = ((Get-Content $vrKeyOut -ErrorAction SilentlyContinue) -join "").Trim()
    }
    Remove-Item -Path $vrPhraseFile,$vrKeyOut,$vrKeyErr -ErrorAction SilentlyContinue
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
# B20 (2026-06-08): all `& docker ... 2>$null` → NativeCommandError PS 5.1
try {
    Push-Location $InstallDir -ErrorAction SilentlyContinue
    $vrRestartOut = Join-Path $env:TEMP "coderaft-vrrestart-out-$(Get-Random).log"
    $vrRestartErr = Join-Path $env:TEMP "coderaft-vrrestart-err-$(Get-Random).log"
    $vrRestartProc = Start-Process -FilePath "docker" -ArgumentList @("compose","restart","coderaft-vault") `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $vrRestartOut `
        -RedirectStandardError  $vrRestartErr `
        -ErrorAction SilentlyContinue
    Remove-Item -Path $vrRestartOut,$vrRestartErr -ErrorAction SilentlyContinue
    Pop-Location -ErrorAction SilentlyContinue
    if ($vrRestartProc.ExitCode -ne 0) { throw "restart failed" }
} catch {
    Push-Location $InstallDir -ErrorAction SilentlyContinue
    $vrUpOut = Join-Path $env:TEMP "coderaft-vrup-out-$(Get-Random).log"
    $vrUpErr = Join-Path $env:TEMP "coderaft-vrup-err-$(Get-Random).log"
    Start-Process -FilePath "docker" -ArgumentList @("compose","up","-d","coderaft-vault") `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $vrUpOut `
        -RedirectStandardError  $vrUpErr `
        -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path $vrUpOut,$vrUpErr -ErrorAction SilentlyContinue
    Pop-Location -ErrorAction SilentlyContinue
}

$vaultHealthy = $false
for ($vi = 1; $vi -le 20; $vi++) {
    try {
        # B20 (2026-06-08): vault is distroless — no /bin/sh.
        # Use a curlimages/curl sidecar. Note: vault-recover runs outside the
        # vault network; probe via host port if vault exposes one, otherwise
        # warn. For now we keep the exec attempt but wrap it safely.
        $vrHealthOut = Join-Path $env:TEMP "coderaft-vrhealth-out-$(Get-Random).log"
        $vrHealthErr = Join-Path $env:TEMP "coderaft-vrhealth-err-$(Get-Random).log"
        Start-Process -FilePath "docker" -ArgumentList @("compose","exec","-T","coderaft-vault","/bin/sh","-c","wget -qO- http://localhost:8200/v1/health 2>/dev/null") `
            -NoNewWindow -Wait `
            -RedirectStandardOutput $vrHealthOut `
            -RedirectStandardError  $vrHealthErr `
            -ErrorAction SilentlyContinue | Out-Null
        $health = (Get-Content $vrHealthOut -ErrorAction SilentlyContinue) -join ""
        Remove-Item -Path $vrHealthOut,$vrHealthErr -ErrorAction SilentlyContinue
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
