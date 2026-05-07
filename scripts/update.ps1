# CodeRaft updater (Windows / PowerShell)
#
# Self-updates from the installer repo, captures a pre-update recovery
# snapshot, pulls new images, runs a post-update healthcheck and triggers
# rollback.ps1 automatically if the dashboard API doesn't come back up.
# Mirrors the logic of update.sh (Linux) with Windows adaptations.

$ErrorActionPreference = "Stop"

$DASHBOARD_API       = if ($env:DASHBOARD_API)       { $env:DASHBOARD_API }       else { "http://localhost:3000" }
$ADMIN_TOKEN         = if ($env:ADMIN_TOKEN)         { $env:ADMIN_TOKEN }         else { "" }
$BACKUP_DIR          = if ($env:BACKUP_DIR)          { $env:BACKUP_DIR }          else { ".\dashboard_data\backups" }
$HEALTHCHECK_RETRIES = if ($env:HEALTHCHECK_RETRIES) { [int]$env:HEALTHCHECK_RETRIES } else { 30 }
$HEALTHCHECK_DELAY   = if ($env:HEALTHCHECK_DELAY)   { [int]$env:HEALTHCHECK_DELAY }   else { 3 }
$INSTALL_DIR         = if ($env:INSTALL_DIR)         { $env:INSTALL_DIR }         else { (Get-Location).Path }

