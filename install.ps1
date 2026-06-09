# =============================================================================
# CodeRaft Platform — One-line installer (PowerShell)
# Usage: irm https://install.coderaft.io/win | iex
#
# Installs the CodeRaft Dashboard. The dashboard handles everything else:
#   - License activation
#   - Product deployment (EntraGuard, Ravenscan, RedFox)
#   - Configuration & updates
# =============================================================================

$ErrorActionPreference = 'Stop'
$InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { 'coderaft' }

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗"
Write-Host "  ║     CodeRaft Platform — Installer        ║"
Write-Host "  ║   Security. Identity. Access. Unified.   ║"
Write-Host "  ╚══════════════════════════════════════════╝"
Write-Host ""

# ── OS detection ─────────────────────────────────────────────────────────────
# Coderaft itself runs in Docker on every OS. The native capture daemon
# (Ravenscan live packet inspection) is the exception: on Docker Desktop
# (Windows here) containers cannot see the host's real NICs, so we
# install a Windows Service on the host instead. On Linux servers the
# Docker sidecar with network_mode: host works natively.
$CoderaftOS   = "windows"
$CoderaftArch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
$CoderaftNeedsNativeCapture = $true
Write-Host "  Detected: $CoderaftOS/$CoderaftArch"
Write-Host ""

# ── Prerequisites ────────────────────────────────────────────────────────────

function Test-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Host "  ✗ $name is required but not installed." -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ $name found" -ForegroundColor Green
}

Write-Host "  Checking prerequisites..."
Test-Command docker
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ✗ 'docker compose' plugin is required." -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ docker compose found" -ForegroundColor Green
Write-Host ""

# ── Install ──────────────────────────────────────────────────────────────────

Write-Host "  Installing to: $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir

function New-HexSecret($length) {
    $bytes = New-Object byte[] $length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ''
}

$AbsoluteInstallDir = (Get-Location).Path

