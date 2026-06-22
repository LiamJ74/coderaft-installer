#!/bin/bash
# =============================================================================
# CodeRaft Platform — One-line installer
# Usage: curl -fsSL https://install.coderaft.io | bash
#
# Installs the CodeRaft Dashboard. The dashboard handles everything else:
#   • License activation
#   • Product deployment (WolfGuard, Ravenscan, RedFox)
#   • Configuration & updates
# =============================================================================

set -e

INSTALL_DIR="${INSTALL_DIR:-./coderaft}"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║     CodeRaft Platform — Installer        ║"
echo "  ║   Security. Identity. Access. Unified.   ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── OS detection ─────────────────────────────────────────────────────────────
# Coderaft itself runs in Docker on every OS. The native capture daemon
# (live packet inspection for Ravenscan) is the exception: on Docker
# Desktop (macOS/Windows) containers cannot see the host's real NICs,
# so we install a native binary on the host instead. On Linux the
# Docker sidecar with network_mode: host works natively — no extra
# binary needed.
case "$(uname -s)" in
    Darwin)  CODERAFT_OS="macos"   ; CODERAFT_NEEDS_NATIVE_CAPTURE=1 ;;
    Linux)   CODERAFT_OS="linux"   ; CODERAFT_NEEDS_NATIVE_CAPTURE=0 ;;
    *)       CODERAFT_OS="unknown" ; CODERAFT_NEEDS_NATIVE_CAPTURE=0 ;;
esac
case "$(uname -m)" in
    arm64|aarch64) CODERAFT_ARCH="arm64" ;;
    x86_64|amd64)  CODERAFT_ARCH="amd64" ;;
    *)             CODERAFT_ARCH="unknown" ;;
esac
echo "  Detected: ${CODERAFT_OS}/${CODERAFT_ARCH}"
echo ""

# B33 (2026-06-01): NE PAS forcer DOCKER_DEFAULT_PLATFORM.
# Forcer "linux/arm64" (bare) cassait les pulls d'images publiques qui
# n'exposent que linux/arm64/v8 (postgres:16-alpine, redis:7-alpine,
# caddy:2-alpine, etc.) → "no matching manifest". Docker Desktop ≥ 4.20
# résout correctement par lui-même. Si un user a un Docker très ancien, il
# peut toujours forcer en exportant DOCKER_DEFAULT_PLATFORM=linux/arm64/v8
# avant de lancer l'install.

# ── Prerequisites ────────────────────────────────────────────────────────────

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "  ✗ $1 is required but not installed."
        exit 1
    fi
    echo "  ✓ $1 found"
}

echo "  Checking prerequisites..."
check_command docker
if ! docker compose version &> /dev/null; then
    echo "  ✗ Docker Compose v2 is required."
    echo "    https://docs.docker.com/compose/install/"
    exit 1
fi
echo "  ✓ docker compose found"

# B-DAEMON-CHECK (2026-06-10): `docker compose version` only validates the
# CLI plugin — the daemon may still be unreachable. `docker info` round-trips
# through the daemon so we fail fast with a clear message instead of pulling
# blindly and producing cryptic errors halfway through the install.
if ! _docker_info=$(docker info --format '{{.ServerVersion}}' 2>&1); then
    echo "  ✗ Docker daemon is not reachable."
    echo ""
    echo "    docker info: ${_docker_info}"
    echo ""
    echo "    Start Docker / Docker Desktop and wait for it to be running,"
    echo "    then re-run this installer."
    exit 1
fi
echo "  ✓ Docker daemon reachable (server ${_docker_info})"
echo ""

# ── Install ──────────────────────────────────────────────────────────────────

echo "  Installing to: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# ── age key setup (SOPS Phase 2 secrets management) ─────────────────────────
# We keep TWO paths:
#   * AGE_KEY_PATH      = /etc/coderaft/age.key      (system-wide, root-owned, legacy)
#   * AGE_KEY_LOCAL     = ${INSTALL_DIR}/.coderaft-age.key (bind-mount source for
#                                                          dashboard-api → /keys/age.key)
# The compose bind-mount uses AGE_KEY_LOCAL so it works on macOS / Windows
# Docker Desktop without giving the container root access to /etc/coderaft.
# When AGE_KEY_PATH already exists (legacy install), we copy it to AGE_KEY_LOCAL
# so the dashboard-api can decrypt .env.enc without changing convention.
AGE_KEY_DIR="/etc/coderaft"
AGE_KEY_PATH="${AGE_KEY_DIR}/age.key"
AGE_KEY_LOCAL="$(pwd)/.coderaft-age.key"

ensure_age_binary() {
    if command -v age-keygen &>/dev/null; then
        return 0
    fi
    echo "  Downloading age-keygen..."
    AGE_VERSION="v1.2.1"
    AGE_OS="${CODERAFT_OS/macos/darwin}"
    AGE_TMP="$(mktemp -d)"
    trap 'rm -rf "$AGE_TMP"' EXIT
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-${AGE_OS}-${CODERAFT_ARCH}.tar.gz" \
        -o "${AGE_TMP}/age.tar.gz" 2>/dev/null || return 1
    tar -xzf "${AGE_TMP}/age.tar.gz" -C "${AGE_TMP}" 2>/dev/null
    sudo install -m 755 "${AGE_TMP}/age/age-keygen" /usr/local/bin/age-keygen 2>/dev/null \
        || install -m 755 "${AGE_TMP}/age/age-keygen" "$HOME/.local/bin/age-keygen" 2>/dev/null \
        || return 1
    sudo install -m 755 "${AGE_TMP}/age/age" /usr/local/bin/age 2>/dev/null \
        || install -m 755 "${AGE_TMP}/age/age" "$HOME/.local/bin/age" 2>/dev/null \
        || true
    echo "  ✓ age installed"
    return 0
}