# ── ADMIN_TOKEN auto-discovery ────────────────────────────────────────────
# Priority order:
#   1. $env:ADMIN_TOKEN
#   2. .env files (INSTALL_DIR, C:\ProgramData\coderaft, ~/.coderaft)
#   3. Plain token files (single word)
# If nothing is found → continue; snapshot/notify are skipped with a warning.
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
        (Join-Path $HOME ".coderaft\admin_token"),
        "\\.\pipe\coderaft_admin_token"  # placeholder; ignored if absent
    )
    foreach ($tokenFile in $tokenCandidates) {
        if ($tokenFile -and (Test-Path $tokenFile -PathType Leaf)) {
            try {
                $val = (Get-Content -LiteralPath $tokenFile -Raw -ErrorAction Stop).Trim()
                if ($val) { return $val }
            } catch { }
        }
    }
    # 5. Auto-discovery from running dashboard-api container (preferred,
    #    avoids any manual setup — dashboard-api auto-generates the token
    #    at boot and persists it to /data/admin_token).
    try {
        Push-Location $INSTALL_DIR -ErrorAction SilentlyContinue
        $services = & docker compose ps --services 2>$null
        if ($services -match '(?m)^dashboard-api$') {
            $val = & docker compose exec -T dashboard-api cat /data/admin_token 2>$null
            if ($val) {
                $val = ($val -join "`n").Trim()
                if ($val) { return $val }
            }
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

# Detect the current PowerShell binary (compat PS5 'powershell.exe' + PS7 'pwsh.exe')
$PSBin = (Get-Process -Id $PID).Path
if (-not $PSBin -or -not (Test-Path $PSBin)) {
    if (Get-Command pwsh -ErrorAction SilentlyContinue)       { $PSBin = "pwsh" }
    elseif (Get-Command powershell -ErrorAction SilentlyContinue) { $PSBin = "powershell" }
    else { $PSBin = "powershell" }
}

# Docker platform detection — Docker Desktop sometimes resolves strictly to
# linux/arm64/v8 or linux/amd64/v3 by default, which fails on manifests that
# only expose linux/arm64 or linux/amd64. Force the platform.
if (-not $env:DOCKER_DEFAULT_PLATFORM) {
    $hostArch = $env:PROCESSOR_ARCHITECTURE
    if ($hostArch -eq "ARM64")        { $env:DOCKER_DEFAULT_PLATFORM = "linux/arm64" }
    elseif ($hostArch -eq "AMD64")    { $env:DOCKER_DEFAULT_PLATFORM = "linux/amd64" }
}

Write-Host "  Updating CodeRaft..."

# ── Self-update update.ps1 + rollback.ps1 (with re-exec) ───────────────────
# The in-memory script keeps running with its OLD logic after we overwrite
# the file on disk. Without re-exec, the freshly downloaded fixes would only
# take effect on the NEXT run. CODERAFT_UPDATE_REEXEC guards against loops.
if (-not $env:CODERAFT_UPDATE_REEXEC) {
    Write-Host "  Checking for script updates..."
    $refreshed = $false
    foreach ($name in @("update.ps1", "rollback.ps1")) {
        try {
            $url = "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/$name"
            $latest = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($latest.StatusCode -eq 200 -and $latest.Content.Length -gt 50) {
                [System.IO.File]::WriteAllText("$PWD\$name", $latest.Content, [System.Text.Encoding]::UTF8)
                Write-Host "  $name refreshed"
                if ($name -eq "update.ps1") { $refreshed = $true }
            }
        } catch {
            # Offline or upstream down — keep the local copy
        }
    }
    if ($refreshed -and (Test-Path ".\update.ps1")) {
        Write-Host "  Re-executing the updated script..."
        $env:CODERAFT_UPDATE_REEXEC = "1"
        & $PSBin -NoProfile -ExecutionPolicy Bypass -File ".\update.ps1"
        exit $LASTEXITCODE
    }
}

# ── Self-heal HOST_PROJECT_DIR in .env ────────────────────────────────────
# Older oneliners (and any install where the dir was renamed/moved) leave
# .env without HOST_PROJECT_DIR, which causes:
#   - docker compose warning "HOST_PROJECT_DIR not set" on every command
#   - dashboard-api boots with empty HOST_PROJECT_DIR → cannot reach
#     /host-compose paths → license.json invisible → fake "first run" UX
# Always (re)write the line with the resolved current install dir.
$envPath = Join-Path $INSTALL_DIR ".env"
if (Test-Path $envPath) {
    $absoluteInstallDir = (Resolve-Path -LiteralPath $INSTALL_DIR).Path
    if ($absoluteInstallDir) {
        $envText = [System.IO.File]::ReadAllText($envPath, [System.Text.UTF8Encoding]::new($false))
        $existingMatch = [regex]::Match($envText, '(?m)^HOST_PROJECT_DIR=(.*)$')
        $needsRewrite = $false
        if ($existingMatch.Success) {
            if ($existingMatch.Groups[1].Value -ne $absoluteInstallDir) { $needsRewrite = $true }
        } else {
            $needsRewrite = $true
        }
        if ($needsRewrite) {
            $lines = $envText -split "`r?`n" | Where-Object { $_ -notmatch '^HOST_PROJECT_DIR=' }
            $newText = (($lines -join "`n").TrimEnd()) + "`nHOST_PROJECT_DIR=$absoluteInstallDir`n"
            [System.IO.File]::WriteAllText($envPath, $newText, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  ✓ HOST_PROJECT_DIR refreshed ($absoluteInstallDir)"
        }
    }
}

# ── Self-heal compose YAML ────────────────────────────────────────────────
# Detects a broken docker-compose.override.yml (buggy YAML generator) and
# auto-recovers: timestamped backup, deletion, pull dashboard-api, restart
# postgres+redis+dashboard-api → the API regenerates a clean override.
Write-Host ""
Write-Host "  Checking compose integrity..."
$composeOK = $false
try {
    & docker compose ps 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $composeOK = $true }
} catch { }
if (-not $composeOK) {
    Write-Host "  ⚠ docker-compose.override.yml appears corrupted — auto-recovery..."
    if (Test-Path "docker-compose.override.yml") {
        $brokenBak = "docker-compose.override.yml.broken-" + (Get-Date -Format "yyyyMMdd_HHmmss")
        try { Copy-Item "docker-compose.override.yml" $brokenBak -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item "docker-compose.override.yml" -ErrorAction SilentlyContinue } catch { }
        Write-Host "    ✓ override backed up + removed"
    }
    try { & docker pull ghcr.io/liamj74/coderaft-dashboard-api:latest *>$null } catch { }
    try {
        & docker compose up -d postgres redis dashboard-api 2>&1 | Out-Null
        Start-Sleep -Seconds 6
        & docker compose ps 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    ✓ compose repaired"
        } else {
            Write-Host "  ERROR: self-heal failed. Inspect docker-compose.override.yml manually."
            exit 1
        }
    } catch {
        Write-Host "  ERROR: cannot restart dashboard-api — $($_.Exception.Message)"
        exit 1
    }
    $LASTEXITCODE = 0
} else {
    Write-Host "  ✓ compose OK"
}

# ── Vault migration (D4) ─────────────────────────────────────────────────
# Runs ONCE when the vault container is absent from the compose stack.
Write-Host ""
Write-Host "  Checking vault migration status..."

$vaultMigrationSentinel = Join-Path $INSTALL_DIR "vault-data\.migrated"
$vaultAgeKey = Join-Path $INSTALL_DIR "vault-keys\age.key"
$vaultRunning = $false
try {
    $ps = & docker compose ps coderaft-vault 2>$null
    if ($ps -match "running") { $vaultRunning = $true }
} catch { }

$vaultNeedsMigration = $false
if (-not (Test-Path $vaultMigrationSentinel) -and -not $vaultRunning) {
    $vaultNeedsMigration = $true
}

if ($vaultNeedsMigration) {
    Write-Host "  Running vault migration..."

    # ── 4b Pre-flight backup ──────────────────────────────────────────────
    $vaultTs  = (Get-Date -Format "yyyyMMddTHHmmssZ")
    $vaultBak = Join-Path $INSTALL_DIR "backups\migrate-vault-$vaultTs"
    New-Item -ItemType Directory -Force -Path $vaultBak | Out-Null
    Write-Host "  Backup directory: $vaultBak"

    $envPath = Join-Path $INSTALL_DIR ".env"
    if (Test-Path $envPath) {
        Copy-Item $envPath (Join-Path $vaultBak "env") -ErrorAction Stop
    } else {
        Write-Host "  ✗ .env not found — cannot backup. Vault migration aborted." -ForegroundColor Red
        exit 1
    }
    $envEncPath = Join-Path $INSTALL_DIR ".env.enc"
    if (Test-Path $envEncPath) { Copy-Item $envEncPath (Join-Path $vaultBak "env.enc") -ErrorAction SilentlyContinue }
    $ageKeyPath = Join-Path $INSTALL_DIR ".coderaft-age.key"
    if (Test-Path $ageKeyPath) { Copy-Item $ageKeyPath (Join-Path $vaultBak "age.key") -ErrorAction SilentlyContinue }

    # Postgres dump
    try {
        $pgRunning = (& docker compose ps postgres 2>$null) -match "running"
        if ($pgRunning) {
            $bakSql = Join-Path $vaultBak "auth_config.sql"
            $proc = Start-Process -FilePath "docker" `
                -ArgumentList @("compose","exec","-T","postgres","pg_dump","-U","coderaft","-t","auth_config","coderaft") `
                -RedirectStandardOutput $bakSql -NoNewWindow -PassThru -Wait
            if ($proc.ExitCode -ne 0) { Remove-Item $bakSql -ErrorAction SilentlyContinue }
        }
    } catch { }

    # Container-side files
    try {
        $rvRunning = (& docker compose ps ravenscan 2>$null) -match "running"
        if ($rvRunning) { & docker compose cp "ravenscan:.ravenscan/ravenscan.db" (Join-Path $vaultBak "ravenscan.db") 2>$null }
    } catch { }
    try {
        $apiRunning = (& docker compose ps dashboard-api 2>$null) -match "running"
        if ($apiRunning) {
            & docker compose cp "dashboard-api:/data/vault.enc"   (Join-Path $vaultBak "dashboard-vault.enc") 2>$null
            & docker compose cp "dashboard-api:/data/admin_token" (Join-Path $vaultBak "admin_token") 2>$null
        }
    } catch { }
    Write-Host "  ✓ Pre-flight backup complete"

    # Migration log (used by all phases — captures docker / openssl stdout+stderr).
    $migrationLog = Join-Path $vaultBak "migration.log"
    "[$(Get-Date -Format o)] migration started" | Out-File -FilePath $migrationLog -Encoding utf8

    # Rollback helper
    function Invoke-VaultMigrationRollback {
        param([string]$Reason)
        Write-Host "  ✗ Vault migration failed: $Reason — rolling back..." -ForegroundColor Red
        try { & docker compose down 2>$null } catch { }
        if (Test-Path (Join-Path $vaultBak "env"))   { Copy-Item (Join-Path $vaultBak "env") $envPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path (Join-Path $vaultBak "env.enc")) { Copy-Item (Join-Path $vaultBak "env.enc") $envEncPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path (Join-Path $vaultBak "age.key")) { Copy-Item (Join-Path $vaultBak "age.key") $ageKeyPath -Force -ErrorAction SilentlyContinue }
        $authSql = Join-Path $vaultBak "auth_config.sql"
        if (Test-Path $authSql) {
            try {
                & docker compose up -d postgres 2>$null
                Start-Sleep -Seconds 5
                Get-Content -Raw $authSql | & docker compose exec -T postgres psql -U coderaft coderaft 2>$null
            } catch { }
        }
        try { & docker compose up -d 2>$null } catch { }
        Write-Host ""
        Write-Host ""
        Write-Host "  Rollback complete. Backup directory: $vaultBak" -ForegroundColor Yellow
        Write-Host "  Legacy secret stores are intact." -ForegroundColor Yellow
        $log = Join-Path $vaultBak "migration.log"
        if (Test-Path $log) {
            Write-Host ""
            Write-Host "  Last 20 lines of migration log:" -ForegroundColor Yellow
            Get-Content -Path $log -Tail 20 | ForEach-Object { Write-Host "    $_" }
            Write-Host ""
            Write-Host "  Full log: $log" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Press any key to acknowledge before the window closes..." -ForegroundColor Yellow
        if (-not $env:CODERAFT_TEST_MODE) {
            try { [void][System.Console]::ReadKey($true) } catch { Start-Sleep -Seconds 30 }
        }
        exit 1
    }

    # ── 4c Vault directories (always) ─────────────────────────────────────
    New-Item -ItemType Directory -Force -Path (Join-Path $INSTALL_DIR "vault-keys")   | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $INSTALL_DIR "vault-tls")    | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $INSTALL_DIR "vault-config") | Out-Null

    # ── 4c.1 Age master key (ONCE — rotating it would orphan vault.db) ────
    if (-not (Test-Path $vaultAgeKey)) {
        Write-Host "  Generating vault master key..."
        $ageKeygen = Get-Command age-keygen -ErrorAction SilentlyContinue
        if (-not $ageKeygen) {
            Write-Host "    age-keygen not on PATH — downloading from GitHub releases..."
            $ageVersion = "v1.2.1"
            $ageArch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
            $ageTmp = Join-Path $env:TEMP "coderaft-age-$(Get-Random)"
            New-Item -ItemType Directory -Force -Path $ageTmp | Out-Null
            $ageZip = Join-Path $ageTmp "age.zip"
            $ageUrl = "https://github.com/FiloSottile/age/releases/download/$ageVersion/age-$ageVersion-windows-$ageArch.zip"
            try {
                Invoke-WebRequest -Uri $ageUrl -OutFile $ageZip -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                Expand-Archive -Path $ageZip -DestinationPath $ageTmp -Force -ErrorAction Stop
                $ageKeygenExe = Get-ChildItem -Path $ageTmp -Filter "age-keygen.exe" -Recurse | Select-Object -First 1
                if (-not $ageKeygenExe) { Invoke-VaultMigrationRollback "age-keygen.exe missing in downloaded archive" }
                $ageKeygen = [pscustomobject]@{ Path = $ageKeygenExe.FullName }
                Write-Host "    ✓ age-keygen downloaded to $($ageKeygen.Path)"
            } catch {
                Invoke-VaultMigrationRollback "age-keygen download failed: $($_.Exception.Message)"
            }
        }

        & $ageKeygen.Path -o $vaultAgeKey 2>$null
        if (-not (Test-Path $vaultAgeKey)) { Invoke-VaultMigrationRollback "age-keygen failed" }

        $recoveryPhrase = ""
        if ($env:CODERAFT_TEST_MODE -ne "1") {
            $privKey = (Get-Content $vaultAgeKey | Where-Object { $_ -match '^AGE-SECRET-KEY-' } | Select-Object -First 1)
            if ($privKey) {
                try {
                    $recoveryPhrase = ($privKey | & docker run --rm -i `
                        ghcr.io/liamj74/coderaft-vault:latest -mnemonic-from-key /dev/stdin 2>$null) -join ""
                } catch { $recoveryPhrase = "" }
            }
        }
        if (-not $recoveryPhrase) {
            $pubKey = (Get-Content $vaultAgeKey | Where-Object { $_ -match '# public key:' } | Select-Object -First 1) -replace '.*# public key:\s*', ''
            $recoveryPhrase = "[FALLBACK] fingerprint: $pubKey"
        }

        Write-Host ""
        Write-Host "  +==================================================================+" -ForegroundColor Cyan
        Write-Host "  | *** VAULT RECOVERY PHRASE — WRITE THIS DOWN NOW ***             |" -ForegroundColor Cyan
        Write-Host "  +==================================================================+" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    $recoveryPhrase" -ForegroundColor White
        Write-Host ""

        if ($env:CODERAFT_TEST_MODE -eq "1") {
            $reply = "CONFIRMED"
        } else {
            $reply = Read-Host "  Type CONFIRMED (all caps) once you have securely stored the phrase"
        }
        if ($reply -ne "CONFIRMED") { Invoke-VaultMigrationRollback "operator did not confirm recovery phrase" }
        Write-Host "  ✓ Recovery phrase confirmed" -ForegroundColor Green
    } else {
        Write-Host "  ✓ Vault age key already exists — reusing"
    }

    # ── 4c.2 mTLS PKI + config.yaml + acl.yaml (ALWAYS — idempotent) ──────
    # These artefacts cost <1s to regenerate and are always overwritten so a
    # half-bootstrapped vault from a previous failed run is healed on next try.
    # PKI generation runs inside a one-shot alpine container (always has openssl
    # baked in) — no host dependency on openssl/Git for Windows.
    Write-Host "  Bootstrapping vault TLS PKI + config (via alpine container)..."
    $tlsDir = Join-Path $INSTALL_DIR "vault-tls"
    $cfgDir = Join-Path $INSTALL_DIR "vault-config"

    # Single shell script run inside alpine that produces all certs at once.
    # Uses /work as the bind-mounted vault-tls directory.
    $opensslScript = @'
set -e
apk add --no-cache openssl >/dev/null
cd /work
# CA
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
    -keyout client-ca.key -out client-ca.crt \
    -subj "/CN=coderaft-vault-ca" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
# Server cert
openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout vault.key -out vault.csr \
    -subj "/CN=coderaft-vault" 2>/dev/null
cat > /tmp/server.ext <<EOF
subjectAltName=DNS:coderaft-vault,DNS:localhost,IP:127.0.0.1
basicConstraints=CA:FALSE
EOF
openssl x509 -req -days 3650 -sha256 \
    -in vault.csr -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
    -out vault.crt -extfile /tmp/server.ext 2>/dev/null
rm -f vault.csr
# Per-product client certs
for pair in "dashboard-api:dashboard-api.coderaft.local" \
            "entraguard:entraguard.coderaft.local" \
            "ravenscan:ravenscan.coderaft.local" \
            "redfox:redfox.coderaft.local"; do
    name="${pair%%:*}"
    san="${pair##*:}"
    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout "${name}-client.key" -out "${name}-client.csr" \
        -subj "/CN=${san}" 2>/dev/null
    cat > /tmp/client.ext <<EOF
subjectAltName=DNS:${san}
basicConstraints=CA:FALSE
EOF
    openssl x509 -req -days 3650 -sha256 \
        -in "${name}-client.csr" -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
        -out "${name}-client.crt" -extfile /tmp/client.ext 2>/dev/null
    rm -f "${name}-client.csr"
done
chmod 600 *.key 2>/dev/null || true
'@
    # Bind-mount tlsDir into the alpine container at /work and run the script.
    # Use --user to keep file ownership readable on Linux hosts; on Windows/Mac
    # Docker Desktop handles UID translation transparently.
    $absTlsDir = (Resolve-Path -LiteralPath $tlsDir).Path
    # Use stdin to avoid quoting nightmares with the heredoc inside the script.
    $opensslOut = $opensslScript | & docker run --rm -i `
        -v "${absTlsDir}:/work" `
        alpine:3.20 sh 2>&1
    $opensslOut | Tee-Object -FilePath $migrationLog -Append | Out-Host
    if (-not (Test-Path (Join-Path $tlsDir "vault.crt"))) {
        Invoke-VaultMigrationRollback "openssl-in-alpine cert generation failed (see $migrationLog)"
    }
    $configYaml = @'
server:
  addr: "0.0.0.0:8200"
  tls_cert: "/tls/vault.crt"
  tls_key:  "/tls/vault.key"
  client_ca: "/tls/client-ca.crt"
storage:
  path: "/data/vault.db"
keys:
  age_key_path: "/keys/age.key"
audit:
  log_path: "/data/audit.log"
acl_path: "/etc/coderaft-vault/acl.yaml"
'@
    [System.IO.File]::WriteAllText((Join-Path $cfgDir "config.yaml"), $configYaml, [System.Text.UTF8Encoding]::new($false))
    $aclYaml = @'
clients:
  - name: dashboard-api
    cert_san: "dashboard-api.coderaft.local"
    permissions: ["*"]
  - name: entraguard
    cert_san: "entraguard.coderaft.local"
    permissions: ["read:azure_*","read:license_key","read:entraguard_*"]
  - name: ravenscan
    cert_san: "ravenscan.coderaft.local"
    permissions: ["read:ravenscan_*","read:neo4j_*","read:license_key"]
  - name: redfox
    cert_san: "redfox.coderaft.local"
    permissions: ["read:redfox_*","read:license_key"]
'@
    [System.IO.File]::WriteAllText((Join-Path $cfgDir "acl.yaml"), $aclYaml, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Vault TLS PKI + config written"

    # ── 4d Pull and start vault ────────────────────────────────────────────
    if ($env:CODERAFT_TEST_FAIL -eq "4d") { Invoke-VaultMigrationRollback "injected test failure at 4d" }

    # All docker output (stdout + stderr) is logged to migration.log inside the
    # backup dir AND streamed to the console. No more silent failures.
    "[$(Get-Date -Format o)] Phase 4d — pull + start vault" | Out-File -FilePath $migrationLog -Append -Encoding utf8

    # ── 4d.1 — Compose patch ───────────────────────────────────────────────
    # Existing installs were generated by an older install.{sh,ps1} that did
    # not know about the vault service. We add it via a sidecar override file
    # docker-compose.vault.yml. This way we never rewrite the user's main
    # docker-compose.yml; compose loads main + override additively.
    $vaultOverride = Join-Path $INSTALL_DIR "docker-compose.vault.yml"
    if (-not (Test-Path $vaultOverride)) {
        Write-Host "  Writing docker-compose.vault.yml override..."
        $vaultYaml = @'
# Generated by update.ps1 vault migration. Do not edit by hand — re-running
# the oneliner overwrites this file.
networks:
  coderaft-vault-net:
    internal: true

volumes:
  vault_data:

services:
  coderaft-vault:
    image: ghcr.io/liamj74/coderaft-vault:latest
    # Run as root so the container can:
    #   - write to the Docker-managed /data volume (SQLite + audit log)
    #   - read /tls/*.key files (mode 0600 from openssl)
    # Effective security stays equivalent to nonroot because we drop ALL
    # capabilities AND set no-new-privileges. This is a standard hardening
    # pattern (root-with-no-caps), not a security regression.
    user: "0:0"
    networks:
      - coderaft-vault-net
    volumes:
      - vault_data:/data
      - ./vault-keys:/keys:ro
      - ./vault-tls:/tls:ro
      - ./vault-config:/etc/coderaft-vault:ro
    healthcheck:
      test: ["CMD", "/coderaft-vault", "-health-check"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    restart: unless-stopped
'@
        [System.IO.File]::WriteAllText($vaultOverride, $vaultYaml, [System.Text.UTF8Encoding]::new($false))
        "[$(Get-Date -Format o)] wrote $vaultOverride" | Out-File -FilePath $migrationLog -Append -Encoding utf8
    }

    # Compose args used for vault-related calls. Both the main file and the
    # vault override are loaded so the vault service resolves.
    $vaultComposeArgs = @("-f", "docker-compose.yml", "-f", "docker-compose.vault.yml")

    if ($env:CODERAFT_TEST_MODE -ne "1") {
        Write-Host "  Pulling vault image..."
        $pullOut = & docker pull ghcr.io/liamj74/coderaft-vault:latest 2>&1
        $pullOut | Tee-Object -FilePath $migrationLog -Append | Out-Host
        if ($LASTEXITCODE -ne 0) { Invoke-VaultMigrationRollback "docker pull failed (see $migrationLog)" }
    }

    Write-Host "  Starting vault container..."
    Push-Location $INSTALL_DIR -ErrorAction Stop
    $upOut = & docker compose @vaultComposeArgs up -d coderaft-vault 2>&1
    $upOut | Tee-Object -FilePath $migrationLog -Append | Out-Host
    $upExit = $LASTEXITCODE
    Pop-Location -ErrorAction SilentlyContinue
    if ($upExit -ne 0) { Invoke-VaultMigrationRollback "docker compose up coderaft-vault failed (see $migrationLog)" }

    # Wait for healthy — print attempts so the operator sees progress
    Write-Host "  Waiting for vault to become healthy..."
    $vaultHealthy = $false
    for ($vi = 1; $vi -le 20; $vi++) {
        try {
            $health = & docker compose @vaultComposeArgs exec -T coderaft-vault `
                /bin/sh -c 'wget --no-check-certificate -qO- https://localhost:8200/v1/health 2>&1' 2>&1
            "[$(Get-Date -Format o)] health attempt $vi → $health" | Out-File -FilePath $migrationLog -Append -Encoding utf8
            if ($health -match '"sealed":false') { $vaultHealthy = $true; break }
        } catch {
            "[$(Get-Date -Format o)] health attempt $vi → exception: $($_.Exception.Message)" | Out-File -FilePath $migrationLog -Append -Encoding utf8
        }
        if ($vi % 3 -eq 0) { Write-Host "    ... still waiting (attempt $vi/20)" }
        Start-Sleep -Seconds 3
    }
    if (-not $vaultHealthy) {
        Write-Host "  Last health probe output (see $migrationLog for full log):" -ForegroundColor Yellow
        Get-Content -Path $migrationLog -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        Invoke-VaultMigrationRollback "coderaft-vault did not become healthy"
    }
    Write-Host "  ✓ coderaft-vault is healthy"

    # ── 4e Migrate secrets ────────────────────────────────────────────────
    if ($env:CODERAFT_TEST_FAIL -eq "4e") { Invoke-VaultMigrationRollback "injected test failure at 4e" }

    function Set-VaultSecret {
        param([string]$Name, [string]$Value)
        if (-not $Value) { return $true }
        # Build JSON via ConvertTo-Json (PS 5.1 compatible) instead of hand-escaped strings.
        $body = @{ name = $Name; value = $Value } | ConvertTo-Json -Compress
        # Encode body for shell single-quote: replace any single quote with the
        # POSIX shell trick '\''.  Vault names/values are alnum-ish so usually
        # nothing to escape, but be defensive.
        $shellSafeBody = $body -replace "'", "'\''"
        $cmd = "wget --no-check-certificate -qO- --post-data='$shellSafeBody' --header='Content-Type: application/json' https://localhost:8200/v1/secret/set"
        try {
            $resp = & docker compose @vaultComposeArgs exec -T coderaft-vault /bin/sh -c $cmd 2>&1
            return (($resp -join "") -match '"ok"\s*:\s*true')
        } catch { return $false }
    }
    function Get-VaultSecret {
        param([string]$Name)
        try {
            $body = @{ name = $Name } | ConvertTo-Json -Compress
            $shellSafeBody = $body -replace "'", "'\''"
            $cmd = "wget --no-check-certificate -qO- --post-data='$shellSafeBody' --header='Content-Type: application/json' https://localhost:8200/v1/secret/get"
            $resp = & docker compose @vaultComposeArgs exec -T coderaft-vault /bin/sh -c $cmd 2>&1
            $respText = ($resp -join "")
            if ($respText -match '"value"\s*:\s*"([^"]*)"') { return $Matches[1] }
        } catch { }
        return ""
    }
    function Get-EnvVal {
        param([string]$Key)
        $line = (Get-Content $envPath -ErrorAction SilentlyContinue | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))=(.+)$" } | Select-Object -First 1)
        if ($line -match "^\s*$([regex]::Escape($Key))=(.+)$") { return $Matches[1].Trim().Trim('"').Trim("'") }
        return ""
    }

    Write-Host "  Migrating secrets to vault..."
    $migrationOk = $true

    $secretMap = @(
        @("LICENSE_KEY",              "license_key"),
        @("POSTGRES_PASSWORD",        "postgres_password"),
        @("REDIS_PASSWORD",           "redis_password"),
        @("DASHBOARD_SECRET",         "dashboard_secret_legacy"),
        @("NEO4J_PASSWORD",           "neo4j_password"),
        @("RAVENSCAN_SECRET_KEY",     "ravenscan_secret_key"),
        @("RAVENSCAN_CAPTURE_TOKEN",  "ravenscan_capture_token"),
        @("RAVENSCAN_LICENSE_KEY",    "ravenscan_license_key"),
        @("REDFOX_MASTER_PASSPHRASE", "redfox_master_passphrase"),
        @("REDFOX_JWT_PRIVATE_KEY",   "redfox_jwt_private_key"),
        @("REDFOX_JWT_PUBLIC_KEY",    "redfox_jwt_public_key"),
        @("REDFOX_GW_SESSION_SECRET", "redfox_gw_session_secret"),
        @("REDFOX_LICENSE_KEY",       "redfox_license_key")
    )
    foreach ($pair in $secretMap) {
        $envKey = $pair[0]; $vaultKey = $pair[1]
        $val = Get-EnvVal -Key $envKey
        if ($val) {
            if (Set-VaultSecret -Name $vaultKey -Value $val) {
                $rb = Get-VaultSecret -Name $vaultKey
                if ($rb -ne $val) {
                    $migrationOk = $false
                    Write-Host "  ✗ Round-trip verify failed: $vaultKey" -ForegroundColor Red
                }
            } else {
                $migrationOk = $false
                Write-Host "  ✗ Failed to migrate: $vaultKey" -ForegroundColor Red
            }
        }
    }
    if (-not $migrationOk) { Invoke-VaultMigrationRollback "secret migration verify failed" }
    Write-Host "  ✓ Secrets migrated and verified"

    # ── 4g Sentinel ───────────────────────────────────────────────────────
    try {
        & docker compose @vaultComposeArgs exec -T coderaft-vault /bin/sh -c "touch /data/.migrated" 2>$null
    } catch { }
    $hostSentinelDir = Join-Path $INSTALL_DIR "vault-data"
    New-Item -ItemType Directory -Force -Path $hostSentinelDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $hostSentinelDir ".migrated"), (Get-Date -Format o)) | Out-Null
    Write-Host "  ✓ Migration sentinel written"

    # ── 4h Write CODERAFT_VAULT_* vars ───────────────────────────────────
    $envText = [System.IO.File]::ReadAllText($envPath, [System.Text.UTF8Encoding]::new($false))
    foreach ($kv in @(
        "CODERAFT_VAULT_URL=https://coderaft-vault:8200",
        "CODERAFT_VAULT_AZURE=0",
        "CODERAFT_VAULT_LICENSE=0",
        "CODERAFT_VAULT_PRODUCTS=0",
        "CODERAFT_VAULT_JWT=0"
    )) {
        $k = $kv.Split('=')[0]
        if ($envText -notmatch "(?m)^$k=") { $envText = $envText.TrimEnd() + "`n$kv`n" }
    }
    [System.IO.File]::WriteAllText($envPath, $envText, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ CODERAFT_VAULT_* vars written to .env"
    Write-Host ""
    Write-Host "  Vault migration complete."
    Write-Host "  Legacy stores retained for 7-day grace period."
    Write-Host ""
} else {
    Write-Host "  ✓ Vault migration not needed (already done or vault running)"
}

# ── Banking-grade plaintext purge (auto) ──────────────────────────────────
# When .env.enc exists, the plaintext .env MUST be purged. The oneliner
# does the finalize itself: verifies decryption matches plaintext, keeps a
# 24h .bak, then deletes plaintext. Falls back to a warning otherwise.
Write-Host ""
Write-Host "  Banking-grade secret check..."
$envPlain = Join-Path $INSTALL_DIR ".env"
$envEnc   = Join-Path $INSTALL_DIR ".env.enc"
if ((Test-Path $envEnc) -and (Test-Path $envPlain)) {
    $ageKey = if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $INSTALL_DIR ".coderaft-age.key" }
    if (-not (Test-Path $ageKey) -and (Test-Path "C:\ProgramData\coderaft\age.key")) {
        $ageKey = "C:\ProgramData\coderaft\age.key"
    }
    $sopsCmd = Get-Command sops -ErrorAction SilentlyContinue
    $sops = if ($sopsCmd) { $sopsCmd.Path } else { $null }
    if (-not (Test-Path $ageKey)) {
        Write-Host "  [!] .env + .env.enc coexist but age key not found at $ageKey" -ForegroundColor Yellow
        Write-Host "      Plaintext .env left in place; investigate before next run." -ForegroundColor Yellow
    } elseif (-not $sops) {
        Write-Host "  [!] sops binary missing on host — cannot finalize purge automatically" -ForegroundColor Yellow
        Write-Host "      Run: iex (irm https://install.coderaft.io/migrate.ps1) -Finalize" -ForegroundColor Yellow
    } else {
        $env:SOPS_AGE_KEY_FILE = $ageKey
        $decrypted = & $sops --decrypt --input-type dotenv --output-type dotenv $envEnc 2>$null
        if (-not $decrypted) {
            Write-Host "  [!] sops decrypt of .env.enc returned empty — leaving plaintext" -ForegroundColor Yellow
        } else {
            $bakDir = Join-Path $INSTALL_DIR "dashboard_data"
            New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
            $bakFile = Join-Path $bakDir ("env-pre-finalize-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".bak")
            Copy-Item $envPlain $bakFile -ErrorAction SilentlyContinue
            $plainNorm   = (Get-Content $envPlain | Where-Object { $_ -notmatch '^\s*(#|$)' } | Sort-Object) -join "`n"
            $decryptNorm = ($decrypted | Where-Object { $_ -notmatch '^\s*(#|$)' } | Sort-Object) -join "`n"
            if ($plainNorm -eq $decryptNorm) {
                Remove-Item $envPlain -Force
                Write-Host "  ✓ plaintext .env purged (backup: $bakFile, kept 24h)"
            } else {
                Write-Host "  [!] .env and .env.enc differ — refusing to purge plaintext." -ForegroundColor Yellow
                Write-Host "      Re-run: iex (irm https://install.coderaft.io/migrate.ps1) -Finalize" -ForegroundColor Yellow
                Write-Host "      Backup written to $bakFile" -ForegroundColor Yellow
            }
        }
    }
}

# ── Host capture sanity check (Live Capture / Frame Analyzer) ─────────────
# Mirrors update.sh: when CODERAFT_HOST_OS=windows|macos the Frame Analyzer
# expects a native daemon on 127.0.0.1:7777. We probe via an alpine curl
# image (Docker Desktop maps host.docker.internal automatically). Failure is
# a *warning* — the host may be unreachable during the update window, or
# the operator may not have run the Setup Wizard's Live Capture step yet.
Write-Host ""
Write-Host "  Live Capture sanity check..."
$hostOsValue = ""
if (Test-Path ".env") {
    $envLine = Get-Content ".env" | Where-Object { $_ -match '^\s*CODERAFT_HOST_OS\s*=' } | Select-Object -Last 1
    if ($envLine) {
        $hostOsValue = ($envLine -replace '^\s*CODERAFT_HOST_OS\s*=', '').Trim().Trim('"').Trim("'").ToLower()
    }
}
switch ($hostOsValue) {
    { @("windows", "macos") -contains $_ } {
        try {
            & docker run --rm --add-host=host.docker.internal:host-gateway `
                curlimages/curl:8.10.1 -fsS --connect-timeout 3 --max-time 4 `
                "http://host.docker.internal:7777/health" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Native capture daemon reachable (CODERAFT_HOST_OS=$hostOsValue)"
            } else {
                Write-Host "  ⚠ CODERAFT_HOST_OS=$hostOsValue but the native daemon is not answering on 127.0.0.1:7777."
                Write-Host "     Frame Analyzer may show empty captures. Open the dashboard → Setup → Live Capture"
                Write-Host "     to (re)install the host daemon. Continuing the update."
            }
        } catch {
            Write-Host "  ⚠ Could not probe the native capture daemon ($($_.Exception.Message)). Continuing."
        }
        $LASTEXITCODE = 0
    }
    { @("linux", "") -contains $_ } {
        # No-op: Linux uses the in-Docker sidecar; missing var = default behaviour.
    }
    default {
        Write-Host "  ⚠ CODERAFT_HOST_OS='$hostOsValue' is not a recognised value (windows|macos|linux). Ignored."
    }
}