if ((Test-Path '.env') -and (Select-String -Path '.env' -Pattern '^POSTGRES_PASSWORD=' -Quiet)) {
    # Fix UTF-8 BOM if present (older installers wrote BOM which breaks Docker Compose)
    $envBytes = [System.IO.File]::ReadAllBytes("$(Get-Location)\.env")
    if ($envBytes.Length -ge 3 -and $envBytes[0] -eq 0xEF -and $envBytes[1] -eq 0xBB -and $envBytes[2] -eq 0xBF) {
        Write-Host "  ⚠ Fixing UTF-8 BOM in .env..." -ForegroundColor Yellow
        $envContent = [System.Text.Encoding]::UTF8.GetString($envBytes, 3, $envBytes.Length - 3)
        [System.IO.File]::WriteAllText("$(Get-Location)\.env", $envContent, [System.Text.UTF8Encoding]::new($false))
    }
    # Always (re)write HOST_PROJECT_DIR with the current install dir — the
    # location may have changed since the previous install, and a stale or
    # missing value breaks docker-compose interpolation (warning + empty
    # bind-mount path → dashboard-api cannot reach .env.enc → fake "first run").
    $envText = [System.IO.File]::ReadAllText("$(Get-Location)\.env", [System.Text.UTF8Encoding]::new($false))
    $envLines = $envText -split "`r?`n" | Where-Object { $_ -notmatch '^HOST_PROJECT_DIR=' }
    $envText = (($envLines -join "`n").TrimEnd()) + "`nHOST_PROJECT_DIR=$AbsoluteInstallDir`n"
    [System.IO.File]::WriteAllText("$(Get-Location)\.env", $envText, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Existing config preserved (HOST_PROJECT_DIR refreshed)" -ForegroundColor Green
} else {
    Write-Host "  Generating secrets..."
    $Env = @"
# CodeRaft Dashboard — $(Get-Date -Format 'yyyy-MM-dd')
POSTGRES_PASSWORD=$(New-HexSecret 24)
REDIS_PASSWORD=$(New-HexSecret 24)
DASHBOARD_SECRET=$(New-HexSecret 32)
HOST_PROJECT_DIR=$AbsoluteInstallDir
RAVENSCAN_CAPTURE_TOKEN=$(New-HexSecret 32)
CODERAFT_HOST_OS=$CoderaftOS
CODERAFT_HOST_ARCH=$CoderaftArch
"@
    # Write without BOM — Docker Compose .env parser chokes on UTF-8 BOM
    [System.IO.File]::WriteAllText("$(Get-Location)\.env", $Env, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Secrets generated" -ForegroundColor Green
}

# Read the capture token back so we can hand it to the native daemon installer.
$RavenscanCaptureToken = (Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_TOKEN=' -Quiet) `
    | ForEach-Object { (Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_TOKEN=(.+)$').Matches.Groups[1].Value }
if (-not $RavenscanCaptureToken) {
    $match = Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_TOKEN=(.+)$'
    if ($match) { $RavenscanCaptureToken = $match.Matches.Groups[1].Value }
}

# ── Vault master-key bootstrap (D2 + D3) ────────────────────────────────────
# Runs once on fresh install. Skipped if vault-keys\age.key already exists.
# NOTE: openssl is required. On Windows, use openssl.exe from Git for Windows
# (typically at C:\Program Files\Git\usr\bin\openssl.exe or on PATH).
# If openssl is absent, the installer prints a clear error and exits.

function Invoke-VaultBootstrap {
    New-Item -ItemType Directory -Force -Path "vault-keys" | Out-Null
    New-Item -ItemType Directory -Force -Path "vault-tls"  | Out-Null
    New-Item -ItemType Directory -Force -Path "vault-config" | Out-Null

    # ── Step 1: Generate vault age key ──────────────────────────────────────
    # B-VAULT-BOOT (2026-06-09): le `return` anticipé skipait aussi TLS PKI +
    # config.yaml quand age.key existait déjà → vault container fail healthcheck
    # car C:\...\vault-config\config.yaml manquant. Skip uniquement la
    # génération de la key et toujours continuer vers TLS + config.
    if (Test-Path "vault-keys\age.key") {
        Write-Host "  ✓ Vault age key already exists — skipping key generation"
        Invoke-VaultBootstrapTLS
        return
    }

    # Find age-keygen on PATH; auto-download from GitHub releases if absent
    # (mirrors the install.sh behaviour for macOS/Linux).
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
            if (-not $ageKeygenExe) {
                Write-Host "  ✗ age-keygen.exe missing in downloaded archive" -ForegroundColor Red
                exit 1
            }
            $ageKeygen = [pscustomobject]@{ Path = $ageKeygenExe.FullName }
            Write-Host "    ✓ age-keygen downloaded ($($ageKeygen.Path))" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Could not auto-download age-keygen: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    Manual install: https://github.com/FiloSottile/age/releases" -ForegroundColor Red
            exit 1
        }
    }

    Write-Host "  Generating vault master key..."
    # B20 (2026-06-09): age-keygen emits "warning: writing secret key to a
    # world-readable file" on stderr because Windows has no POSIX chmod.
    # Neither `2>$null` nor `2>&1 | Out-Null` reliably suppress native-command
    # stderr in PowerShell 5.1 (the default on Windows) — they still surface
    # as NativeCommandError red blocks. The only robust approach is
    # Start-Process with -RedirectStandardError to a temp file we discard.
    # ACL tightening immediately after addresses the underlying "world-readable"
    # concern, so silencing the warning loses nothing.
    $ageStderr = Join-Path $env:TEMP "coderaft-age-stderr-$(Get-Random).txt"
    $ageProc = Start-Process -FilePath $ageKeygen.Path `
        -ArgumentList "-o","vault-keys\age.key" `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardError $ageStderr `
        -ErrorAction Stop
    Remove-Item -Path $ageStderr -ErrorAction SilentlyContinue
    if ($ageProc.ExitCode -ne 0 -or -not (Test-Path "vault-keys\age.key")) {
        Write-Host "  ✗ age-keygen failed (exit $($ageProc.ExitCode))" -ForegroundColor Red
        exit 1
    }
    # Restrict permissions (owner read-only)
    $acl = Get-Acl "vault-keys\age.key"
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        "Read", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl "vault-keys\age.key" $acl -ErrorAction SilentlyContinue

    # ── Step 2: Compute BIP39 recovery phrase ───────────────────────────────
    # TODO (Phase 1 follow-up): verify -mnemonic-from-key sub-command exists
    # in coderaft-vault image before relying on it.
    $recoveryPhrase = ""
    if ($env:CODERAFT_TEST_MODE -ne "1") {
        $privKey = (Get-Content "vault-keys\age.key" | Where-Object { $_ -match '^AGE-SECRET-KEY-' } | Select-Object -First 1)
        if ($privKey) {
            try {
                $recoveryPhrase = ($privKey | & docker run --rm -i `
                    ghcr.io/liamj74/coderaft-vault:latest `
                    -mnemonic-from-key /dev/stdin 2>$null) -join ""
            } catch { $recoveryPhrase = "" }
        }
    }
    # Fallback: use age public-key fingerprint as placeholder
    if (-not $recoveryPhrase) {
        $pubKey = (Get-Content "vault-keys\age.key" | Where-Object { $_ -match '# public key:' } | Select-Object -First 1) -replace '.*# public key:\s*', ''
        $recoveryPhrase = "[FALLBACK — save vault-keys\age.key securely] fingerprint: $pubKey"
        Write-Host ""
        Write-Host "  [!] coderaft-vault -mnemonic-from-key not available yet (Phase 1 TODO)." -ForegroundColor Yellow
        Write-Host "      Using fingerprint as placeholder. Secure vault-keys\age.key manually." -ForegroundColor Yellow
        Write-Host ""
    }

    # ── Step 3: Display recovery phrase ─────────────────────────────────────
    Write-Host ""
    Write-Host "  +==================================================================+" -ForegroundColor Cyan
    Write-Host "  | *** VAULT RECOVERY PHRASE — WRITE THIS DOWN NOW ***             |" -ForegroundColor Cyan
    Write-Host "  |                                                                  |" -ForegroundColor Cyan
    Write-Host "  | This 24-word phrase is the ONLY way to recover your vault       |" -ForegroundColor Cyan
    Write-Host "  | if vault-keys\age.key is lost or corrupted.                     |" -ForegroundColor Cyan
    Write-Host "  |                                                                  |" -ForegroundColor Cyan
    Write-Host "  | Store it on an encrypted USB, in 1Password, or a physical safe. |" -ForegroundColor Cyan
    Write-Host "  | DO NOT store it on this machine or in plaintext.                |" -ForegroundColor Cyan
    Write-Host "  |                                                                  |" -ForegroundColor Cyan
    Write-Host "  | If BOTH vault-keys\age.key AND this phrase are lost,            |" -ForegroundColor Cyan
    Write-Host "  | ALL encrypted secrets are permanently unrecoverable.            |" -ForegroundColor Cyan
    Write-Host "  +==================================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  RECOVERY PHRASE:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    $recoveryPhrase" -ForegroundColor White
    Write-Host ""

    if ($env:CODERAFT_TEST_MODE -eq "1") {
        Write-Host "  [CODERAFT_TEST_MODE] Auto-accepting CONFIRMED prompt"
        $reply = "CONFIRMED"
    } else {
        $reply = Read-Host "  Type CONFIRMED (all caps) once you have securely stored the phrase"
    }

    if ($reply -ne "CONFIRMED") {
        Write-Host ""
        Write-Host "  Aborted. vault-keys\age.key has been kept in place."
        Write-Host "  Re-run the installer when you are ready."
        exit 1
    }
    Write-Host "  ✓ Recovery phrase confirmed" -ForegroundColor Green

    # ── Step 4: Generate mTLS PKI ────────────────────────────────────────────
    Invoke-VaultBootstrapTLS
}

function Invoke-VaultBootstrapTLS {
    # B12 fix: correct cert filenames (client-ca.crt, vault.crt — NOT ca.crt, server.crt).
    # B11 fix: correct ACL field names (name, cert_san, permissions — NOT san/role/allow).
    # B7  fix: server cert SAN includes localhost + 127.0.0.1 for mTLS hostname verify.
    # NON-NEGOTIABLE: DO NOT require host openssl on Windows. Always use the
    # alpine container approach (same as update.ps1 4c.2) — Git for Windows
    # openssl is not guaranteed on all Windows installs.

    if ((Test-Path "vault-tls\client-ca.crt") -and (Test-Path "vault-tls\vault.crt")) {
        Write-Host "  ✓ Vault mTLS PKI already exists — skipping cert generation"
        return
    }

    Write-Host "  Bootstrapping vault TLS PKI + config (via alpine container)..."
    $tlsDir = "$(Get-Location)\vault-tls"
    $cfgDir = "$(Get-Location)\vault-config"

    # Single shell script run inside alpine — produces all certs at once.
    $opensslScript = @'
set -e
apk add --no-cache openssl >/dev/null
cd /work
# CA (client-ca.crt — exact name expected by vault config.yaml)
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
    -keyout client-ca.key -out client-ca.crt \
    -subj "/CN=coderaft-vault-ca" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
# Server cert (vault.crt — SAN includes localhost + 127.0.0.1 for mTLS probe)
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
    $absTlsDir = (Resolve-Path -LiteralPath $tlsDir -ErrorAction SilentlyContinue)
    if (-not $absTlsDir) {
        New-Item -ItemType Directory -Force -Path $tlsDir | Out-Null
        $absTlsDir = (Resolve-Path -LiteralPath $tlsDir).Path
    } else {
        $absTlsDir = $absTlsDir.Path
    }
    # B20-docker (2026-06-09): the previous form
    #   $opensslScript | & docker run --rm -i ... 2>&1
    # surfaced docker's image-pull progress (and any alpine sh stderr) as a
    # red NativeCommandError block in PowerShell 5.1, alarming users. The
    # only reliable suppression is Start-Process with -RedirectStandardError.
    # We write the script to a temp file, mount it, and run sh against it so
    # we don't need stdin piping.
    $opensslScriptFile = Join-Path $env:TEMP "coderaft-openssl-$(Get-Random).sh"
    # IMPORTANT: write with Unix line endings, otherwise sh barfs on CRLF.
    $opensslScriptLF = $opensslScript -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($opensslScriptFile, $opensslScriptLF, [System.Text.UTF8Encoding]::new($false))

    # Pre-pull alpine silently so `docker run` doesn't emit pull progress on
    # stderr (which PS would still treat as NativeCommandError).
    $pullLog = Join-Path $env:TEMP "coderaft-docker-pull-$(Get-Random).log"
    Start-Process -FilePath "docker" -ArgumentList @("pull","alpine:3.20") `
        -NoNewWindow -Wait `
        -RedirectStandardError $pullLog `
        -RedirectStandardOutput $pullLog `
        -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path $pullLog -ErrorAction SilentlyContinue

    $runLog = Join-Path $env:TEMP "coderaft-docker-run-$(Get-Random).log"
    $dockerProc = Start-Process -FilePath "docker" -ArgumentList @(
        "run","--rm",
        "-v","${opensslScriptFile}:/script.sh:ro",
        "-v","${absTlsDir}:/work",
        "alpine:3.20","sh","/script.sh"
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardError $runLog `
        -RedirectStandardOutput $runLog `
        -ErrorAction Stop
    if (Test-Path $runLog) {
        $runOutput = Get-Content $runLog -ErrorAction SilentlyContinue
        if ($runOutput) { $runOutput | Out-Host }
        Remove-Item -Path $runLog -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $opensslScriptFile -ErrorAction SilentlyContinue
    if ($dockerProc.ExitCode -ne 0 -or -not (Test-Path (Join-Path $tlsDir "vault.crt"))) {
        Write-Host "  ✗ Alpine openssl cert generation failed (docker exit $($dockerProc.ExitCode))" -ForegroundColor Red
        exit 1
    }

    # vault config.yaml — correct file paths
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

    # B11 fix: correct ACL field names (name, cert_san, permissions)
    $aclYaml = @'
# coderaft-vault ACL — field names: name, cert_san, permissions (NOT san/role/allow)
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
    Write-Host "  ✓ Vault mTLS PKI generated (CA + server cert + 4 client certs)" -ForegroundColor Green
}

Invoke-VaultBootstrap

# Append CODERAFT_VAULT_* env vars if not already present
$envText = [System.IO.File]::ReadAllText("$(Get-Location)\.env", [System.Text.UTF8Encoding]::new($false))
foreach ($kv in @(
    "CODERAFT_VAULT_URL=https://coderaft-vault:8200",
    "CODERAFT_VAULT_AZURE=0",
    "CODERAFT_VAULT_LICENSE=0",
    "CODERAFT_VAULT_PRODUCTS=0",
    "CODERAFT_VAULT_JWT=0"
)) {
    $k = $kv.Split('=')[0]
    if ($envText -notmatch "(?m)^$k=") {
        $envText = $envText.TrimEnd() + "`n$kv`n"
    }
}
[System.IO.File]::WriteAllText("$(Get-Location)\.env", $envText, [System.Text.UTF8Encoding]::new($false))

# Init DB
[System.IO.File]::WriteAllText("$(Get-Location)\init-db.sql", '-- Product databases are created by the dashboard on demand', [System.Text.UTF8Encoding]::new($false))

# Docker compose — dashboard + vault
Write-Host "  Writing docker-compose.yml..."
$Compose = @'
# CodeRaft Dashboard
# Products are deployed by the dashboard after license activation.

services:
  # Caddy local HTTPS reverse proxy.
  # Terminates TLS using mkcert-generated certs (trusted locally) and forwards
  # to the nginx SPA inside the `dashboard` container. Falls back to plain
  # HTTP on :3000 if no certs are mounted (compat retrograde).
  caddy:
    image: caddy:2-alpine
    depends_on:
      dashboard: { condition: service_started }
    ports:
      - "127.0.0.1:443:443"
      - "127.0.0.1:80:80"
    volumes:
      - ./caddy_certs:/certs:ro
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    security_opt: [no-new-privileges:true]
    restart: unless-stopped

  dashboard:
    image: ghcr.io/liamj74/coderaft-dashboard:latest
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
      dashboard-api: { condition: service_started }
    environment:
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - DASHBOARD_SECRET=${DASHBOARD_SECRET}
      - LICENSE_SERVER_URL=https://license.coderaft.io
    security_opt: [no-new-privileges:true]
    restart: unless-stopped

  dashboard-api:
    image: ghcr.io/liamj74/coderaft-dashboard-api:latest
    networks:
      - default
      - coderaft-vault-net
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
      coderaft-vault: { condition: service_healthy }
    environment:
      # B15 (2026-05-19): Node.js résout IPv6 d'abord par défaut. Le container
      # Docker n'a pas d'IPv6 → ENETUNREACH → fallback IPv4 lent ou timeout
      # sur les appels sortants (license.coderaft.io, login.microsoftonline.com).
      # Force IPv4-first.
      - NODE_OPTIONS=--dns-result-order=ipv4first
      - LICENSE_SERVER_URL=https://license.coderaft.io
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - DASHBOARD_SECRET=${DASHBOARD_SECRET}
      - CONTAINER_COMPOSE_DIR=/host-compose
      - HOST_PROJECT_DIR=${HOST_PROJECT_DIR}
      - COMPOSE_PROJECT_NAME=coderaft
      # NOTE: Phase 0.5 keeps SOPS path for backward compat; Phase 5 removes it.
      - CODERAFT_VAULT_URL=https://coderaft-vault:8200
      # B12 fix: correct vault TLS filenames (client-ca.crt, not ca.crt)
      - CODERAFT_VAULT_TLS_CA=/vault-tls/client-ca.crt
      - CODERAFT_VAULT_TLS_CERT=/vault-tls/dashboard-api-client.crt
      - CODERAFT_VAULT_TLS_KEY=/vault-tls/dashboard-api-client.key
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - dashboard_data:/data
      - .:/host-compose
      # Age private key for SOPS decryption (legacy — kept for backward compat).
      - ./.coderaft-age.key:/keys/age.key:ro
      # Vault mTLS client cert for dashboard-api (B12: correct filenames)
      - ./vault-tls/client-ca.crt:/vault-tls/client-ca.crt:ro
      - ./vault-tls/dashboard-api-client.crt:/vault-tls/dashboard-api-client.crt:ro
      - ./vault-tls/dashboard-api-client.key:/vault-tls/dashboard-api-client.key:ro
    security_opt: [no-new-privileges:true]
    restart: unless-stopped

  # ── coderaft-vault ──────────────────────────────────────────────────────────
  # Centralised secret store. All products read/write through it via mTLS.
  # Port 8200 is internal-only (coderaft-vault-net). No external exposure.
  coderaft-vault:
    image: ghcr.io/liamj74/coderaft-vault:latest
    # B8 fix: run as root so container can write /data SQLite and read 0600 .key files.
    # Security maintained via cap_drop:ALL + no-new-privileges.
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

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: coderaft
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: coderaft
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      # init-db.sql is intentionally NOT bind-mounted — when the
      # dashboard-api spawns docker-compose from inside a Linux container
      # against a Windows host, the resolved Windows path contains a
      # drive-letter colon that the daemon rejects ("too many colons").
      # The script was a no-op anyway (just a comment); product databases
      # are created on demand by the dashboard.
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coderaft"]
      interval: 5s
      timeout: 5s
      retries: 5
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    command: redis-server --requirepass ${REDIS_PASSWORD} --maxmemory 128mb
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

networks:
  # Internal network for vault <-> product communication. No external port.
  coderaft-vault-net:
    internal: true

volumes:
  postgres_data:
  dashboard_data:
  caddy_data:
  caddy_config:
  vault_data:
'@
[System.IO.File]::WriteAllText("$(Get-Location)\docker-compose.yml", $Compose, [System.Text.UTF8Encoding]::new($false))

# ── Caddyfile (local HTTPS) ──────────────────────────────────────────────────
$Caddyfile = @'
{
    auto_https off
    admin off
}

(coderaft_tls) {
    tls /certs/coderaft.local.pem /certs/coderaft.local-key.pem
}

https://coderaft.local, https://*.coderaft.local {
    import coderaft_tls
    reverse_proxy dashboard:3000 {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
    }
}

http://coderaft.local, http://*.coderaft.local {
    redir https://{host}{uri} permanent
}

:80 {
    reverse_proxy dashboard:3000
}
'@
if (-not (Test-Path "$(Get-Location)\Caddyfile")) {
    [System.IO.File]::WriteAllText("$(Get-Location)\Caddyfile", $Caddyfile, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Caddyfile generated"
}

# ── Local HTTPS via mkcert ───────────────────────────────────────────────────
function Setup-LocalHttps {
    if ($env:CODERAFT_SKIP_HTTPS -eq "1") {
        Write-Host "  CODERAFT_SKIP_HTTPS=1 — skipping local HTTPS setup"
        return $false
    }

    New-Item -ItemType Directory -Force -Path "caddy_certs" | Out-Null

    $certPath = "caddy_certs\coderaft.local.pem"
    $keyPath  = "caddy_certs\coderaft.local-key.pem"
    if ((Test-Path $certPath) -and (Test-Path $keyPath)) {
        $age = (Get-Date) - (Get-Item $certPath).LastWriteTime
        if ($age.TotalDays -lt 80) {
            Write-Host "  ✓ Local HTTPS certs already present (caddy_certs\)" -ForegroundColor Green
            return $true
        }
        Write-Host "  Local HTTPS certs older than 80 days — regenerating"
    }

    if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
        Write-Host "  mkcert not found."
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "  Installing mkcert via Chocolatey (choco install mkcert)…"
            try {
                choco install mkcert -y --no-progress *> $null
            } catch {
                Write-Host "  ⚠ choco install mkcert failed — fallback to http://localhost:3000" -ForegroundColor Yellow
                return $false
            }
        } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
            Write-Host "  Installing mkcert via Scoop (scoop install mkcert)…"
            try {
                scoop install mkcert *> $null
            } catch {
                Write-Host "  ⚠ scoop install mkcert failed — fallback to http://localhost:3000" -ForegroundColor Yellow
                return $false
            }
        } else {
            Write-Host "  ⚠ Neither Chocolatey nor Scoop found — install mkcert manually:" -ForegroundColor Yellow
            Write-Host "      https://github.com/FiloSottile/mkcert#installation"
            Write-Host "    Continuing in HTTP-only mode (http://localhost:3000)."
            return $false
        }
    }

    Write-Host "  Installing mkcert local CA (one-time)…"
    try {
        & mkcert -install *> $null
    } catch {
        Write-Host "  ⚠ mkcert -install failed — local HTTPS will not be trusted." -ForegroundColor Yellow
    }

    Write-Host "  Generating local cert for coderaft.local…"
    try {
        & mkcert -cert-file $certPath -key-file $keyPath `
            "coderaft.local" "*.coderaft.local" "localhost" "127.0.0.1" "::1" *> $null
    } catch {
        Write-Host "  ⚠ mkcert cert generation failed — fallback to http://localhost:3000" -ForegroundColor Yellow
        Remove-Item -ErrorAction SilentlyContinue $certPath, $keyPath
        return $false
    }
    Write-Host "  ✓ Local HTTPS cert generated (valid 825d)" -ForegroundColor Green
    return $true
}

# ── hosts file entries ──────────────────────────────────────────────────────
function Ensure-HostsEntry {
    $hostsFile = "$env:WINDIR\System32\drivers\etc\hosts"
    $marker    = "# coderaft-platform"
    $entry     = "127.0.0.1 coderaft.local entraguard.coderaft.local ravenscan.coderaft.local redfox.coderaft.local $marker"

    if (Test-Path $hostsFile) {
        $existing = Get-Content $hostsFile -ErrorAction SilentlyContinue
        if ($existing -match "coderaft\.local") {
            Write-Host "  ✓ hosts file already contains coderaft.local"
            return
        }
    }

    if ($env:CODERAFT_SKIP_HOSTS -eq "1") {
        Write-Host "  CODERAFT_SKIP_HOSTS=1 — skipping hosts update"
        return
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        try {
            Add-Content -Path $hostsFile -Value $entry -ErrorAction Stop
            Write-Host "  ✓ hosts file updated"
        } catch {
            Write-Host "  ⚠ Could not update hosts file: $_" -ForegroundColor Yellow
            Write-Host "    Add manually to ${hostsFile}:"
            Write-Host "      $entry"
        }
    } else {
        Write-Host "  ⚠ Not running as Administrator — cannot update hosts file." -ForegroundColor Yellow
        Write-Host "    Add the following line to ${hostsFile} (run as admin):"
        Write-Host "      $entry"
    }
}

$httpsReady = Setup-LocalHttps
if ($httpsReady) {
    Ensure-HostsEntry
}

# Helper scripts
Set-Content -Path 'start.ps1' -Value @'
Write-Host "Starting CodeRaft..."
docker compose up -d
$Url = "http://localhost:3000"
if ((Test-Path "caddy_certs\coderaft.local.pem") -and `
    ((Get-Content "$env:WINDIR\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue) -match "coderaft\.local")) {
    $Url = "https://coderaft.local"
}
Write-Host "  Dashboard: $Url"
Start-Process $Url
'@ -Encoding UTF8

Set-Content -Path 'stop.ps1' -Value @'
Write-Host "Stopping CodeRaft..."
docker compose down
Write-Host "Done."
'@ -Encoding UTF8

try {
    $u = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/update.ps1" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    [System.IO.File]::WriteAllText("$PWD\update.ps1", $u.Content, [System.Text.Encoding]::UTF8)
} catch {
    Set-Content -Path 'update.ps1' -Value @'
Write-Host "Updating CodeRaft..."
docker compose pull
docker compose up -d --force-recreate --remove-orphans
Write-Host "  Updated! Dashboard: http://localhost:3000"
'@ -Encoding UTF8
}

try {
    $r = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/rollback.ps1" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    [System.IO.File]::WriteAllText("$PWD\rollback.ps1", $r.Content, [System.Text.Encoding]::UTF8)
} catch {
    Set-Content -Path 'rollback.ps1' -Value @'
Write-Host "rollback.ps1 placeholder — fetch the real one from https://install.coderaft.io/rollback.ps1"
Write-Host "or run: irm https://install.coderaft.io/rollback.ps1 -OutFile rollback.ps1"
exit 1
'@ -Encoding UTF8
}

# ── Vault unseal helper (fresh install) ──────────────────────────────────────
# B6/B7 fix: vault image is distroless — no shell, no wget.
# NEVER `docker compose exec coderaft-vault sh`. Use curlimages/curl sidecar.
# B10 fix: vault starts sealed — must POST /v1/unseal after container is up.
function Invoke-VaultUnsealFresh {
    $vaultAgeKey = "vault-keys\age.key"
    if (-not (Test-Path $vaultAgeKey)) {
        Write-Host "  ✗ vault-keys\age.key not found — cannot unseal" -ForegroundColor Red
        return $false
    }

    # Detect compose project name (determines Docker network for sidecar)
    $vaultProject = (& docker inspect coderaft-coderaft-vault-1 `
        --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>$null) -join ""
    if (-not $vaultProject) { $vaultProject = "coderaft" }
    $vaultNetwork = "${vaultProject}_coderaft-vault-net"
    $absTlsDir = (Resolve-Path -LiteralPath "vault-tls").Path

    function Invoke-VaultCurlFresh {
        param([string]$Method, [string]$Path, [string]$JsonBody = "")
        # A5 fix: do NOT name this $args — that is a PS automatic variable.
        $dockerArgs = @(
            "run", "--rm",
            "--user", "0:0",
            "--network", $vaultNetwork,
            "-v", "${absTlsDir}:/tls:ro",
            "curlimages/curl:latest",
            "--cert", "/tls/dashboard-api-client.crt",
            "--key",  "/tls/dashboard-api-client.key",
            "--cacert", "/tls/client-ca.crt",
            "-sS", "-X", $Method,
            "https://coderaft-vault:8200$Path"
        )
        if ($JsonBody) {
            $dockerArgs += @("-H", "Content-Type: application/json", "-d", $JsonBody)
        }
        $resp = & docker @dockerArgs 2>&1
        return ($resp -join "")
    }

    Write-Host "  Waiting for vault to be reachable..."
    $vaultReachable = $false
    $lastSealed = "true"
    for ($vi = 1; $vi -le 20; $vi++) {
        try {
            $health = Invoke-VaultCurlFresh -Method "GET" -Path "/v1/health"
            if ($health -match '"sealed":(true|false)') {
                $vaultReachable = $true
                $lastSealed = $Matches[1]
                break
            }
        } catch { }
        if ($vi % 3 -eq 0) { Write-Host "    ... still waiting (attempt $vi/20)" }
        Start-Sleep -Seconds 3
    }

    if (-not $vaultReachable) {
        Write-Host "  ✗ coderaft-vault did not respond to TLS probes" -ForegroundColor Red
        return $false
    }

    # B10 fix: unseal if sealed (1 share = base64-encoded age key file bytes)
    if ($lastSealed -eq "true") {
        Write-Host "  Vault is sealed — sending unseal request..."
        $ageKeyBytes = [System.IO.File]::ReadAllBytes($vaultAgeKey)
        $shareB64 = [Convert]::ToBase64String($ageKeyBytes)
        $unsealBody = @{ shares = @($shareB64) } | ConvertTo-Json -Compress
        $unsealResp = Invoke-VaultCurlFresh -Method "POST" -Path "/v1/unseal" -JsonBody $unsealBody
        if ($unsealResp -notmatch '"ok"\s*:\s*true|"sealed"\s*:\s*false') {
            Write-Host "  Unseal response: $unsealResp" -ForegroundColor Yellow
            Write-Host "  ✗ Vault unseal failed" -ForegroundColor Red
            return $false
        }
        Write-Host "  ✓ Vault unsealed" -ForegroundColor Green
    }

    $finalHealth = Invoke-VaultCurlFresh -Method "GET" -Path "/v1/health"
    if ($finalHealth -notmatch '"sealed"\s*:\s*false') {
        Write-Host "  Final health: $finalHealth" -ForegroundColor Yellow
        Write-Host "  ✗ Vault still sealed after unseal call" -ForegroundColor Red
        return $false
    }
    Write-Host "  ✓ coderaft-vault is healthy (sealed:false)" -ForegroundColor Green
    return $true
}

# ── Pull & Start ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  Pulling dashboard image..."
docker compose pull

Write-Host ""
Write-Host "  Starting dashboard..."
# B9 fix: explicit stop+rm for vault container before up so fresh certs
# are picked up from bind mounts (--force-recreate alone can leave a
# Running container with stale certs in Docker Desktop memory).
& docker compose stop coderaft-vault 2>$null | Out-Null
& docker compose rm -f coderaft-vault 2>$null | Out-Null
docker compose up -d

Write-Host ""
Write-Host "  Unsealing vault..."
$vaultOk = Invoke-VaultUnsealFresh
if (-not $vaultOk) {
    Write-Host "  ⚠ Vault unseal failed — dashboard may show 'vault unavailable'." -ForegroundColor Yellow
    Write-Host "    Re-run the installer or run: docker compose restart coderaft-vault"
}

Write-Host ""
Write-Host "  Waiting for dashboard to be ready..."
Start-Sleep -Seconds 10


# ── Native capture daemon (Windows Service) ───────────────────────────────────
if ($CoderaftNeedsNativeCapture -and $env:SKIP_NATIVE_CAPTURE -ne "1") {
    Write-Host ""
    Write-Host "  ── Live capture daemon (native Windows Service) ────"
    Write-Host "  Coderaft runs in Docker but live packet capture needs"
    Write-Host "  a native service that can see your real Wi-Fi and"
    Write-Host "  Ethernet interfaces (Docker Desktop hides them)."
    Write-Host ""

    # Public ravenscan-installer repo — same pattern as the other
    # Coderaft products (private source repo, public installer repo
    # holds release artifacts). Pinned to a deliberate tag.
    $CaptureBaseUrl = if ($env:CAPTURE_BASE_URL) { $env:CAPTURE_BASE_URL } `
                      else { "https://github.com/LiamJ74/ravenscan-installer/releases/download/capture-v0.1.0" }
    $CaptureBin     = "ravenscan-capture-host-windows-$CoderaftArch.exe"
    $CaptureTmp     = Join-Path $env:TEMP ("coderaft-capture-{0}" -f (Get-Random))
    New-Item -ItemType Directory -Force -Path $CaptureTmp | Out-Null

    try {
        Write-Host "  Downloading $CaptureBin from $CaptureBaseUrl…"
        $files = @($CaptureBin, "install-windows.ps1", "uninstall-windows.ps1", "SHA256SUMS")
        foreach ($f in $files) {
            try {
                Invoke-WebRequest -Uri "$CaptureBaseUrl/$f" `
                    -OutFile (Join-Path $CaptureTmp $f) -UseBasicParsing
            } catch {
                if ($f -eq "SHA256SUMS") { continue }  # optional
                throw
            }
        }

        # Optional checksum verification.
        $sumsPath = Join-Path $CaptureTmp "SHA256SUMS"
        if (Test-Path $sumsPath) {
            foreach ($line in Get-Content $sumsPath) {
                if ($line -match '^([0-9a-f]{64})\s+(\S+)$') {
                    $expected = $Matches[1]
                    $name     = $Matches[2]
                    $localPath = Join-Path $CaptureTmp $name
                    if (Test-Path $localPath) {
                        $actual = (Get-FileHash -Algorithm SHA256 $localPath).Hash.ToLower()
                        if ($actual -ne $expected) {
                            throw "Checksum mismatch for ${name}: expected $expected, got $actual"
                        }
                    }
                }
            }
            Write-Host "  ✓ Checksums verified"
        }

        # Self-elevate to install the Windows Service if not already admin.
        $isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)

        $installScript = Join-Path $CaptureTmp "install-windows.ps1"
        if ($isAdmin) {
            Write-Host "  Running install-windows.ps1 as administrator…"
            & $installScript -Token $RavenscanCaptureToken
        } else {
            Write-Host "  Re-launching capture installer with elevated privileges…"
            $args = "-NoProfile -ExecutionPolicy Bypass -File `"$installScript`" -Token `"$RavenscanCaptureToken`""
            Start-Process powershell -ArgumentList $args -Verb RunAs -Wait
        }

        # Tell the platform to talk to the host daemon instead of the
        # Docker sidecar (Docker Desktop on Windows can only see the
        # bridge network from inside containers).
        if (-not (Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_SIDECAR_URL=' -Quiet)) {
            $line = "`nRAVENSCAN_CAPTURE_SIDECAR_URL=http://host.docker.internal:7777"
            [System.IO.File]::AppendAllText("$(Get-Location)\.env", $line, [System.Text.UTF8Encoding]::new($false))
        }
        Write-Host "  ✓ Native capture daemon installed and running on 127.0.0.1:7777" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Could not install the native capture daemon: $_" -ForegroundColor Yellow
        Write-Host "    Live capture will be limited to the Docker bridge until you"
        Write-Host "    install the daemon manually from the Settings page."
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $CaptureTmp
    }
    Write-Host ""
}

$DashboardUrl = "http://localhost:3000"
if ((Test-Path "caddy_certs\coderaft.local.pem") -and `
    ((Get-Content "$env:WINDIR\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue) -match "coderaft\.local")) {
    $DashboardUrl = "https://coderaft.local"
}

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║            Installation complete!                    ║" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host ("  ║   Dashboard: {0,-39} ║" -f $DashboardUrl) -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║   Open the dashboard to activate your license        ║" -ForegroundColor Green
Write-Host "  ║   and deploy your products.                          ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Commands:  .\start.ps1  .\stop.ps1  .\update.ps1  .\rollback.ps1"
Write-Host ""

Start-Process $DashboardUrl