setup_age_key() {
    # 1. If a legacy /etc/coderaft/age.key exists and the local one doesn't,
    #    mirror it so the dashboard-api bind-mount works without sudo.
    if [ -f "${AGE_KEY_PATH}" ] && [ ! -f "${AGE_KEY_LOCAL}" ]; then
        echo "  ✓ Reusing legacy age key from ${AGE_KEY_PATH}"
        sudo cat "${AGE_KEY_PATH}" 2>/dev/null > "${AGE_KEY_LOCAL}" \
            || cat "${AGE_KEY_PATH}" 2>/dev/null > "${AGE_KEY_LOCAL}" \
            || { echo "  ⚠ Could not read ${AGE_KEY_PATH} — generating a new local key."; rm -f "${AGE_KEY_LOCAL}"; }
        if [ -s "${AGE_KEY_LOCAL}" ]; then
            chmod 400 "${AGE_KEY_LOCAL}"
            return 0
        fi
    fi

    if [ -f "${AGE_KEY_LOCAL}" ]; then
        echo "  ✓ age key already exists at ${AGE_KEY_LOCAL}"
        return 0
    fi

    if ! ensure_age_binary; then
        echo "  ⚠ Could not install age — SOPS encryption deferred to migrate-to-sops.sh"
        return 1
    fi

    echo "  Generating age key at ${AGE_KEY_LOCAL}..."
    age-keygen -o "${AGE_KEY_LOCAL}" 2>/dev/null || return 1
    chmod 400 "${AGE_KEY_LOCAL}"
    echo "  ✓ age key generated (${AGE_KEY_LOCAL})"
    echo ""
    echo "  IMPORTANT: Back up ${AGE_KEY_LOCAL} to an encrypted USB or secure vault."
    echo "  If this key is lost, all encrypted .env.enc secrets are unrecoverable."
    echo ""
    return 0
}

# Try to set up age key on every OS. Failure is non-fatal: the dashboard
# falls back to plaintext .env with a loud warning, and the operator can
# run scripts/migrate-to-sops.sh later.
setup_age_key || true

# Generate secrets on first install
gen_hex() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

ABSOLUTE_INSTALL_DIR="$(pwd)"

if [ -f ".env" ] && grep -q '^POSTGRES_PASSWORD=' .env 2>/dev/null; then
    # Always (re)write HOST_PROJECT_DIR with current install dir — the location
    # may have changed since the previous install, and a stale or missing value
    # breaks docker-compose interpolation (warning + empty bind-mount path →
    # dashboard-api cannot reach .env.enc → fake "first run").
    grep -v '^HOST_PROJECT_DIR=' .env > .env.tmp 2>/dev/null \
        && printf 'HOST_PROJECT_DIR=%s\n' "${ABSOLUTE_INSTALL_DIR}" >> .env.tmp \
        && mv .env.tmp .env \
        && chmod 600 .env
    # Backward compat: legacy install without .env.enc — show warning in dashboard
    if [ ! -f "${AGE_KEY_LOCAL}" ] && [ ! -f "${AGE_KEY_PATH}" ]; then
        echo "  ⚠ Legacy install detected: no age key found."
        echo "    Secrets are currently stored as plaintext in .env."
        echo "    Run the Setup Wizard to migrate to encrypted .env.enc."
    fi
    echo "  ✓ Existing config preserved"
else
    echo "  Generating secrets..."
    cat > .env << ENVFILE
# CodeRaft Dashboard — $(date -u +"%Y-%m-%d")
POSTGRES_PASSWORD=$(gen_hex 24)
REDIS_PASSWORD=$(gen_hex 24)
DASHBOARD_SECRET=$(gen_hex 32)
HOST_PROJECT_DIR=${ABSOLUTE_INSTALL_DIR}
RAVENSCAN_CAPTURE_TOKEN=$(gen_hex 32)
CODERAFT_HOST_OS=${CODERAFT_OS}
CODERAFT_HOST_ARCH=${CODERAFT_ARCH}
ENVFILE
    chmod 600 .env
    echo "  ✓ Secrets generated"
fi

# ── Encrypt .env → .env.enc and purge plaintext (banking-grade) ─────────────
# Runs on first install OR on a re-install where plaintext is still around. The
# dashboard-api still needs a plaintext .env at `docker compose up` time for
# variable interpolation, so we keep .env present here and let the dashboard
# decrypt .env.enc on subsequent boots. The migrate-to-sops.sh --finalize step
# is what eventually purges plaintext on running deployments. For NEW installs
# we can be more aggressive: write .env.enc immediately so readHostEnv() never
# touches plaintext after the first `docker compose up` settles.
encrypt_env_to_enc() {
    local age_key=""
    if [ -f "${AGE_KEY_LOCAL}" ]; then
        age_key="${AGE_KEY_LOCAL}"
    elif [ -f "${AGE_KEY_PATH}" ]; then
        # Mirror legacy key into install dir so the bind-mount works.
        sudo cat "${AGE_KEY_PATH}" 2>/dev/null > "${AGE_KEY_LOCAL}" \
            || cat "${AGE_KEY_PATH}" 2>/dev/null > "${AGE_KEY_LOCAL}" \
            || return 1
        chmod 400 "${AGE_KEY_LOCAL}"
        age_key="${AGE_KEY_LOCAL}"
    else
        return 1
    fi

    if ! command -v sops &>/dev/null; then
        # Try to install sops on the fly; non-fatal.
        SOPS_VERSION="v3.8.1"
        SOPS_OS="${CODERAFT_OS/macos/darwin}"
        curl -fsSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.${SOPS_OS}.${CODERAFT_ARCH}" \
            -o /tmp/sops-coderaft 2>/dev/null || return 1
        sudo install -m 755 /tmp/sops-coderaft /usr/local/bin/sops 2>/dev/null \
            || install -m 755 /tmp/sops-coderaft "$HOME/.local/bin/sops" 2>/dev/null \
            || return 1
        rm -f /tmp/sops-coderaft
    fi

    local age_pub
    age_pub=$(grep "# public key:" "${age_key}" 2>/dev/null | head -1 | awk '{print $NF}')
    [ -n "${age_pub}" ] || return 1

    SOPS_AGE_KEY_FILE="${age_key}" sops --encrypt --age "${age_pub}" --output .env.enc .env \
        || return 1
    chmod 600 .env.enc
    echo "  ✓ .env.enc created (sops + age)"
    return 0
}