# ── Mandatory pre-update backup ───────────────────────────────────────────
# If pg_dumpall fails → block the update (no backup = no update).
Write-Host ""
Write-Host "  Pre-update backup..."
New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
$timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$BACKUP_FILE = Join-Path $BACKUP_DIR "preupdate-$timestamp.sql"

$postgresRunning = $false
try {
    $psOutput = & docker compose ps postgres --quiet 2>$null
    if ($psOutput) { $postgresRunning = $true }
} catch { }

if ($postgresRunning) {
    try {
        # Start-Process redirects stdout cleanly (no PS encoding issues)
        $proc = Start-Process -FilePath "docker" `
            -ArgumentList @("compose", "exec", "-T", "postgres", "pg_dumpall", "-U", "coderaft") `
            -RedirectStandardOutput $BACKUP_FILE `
            -NoNewWindow -PassThru -Wait

        if ($proc.ExitCode -eq 0 -and (Get-Item $BACKUP_FILE).Length -gt 0) {
            Write-Host "  Backup saved: $BACKUP_FILE"
        } else {
            Write-Host "  ERROR: pg_dumpall failed (exit $($proc.ExitCode)). Update cancelled."
            Write-Host "  Check that the postgres container is healthy: docker compose ps"
            exit 1
        }
    } catch {
        Write-Host "  ERROR: pg_dumpall failed — $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-Host "  PostgreSQL not detected — backup skipped (dashboard without DB)."
}

# ── Capture recovery snapshot via dashboard-api ───────────────────────────
Write-Host "  Capturing recovery snapshot..."
if ($ADMIN_TOKEN) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $ADMIN_TOKEN"
        }
        Invoke-RestMethod -Method Post -Uri "$DASHBOARD_API/api/dashboard/recovery/snapshots" `
            -Headers $headers -Body '{"reason":"pre-update"}' -TimeoutSec 10 | Out-Null
        Write-Host "    Snapshot saved."
    } catch {
        Write-Host "    Snapshot failed (auto-snapshot will run again at next deploy)."
    }
} else {
    Write-Host "    [warn] ADMIN_TOKEN not found — snapshot skipped."
    Write-Host "    (set `$env:ADMIN_TOKEN, or place token in $INSTALL_DIR\.env, C:\ProgramData\coderaft\admin_token, or ~/.coderaft/admin_token)"
}

