#!/bin/bash
# =============================================================================
# CodeRaft Platform — One-line installer
# Usage: curl -fsSL https://install.coderaft.io | bash
#
# Installs the CodeRaft Dashboard. The dashboard handles everything else:
#   • License activation
#   • Product deployment (EntraGuard, Ravenscan, RedFox)
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

# Force DOCKER_DEFAULT_PLATFORM to work around the Docker Desktop bug that
# resolves strict linux/arm64/v8 or linux/amd64/v3 and fails the pull on
# manifests that only expose linux/arm64 or linux/amd64.
if [ -z "$DOCKER_DEFAULT_PLATFORM" ] && [ "$CODERAFT_ARCH" != "unknown" ]; then
    export DOCKER_DEFAULT_PLATFORM="linux/${CODERAFT_ARCH}"
fi

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
echo ""

# ── Install ──────────────────────────────────────────────────────────────────

echo "  Installing to: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# ── age key setup (SOPS Phase 2 secrets management) ─────────────────────────
AGE_KEY_DIR="/etc/coderaft"
AGE_KEY_PATH="${AGE_KEY_DIR}/age.key"

setup_age_key() {
    if [ -f "${AGE_KEY_PATH}" ]; then
        echo "  ✓ age key already exists at ${AGE_KEY_PATH}"
        return 0
    fi

    # Install age-keygen if not present
    if ! command -v age-keygen &>/dev/null; then
        echo "  Downloading age-keygen..."
        AGE_VERSION="v1.2.1"
        AGE_OS="${CODERAFT_OS/macos/darwin}"
        AGE_TMP="$(mktemp -d)"
        trap 'rm -rf "$AGE_TMP"' EXIT
        curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-${AGE_OS}-${CODERAFT_ARCH}.tar.gz" \
            -o "${AGE_TMP}/age.tar.gz" 2>/dev/null || {
            echo "  ⚠ Could not download age-keygen. SOPS encryption will be set up by the dashboard."
            return 1
        }
        tar -xzf "${AGE_TMP}/age.tar.gz" -C "${AGE_TMP}" 2>/dev/null
        sudo install -m 755 "${AGE_TMP}/age/age-keygen" /usr/local/bin/age-keygen 2>/dev/null || {
            echo "  ⚠ Could not install age-keygen (no sudo?). SOPS encryption skipped."
            return 1
        }
        echo "  ✓ age-keygen installed"
    fi

    echo "  Generating age key at ${AGE_KEY_PATH} (sudo required)..."
    sudo mkdir -p "${AGE_KEY_DIR}"
    sudo age-keygen -o "${AGE_KEY_PATH}" 2>/dev/null
    sudo chmod 400 "${AGE_KEY_PATH}"
    sudo chown root:root "${AGE_KEY_PATH}" 2>/dev/null || true
    echo "  ✓ age key generated"
    echo ""
    echo "  IMPORTANT: Back up ${AGE_KEY_PATH} to an encrypted USB or secure vault."
    echo "  If this key is lost, all encrypted .env.enc secrets are unrecoverable."
    echo ""
}

# Only attempt age setup on Linux (where /etc/coderaft is writable with sudo).
# On macOS the dashboard-api handles it at first boot.
if [ "${CODERAFT_OS}" = "linux" ]; then
    setup_age_key || true
fi

# Generate secrets on first install
gen_hex() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

ABSOLUTE_INSTALL_DIR="$(pwd)"

if [ -f ".env" ] && grep -q '^POSTGRES_PASSWORD=' .env 2>/dev/null; then
    # Update HOST_PROJECT_DIR in case install location changed
    grep -q '^HOST_PROJECT_DIR=' .env 2>/dev/null || echo "HOST_PROJECT_DIR=${ABSOLUTE_INSTALL_DIR}" >> .env
    # Backward compat: legacy install without .env.enc — show warning in dashboard
    if [ ! -f "${AGE_KEY_PATH}" ]; then
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

# Read the capture token back so we can pass it to the native daemon
# install step (only relevant on macOS).
RAVENSCAN_CAPTURE_TOKEN_VALUE="$(grep '^RAVENSCAN_CAPTURE_TOKEN=' .env | cut -d= -f2)"

# Init DB
cat > init-db.sql << 'SQL'
-- Product databases are created by the dashboard on demand
SQL

# Docker compose — dashboard only
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
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:2019/config/", "||", "exit", "0"]
      interval: 30s
      timeout: 5s
      retries: 3
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
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    environment:
      - LICENSE_SERVER_URL=https://license.coderaft.io
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - DASHBOARD_SECRET=${DASHBOARD_SECRET}
      - CONTAINER_COMPOSE_DIR=/host-compose
      - HOST_PROJECT_DIR=${HOST_PROJECT_DIR}
      - COMPOSE_PROJECT_NAME=coderaft
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - dashboard_data:/data
      - .:/host-compose
    security_opt: [no-new-privileges:true]
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