if [ -f .env ] && [ ! -f .env.enc ]; then
    if encrypt_env_to_enc; then
        echo "  ✓ Secrets encrypted to .env.enc"
        # On a fresh install we keep .env (compose interpolation needs it for
        # the very first `up`). The dashboard-api re-encrypts on every deploy
        # and will refuse to read plaintext at runtime when CODERAFT_REJECT_PLAINTEXT_ENV=1.
        # Operators can run `bash scripts/migrate-to-sops.sh --finalize` after
        # the first successful boot to purge plaintext for good.
        echo ""
        echo "  ⚠ Plaintext .env still on disk (needed by 'docker compose up' for"
        echo "    variable interpolation). Run this AFTER the dashboard boots OK:"
        echo "        curl -fsSL https://install.coderaft.io/migrate.sh | bash -s -- --finalize"
        echo ""
    else
        echo "  ⚠ Could not encrypt .env to .env.enc (age/sops unavailable)."
        echo "    Plaintext .env will be used as fallback."
        echo "    Run scripts/migrate-to-sops.sh later to fix."
    fi
fi

# Read the capture token back so we can pass it to the native daemon
# install step (only relevant on macOS).
RAVENSCAN_CAPTURE_TOKEN_VALUE="$(grep '^RAVENSCAN_CAPTURE_TOKEN=' .env | cut -d= -f2)"

# ── Vault master-key bootstrap (D2 + D3) ────────────────────────────────────
# Runs once on fresh install. Skipped if vault-keys/age.key already exists.
# The vault age key is SEPARATE from the SOPS age key (.coderaft-age.key).
# .coderaft-age.key = SOPS legacy path (kept for backward compat per Phase 0.5)
# vault-keys/age.key = master key that encrypts the vault's envelope DEK
vault_bootstrap() {
    mkdir -p vault-keys vault-tls vault-config

    # ── Step 1: Generate vault age key (or reuse existing) ──────────────────
    # B-VAULT-BOOT (2026-06-09): le return 0 anticipé skipait aussi TLS PKI +
    # config.yaml quand age.key existait déjà → vault container fail healthcheck
    # car /etc/coderaft-vault/config.yaml manquant. Skip uniquement la génération
    # de la key et toujours continuer vers TLS + config (ces étapes sont
    # idempotentes via leurs propres "skip si déjà existant" en interne).
    if [ -f vault-keys/age.key ]; then
        echo "  ✓ Vault age key already exists — skipping key generation"
        vault_bootstrap_tls
        return 0
    fi

    if ! ensure_age_binary; then
        echo "  ✗ Cannot generate vault age key — age-keygen not available"
        echo "    Install age from https://github.com/FiloSottile/age/releases"
        echo "    then re-run the installer."
        exit 1
    fi

    # B-VAULT-DEK (2026-06-22): wipe a stale coderaft_vault_data volume left
    # by a prior install attempt. Its wrapped DEK was sealed with the previous
    # age key; a fresh age.key here will produce "unseal failed: bad master
    # key" on the next /v1/unseal call. age.key didn't exist yet so there's
    # no legitimate data to preserve.
    if docker volume inspect coderaft_vault_data >/dev/null 2>&1; then
        echo "  Removing stale coderaft_vault_data volume from a previous install attempt..."
        if docker volume rm -f coderaft_vault_data >/dev/null 2>&1; then
            echo "    ✓ stale vault data removed"
        else
            echo "    ⚠ could not remove coderaft_vault_data — vault unseal may fail with 'bad master key'"
            echo "      Manual fix: docker compose down; docker volume rm coderaft_vault_data; docker compose up -d"
        fi
    fi

    echo "  Generating vault master key..."
    age-keygen -o vault-keys/age.key 2>/dev/null || {
        echo "  ✗ age-keygen failed"
        exit 1
    }
    chmod 400 vault-keys/age.key

    # ── Step 2: Compute BIP39 recovery phrase ───────────────────────────────
    # The vault container exposes: docker run --rm ... -mnemonic-from-key /dev/stdin
    # We feed it the raw age private key to get a 24-word BIP39 mnemonic.
    # TODO (Phase 1 follow-up): verify this sub-command exists in coderaft-vault
    # image — if it returns non-zero, we fall back to the raw key fingerprint
    # as a placeholder so the installer is never blocked.
    RECOVERY_PHRASE=""
    if [ "${CODERAFT_TEST_MODE:-0}" != "1" ]; then
        VAULT_PRIV_KEY=$(grep '^AGE-SECRET-KEY-' vault-keys/age.key 2>/dev/null || true)
        if [ -n "$VAULT_PRIV_KEY" ]; then
            RECOVERY_PHRASE=$(echo "$VAULT_PRIV_KEY" | \
                docker run --rm -i ghcr.io/liamj74/coderaft-vault:latest \
                    -mnemonic-from-key /dev/stdin 2>/dev/null || true)
        fi
    fi
    # Fallback: use age public-key fingerprint as placeholder
    if [ -z "$RECOVERY_PHRASE" ]; then
        VAULT_PUB=$(grep '# public key:' vault-keys/age.key 2>/dev/null | awk '{print $NF}' || true)
        RECOVERY_PHRASE="[FALLBACK — save vault-keys/age.key securely] fingerprint: ${VAULT_PUB}"
        echo ""
        echo "  ⚠ coderaft-vault -mnemonic-from-key not available yet (Phase 1 TODO)."
        echo "    Using fingerprint as placeholder. Secure vault-keys/age.key manually."
        echo ""
    fi

    # ── Step 3: Display recovery phrase with big warning ────────────────────
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║   *** VAULT RECOVERY PHRASE — WRITE THIS DOWN NOW ***           ║"
    echo "  ║                                                                  ║"
    echo "  ║   This 24-word phrase is the ONLY way to recover your vault     ║"
    echo "  ║   if vault-keys/age.key is lost or corrupted.                   ║"
    echo "  ║                                                                  ║"
    echo "  ║   Store it on an encrypted USB, in 1Password, or a physical     ║"
    echo "  ║   safe. DO NOT store it on this machine or in plaintext.        ║"
    echo "  ║                                                                  ║"
    echo "  ║   If BOTH vault-keys/age.key AND this phrase are lost,          ║"
    echo "  ║   ALL encrypted secrets are permanently unrecoverable.          ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  RECOVERY PHRASE:"
    echo ""
    echo "    ${RECOVERY_PHRASE}"
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║   Type CONFIRMED (all caps) once you have securely stored       ║"
    echo "  ║   the recovery phrase, then press Enter to continue.            ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    if [ "${CODERAFT_TEST_MODE:-0}" = "1" ]; then
        echo "  [CODERAFT_TEST_MODE] Auto-accepting CONFIRMED prompt"
        REPLY="CONFIRMED"
    else
        # stty trick: disable echo so the phrase isn't logged twice, then re-enable
        if command -v stty &>/dev/null; then
            stty -echo 2>/dev/null || true
            printf "  Type CONFIRMED to continue: "
            read -r REPLY
            stty echo 2>/dev/null || true
            echo ""
        else
            printf "  Type CONFIRMED to continue: "
            read -r REPLY
        fi
    fi

    if [ "$REPLY" != "CONFIRMED" ]; then
        echo ""
        echo "  Aborted. vault-keys/age.key has been kept in place."
        echo "  Re-run the installer when you are ready."
        exit 1
    fi
    echo "  ✓ Recovery phrase confirmed"

    # ── Step 4: Generate mTLS PKI (D3) ─────────────────────────────────────
    vault_bootstrap_tls
}