# ── Pull and recreate ─────────────────────────────────────────────────────
# Include docker-compose.override.yml when it exists so product containers
# (entraguard-*, neo4j, ravenscan, redfox-*) are within scope. Without it,
# `--remove-orphans` treats every product as an orphan and silently nukes
# them, which is exactly what broke scans for users who had previously
# activated a Suite license.
$ComposeArgs = @("compose")
if (Test-Path ".\docker-compose.override.yml") {
    $ComposeArgs += @("-f", ".\docker-compose.yml", "-f", ".\docker-compose.override.yml")
}

# ── Refresh license keys (drift "superseded") ─────────────────────────────
# When the License Server resigns a license (e.g. feature added, key
# rotation), it returns 403 "License has been superseded by a newer version"
# for any request using the old key. So we refresh the key in
# docker-compose.override.yml BEFORE `docker compose up`. Backup is .bak.
# If the License Server is unreachable, we continue silently.
function Update-License {
    param(
        [Parameter(Mandatory=$true)] [string] $EnvVar,
        [Parameter(Mandatory=$true)] [string] $OverrideFile
    )

    $content = if (Test-Path $OverrideFile -PathType Leaf) {
        Get-Content -LiteralPath $OverrideFile -ErrorAction SilentlyContinue
    } else { @() }

    # Read current key from .env first (source of truth read by
    # dashboard-api), fall back to override.yml. Ensures we always validate
    # the OLDEST stale key still on disk and propagate the refreshed value
    # to all stores — even when override.yml was rotated by a previous run
    # but .env wasn't.
    $currentKey = $null
    $envFile = Join-Path $INSTALL_DIR ".env"
    if (Test-Path $envFile -PathType Leaf) {
        $envLines = Get-Content -LiteralPath $envFile
        foreach ($line in $envLines) {
            if ($line -match "^\s*$([Regex]::Escape($EnvVar))=(.+)$") {
                $currentKey = $Matches[1].Trim().Trim('"').Trim("'")
                break
            }
        }
    }
    if (-not $currentKey) {
        $regex = "^\s*-?\s*$([Regex]::Escape($EnvVar))=(.+)$"
        foreach ($line in $content) {
            if ($line -match $regex) {
                $currentKey = $Matches[1].Trim().Trim('"').Trim("'")
                break
            }
        }
    }
    $regex = "^\s*-?\s*$([Regex]::Escape($EnvVar))=(.+)$"
    if (-not $currentKey -or $currentKey -eq "UNCONFIGURED") { return $false }

    $server = if ($env:LICENSE_SERVER_URL) { $env:LICENSE_SERVER_URL } else { "https://license.coderaft.io" }
    $latest = $null
    try {
        $body = @{ license_key = $currentKey } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Method Post -Uri "$server/api/licenses/validate" `
            -ContentType "application/json" -Body $body -TimeoutSec 10 -ErrorAction Stop
        if ($resp.latest_license_key) { $latest = [string]$resp.latest_license_key }
    } catch {
        # License Server unreachable or network error → silent
        return $false
    }

    if ($latest -and $latest -ne $currentKey) {
        # 1. override.yml — replace ALL occurrences (worker + api may share)
        Copy-Item -LiteralPath $OverrideFile -Destination "$OverrideFile.bak" -Force
        $newContent = foreach ($line in $content) {
            if ($line -match $regex) {
                $padMatch = [Regex]::Match($line, "^(\s*-?\s*)")
                $pad = $padMatch.Groups[1].Value
                "$pad$EnvVar=$latest"
            } else { $line }
        }
        [System.IO.File]::WriteAllLines($OverrideFile, $newContent, (New-Object System.Text.UTF8Encoding($false)))

        # 2. .env (host) — dashboard-api reads this directly. Without this
        #    sync, override.yml has the new key but dashboard-api keeps
        #    seeing the old one and license.json never refreshes.
        $envFile = Join-Path $INSTALL_DIR ".env"
        if (Test-Path $envFile) {
            $envLines = Get-Content -LiteralPath $envFile
            $envRegex = "^\s*${EnvVar}="
            if ($envLines -match $envRegex) {
                Copy-Item -LiteralPath $envFile -Destination "$envFile.bak.$(Get-Date -UFormat %s)" -Force -ErrorAction SilentlyContinue
                $newEnv = foreach ($l in $envLines) {
                    if ($l -match $envRegex) { "$EnvVar=$latest" } else { $l }
                }
                [System.IO.File]::WriteAllLines($envFile, $newEnv, (New-Object System.Text.UTF8Encoding($false)))
            }
        }

        # 3. .env.enc — re-encrypt so next dashboard-api boot reads fresh
        $envEnc = Join-Path $INSTALL_DIR ".env.enc"
        $sopsCmd = Get-Command sops -ErrorAction SilentlyContinue
        if ((Test-Path $envEnc) -and $sopsCmd -and (Test-Path $envFile)) {
            $ageKey = if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $INSTALL_DIR ".coderaft-age.key" }
            if (-not (Test-Path $ageKey) -and (Test-Path "C:\ProgramData\coderaft\age.key")) {
                $ageKey = "C:\ProgramData\coderaft\age.key"
            }
            if (Test-Path $ageKey) {
                $env:SOPS_AGE_KEY_FILE = $ageKey
                try {
                    & $sopsCmd.Path --encrypt --input-type dotenv --output-type dotenv $envFile > "$envEnc.tmp" 2>$null
                    if ($LASTEXITCODE -eq 0) { Move-Item -Force "$envEnc.tmp" $envEnc } else { Remove-Item -Force "$envEnc.tmp" -ErrorAction SilentlyContinue }
                } catch { }
            }
        }

        Write-Host "  🔄 License refreshed for $EnvVar"
        return $true
    }
    return $false
}

function Update-AllLicenses {
    $overrideFile = Join-Path $INSTALL_DIR "docker-compose.override.yml"
    Write-Host ""
    Write-Host "  ▶ Checking for license drift..."
    $any = $false
    foreach ($var in @("LICENSE_KEY", "RAVENSCAN_LICENSE_KEY", "REDFOX_LICENSE_KEY")) {
        try {
            if (Update-License -EnvVar $var -OverrideFile $overrideFile) { $any = $true }
        } catch {
            # Never fail the update because of a refresh
        }
    }
    if ($any) {
        Write-Host "  ⚠️  At least one license was refreshed; services will be restarted"
    } else {
        Write-Host "  ✅ All licenses are up to date"
    }
}

try { Update-AllLicenses } catch { }

# ── Renew local HTTPS certs if older than 80 days ─────────────────────────
# Preserve user-provided certs untouched. Only auto-renew the ones we
# generated (mkcert) before they hit mkcert's 825d expiry. Failure is
# non-fatal — the dashboard remains reachable on http://localhost:3000.
function Update-LocalHttpsCerts {
    $cert = Join-Path $INSTALL_DIR "caddy_certs\coderaft.local.pem"
    $key  = Join-Path $INSTALL_DIR "caddy_certs\coderaft.local-key.pem"
    if (-not (Test-Path $cert) -or -not (Test-Path $key)) { return }
    $age = (Get-Date) - (Get-Item $cert).LastWriteTime
    if ($age.TotalDays -lt 80) { return }
    if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
        Write-Host "  ⚠ mkcert absent — cannot renew local HTTPS certs (still valid until mkcert default 825d)."
        return
    }
    Write-Host "  Renewing local HTTPS cert (>80d old)…"
    try {
        & mkcert -cert-file $cert -key-file $key `
            "coderaft.local" "*.coderaft.local" "localhost" "127.0.0.1" "::1" *> $null
        Write-Host "  ✓ Local HTTPS cert renewed"
    } catch {
        Write-Host "  ⚠ Cert renewal failed — keeping previous cert"
    }
}

