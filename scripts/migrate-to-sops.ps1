#Requires -Version 5.1
# =============================================================================
# CodeRaft Platform — Migration secrets legacy vers SOPS + age (Windows)
# Usage : iex (irm https://install.coderaft.io/migrate.ps1)
#      ou : .\migrate-to-sops.ps1   (depuis le répertoire d'install)
#
# Idempotent : peut être relancé sans risque si la première exécution échoue.
# =============================================================================

[CmdletBinding()]
param(
    [string]$BackupPassphrase = $env:CODERAFT_BACKUP_PASS,
    [switch]$SkipSelfUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion  = '1.0.0'
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
            Write-Host "  [migrate] Nouvelle version disponible ($remoteVer). Mise à jour..."
            & powershell -ExecutionPolicy Bypass -File $tmpScript -SkipSelfUpdate
            exit $LASTEXITCODE
        }
    } catch { <# réseau indisponible — on continue avec la version locale #> }
    finally { Remove-Item $tmpScript -ErrorAction SilentlyContinue }
}

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Info  { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Fatal { param($m) Write-Error "  [X]  $m"; exit 1 }

Write-Host ""
Write-Host "  +-----------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  CodeRaft - Migration secrets SOPS+age  |" -ForegroundColor Cyan
Write-Host "  |  (v$ScriptVersion)                              |" -ForegroundColor Cyan
Write-Host "  +-----------------------------------------+" -ForegroundColor Cyan
Write-Host ""

# ── 1. Détecter .env clair ───────────────────────────────────────────────────
Write-Host "  -- Detection .env --"
if (-not (Test-Path '.env')) {
    Write-Info "Aucun fichier .env trouvé. Aucune migration nécessaire."
    exit 0
}
if ((Test-Path '.env.enc') -and -not (Test-Path '.env')) {
    Write-Info "Migration déjà effectuée (.env.enc présent, .env absent)."
    exit 0
}
if (Test-Path '.env.enc') {
    Write-Warn "Les deux .env et .env.enc sont présents — vérification de cohérence..."
}
Write-Info ".env détecté. Lancement de la migration..."

# ── 2. Vérifier/installer age ─────────────────────────────────────────────────
Write-Host "  -- Vérification binaires --"

$arch = if ([System.Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'arm64' }
$ageExe  = Get-Command age-keygen.exe -ErrorAction SilentlyContinue
$sopsExe = Get-Command sops.exe -ErrorAction SilentlyContinue

if (-not $ageExe) {
    Write-Host "  Téléchargement de age $AgeVersion..."
    $ageTar  = Join-Path $env:TEMP "age-${AgeVersion}-windows-${arch}.zip"
    $ageUrl  = "https://github.com/FiloSottile/age/releases/download/$AgeVersion/age-$AgeVersion-windows-$arch.zip"
    Invoke-WebRequest -Uri $ageUrl -OutFile $ageTar -UseBasicParsing -ErrorAction Stop
    Expand-Archive -Path $ageTar -DestinationPath (Join-Path $env:TEMP 'age') -Force
    $ageBin  = Join-Path $env:TEMP 'age\age\age-keygen.exe'
    $destBin = 'C:\Windows\System32\age-keygen.exe'
    Copy-Item $ageBin $destBin -Force -ErrorAction Stop
    Write-Info "age-keygen.exe installé"
} else {
    Write-Info "age-keygen.exe trouvé : $($ageExe.Source)"
}

if (-not $sopsExe) {
    Write-Host "  Téléchargement de sops $SopsVersion..."
    $sopsUrl = "https://github.com/getsops/sops/releases/download/$SopsVersion/sops-$SopsVersion.windows.$arch.exe"
    $sopsDst = 'C:\Windows\System32\sops.exe'
    Invoke-WebRequest -Uri $sopsUrl -OutFile $sopsDst -UseBasicParsing -ErrorAction Stop
    Write-Info "sops.exe installé"
} else {
    Write-Info "sops.exe trouvé : $($sopsExe.Source)"
}

# ── 3. Clé age ────────────────────────────────────────────────────────────────
Write-Host "  -- Clé age --"
if (-not (Test-Path $AgeKeyPath)) {
    New-Item -ItemType Directory -Path $AgeKeyDir -Force | Out-Null
    & age-keygen.exe -o $AgeKeyPath 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Fatal "Impossible de générer la clé age" }

    # ACL : admin seulement
    $acl = Get-Acl $AgeKeyPath
    $acl.SetAccessRuleProtection($true, $false)
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators","FullControl","Allow"
    )
    $acl.SetAccessRule($adminRule)
    Set-Acl -Path $AgeKeyPath -AclObject $acl
    Write-Info "Clé age générée : $AgeKeyPath"
} else {
    Write-Info "Clé age existante : $AgeKeyPath"
}

$agePub = (Select-String -Path $AgeKeyPath -Pattern '# public key: (.+)').Matches.Groups[1].Value.Trim()
if (-not $agePub) { Write-Fatal "Impossible d'extraire la clé publique age" }
Set-Content -Path $AgePubPath -Value $agePub -Encoding UTF8
Write-Info "Clé publique : $agePub"

# ── 4. Backup GPG ─────────────────────────────────────────────────────────────
Write-Host "  -- Backup .env --"
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$ts         = (Get-Date -Format 'yyyyMMddTHHmmssZ')
$backupPath = Join-Path $DataDir "migration-backup-$ts.env.gpg"