vault_bootstrap_tls() {
    # B12 fix: correct cert filenames: vault.crt / vault.key / client-ca.crt
    # B11 fix: correct ACL field names: name, cert_san, permissions (NOT san/role/allow)
    # B7  fix: server cert SAN includes localhost + 127.0.0.1 for mTLS hostname verification
    # Prefer host openssl if available; otherwise use an alpine container (no host dep).
    if command -v openssl &>/dev/null; then
        _vault_bootstrap_tls_host
    else
        _vault_bootstrap_tls_alpine
    fi
}

_vault_bootstrap_tls_host() {
    # Skip if already generated (re-run safety)
    if [ -f vault-tls/client-ca.crt ] && [ -f vault-tls/vault.crt ]; then
        echo "  ✓ Vault mTLS PKI already exists — skipping cert generation"
        return 0
    fi

    echo "  Generating vault mTLS PKI (host openssl)..."
    chmod 700 vault-tls

    # CA (client-ca.crt — not ca.crt, the vault config.yaml expects this exact name)
    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
        -keyout vault-tls/client-ca.key \
        -out vault-tls/client-ca.crt \
        -subj "/CN=coderaft-vault-ca" \
        -addext "basicConstraints=critical,CA:TRUE" \
        2>/dev/null
    chmod 600 vault-tls/client-ca.key vault-tls/client-ca.crt

    # Server cert — SAN must include coderaft-vault, localhost, 127.0.0.1
    # so the curlimages/curl sidecar can verify --cacert client-ca.crt against
    # https://coderaft-vault:8200 (hostname check fails without the DNS SAN).
    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout vault-tls/vault.key \
        -out vault-tls/vault.csr \
        -subj "/CN=coderaft-vault" \
        2>/dev/null
    openssl x509 -req -days 3650 -sha256 \
        -in vault-tls/vault.csr \
        -CA vault-tls/client-ca.crt -CAkey vault-tls/client-ca.key -CAcreateserial \
        -out vault-tls/vault.crt \
        -extfile <(printf "subjectAltName=DNS:coderaft-vault,DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE") \
        2>/dev/null
    rm -f vault-tls/vault.csr
    chmod 600 vault-tls/vault.crt vault-tls/vault.key

    # Per-product client certs
    _vault_client_cert "dashboard-api"  "dashboard-api.coderaft.local"
    _vault_client_cert "entraguard"     "entraguard.coderaft.local"
    _vault_client_cert "ravenscan"      "ravenscan.coderaft.local"
    _vault_client_cert "redfox"         "redfox.coderaft.local"

    _vault_write_config
}