try { Update-LocalHttpsCerts } catch { }

# ── AGGRESSIVE Docker image cache invalidation ────────────────────────────
# Docker Desktop multi-arch bug: `docker pull` may say "Image is up to date"
# while the local and remote digests differ (tag→digest resolution cache).
# Force full removal: containers, tag, image-by-ID.
Write-Host ""
Write-Host "  Aggressive Coderaft image cache invalidation..."
$ComposeImages = & docker @ComposeArgs config --images 2>$null
foreach ($img in $ComposeImages) {
    if ($img -like "ghcr.io/liamj74/*") {
        # 1. Stop containers running on this image
        $containerIds = & docker ps -q --filter "ancestor=$img" 2>$null
        if ($containerIds) {
            & docker stop $containerIds 2>&1 | Out-Null
            & docker rm -f $containerIds 2>&1 | Out-Null
        }
        # 2. Untag (silent if the image doesn't exist locally — first update)
        & docker image inspect $img 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & docker rmi -f $img 2>&1 | Out-Null
        }
        $LASTEXITCODE = 0
        # 3. Remove by ID (in case the image survives untagged)
        $imageIds = & docker images --format "{{.ID}}" $img 2>$null
        if ($imageIds) {
            foreach ($iid in $imageIds) {
                if ($iid) { & docker rmi -f $iid 2>&1 | Out-Null }
            }
        }
        $LASTEXITCODE = 0
    }
}