$gpgExe = Get-Command gpg.exe -ErrorAction SilentlyContinue
if (-not $gpgExe) {
    Write-Warn "gpg.exe non trouvé."
    Write-Warn "Installez Gpg4win (https://gpg4win.org) pour le backup chiffré."
    Write-Warn "ATTENTION : Sans backup GPG, le .env ne sera pas sauvegardé !"
    $confirm = Read-Host "  Continuer sans backup GPG ? [oui/NON]"
    if ($confirm -ne 'oui') { Write-Fatal "Migration annulée par l'utilisateur." }
} else {
    # Passphrase
    if ([string]::IsNullOrEmpty($BackupPassphrase)) {
        $secPass1 = Read-Host "  Passphrase pour le backup GPG" -AsSecureString
        $secPass2 = Read-Host "  Confirmer la passphrase" -AsSecureString
        $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass1))
        $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass2))
        if ($p1 -ne $p2) { Write-Fatal "Les passphrases ne correspondent pas." }
        if ([string]::IsNullOrEmpty($p1)) { Write-Fatal "La passphrase ne peut pas être vide." }
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
    if ($LASTEXITCODE -ne 0) { Write-Fatal "Échec du backup GPG" }
    Remove-Variable BackupPassphrase
    Write-Info "Backup GPG créé : $backupPath"
    Write-Warn "IMPORTANT : Conservez la passphrase hors-ligne."
    Write-Warn "           Passphrase perdue = backup inaccessible = perte des secrets."
}

# ── 5. Chiffrement SOPS ───────────────────────────────────────────────────────
Write-Host "  -- Chiffrement SOPS --"
& sops.exe --encrypt --age $agePub --output .env.enc .env
if ($LASTEXITCODE -ne 0) { Write-Fatal "Échec du chiffrement SOPS" }
Write-Info ".env.enc créé"

# ── 6. Vérification déchiffrement ─────────────────────────────────────────────
Write-Host "  -- Vérification intégrité --"
$verifyTmp = Join-Path $env:TEMP "coderaft-verify-$ts.env"
$env:SOPS_AGE_KEY_FILE = $AgeKeyPath
try {
    & sops.exe --decrypt .env.enc | Out-File -FilePath $verifyTmp -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { Write-Fatal "Impossible de déchiffrer .env.enc — abandon (.env conservé)" }

    $original  = Get-Content '.env'      -Raw
    $decrypted = Get-Content $verifyTmp  -Raw
    $diff = Compare-Object ($original -split "`n") ($decrypted -split "`n")
    if ($diff) {
        Write-Warn "Différence détectée entre .env et le résultat du déchiffrement !"
        $diff | Format-Table | Out-String | Write-Host
        Write-Fatal "Vérification échouée — le .env est conservé intact."
    }
} finally {
    Remove-Item $verifyTmp -ErrorAction SilentlyContinue
    Remove-Item Env:SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue
}
Write-Info "Vérification OK : le déchiffrement est identique au .env original"

# ── 7. Suppression .env ───────────────────────────────────────────────────────
Write-Host "  -- Suppression .env en clair --"
Remove-Item '.env' -Force
Write-Info ".env supprimé (seul .env.enc reste sur disque)"

# ── 8. Migration RedFox jwt.key ───────────────────────────────────────────────
Write-Host "  -- Migration RedFox jwt.key --"
$redfoxJwt   = '.\redfox-certs\jwt.key'
$overrideFile = '.\docker-compose.override.yml'
if (Test-Path $redfoxJwt) {
    if ((Test-Path $overrideFile) -and (Select-String -Path $overrideFile -Pattern 'REDFOX_JWT_KEY' -Quiet)) {
        Write-Info "jwt.key détecté et référencé comme env var. Migration vers file mount..."
        $ovBak = "$overrideFile.pre-migration-$ts"
        Copy-Item $overrideFile $ovBak
        (Get-Content $overrideFile) -replace 'REDFOX_JWT_KEY=.*', 'REDFOX_JWT_KEY_PATH=/run/secrets/jwt.key' |
            Set-Content $overrideFile
        if (-not (Select-String -Path $overrideFile -Pattern 'redfox-certs/jwt.key' -Quiet)) {
            Write-Warn "Ajoutez manuellement sous le service redfox-api dans $overrideFile :"
            Write-Warn "  volumes:"
            Write-Warn "    - ./redfox-certs/jwt.key:/run/secrets/jwt.key:ro"
        }
        $acl = Get-Acl $redfoxJwt
        $acl.SetAccessRuleProtection($true, $false)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "BUILTIN\Administrators","FullControl","Allow")
        $acl.SetAccessRule($adminRule)
        Set-Acl -Path $redfoxJwt -AclObject $acl
        Write-Info "jwt.key converti en file mount"
    } else {
        Write-Info "jwt.key trouvé mais pas référencé comme env var — aucune action requise."
    }
} else {
    Write-Info "Pas de redfox-certs\jwt.key — aucune action requise."
}

# ── 9. Audit log ─────────────────────────────────────────────────────────────
$logPath = Join-Path $DataDir 'migration.log'
$encLines = (Get-Content '.env.enc' | Measure-Object -Line).Lines
"[migrate] migrated at $ts | sops+age | secrets_lines=$encLines" | Add-Content -Path $logPath
Write-Info "Audit log : $logPath"

# ── Résumé ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |         Migration terminée avec succès               |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  .env.enc   : $(Resolve-Path '.env.enc')"
Write-Host "  |  Clé age    : $AgeKeyPath"
if (Test-Path $backupPath) {
Write-Host "  |  Backup GPG : $backupPath"
}
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  IMPORTANT : Sauvegardez la clé age hors-ligne !    |" -ForegroundColor Yellow
Write-Host "  |  gpg --symmetric C:\ProgramData\coderaft\age.key    |" -ForegroundColor Yellow
Write-Host "  +------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