_vault_bootstrap_tls_alpine() {
    # Fallback: run openssl inside an alpine one-shot container (no host dep).
    # Mirrors the approach in update.ps1 4c.2.
    if [ -f vault-tls/client-ca.crt ] && [ -f vault-tls/vault.crt ]; then
        echo "  ✓ Vault mTLS PKI already exists — skipping cert generation"
        return 0
    fi

    echo "  Generating vault mTLS PKI (alpine container — host openssl absent)..."
    chmod 700 vault-tls

    local openssl_script
    openssl_script=$(cat <<'SCRIPT'
set -e
apk add --no-cache openssl >/dev/null
cd /work
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
    -keyout client-ca.key -out client-ca.crt \
    -subj "/CN=coderaft-vault-ca" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
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
SCRIPT
)

    local abs_tls_dir
    abs_tls_dir="$(cd vault-tls && pwd)"
    echo "$openssl_script" | docker run --rm -i \
        -v "${abs_tls_dir}:/work" \
        alpine:3.20 sh 2>&1

    if [ ! -f vault-tls/vault.crt ]; then
        echo "  ✗ Alpine openssl cert generation failed" >&2
        exit 1
    fi

    _vault_write_config
}

_vault_write_config() {
    # vault config.yaml — references /tls/vault.crt (not server.crt) and /tls/client-ca.crt (not ca.crt)
    cat > vault-config/config.yaml << 'CFGEOF'
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
CFGEOF
    chmod 600 vault-config/config.yaml

    # B11 fix: correct ACL field names: name, cert_san, permissions
    cat > vault-config/acl.yaml << 'ACLEOF'
# coderaft-vault ACL — controls which client cert SAN can access which secrets.
# Field names: name, cert_san, permissions (NOT san/role/allow).
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
ACLEOF
    chmod 600 vault-config/acl.yaml

    echo "  ✓ Vault mTLS PKI generated"
    echo "    CA:      vault-tls/client-ca.crt"
    echo "    Server:  vault-tls/vault.{crt,key}"
    echo "    Clients: vault-tls/{dashboard-api,entraguard,ravenscan,redfox}-client.{crt,key}"
}

_vault_client_cert() {
    local name="$1" san="$2"
    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout "vault-tls/${name}-client.key" \
        -out    "vault-tls/${name}-client.csr" \
        -subj   "/CN=${san}" \
        2>/dev/null
    openssl x509 -req -days 3650 -sha256 \
        -in "vault-tls/${name}-client.csr" \
        -CA vault-tls/client-ca.crt -CAkey vault-tls/client-ca.key -CAcreateserial \
        -out "vault-tls/${name}-client.crt" \
        -extfile <(printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE" "$san") \
        2>/dev/null
    rm -f "vault-tls/${name}-client.csr"
    chmod 600 "vault-tls/${name}-client.crt" "vault-tls/${name}-client.key"
}

vault_bootstrap

# Append CODERAFT_VAULT_* env vars if not already present
_add_env_if_missing() {
    local key="$1" val="$2"
    if ! grep -q "^${key}=" .env 2>/dev/null; then
        printf '%s=%s\n' "$key" "$val" >> .env
    fi
}
_add_env_if_missing "CODERAFT_VAULT_URL"      "https://coderaft-vault:8200"
_add_env_if_missing "CODERAFT_VAULT_AZURE"    "0"
_add_env_if_missing "CODERAFT_VAULT_LICENSE"  "0"
_add_env_if_missing "CODERAFT_VAULT_PRODUCTS" "0"
_add_env_if_missing "CODERAFT_VAULT_JWT"      "0"

# Init DB
cat > init-db.sql << 'SQL'
-- Product databases are created by the dashboard on demand
SQL

# Docker compose — dashboard + vault
echo "  Writing docker-compose.yml..."
cat > docker-compose.yml << 'COMPOSE'
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
    # B-HEALTH (2026-06-09): le healthcheck pointait vers l'admin API Caddy
    # (port 2019) qu'on désactive volontairement (`admin off` dans Caddyfile,
    # sécurité). On check le listener HTTP réel (:80) avec 127.0.0.1 pour
    # éviter le piège IPv6-first (localhost résout ::1 d'abord, nginx/caddy
    # écoute IPv4 → connection refused). Cf bug récurrent B15 côté Node.
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:80/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    security_opt: [no-new-privileges:true]
    restart: unless-stopped

  dashboard:
    image: ghcr.io/liamj74/coderaft-dashboard:latest
    ports:
      # Plain HTTP kept on 3000 (loopback only) for fallback when caddy is off
      # and for the dashboard-api healthchecks/internal helpers.
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
      # B-VAULT-DEP (2026-06-09): coderaft-vault starts sealed and needs the
      # installer/update script to POST /v1/unseal before it can pass its
      # own healthcheck. With `service_healthy` here, compose would kill the
      # whole stack waiting for vault before the unseal step ever runs.
      # Use `service_started` so dashboard-api boots; it gracefully degrades
      # to "vault unavailable" until unseal completes, then reconnects.
      coderaft-vault: { condition: service_started }
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
      # Banking-grade: dashboard-api reads .env.enc (sops+age). Plaintext .env
      # is refused at runtime when CODERAFT_REJECT_PLAINTEXT_ENV=1.
      # NOTE: Phase 0.5 keeps SOPS path for backward compat; Phase 5 removes it.
      - CODERAFT_REJECT_PLAINTEXT_ENV=1
      - SOPS_AGE_KEY_FILE=/keys/age.key
      # Vault integration (Phase 0.5 — products read secrets from the vault)
      - CODERAFT_VAULT_URL=https://coderaft-vault:8200
      # B12 fix: correct vault TLS filenames (client-ca.crt, not ca.crt)
      - CODERAFT_VAULT_CA=/vault-tls/client-ca.crt
      - CODERAFT_VAULT_CLIENT_CERT=/vault-tls/dashboard-api-client.crt
      - CODERAFT_VAULT_CLIENT_KEY=/vault-tls/dashboard-api-client.key
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - dashboard_data:/data
      - .:/host-compose
      # Age private key for SOPS decryption (legacy — kept for backward compat).
      # The installer creates the host file at .coderaft-age.key on first run.
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
  # Phase 0.5: deployed from fresh install; existing installs migrate on update.
  coderaft-vault:
    image: ghcr.io/liamj74/coderaft-vault:latest
    # B8 fix: Run as root so the container can write to the Docker-managed
    # /data volume (SQLite + audit log) and read /tls/*.key files (mode 0600).
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
  # Internal network for vault ↔ product communication. No external port.
  coderaft-vault-net:
    internal: true

volumes:
  postgres_data:
  dashboard_data:
  caddy_data:
  caddy_config:
  vault_data:
COMPOSE

# ── Caddyfile (local HTTPS) ──────────────────────────────────────────────────
# If mkcert-generated certs exist in ./caddy_certs, Caddy will serve HTTPS
# on https://coderaft.local (trusted, no browser warning). Otherwise it
# silently no-ops and the user keeps using http://localhost:3000.
if [ ! -f Caddyfile ]; then
    cat > Caddyfile << 'CADDY'
{
    # Disable Caddy's automatic public ACME issuance — we use mkcert for local trust.
    auto_https off
    admin off
}

# Local HTTPS via mkcert. Add to /etc/hosts:
#   127.0.0.1 coderaft.local entraguard.coderaft.local ravenscan.coderaft.local redfox.coderaft.local
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

# HTTP → HTTPS redirect for the same hosts
http://coderaft.local, http://*.coderaft.local {
    redir https://{host}{uri} permanent
}