Write-Host ""
Write-Host "  Downloading new images..."
& docker @ComposeArgs pull
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: docker compose pull failed."
    exit 1
}

# Note: `--pull always` retried a per-service GHCR manifest check at redeploy
# time (intermittent timeout on slow connections). The Docker Desktop tag-cache
# bug is already covered by `docker rmi -f` + `docker compose pull` above, so
# we let `up` reuse the freshly pulled local images.
& docker @ComposeArgs up -d --force-recreate --remove-orphans
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: docker compose up failed."
    exit 1
}

# ── Post-update healthcheck ───────────────────────────────────────────────
Write-Host ""
Write-Host "  Post-update health check..."
$healthOk  = $false
$healthUrl = "$DASHBOARD_API/api/health"

for ($i = 1; $i -le $HEALTHCHECK_RETRIES; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($resp.StatusCode -lt 500 -and $resp.StatusCode -ne 0) {
            Write-Host "  Dashboard API healthy (HTTP $($resp.StatusCode)) after $i attempt(s)."
            $healthOk = $true
            break
        }
    } catch {
        # Continue retry
    }
    Write-Host "  Attempt $i/$HEALTHCHECK_RETRIES — waiting ${HEALTHCHECK_DELAY}s..."
    Start-Sleep -Seconds $HEALTHCHECK_DELAY
}

