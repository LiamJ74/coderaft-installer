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

# Generate secrets on first install
gen_hex() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

if [ -f ".env" ] && grep -q '^POSTGRES_PASSWORD=' .env 2>/dev/null; then
    echo "  ✓ Existing config preserved"
else
    echo "  Generating secrets..."
    cat > .env << ENVFILE
# CodeRaft Dashboard — $(date -u +"%Y-%m-%d")
POSTGRES_PASSWORD=$(gen_hex 24)
REDIS_PASSWORD=$(gen_hex 24)
DASHBOARD_SECRET=$(gen_hex 32)
ENVFILE
    chmod 600 .env
    echo "  ✓ Secrets generated"
fi

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
  dashboard:
    image: ghcr.io/liamj74/coderaft-dashboard:latest
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
    environment:
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - DASHBOARD_SECRET=${DASHBOARD_SECRET}
      - LICENSE_SERVER_URL=https://license.coderaft.io
      - DOCKER_HOST=unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - dashboard_data:/data
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
      - ./init-db.sql:/docker-entrypoint-initdb.d/10-init.sql:ro
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
    command: redis-server --requirepass ${REDIS_PASSWORD} --maxmemory 128mb --appendonly yes
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [SETGID, SETUID]
    restart: unless-stopped

volumes:
  postgres_data:
  dashboard_data:
COMPOSE

# Helper scripts
for script in start stop update; do
    case $script in
        start) CMD='docker compose up -d'; MSG="Dashboard: http://localhost:3000" ;;
        stop)  CMD='docker compose down'; MSG="Done." ;;
        update) CMD='docker compose pull && docker compose up -d --remove-orphans'; MSG="Updated!" ;;
    esac
    cat > "${script}.sh" << SCRIPT
#!/bin/bash
echo "${script^}ing CodeRaft..."
${CMD}
echo "  ${MSG}"
SCRIPT
    chmod +x "${script}.sh"
done

# ── Pull & Start ─────────────────────────────────────────────────────────────

echo ""
echo "  Pulling dashboard image..."
docker compose pull

echo ""
echo "  Starting dashboard..."
docker compose up -d

echo ""
echo "  Waiting for dashboard to be ready..."
sleep 10

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║            Installation complete!                    ║"
echo "  ║                                                      ║"
echo "  ║   Dashboard: http://localhost:3000                   ║"
echo "  ║                                                      ║"
echo "  ║   Open the dashboard to activate your license        ║"
echo "  ║   and deploy your products.                          ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Commands:  ./start.sh  ./stop.sh  ./update.sh"
echo ""

command -v open &>/dev/null && open http://localhost:3000
command -v xdg-open &>/dev/null && xdg-open http://localhost:3000
