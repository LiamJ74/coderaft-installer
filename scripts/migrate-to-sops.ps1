#Requires -Version 5.1
# =============================================================================
# CodeRaft Platform — Migrate legacy secrets to SOPS + age (Windows)
# Usage: iex (irm https://install.coderaft.io/migrate.ps1)
#    or: .\migrate-to-sops.ps1   (from the install directory)
#
# Idempotent: can be safely re-run if the first execution fails.
# =============================================================================

[CmdletBinding()]
param(
    [string]$BackupPassphrase = $env:CODERAFT_BACKUP_PASS,
    [switch]$SkipSelfUpdate,
    [switch]$Finalize
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion  = '1.1.0'
$GithubRaw      = 'https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/migrate-to-sops.ps1'
$AgeKeyDir      = 'C:\ProgramData\coderaft'
$AgeKeyPath     = Join-Path $AgeKeyDir 'age.key'
$AgePubPath     = Join-Path $AgeKeyDir 'age.pub'
$SopsVersion    = 'v3.8.1'
$AgeVersion     = 'v1.2.1'
$DataDir        = if ($env:CODERAFT_DATA_DIR) { $env:CODERAFT_DATA_DIR } else { '.\dashboard_data' }

# ── Self-update ───────────────────────────────────────────────────────────────
if (-not $SkipSelfUpdate) {
    try {
        $tmpScript = [System.IO.Path]::GetTempFileName() + '.ps1'
        Invoke-WebRequest -Uri $GithubRaw -OutFile $tmpScript -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
        $remoteVer = (Select-String -Path $tmpScript -Pattern '^\$ScriptVersion\s*=\s*[''"](.+)[''"]').Matches.Groups[1].Value
        if ($remoteVer -and $remoteVer -ne $ScriptVersion) {
            Write-Host "  [migrate] New version available ($remoteVer). Updating..."
            & powershell -ExecutionPolicy Bypass -File $tmpScript -SkipSelfUpdate
            exit $LASTEXITCODE
        }
    } catch { <# network unavailable — continue with the local version #> }
    finally { Remove-Item $tmpScript -ErrorAction SilentlyContinue }
}

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Info  { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Fatal { param($m) Write-Error "  [X]  $m"; exit 1 }

Write-Host ""
Write-Host "  +-----------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  CodeRaft - SOPS+age secrets migration  |" -ForegroundColor Cyan
Write-Host "  |  (v$ScriptVersion)                              |" -ForegroundColor Cyan
Write-Host "  +-----------------------------------------+" -ForegroundColor Cyan
Write-Host ""

# ── Local age key (bind-mount source for dashboard-api) ─────────────────────
$AgeKeyLocal = Join-Path (Get-Location) '.coderaft-age.key'

function Mirror-AgeKeyToLocal {
    if (Test-Path $AgeKeyLocal) { return $true }
    if (Test-Path $AgeKeyPath) {
        try {
            Copy-Item -LiteralPath $AgeKeyPath -Destination $AgeKeyLocal -Force
            $acl = Get-Acl $AgeKeyLocal
            $acl.SetAccessRuleProtection($true, $false)
            $admin = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "BUILTIN\Administrators","FullControl","Allow")
            $acl.SetAccessRule($admin)
            Set-Acl -Path $AgeKeyLocal -AclObject $acl
            Write-Info "Mirrored age key to $AgeKeyLocal (bind-mount source for dashboard-api)"
            return $true
        } catch {
            return $false
        }
    }
    return $false
}

# ── -Finalize fast path: purge leftover plaintext .env safely ───────────────
if ($Finalize) {
    Write-Host "  -- -Finalize: purge plaintext .env --"
    if (-not (Test-Path '.env.enc')) {
        Write-Fatal ".env.enc missing — nothing to finalize. Run a full migration first."
    }
    if (-not (Test-Path '.env')) {
        Write-Info "No plaintext .env present. Nothing to do."
        exit 0
    }
    if (-not (Get-Command sops.exe -ErrorAction SilentlyContinue)) {
        Write-Fatal "sops.exe required for -Finalize. Install it first or run a full migration."
    }
    if (-not (Test-Path $AgeKeyPath) -and -not (Test-Path $AgeKeyLocal)) {
        Write-Fatal "No age key found at $AgeKeyPath or $AgeKeyLocal. Cannot verify .env.enc."
    }
    Mirror-AgeKeyToLocal | Out-Null
    $ageKeyForDecrypt = if (Test-Path $AgeKeyLocal) { $AgeKeyLocal } else { $AgeKeyPath }

    $verifyTmp = Join-Path $env:TEMP ("coderaft-finalize-" + (Get-Date -Format 'yyyyMMddHHmmss') + ".env")
    $env:SOPS_AGE_KEY_FILE = $ageKeyForDecrypt
    try {
        & sops.exe --decrypt .env.enc | Out-File -FilePath $verifyTmp -Encoding UTF8
        if ($LASTEXITCODE -ne 0) {
            Write-Fatal ".env.enc cannot be decrypted with the available age key — refusing to purge .env."
        }
        $original  = Get-Content '.env'      -Raw
        $decrypted = Get-Content $verifyTmp  -Raw
        $diff = Compare-Object ($original -split "`n") ($decrypted -split "`n")
        if ($diff) {
            Write-Warn ".env and .env.enc differ. Aborting -Finalize."
            $diff | Format-Table | Out-String | Write-Host
            exit 1
        }
    } finally {
        Remove-Item $verifyTmp -ErrorAction SilentlyContinue
        Remove-Item Env:SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue
    }

    $ts = Get-Date -Format 'yyyyMMddTHHmmssZ'
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    $bak = Join-Path $DataDir "env-pre-finalize-$ts.bak"
    Copy-Item '.env' $bak -Force
    $acl = Get-Acl $bak
    $acl.SetAccessRuleProtection($true, $false)
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators","FullControl","Allow")
    $acl.SetAccessRule($adminRule)
    Set-Acl -Path $bak -AclObject $acl
    Remove-Item '.env' -Force
    Write-Info ".env purged (24h backup: $bak)"
    Add-Content -Path (Join-Path $DataDir 'migration.log') `
        -Value "[migrate] finalize at $ts | plaintext purged | backup=$bak"

    # Clean older 24h+ backups
    Get-ChildItem -Path $DataDir -Filter 'env-pre-finalize-*.bak' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
        Remove-Item -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Info "Plaintext .env purged. Restart the dashboard-api so it re-reads .env.enc:"
    Write-Host "    docker compose restart dashboard-api"
    Write-Host ""
    exit 0
}

# ── 1. Detect plaintext .env ─────────────────────────────────────────────────
Write-Host "  -- .env detection --"
if (-not (Test-Path '.env')) {
    Write-Info "No .env file found. No migration needed."
    exit 0
}
if ((Test-Path '.env.enc') -and -not (Test-Path '.env')) {
    Write-Info "Migration already done (.env.enc present, .env absent)."
    exit 0
}
if (Test-Path '.env.enc') {
    Write-Warn "Both .env and .env.enc are present — running consistency check..."
}
Write-Info ".env detected. Starting migration..."

# ── 2. Check/install age ─────────────────────────────────────────────────────
Write-Host "  -- Binary check --"

$arch = if ([System.Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'arm64' }
$ageExe  = Get-Command age-keygen.exe -ErrorAction SilentlyContinue
$sopsExe = Get-Command sops.exe -ErrorAction SilentlyContinue

if (-not $ageExe) {
    Write-Host "  Downloading age $AgeVersion..."
    $ageTar  = Join-Path $env:TEMP "age-${AgeVersion}-windows-${arch}.zip"
    $ageUrl  = "https://github.com/FiloSottile/age/releases/download/$AgeVersion/age-$AgeVersion-windows-$arch.zip"
    Invoke-WebRequest -Uri $ageUrl -OutFile $ageTar -UseBasicParsing -ErrorAction Stop
    Expand-Archive -Path $ageTar -DestinationPath (Join-Path $env:TEMP 'age') -Force
    $ageBin  = Join-Path $env:TEMP 'age\age\age-keygen.exe'
    $destBin = 'C:\Windows\System32\age-keygen.exe'
    Copy-Item $ageBin $destBin -Force -ErrorAction Stop
    Write-Info "age-keygen.exe installed"
} else {
    Write-Info "age-keygen.exe found: $($ageExe.Source)"
}

if (-not $sopsExe) {
    Write-Host "  Downloading sops $SopsVersion..."
    $sopsUrl = "https://github.com/getsops/sops/releases/download/$SopsVersion/sops-$SopsVersion.windows.$arch.exe"
    $sopsDst = 'C:\Windows\System32\sops.exe'
    Invoke-WebRequest -Uri $sopsUrl -OutFile $sopsDst -UseBasicParsing -ErrorAction Stop
    Write-Info "sops.exe installed"
} else {
    Write-Info "sops.exe found: $($sopsExe.Source)"
}

# ── 3. age key ───────────────────────────────────────────────────────────────
Write-Host "  -- age key --"
if (-not (Test-Path $AgeKeyPath)) {
    New-Item -ItemType Directory -Path $AgeKeyDir -Force | Out-Null
    & age-keygen.exe -o $AgeKeyPath 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Fatal "Could not generate the age key" }

    # ACL: admin only
    $acl = Get-Acl $AgeKeyPath
    $acl.SetAccessRuleProtection($true, $false)
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators","FullControl","Allow"
    )
    $acl.SetAccessRule($adminRule)
    Set-Acl -Path $AgeKeyPath -AclObject $acl
    Write-Info "age key generated: $AgeKeyPath"
} else {
    Write-Info "Existing age key: $AgeKeyPath"
}

$agePub = (Select-String -Path $AgeKeyPath -Pattern '# public key: (.+)').Matches.Groups[1].Value.Trim()
if (-not $agePub) { Write-Fatal "Could not extract age public key" }
Set-Content -Path $AgePubPath -Value $agePub -Encoding UTF8
Write-Info "Public key: $agePub"

# ── 4. GPG backup ────────────────────────────────────────────────────────────
Write-Host "  -- .env backup --"
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$ts         = (Get-Date -Format 'yyyyMMddTHHmmssZ')
$backupPath = Join-Path $DataDir "migration-backup-$ts.env.gpg"

$gpgExe = Get-Command gpg.exe -ErrorAction SilentlyContinue
if (-not $gpgExe) {
    Write-Warn "gpg.exe not found."
    Write-Warn "Install Gpg4win (https://gpg4win.org) for the encrypted backup."
    Write-Warn "WARNING: Without a GPG backup, .env will not be saved!"
    $confirm = Read-Host "  Continue without GPG backup? [yes/NO]"
    if ($confirm -ne 'yes') { Write-Fatal "Migration cancelled by user." }
} else {
    # Passphrase
    if ([string]::IsNullOrEmpty($BackupPassphrase)) {
        $secPass1 = Read-Host "  Passphrase for the GPG backup" -AsSecureString
        $secPass2 = Read-Host "  Confirm the passphrase" -AsSecureString
        $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass1))
        $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass2))
        if ($p1 -ne $p2) { Write-Fatal "Passphrases do not match." }
        if ([string]::IsNullOrEmpty($p1)) { Write-Fatal "Passphrase cannot be empty." }
        $BackupPassphrase = $p1
        Remove-Variable p1, p2
    }

    # gpg --batch passphrase via stdin
    $BackupPassphrase | gpg.exe --batch --yes `
        --passphrase-fd 0 `
        --cipher-algo AES256 `
        --compress-algo none `
        --symmetric `
        --output $backupPath `
        .env
    if ($LASTEXITCODE -ne 0) { Write-Fatal "GPG backup failed" }
    Remove-Variable BackupPassphrase
    Write-Info "GPG backup created: $backupPath"
    Write-Warn "IMPORTANT: Keep the passphrase offline."
    Write-Warn "          Lost passphrase = backup inaccessible = secrets lost."
}

# ── 5. SOPS encryption ───────────────────────────────────────────────────────
Write-Host "  -- SOPS encryption --"
& sops.exe --encrypt --age $agePub --output .env.enc .env
if ($LASTEXITCODE -ne 0) { Write-Fatal "SOPS encryption failed" }
Write-Info ".env.enc created"

# ── 6. Verify decryption ─────────────────────────────────────────────────────
Write-Host "  -- Integrity check --"
$verifyTmp = Join-Path $env:TEMP "coderaft-verify-$ts.env"
$env:SOPS_AGE_KEY_FILE = $AgeKeyPath
try {
    & sops.exe --decrypt .env.enc | Out-File -FilePath $verifyTmp -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { Write-Fatal "Could not decrypt .env.enc — aborting (.env preserved)" }

    $original  = Get-Content '.env'      -Raw
    $decrypted = Get-Content $verifyTmp  -Raw
    $diff = Compare-Object ($original -split "`n") ($decrypted -split "`n")
    if ($diff) {
        Write-Warn "Difference detected between .env and the decryption output!"
        $diff | Format-Table | Out-String | Write-Host
        Write-Fatal "Verification failed — .env is preserved intact."
    }
} finally {
    Remove-Item $verifyTmp -ErrorAction SilentlyContinue
    Remove-Item Env:SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue
}
Write-Info "Verification OK: decryption matches the original .env"

# ── 7. Remove .env ───────────────────────────────────────────────────────────
Write-Host "  -- Remove plaintext .env --"
# 24h-retention backup: copy .env to dashboard_data\.env.pre-sops-<ts>.bak
$preSopsBak = Join-Path $DataDir ".env.pre-sops-$ts.bak"
Copy-Item '.env' $preSopsBak -Force
$acl = Get-Acl $preSopsBak
$acl.SetAccessRuleProtection($true, $false)
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Administrators","FullControl","Allow")
$acl.SetAccessRule($adminRule)
Set-Acl -Path $preSopsBak -AclObject $acl
Remove-Item '.env' -Force
Write-Info ".env removed (only .env.enc remains on disk)"
Write-Info "Short-lived backup: $preSopsBak (auto-purged after 24h on next migrate run)"

# Clean backups older than 24h on every run
Get-ChildItem -Path $DataDir -Filter '.env.pre-sops-*.bak' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
    Remove-Item -ErrorAction SilentlyContinue

# Mirror age key to install dir so the dashboard-api bind-mount works
if (-not (Mirror-AgeKeyToLocal)) {
    Write-Warn "Could not mirror age key to $AgeKeyLocal — dashboard-api may fail to decrypt."
}

# ── 8. RedFox jwt.key migration ──────────────────────────────────────────────
Write-Host "  -- RedFox jwt.key migration --"
$redfoxJwt   = '.\redfox-certs\jwt.key'
$overrideFile = '.\docker-compose.override.yml'
if (Test-Path $redfoxJwt) {
    if ((Test-Path $overrideFile) -and (Select-String -Path $overrideFile -Pattern 'REDFOX_JWT_KEY' -Quiet)) {
        Write-Info "jwt.key detected and referenced as env var. Migrating to file mount..."
        $ovBak = "$overrideFile.pre-migration-$ts"
        Copy-Item $overrideFile $ovBak
        (Get-Content $overrideFile) -replace 'REDFOX_JWT_KEY=.*', 'REDFOX_JWT_KEY_PATH=/run/secrets/jwt.key' |
            Set-Content $overrideFile
        if (-not (Select-String -Path $overrideFile -Pattern 'redfox-certs/jwt.key' -Quiet)) {
            Write-Warn "Add manually under the redfox-api service in ${overrideFile}:"
            Write-Warn "  volumes:"
            Write-Warn "    - ./redfox-certs/jwt.key:/run/secrets/jwt.key:ro"
        }
        $acl = Get-Acl $redfoxJwt
        $acl.SetAccessRuleProtection($true, $false)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "BUILTIN\Administrators","FullControl","Allow")
        $acl.SetAccessRule($adminRule)
        Set-Acl -Path $redfoxJwt -AclObject $acl
        Write-Info "jwt.key converted to file mount"
    } else {
        Write-Info "jwt.key found but not referenced as env var — no action required."
    }
} else {
    Write-Info "No redfox-certs\jwt.key — no action required."
}

# ── 9. Audit log ─────────────────────────────────────────────────────────────
$logPath = Join-Path $DataDir 'migration.log'
$encLines = (Get-Content '.env.enc' | Measure-Object -Line).Lines
"[migrate] migrated at $ts | sops+age | secrets_lines=$encLines" | Add-Content -Path $logPath
Write-Info "Audit log: $logPath"

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |        Migration completed successfully              |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  .env.enc   : $(Resolve-Path '.env.enc')"
Write-Host "  |  age key    : $AgeKeyPath"
if (Test-Path $backupPath) {
Write-Host "  |  GPG backup : $backupPath"
}
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  IMPORTANT: Back up the age key offline!            |" -ForegroundColor Yellow
Write-Host "  |  gpg --symmetric C:\ProgramData\coderaft\age.key    |" -ForegroundColor Yellow
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