# Fallback: anything else (IP access, localhost) stays on plain HTTP and
# proxies to the dashboard. This keeps `http://localhost:3000` working
# transparently and avoids breaking existing flows.
:80 {
    reverse_proxy dashboard:3000
}
CADDY
    echo "  ✓ Caddyfile generated"
fi

# ── mkcert local HTTPS setup ────────────────────────────────────────────────
# We generate a locally-trusted cert for coderaft.local + wildcard. mkcert
# installs a root CA into the OS / browser trust stores (one-time per machine).
# Failure is non-fatal: the platform stays usable on http://localhost:3000.
setup_local_https() {
    if [ "${CODERAFT_SKIP_HTTPS:-0}" = "1" ]; then
        echo "  CODERAFT_SKIP_HTTPS=1 — skipping local HTTPS setup"
        return 0
    fi

    mkdir -p caddy_certs

    # Reuse certs if already present and < 80 days old (mkcert default 825d, we
    # rotate generously well before expiry).
    if [ -f caddy_certs/coderaft.local.pem ] && [ -f caddy_certs/coderaft.local-key.pem ]; then
        if find caddy_certs/coderaft.local.pem -mtime -80 2>/dev/null | grep -q .; then
            echo "  ✓ Local HTTPS certs already present (caddy_certs/)"
            return 0
        fi
        echo "  Local HTTPS certs older than 80 days — regenerating"
    fi

    if ! command -v mkcert &>/dev/null; then
        echo "  mkcert not found."
        case "${CODERAFT_OS}" in
            macos)
                if command -v brew &>/dev/null; then
                    echo "  Installing mkcert via Homebrew (brew install mkcert nss)…"
                    brew install mkcert nss >/dev/null 2>&1 || {
                        echo "  ⚠ brew install mkcert failed — fallback to http://localhost:3000"
                        return 1
                    }
                else
                    echo "  ⚠ Homebrew not installed — install mkcert manually:"
                    echo "      https://github.com/FiloSottile/mkcert#installation"
                    echo "    Continuing in HTTP-only mode (http://localhost:3000)."
                    return 1
                fi
                ;;
            linux)
                if command -v apt-get &>/dev/null; then
                    echo "  Installing mkcert via apt…"
                    sudo apt-get update -qq >/dev/null 2>&1 || true
                    sudo apt-get install -y libnss3-tools mkcert >/dev/null 2>&1 || {
                        echo "  ⚠ apt install mkcert failed — fallback to http://localhost:3000"
                        return 1
                    }
                else
                    echo "  ⚠ Auto-install mkcert only supported via apt — install manually:"
                    echo "      https://github.com/FiloSottile/mkcert#installation"
                    echo "    Continuing in HTTP-only mode (http://localhost:3000)."
                    return 1
                fi
                ;;
            *)
                echo "  ⚠ Unsupported OS for mkcert auto-install — HTTP-only mode."
                return 1
                ;;
        esac
    fi

    echo "  Installing mkcert local CA (one-time, may prompt for sudo)…"
    mkcert -install >/dev/null 2>&1 || {
        echo "  ⚠ mkcert -install failed — local HTTPS will not be trusted."
    }

    echo "  Generating local cert for coderaft.local…"
    mkcert \
        -cert-file caddy_certs/coderaft.local.pem \
        -key-file  caddy_certs/coderaft.local-key.pem \
        coderaft.local "*.coderaft.local" localhost 127.0.0.1 ::1 >/dev/null 2>&1 || {
        echo "  ⚠ mkcert cert generation failed — fallback to http://localhost:3000"
        rm -f caddy_certs/coderaft.local.pem caddy_certs/coderaft.local-key.pem
        return 1
    }
    chmod 600 caddy_certs/coderaft.local-key.pem
    echo "  ✓ Local HTTPS cert generated (valid 825d)"
}