volumes:
  postgres_data:
  dashboard_data:
  caddy_data:
  caddy_config:
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
    "ghcr.io/liamj74/coderaft-dashboard-api:latest"; do
    verify_coderaft_image "${img}"
done

echo ""
echo "  Pulling dashboard image..."
docker compose pull

echo ""
echo "  Starting dashboard..."
docker compose up -d

echo ""
echo "  Waiting for dashboard to be ready..."
sleep 10


# ── Native capture daemon install (macOS only — Linux uses Docker, Windows handled by install.ps1) ──
if [ "${CODERAFT_NEEDS_NATIVE_CAPTURE}" = "1" ] && [ "${SKIP_NATIVE_CAPTURE:-0}" != "1" ]; then
    echo ""
    echo "  ── Live capture daemon (native) ─────────────────────"
    echo "  Detected ${CODERAFT_OS} — installing the native capture daemon"
    echo "  so Ravenscan can see your real Wi-Fi/Ethernet interfaces."
    echo "  (Set SKIP_NATIVE_CAPTURE=1 to skip — capture will be limited"
    echo "   to the Docker bridge until the daemon is installed manually.)"
    echo ""

    # Source: public ravenscan-installer repo (mirrors the same pattern
    # used for the other Coderaft installers — source repos are private,
    # release artifacts live in the matching public installer repo).
    # Bumping the tag here is a deliberate release decision.
    CAPTURE_BASE_URL="${CAPTURE_BASE_URL:-https://github.com/LiamJ74/ravenscan-installer/releases/download/capture-v0.1.0}"
    # Release uses Go convention (darwin/linux/windows) — map macos → darwin
    CAPTURE_OS_NAME="${CODERAFT_OS/macos/darwin}"
    CAPTURE_BIN_NAME="ravenscan-capture-host-${CAPTURE_OS_NAME}-${CODERAFT_ARCH}"

    CAPTURE_TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$CAPTURE_TMP_DIR"' EXIT

    echo "  Downloading ${CAPTURE_BIN_NAME} from ${CAPTURE_BASE_URL}…"
    if curl -fsSL -o "${CAPTURE_TMP_DIR}/${CAPTURE_BIN_NAME}" \
            "${CAPTURE_BASE_URL}/${CAPTURE_BIN_NAME}" \
       && curl -fsSL -o "${CAPTURE_TMP_DIR}/install-macos.sh" \
            "${CAPTURE_BASE_URL}/install-macos.sh" \
       && curl -fsSL -o "${CAPTURE_TMP_DIR}/io.coderaft.ravenscan-capture.plist" \
            "${CAPTURE_BASE_URL}/io.coderaft.ravenscan-capture.plist"; then

        # Optional checksum verification when SHA256SUMS is published.
        if curl -fsSL -o "${CAPTURE_TMP_DIR}/SHA256SUMS" \
                "${CAPTURE_BASE_URL}/SHA256SUMS" 2>/dev/null; then
            ( cd "${CAPTURE_TMP_DIR}" && \
              shasum -a 256 -c --ignore-missing SHA256SUMS >/dev/null 2>&1 ) \
              || { echo "  ✗ Capture daemon checksum mismatch — aborting"; exit 1; }
            echo "  ✓ Checksum verified"
        fi

        chmod +x "${CAPTURE_TMP_DIR}/install-macos.sh" "${CAPTURE_TMP_DIR}/${CAPTURE_BIN_NAME}"
        echo "  Installing daemon (sudo required for raw socket access)…"
        if sudo -n true 2>/dev/null; then
            sudo RAVENSCAN_CAPTURE_TOKEN="${RAVENSCAN_CAPTURE_TOKEN_VALUE}" \
                bash -c "cd '${CAPTURE_TMP_DIR}' && ./install-macos.sh"
        else
            echo "  (you will be prompted for your password)"
            sudo RAVENSCAN_CAPTURE_TOKEN="${RAVENSCAN_CAPTURE_TOKEN_VALUE}" \
                bash -c "cd '${CAPTURE_TMP_DIR}' && ./install-macos.sh"
        fi

        # Tell the platform to talk to the host daemon instead of the
        # Docker sidecar (which would only see the bridge network on Mac).
        if ! grep -q '^RAVENSCAN_CAPTURE_SIDECAR_URL=' .env 2>/dev/null; then
            echo "RAVENSCAN_CAPTURE_SIDECAR_URL=http://host.docker.internal:7777" >> .env
        fi
        echo "  ✓ Native capture daemon installed and running on 127.0.0.1:7777"
    else
        echo "  ⚠ Could not download the native capture daemon."
        echo "    Live capture will work on the Docker bridge only until you"
        echo "    install the daemon manually from the Settings page."
    fi
    echo ""
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