if (-not $healthOk) {
    Write-Host ""
    Write-Host "  ERROR: healthcheck failed after $HEALTHCHECK_RETRIES attempts."
    Write-Host "  Triggering automatic rollback..."
    if (Test-Path ".\rollback.ps1") {
        & $PSBin -NoProfile -ExecutionPolicy Bypass -File ".\rollback.ps1"
    } else {
        Write-Host "  rollback.ps1 not found. Manual rollback required."
        Write-Host "  Command: docker compose down; docker compose up -d"
    }
    exit 1
}

# ── Post-update notification ──────────────────────────────────────────────
if ($ADMIN_TOKEN) {
    try {
        $headers = @{
            "Content-Type"  = "application/json"
            "Authorization" = "Bearer $ADMIN_TOKEN"
        }
        Invoke-RestMethod -Method Post -Uri "$DASHBOARD_API/api/platform/update/notify" `
            -Headers $headers -Body '{"status":"done","source":"update.ps1"}' -TimeoutSec 5 | Out-Null
    } catch {
        # Non-critical
    }
}

Write-Host ""
Write-Host "  Update successful! Dashboard: http://localhost:3000"
Write-Host "  If something went wrong: .\rollback.ps1"
Write-Host "  (or: irm https://install.coderaft.io/rollback.ps1 | iex)"