# ── /etc/hosts entries ──────────────────────────────────────────────────────
# Best-effort: add coderaft.local and product subdomains. Skipped if already
# present or if sudo is unavailable.
ensure_hosts_entry() {
    local hosts_file="/etc/hosts"
    local marker="# coderaft-platform"
    local entry="127.0.0.1 coderaft.local entraguard.coderaft.local ravenscan.coderaft.local redfox.coderaft.local ${marker}"

    if grep -q "coderaft.local" "$hosts_file" 2>/dev/null; then
        echo "  ✓ /etc/hosts already contains coderaft.local"
        return 0
    fi

    if [ "${CODERAFT_SKIP_HOSTS:-0}" = "1" ]; then
        echo "  CODERAFT_SKIP_HOSTS=1 — skipping /etc/hosts update"
        return 0
    fi

    echo "  Adding coderaft.local entries to /etc/hosts (sudo required)…"
    if echo "$entry" | sudo tee -a "$hosts_file" >/dev/null 2>&1; then
        echo "  ✓ /etc/hosts updated"
    else
        echo "  ⚠ Could not update /etc/hosts — add manually:"
        echo "      $entry"
    fi
}

setup_local_https || true
if [ -f caddy_certs/coderaft.local.pem ]; then
    ensure_hosts_entry || true
fi

# Helper scripts
cat > start.sh << 'EOF'
#!/bin/bash
echo "Starting CodeRaft..."
docker compose up -d
if [ -f caddy_certs/coderaft.local.pem ] && grep -q "coderaft.local" /etc/hosts 2>/dev/null; then
    echo "  Dashboard: https://coderaft.local"
else
    echo "  Dashboard: http://localhost:3000"
fi
EOF

cat > stop.sh << 'EOF'
#!/bin/bash
echo "Stopping CodeRaft..."
docker compose down
echo "  Done."
EOF

curl -fsSL "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/update.sh" -o update.sh 2>/dev/null || cat > update.sh << 'EOF'
#!/bin/bash
echo "Updating CodeRaft..."
docker compose pull && docker compose up -d --force-recreate --remove-orphans
echo "  Updated! Dashboard: http://localhost:3000"
EOF

curl -fsSL "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/rollback.sh" -o rollback.sh 2>/dev/null || cat > rollback.sh << 'EOF'
#!/bin/bash
echo "rollback.sh placeholder — fetch the real one from https://install.coderaft.io/rollback"
echo "or run: curl -fsSL https://install.coderaft.io/rollback -o rollback.sh && chmod +x rollback.sh"
exit 1
EOF

chmod +x start.sh stop.sh update.sh rollback.sh

# ── Pull & Start ─────────────────────────────────────────────────────────────

echo ""
echo "  Verifying image signatures..."
verify_coderaft_image() {
    local image="$1"
    if [ "${SKIP_COSIGN_VERIFY:-}" = "1" ]; then
        return 0
    fi
    if ! command -v cosign &> /dev/null; then
        if [ "${STRICT_COSIGN_VERIFY:-}" = "1" ]; then
            echo "  ✗ cosign required (STRICT_COSIGN_VERIFY=1). Install: https://docs.sigstore.dev/cosign/installation"
            exit 1
        fi
        echo "  ⚠ cosign not installed — skipping signature verification"
        return 0
    fi
    if cosign verify \
        --certificate-identity-regexp="^https://github.com/LiamJ74/" \
        --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
        "${image}" > /dev/null 2>&1; then
        echo "  ✓ Signature valid: ${image}"
    else
        if [ "${STRICT_COSIGN_VERIFY:-}" = "1" ]; then
            echo "  ✗ Signature verification FAILED for ${image} (STRICT_COSIGN_VERIFY=1)"
            exit 1
        fi
        echo "  ⚠ Signature missing or invalid: ${image} (continuing — set STRICT_COSIGN_VERIFY=1 to enforce)"
    fi
}
for img in \
    "ghcr.io/liamj74/coderaft-dashboard:latest" \
    "ghcr.io/liamj74/coderaft-dashboard-api:latest" \
    "ghcr.io/liamj74/coderaft-vault:latest"; do
    verify_coderaft_image "${img}"
done

# ── Vault unseal helper (fresh install) ──────────────────────────────────────
# B6/B7 fix: vault image is distroless — no shell, no wget. NEVER use
# `docker compose exec coderaft-vault sh -c`. Use a curlimages/curl sidecar
# on the coderaft-vault-net network with the dashboard-api client cert.
# B10 fix: vault starts sealed — must POST /v1/unseal after container is up.
vault_unseal_fresh() {
    local vault_age_key="vault-keys/age.key"
    if [ ! -f "$vault_age_key" ]; then
        echo "  ✗ vault-keys/age.key not found — cannot unseal" >&2
        return 1
    fi

    # Detect compose project name (determines Docker network name)
    local vault_project
    vault_project=$(docker inspect coderaft-coderaft-vault-1 \
        --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
    [ -z "$vault_project" ] && vault_project="coderaft"
    local vault_network="${vault_project}_coderaft-vault-net"

    local abs_tls_dir
    abs_tls_dir="$(cd vault-tls && pwd)"

    _vault_curl_fresh() {
        local method="$1" path="$2" body="${3:-}"
        local curl_args=(
            "run" "--rm"
            "--user" "0:0"
            "--network" "$vault_network"
            "-v" "${abs_tls_dir}:/tls:ro"
            "curlimages/curl:latest"
            "--cert" "/tls/dashboard-api-client.crt"
            "--key"  "/tls/dashboard-api-client.key"
            "--cacert" "/tls/client-ca.crt"
            "-sS" "-X" "$method"
            "https://coderaft-vault:8200${path}"
        )
        if [ -n "$body" ]; then
            curl_args+=("-H" "Content-Type: application/json" "-d" "$body")
        fi
        docker "${curl_args[@]}" 2>&1
    }

    echo "  Waiting for vault to be reachable..."
    local vault_reachable=0
    local last_sealed=""
    local i
    for i in $(seq 1 20); do
        local health
        health=$(_vault_curl_fresh "GET" "/v1/health" 2>/dev/null || true)
        if echo "$health" | grep -q '"sealed":'; then
            vault_reachable=1
            if echo "$health" | grep -q '"sealed":true'; then
                last_sealed="true"
            else
                last_sealed="false"
            fi
            break
        fi
        [ $((i % 3)) -eq 0 ] && echo "    ... still waiting (attempt $i/20)"
        sleep 3
    done

    if [ "$vault_reachable" = "0" ]; then
        echo "  ✗ coderaft-vault did not respond to TLS probes" >&2
        return 1
    fi

    # B10 fix: unseal if sealed (1 share = base64-encoded age key file bytes)
    if [ "$last_sealed" = "true" ]; then
        echo "  Vault is sealed — sending unseal request..."
        local share_b64
        share_b64=$(base64 < "$vault_age_key" | tr -d '\n')
        local unseal_body="{\"shares\":[\"${share_b64}\"]}"
        local unseal_resp
        unseal_resp=$(_vault_curl_fresh "POST" "/v1/unseal" "$unseal_body" 2>/dev/null || true)
        if ! echo "$unseal_resp" | grep -qE '"ok"\s*:\s*true|"sealed"\s*:\s*false'; then
            echo "  Unseal response: $unseal_resp" >&2
            echo "  ✗ Vault unseal failed" >&2
            return 1
        fi
        echo "  ✓ Vault unsealed"
    fi

    # Final health check — must say sealed:false
    local final_health
    final_health=$(_vault_curl_fresh "GET" "/v1/health" 2>/dev/null || true)
    if ! echo "$final_health" | grep -q '"sealed":false'; then
        echo "  Final health: $final_health" >&2
        echo "  ✗ Vault still sealed after unseal call" >&2
        return 1
    fi
    echo "  ✓ coderaft-vault is healthy (sealed:false)"
}

if [ "${CODERAFT_TEST_MODE:-0}" = "1" ]; then
    echo ""
    echo "  [CODERAFT_TEST_MODE] Skipping docker compose pull and up"
    echo "  Compose YAML and vault PKI validated — test run complete."
else
    echo ""
    echo "  Pulling platform images..."
    if ! docker compose pull; then
        echo ""
        echo "  ✗ Image pull failed. Aborting install."
        echo "    Check Docker daemon, network connectivity, or GHCR auth."
        exit 1
    fi

    echo ""
    echo "  Starting platform..."
    # B9 fix: explicit stop+rm for vault container before up so fresh certs
    # are picked up from bind mounts (--force-recreate alone can leave a
    # Running container with stale certs in Docker Desktop memory).
    docker compose stop coderaft-vault 2>/dev/null || true
    docker compose rm -f coderaft-vault 2>/dev/null || true
    if ! docker compose up -d; then
        echo ""
        echo "  ✗ docker compose up failed. Aborting install."
        echo "    Run 'docker compose logs' to investigate."
        exit 1
    fi

    echo ""
    echo "  Unsealing vault..."
    vault_unseal_fresh || {
        echo "  ⚠ Vault unseal failed — dashboard may show 'vault unavailable'."
        echo "    Re-run the installer or run: docker compose restart coderaft-vault"
    }

    echo ""
    echo "  Waiting for dashboard to be ready..."
    sleep 10
fi


# ── Native capture daemon — REMOVED FROM ONELINER (B-CAPTURE-DEFER) ─────────
# 2026-06-09: per Liam, the capture daemon must NOT be installed at the
# oneliner stage — only inside the Setup Wizard, AFTER license activation,
# and only if Ravenscan is in the licensed products (bundle_products
# contains "secaudit"). Installing it upfront prompts sudo for a product
# the user may not even own a license for, violating the unified
# architecture "oneliner = platform + deps only".
#
# The capture daemon install now lives in dashboard-api as a dedicated
# endpoint, called from the Setup Wizard / Settings page when Ravenscan
# is activated. See task #31.
#
# Skip flag retained for documentation; no-op now.
if [ "${SKIP_NATIVE_CAPTURE:-0}" = "1" ]; then
    echo "  ⓘ Capture daemon install skipped (SKIP_NATIVE_CAPTURE=1)"
fi

DASHBOARD_URL="http://localhost:3000"
if [ -f caddy_certs/coderaft.local.pem ] && grep -q "coderaft.local" /etc/hosts 2>/dev/null; then
    DASHBOARD_URL="https://coderaft.local"
fi

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║            Installation complete!                    ║"
echo "  ║                                                      ║"
printf  "  ║   Dashboard: %-39s ║\n" "$DASHBOARD_URL"
echo "  ║                                                      ║"
echo "  ║   Open the dashboard to activate your license        ║"
echo "  ║   and deploy your products.                          ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Commands:  ./start.sh  ./stop.sh  ./update.sh  ./rollback.sh"
echo ""

command -v open &>/dev/null && open "$DASHBOARD_URL" 2>/dev/null || true
command -v xdg-open &>/dev/null && xdg-open "$DASHBOARD_URL" 2>/dev/null || true
