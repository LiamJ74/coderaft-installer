#!/bin/bash
#
# CodeRaft updater
#
# Self-updates from the installer repo, then compares image digests before
# pulling new ones. If something breaks, runs rollback.sh.
#
set -e

# B-SH-GUARD (2026-06-23): the openssl steps below use bash process
# substitution `<(printf ...)`. Invoking this script via `sh update.sh`
# on macOS (where /bin/sh is bash in POSIX mode) crashes with
# "syntax error near unexpected token `('". Refuse explicitly so the
# operator gets an actionable message instead of an opaque syntax error.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: update.sh requires bash (uses process substitution)." >&2
    echo "Run with: bash update.sh   (NOT sh update.sh)" >&2
    exit 1
fi

DASHBOARD_API="${DASHBOARD_API:-http://localhost:3000}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"
BACKUP_DIR="${BACKUP_DIR:-./dashboard_data/backups}"
HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-30}"
HEALTHCHECK_DELAY="${HEALTHCHECK_DELAY:-3}"
INSTALL_DIR="${INSTALL_DIR:-$PWD}"

# ── Argument parsing ───────────────────────────────────────────────────────
# --product <slug>  Update ONE product only (granular update). Delegates to
#                   the dashboard-api per-product endpoint, which snapshots
#                   the product, pulls only its images, deploys any newly
#                   declared service and auto-rolls-back on failure.
#                   Clicking "Mettre à jour ce produit" in the dashboard is
#                   the exact equivalent of `update.sh --product <slug>`.
# Without --product: legacy behavior — full platform update (all licensed
# products), unchanged.
PRODUCT_SLUG="${CODERAFT_PRODUCT:-}"
ORIG_ARGS=("$@")   # preserved for the self-update re-exec below
while [ $# -gt 0 ]; do
    case "$1" in
        --product)
            PRODUCT_SLUG="${2:-}"
            if [ -z "$PRODUCT_SLUG" ]; then
                echo "ERROR: --product requires a slug (entra-audit | secaudit | redfox | mantisstrike | falconone)" >&2
                exit 1
            fi
            shift 2
            ;;
        --product=*)
            PRODUCT_SLUG="${1#--product=}"
            shift
            ;;
        -h|--help)
            echo "Usage: bash update.sh [--product <slug>]"
            echo ""
            echo "  (no flag)          Update the whole platform (all licensed products)."
            echo "  --product <slug>   Update ONE product only via the dashboard-api"
            echo "                     granular endpoint (per-product snapshot + auto-rollback)."
            echo "                     Slugs: entra-audit, secaudit, redfox, mantisstrike, falconone"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done
case "$PRODUCT_SLUG" in
    ""|entra-audit|secaudit|redfox|mantisstrike|falconone) ;;
    *)
        echo "ERROR: unknown product slug '$PRODUCT_SLUG'" >&2
        echo "Valid slugs: entra-audit, secaudit, redfox, mantisstrike, falconone" >&2
        exit 1
        ;;
esac

# ── ADMIN_TOKEN auto-discovery ────────────────────────────────────────────
# Priority order:
#   1. $ADMIN_TOKEN env var (already set above)
#   2. .env files (INSTALL_DIR, /etc/coderaft, ~/.coderaft)
#   3. Plain token files (single word)
#   4. Mounted Docker secret
# If nothing is found → continue; snapshot/notify are skipped with a warning.
# IMPORTANT: NEVER echo the discovered token.
discover_admin_token() {
    if [ -n "${ADMIN_TOKEN:-}" ]; then
        printf '%s' "$ADMIN_TOKEN"
        return 0
    fi
    local env_file val
    for env_file in "$INSTALL_DIR/.env" "/etc/coderaft/.env" "$HOME/.coderaft/.env"; do
        if [ -f "$env_file" ] && [ -r "$env_file" ]; then
            val=$(grep -E '^[[:space:]]*ADMIN_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]')
            if [ -n "$val" ]; then
                printf '%s' "$val"
                return 0
            fi
        fi
    done
    local token_file
    for token_file in "/etc/coderaft/admin_token" "$HOME/.coderaft/admin_token" "/run/secrets/admin_token"; do
        if [ -f "$token_file" ] && [ -r "$token_file" ]; then
            val=$(tr -d '[:space:]' < "$token_file" 2>/dev/null)
            if [ -n "$val" ]; then
                printf '%s' "$val"
                return 0
            fi
        fi
    done
    # 5. Auto-discovery from running dashboard-api container (preferred,
    #    avoids any manual setup — dashboard-api auto-generates the token
    #    at boot and persists it to /data/admin_token).
    if (cd "$INSTALL_DIR" 2>/dev/null && docker compose ps --services 2>/dev/null | grep -q '^dashboard-api$'); then
        val=$(cd "$INSTALL_DIR" && docker compose exec -T dashboard-api cat /data/admin_token 2>/dev/null < /dev/null | tr -d '[:space:]')
        if [ -n "$val" ]; then
            printf '%s' "$val"
            return 0
        fi
    fi
    return 1
}

if [ -z "$ADMIN_TOKEN" ]; then
    if discovered=$(discover_admin_token); then
        ADMIN_TOKEN="$discovered"
    fi
    unset discovered
fi

# ── Granular per-product update (--product <slug>) ─────────────────────────
# Delegates the whole operation to dashboard-api:
#   POST /api/dashboard/products/<slug>/update
# then polls /update-status until the operation reaches a terminal state.
# The endpoint captures a per-product snapshot first, pulls ONLY that
# product's images, creates newly declared services, health-checks, and
# auto-rolls-back on failure. Shared infra (postgres/redis/vault) untouched.
if [ -n "$PRODUCT_SLUG" ]; then
    echo ""
    echo "  Granular update: product '$PRODUCT_SLUG' only"

    if [ -z "$ADMIN_TOKEN" ]; then
        echo "  ERROR: ADMIN_TOKEN not found — the per-product update needs the dashboard API." >&2
        echo "  Set ADMIN_TOKEN, or ensure the dashboard-api container is running" >&2
        echo "  (token auto-discovery reads /data/admin_token inside it)." >&2
        exit 1
    fi

    RESP=$(curl -fsS -X POST "$DASHBOARD_API/api/dashboard/products/$PRODUCT_SLUG/update" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -d '{"backup_data":true}' 2>&1) || {
        echo "  ERROR: failed to start the update:" >&2
        echo "    $RESP" >&2
        echo "  (409 = another operation is already running; 403 = product not licensed)" >&2
        exit 1
    }
    echo "  Update started. Waiting for completion (snapshot → backup → pull → recreate → health)…"

    # Poll the operation status (terminal: healthy | rolled_back | rollback_failed | failed)
    STATUS="in_progress"
    LAST_PHASE=""
    for _i in $(seq 1 200); do   # 200 × 3s = 10 min max
        sleep 3
        BODY=$(curl -fsS "$DASHBOARD_API/api/dashboard/products/$PRODUCT_SLUG/update-status" \
            -H "Authorization: Bearer $ADMIN_TOKEN" 2>/dev/null) || continue
        STATUS=$(printf '%s' "$BODY" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
        PHASE=$(printf '%s' "$BODY" | grep -o '"phase":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ "$PHASE" != "$LAST_PHASE" ] && [ -n "$PHASE" ]; then
            echo "    phase: $PHASE"
            LAST_PHASE="$PHASE"
        fi
        [ "$STATUS" != "in_progress" ] && break
    done

    case "$STATUS" in
        healthy)
            echo ""
            echo "  ✓ $PRODUCT_SLUG updated successfully — all services healthy."
            exit 0
            ;;
        rolled_back)
            echo ""
            echo "  ✗ Update failed — automatic rollback restored the previous version." >&2
            echo "    Details: docker compose logs, or the dashboard → Settings → Platform." >&2
            exit 1
            ;;
        rollback_failed)
            echo ""
            echo "  ✗✗ Update AND rollback failed — manual intervention required." >&2
            echo "     Snapshots: GET $DASHBOARD_API/api/dashboard/products/$PRODUCT_SLUG/snapshots" >&2
            exit 2
            ;;
        failed)
            echo ""
            echo "  ✗ Update failed before any service was modified (e.g. backup failure)." >&2
            exit 1
            ;;
        *)
            echo ""
            echo "  ? Update still running after 10 min — check the dashboard for live status." >&2
            exit 1
            ;;
    esac
fi

# ── Docker platform detection ──────────────────────────────────────────────
# Docker Desktop on Mac M-series resolves strictly to linux/arm64/v8 by
# default, which fails on manifests that only expose linux/arm64. Same goes
# for various Docker Engine versions. Force DOCKER_DEFAULT_PLATFORM based
# on the host arch to work around this bug.
if [ -z "$DOCKER_DEFAULT_PLATFORM" ]; then
    HOST_ARCH=$(uname -m 2>/dev/null || echo "")
    case "$HOST_ARCH" in
        arm64|aarch64) export DOCKER_DEFAULT_PLATFORM="linux/arm64" ;;
        x86_64|amd64)  export DOCKER_DEFAULT_PLATFORM="linux/amd64" ;;
    esac
fi

# ── Self-update both update.sh and rollback.sh (with re-exec) ──────────────
if [ -z "$CODERAFT_UPDATE_REEXEC" ]; then
    echo "  Checking for script updates..."
    REFRESHED=0
    for name in update.sh rollback.sh; do
        LATEST=$(curl -fsSL "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/$name" 2>/dev/null)
        if [ -n "$LATEST" ] && [ ${#LATEST} -gt 50 ]; then
            echo "$LATEST" > "$name.tmp"
            if ! cmp -s "$name" "$name.tmp" 2>/dev/null; then
                mv "$name.tmp" "$name" && chmod +x "$name"
                echo "  $name refreshed"
                [ "$name" = "update.sh" ] && REFRESHED=1
            else
                rm -f "$name.tmp"
            fi
        fi
    done
    if [ "$REFRESHED" = "1" ] && [ -x "./update.sh" ]; then
        echo ""
        echo "  ╔════════════════════════════════════════════════════════════╗"
        echo "  ║  ⓘ  Updater script itself was refreshed.                    ║"
        echo "  ║                                                            ║"
        echo "  ║     Re-running update with the latest version — this is    ║"
        echo "  ║     normal, not a crash. The same update continues below.  ║"
        echo "  ╚════════════════════════════════════════════════════════════╝"
        echo ""
        sleep 1
        export CODERAFT_UPDATE_REEXEC=1
        exec bash ./update.sh "${ORIG_ARGS[@]}"
    fi
fi

# ── Self-heal CODERAFT_HOST_OS in .env (B25) ──────────────────────────────
# Les installs antérieures préservaient .env sans ajouter CODERAFT_HOST_OS.
# Dashboard-api lit cette valeur pour le mode capture (native vs sidecar).
ENV_PATH_HO="${INSTALL_DIR}/.env"
if [ -f "$ENV_PATH_HO" ] && ! grep -qE '^\s*CODERAFT_HOST_OS\s*=' "$ENV_PATH_HO"; then
    case "$(uname -s)" in
        Darwin) HOST_OS_VAL="macos" ;;
        Linux)  HOST_OS_VAL="linux" ;;
        *)      HOST_OS_VAL="linux" ;;
    esac
    printf '\nCODERAFT_HOST_OS=%s\n' "$HOST_OS_VAL" >> "$ENV_PATH_HO"
    echo "  ✓ Self-heal .env — CODERAFT_HOST_OS=$HOST_OS_VAL ajouté"
fi

# ── Self-heal: docker-compose.yml drift (B24 — depends_on coderaft-vault) ──
# Les installs antérieures déclaraient coderaft-vault avec
# `condition: service_healthy`. Le healthcheck binary est buggé → vault
# toujours unhealthy → dashboard-api bloqué. Workaround: service_started.
COMPOSE_PATH="${INSTALL_DIR}/docker-compose.yml"
if [ -f "$COMPOSE_PATH" ] && grep -qF 'coderaft-vault: { condition: service_healthy }' "$COMPOSE_PATH"; then
    cp "$COMPOSE_PATH" "$COMPOSE_PATH.bak-$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    sed -i.tmp 's|coderaft-vault: { condition: service_healthy }|coderaft-vault: { condition: service_started }|' "$COMPOSE_PATH"
    rm -f "$COMPOSE_PATH.tmp"
    echo "  ✓ Self-heal docker-compose.yml — coderaft-vault: service_healthy → service_started"
fi

# ── Self-heal: NODE_OPTIONS=ipv4first dans dashboard-api (B15) ────────────
# Node.js IPv6-first, container Docker n'a pas d'IPv6 → ENETUNREACH sur appels
# sortants (license.coderaft.io, login.microsoftonline.com). Manifestation:
# 'Authentication failed: server_error' lors du callback Entra.
if [ -f "$COMPOSE_PATH" ] && ! grep -qF 'NODE_OPTIONS=--dns-result-order=ipv4first' "$COMPOSE_PATH"; then
    if grep -qF '      - LICENSE_SERVER_URL=https://license.coderaft.io' "$COMPOSE_PATH"; then
        cp "$COMPOSE_PATH" "$COMPOSE_PATH.bak-b15-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        # Inject NODE_OPTIONS line BEFORE every LICENSE_SERVER_URL line.
        sed -i.tmp 's|      - LICENSE_SERVER_URL=https://license.coderaft.io|      - NODE_OPTIONS=--dns-result-order=ipv4first\
      - LICENSE_SERVER_URL=https://license.coderaft.io|g' "$COMPOSE_PATH"
        rm -f "$COMPOSE_PATH.tmp"
        echo "  ✓ Self-heal docker-compose.yml — NODE_OPTIONS=ipv4first ajouté (B15)"
    fi
fi

# ── Self-heal: docker-compose.yml missing coderaft-cve-proxy service ──────
# coderaft-cve-proxy (sidecar in front of the shared coderaft-cve-engine,
# cve.coderaft.io) is a platform-level service like coderaft-vault — added
# here, not via the per-product PRODUCT_SERVICES update mechanism, so it
# reaches every existing install regardless of which products are licensed.
if [ -f "$COMPOSE_PATH" ] && ! grep -qE '^[[:space:]]*coderaft-cve-proxy:[[:space:]]*$' "$COMPOSE_PATH" \
   && grep -qE '^[[:space:]]*postgres:[[:space:]]*$' "$COMPOSE_PATH"; then
    cp "$COMPOSE_PATH" "$COMPOSE_PATH.bak-cveproxy-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    _cveproxy_block=$(cat <<'CVEPROXYBLOCK'
  # ── coderaft-cve-proxy ───────────────────────────────────────────────────
  # Internal sidecar in front of the shared coderaft-cve-engine
  # (cve.coderaft.io): holds the ONE bearer key for this deployment (read
  # from vault at boot) and forwards CVE/KEV/EPSS/MSRC lookups from any
  # product on coderaft-backend. No host port published.
  coderaft-cve-proxy:
    image: ghcr.io/liamj74/coderaft-cve-proxy:latest
    networks:
      - coderaft-vault-net
      - coderaft-backend
      - coderaft-frontend
    depends_on:
      coderaft-vault: { condition: service_started }
    environment:
      - CODERAFT_VAULT_URL=https://coderaft-vault:8200
      - CODERAFT_VAULT_CA=/vault-tls/client-ca.crt
      - CODERAFT_VAULT_CLIENT_CERT=/vault-tls/cve-proxy-client.crt
      - CODERAFT_VAULT_CLIENT_KEY=/vault-tls/cve-proxy-client.key
      - XPRODUCT_INTERNAL_TOKEN=${XPRODUCT_INTERNAL_TOKEN}
    volumes:
      - ./vault-tls/client-ca.crt:/vault-tls/client-ca.crt:ro
      - ./vault-tls/cve-proxy-client.crt:/vault-tls/cve-proxy-client.crt:ro
      - ./vault-tls/cve-proxy-client.key:/vault-tls/cve-proxy-client.key:ro
    healthcheck:
      test: ["CMD", "/coderaft-cve-proxy", "-healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 3
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    restart: unless-stopped

CVEPROXYBLOCK
)
    awk -v block="$_cveproxy_block" '
        /^[[:space:]]*postgres:[[:space:]]*$/ && !done { printf "%s", block; done=1 }
        { print }
    ' "$COMPOSE_PATH" > "$COMPOSE_PATH.tmp" && mv "$COMPOSE_PATH.tmp" "$COMPOSE_PATH"
    echo "  ✓ Self-heal docker-compose.yml — coderaft-cve-proxy service added"
fi

# ── Self-heal: docker-compose.override.yml neo4j port (B26) ───────────────
# Bind 127.0.0.1 + port paramétrable. Banking-grade.
OVERRIDE_PATH="${INSTALL_DIR}/docker-compose.override.yml"
if [ -f "$OVERRIDE_PATH" ] && grep -qE '"7687:7687"|- 7687:7687' "$OVERRIDE_PATH"; then
    cp "$OVERRIDE_PATH" "$OVERRIDE_PATH.bak-$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    sed -i.tmp 's|"7687:7687"|"127.0.0.1:${NEO4J_BOLT_PORT:-7687}:7687"|g; s|- 7687:7687|- "127.0.0.1:${NEO4J_BOLT_PORT:-7687}:7687"|g' "$OVERRIDE_PATH"
    rm -f "$OVERRIDE_PATH.tmp"
    echo "  ✓ Self-heal docker-compose.override.yml — neo4j 127.0.0.1 only + paramétrable"
fi

# ── Self-heal HOST_PROJECT_DIR in .env ────────────────────────────────────
# Older oneliners (and any install where the dir was renamed/moved) leave
# .env without HOST_PROJECT_DIR, which causes:
#   - docker compose warning "HOST_PROJECT_DIR not set" on every command
#   - dashboard-api boots with empty HOST_PROJECT_DIR → cannot reach
#     /host-compose paths → license.json invisible → fake "first run" UX
# Always (re)write the line with the resolved current install dir.
if [ -f "$INSTALL_DIR/.env" ]; then
    ABSOLUTE_INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
    if [ -n "$ABSOLUTE_INSTALL_DIR" ]; then
        if grep -q '^HOST_PROJECT_DIR=' "$INSTALL_DIR/.env" 2>/dev/null; then
            CURRENT=$(grep '^HOST_PROJECT_DIR=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2-)
            if [ "$CURRENT" != "$ABSOLUTE_INSTALL_DIR" ]; then
                grep -v '^HOST_PROJECT_DIR=' "$INSTALL_DIR/.env" > "$INSTALL_DIR/.env.tmp" \
                    && printf 'HOST_PROJECT_DIR=%s\n' "$ABSOLUTE_INSTALL_DIR" >> "$INSTALL_DIR/.env.tmp" \
                    && mv "$INSTALL_DIR/.env.tmp" "$INSTALL_DIR/.env" \
                    && chmod 600 "$INSTALL_DIR/.env" \
                    && echo "  ✓ HOST_PROJECT_DIR refreshed ($ABSOLUTE_INSTALL_DIR)"
            fi
        else
            printf 'HOST_PROJECT_DIR=%s\n' "$ABSOLUTE_INSTALL_DIR" >> "$INSTALL_DIR/.env"
            chmod 600 "$INSTALL_DIR/.env" 2>/dev/null || true
            echo "  ✓ HOST_PROJECT_DIR added ($ABSOLUTE_INSTALL_DIR)"
        fi
    fi
fi

# ── Self-heal compose YAML ────────────────────────────────────────────────
# Detects a docker-compose.override.yml generated by an older dashboard-api
# version with a broken YAML serializer. Without this, every `docker compose
# ps/up/down` fails with "yaml: line N: ..." and the oneliner cannot do
# anything. Recovery: back up the broken override, pull the latest
# dashboard-api, start it alone (with postgres+redis); it regenerates a
# clean override, then we continue normally.
echo ""
echo "  Checking compose integrity..."
if ! docker compose ps >/dev/null 2>&1; then
    echo "  ⚠ docker-compose.override.yml appears corrupted — auto-recovery..."
    if [ -f "docker-compose.override.yml" ]; then
        cp docker-compose.override.yml "docker-compose.override.yml.broken-$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        rm -f docker-compose.override.yml
        echo "    ✓ override backed up + removed"
    fi
    docker pull ghcr.io/liamj74/coderaft-dashboard-api:latest >/dev/null 2>&1 || true
    if docker compose up -d postgres redis dashboard-api >/dev/null 2>&1; then
        sleep 6
        if docker compose ps >/dev/null 2>&1; then
            echo "    ✓ compose repaired"
        else
            echo "  ERROR: self-heal failed. Inspect docker-compose.override.yml manually."
            exit 1
        fi
    else
        echo "  ERROR: cannot restart dashboard-api. Check Docker Engine."
        exit 1
    fi
else
    echo "  ✓ compose OK"
fi

# ── FalconOne agents mTLS PKI (#170) ─────────────────────────────────────────
# Distinct CA/leaf from the vault client PKI: falconone-tls/agents-ca.crt is
# the pool of ClientCAs falconone-api trusts for inbound agent mTLS, and
# falconone-tls/server.crt is the leaf falconone-api presents on :8443 to its
# own Windows agents. Bug #170: server.crt's SAN only ever had
# [localhost, falconone-api] — remote agents connecting via
# https://<public-hostname>:8443/agent/v1 failed hostname verification.
# Self-healing: the CA is preserved if it already exists (regenerating it
# would break trust for any agent already enrolled); only the leaf is
# regenerated, and only when it's missing the "coderaft.local" SAN.
#
# Defined here (and called both inside the one-time migration block below
# AND unconditionally after it) because the migration block only ever runs
# ONCE per install — already-migrated installs would otherwise never get
# this SAN fix or a falconone-tls dir that didn't exist on an older version.
_falconone_tls_bootstrap() {
    local install_dir="${1:?install_dir required}"
    local fo_tls_dir="${install_dir}/falconone-tls"
    mkdir -p "$fo_tls_dir"
    chmod 755 "$fo_tls_dir"

    local fo_sans="DNS:localhost,DNS:falconone-api,DNS:coderaft.local"
    local fo_hostname
    fo_hostname="$(hostname 2>/dev/null || true)"
    [ -n "$fo_hostname" ] && fo_sans="${fo_sans},DNS:${fo_hostname}"
    if [ -n "${CODERAFT_EXTRA_HOSTS:-}" ]; then
        local _h _extra_hosts
        IFS=',' read -ra _extra_hosts <<< "$CODERAFT_EXTRA_HOSTS"
        for _h in "${_extra_hosts[@]}"; do
            _h="$(echo "$_h" | xargs)"
            [ -n "$_h" ] && fo_sans="${fo_sans},DNS:${_h}"
        done
    fi
    fo_sans="${fo_sans},IP:127.0.0.1"

    if command -v openssl &>/dev/null; then
        if [ ! -f "${fo_tls_dir}/agents-ca.crt" ]; then
            openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
                -keyout "${fo_tls_dir}/agents-ca.key" -out "${fo_tls_dir}/agents-ca.crt" \
                -subj "/CN=falconone-agents-ca" \
                -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
        fi
        local need_regen=1
        if [ -f "${fo_tls_dir}/server.crt" ] && openssl x509 -in "${fo_tls_dir}/server.crt" -noout -text 2>/dev/null | grep -q "coderaft.local"; then
            need_regen=0
        fi
        if [ "$need_regen" = "1" ]; then
            openssl req -newkey rsa:2048 -nodes -sha256 \
                -keyout "${fo_tls_dir}/server.key" -out "${fo_tls_dir}/server.csr" \
                -subj "/CN=falconone-agents" 2>/dev/null
            openssl x509 -req -days 3650 -sha256 \
                -in "${fo_tls_dir}/server.csr" \
                -CA "${fo_tls_dir}/agents-ca.crt" -CAkey "${fo_tls_dir}/agents-ca.key" -CAcreateserial \
                -out "${fo_tls_dir}/server.crt" \
                -extfile <(printf "subjectAltName=%s\nbasicConstraints=CA:FALSE" "$fo_sans") 2>/dev/null
            rm -f "${fo_tls_dir}/server.csr"
        fi
        chmod 644 "${fo_tls_dir}"/*.crt "${fo_tls_dir}"/*.key 2>/dev/null || true
    else
        local abs_fo_tls_dir fo_script_file
        abs_fo_tls_dir="$(cd "$fo_tls_dir" && pwd)"
        fo_script_file="$(mktemp)"
        cat > "$fo_script_file" <<'FOSCRIPT'
set -e
apk add --no-cache openssl >/dev/null
cd /work
if [ ! -f agents-ca.crt ]; then
    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
        -keyout agents-ca.key -out agents-ca.crt \
        -subj "/CN=falconone-agents-ca" \
        -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
fi
NEED_REGEN=1
if [ -f server.crt ] && openssl x509 -in server.crt -noout -text 2>/dev/null | grep -q "coderaft.local"; then
    NEED_REGEN=0
fi
if [ "$NEED_REGEN" = "1" ]; then
    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout server.key -out server.csr \
        -subj "/CN=falconone-agents" 2>/dev/null
    printf "subjectAltName=__FO_SAN_LIST__\nbasicConstraints=CA:FALSE" > /tmp/server.ext
    openssl x509 -req -days 3650 -sha256 \
        -in server.csr -CA agents-ca.crt -CAkey agents-ca.key -CAcreateserial \
        -out server.crt -extfile /tmp/server.ext 2>/dev/null
    rm -f server.csr
fi
chmod 644 *.crt *.key 2>/dev/null || true
FOSCRIPT
        sed -i.tmp "s/__FO_SAN_LIST__/${fo_sans}/" "$fo_script_file" && rm -f "${fo_script_file}.tmp"
        docker run --rm -v "${fo_script_file}:/script.sh:ro" -v "${abs_fo_tls_dir}:/work" alpine:3.20 sh /script.sh 2>&1
        rm -f "$fo_script_file"
    fi
    echo "  ✓ FalconOne agents PKI written (SAN: ${fo_sans})"
}

# ── ACL self-heal: falconone entry/permissions (#172) ────────────────────────
# The acl.yaml rewrite in _vault_gen_tls_update only runs once, inside the
# migration block (gated by $_VAULT_NEEDS_MIGRATION). That means any install
# that already migrated to vault before this fix shipped would never get the
# falconone entry/permissions rewritten. This self-heal is additive-only,
# idempotent, and safe to call on every install/update run: if the
# "falconone" client entry is missing, it appends the full canonical block;
# if present, it appends only whichever required permissions are missing,
# leaving everything else in the file untouched. Backs up acl.yaml before
# any modification.
_falconone_acl_selfheal() {
    local acl_path="$1"

    if [ ! -f "$acl_path" ]; then
        echo "  [install] ACL self-heal: $acl_path not found — skipping (vault not provisioned yet)"
        return 0
    fi

    local required_perms=(
        "read:license_key"
        "read:falconone_*"
        "read:platform/identity/oidc"
        "sign:falconone_agent_cert"
        "read:falconone/nvd_api_key"
        "read:falconone/audit_hmac_key"
        "write:falconone/audit_hmac_key"
        "read:falconone/pki/agents-ca/cert"
        "read:pki/falconone-agents-ca*"
        "write:pki/falconone-agents-ca*"
    )

    local ts
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"

    if ! grep -qE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*falconone[[:space:]]*$' "$acl_path"; then
        cp "$acl_path" "${acl_path}.bak-${ts}"
        cat >> "$acl_path" <<'FALCONONEACL'

  - name: falconone
    cert_san: "falconone.coderaft.local"
    permissions:
      - "read:license_key"
      - "read:falconone_*"
      - "read:platform/identity/oidc"
      - "sign:falconone_agent_cert"
      - "read:falconone/nvd_api_key"
      - "read:falconone/audit_hmac_key"
      - "write:falconone/audit_hmac_key"
      - "read:falconone/pki/agents-ca/cert"
      - "read:pki/falconone-agents-ca*"
      - "write:pki/falconone-agents-ca*"
FALCONONEACL
        echo "  [install] Self-heal ACL: falconone permissions updated (+${#required_perms[@]} added, entry created)"
        return 0
    fi

    local start_line end_line
    start_line=$(grep -nE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*falconone[[:space:]]*$' "$acl_path" | head -1 | cut -d: -f1)
    end_line=$(awk -v s="$start_line" 'NR>s && /^[[:space:]]*-[[:space:]]*name:/{print NR; exit}' "$acl_path")
    if [ -z "$end_line" ]; then
        end_line=$(( $(wc -l < "$acl_path") + 1 ))
    fi

    local block
    block=$(sed -n "${start_line},$((end_line - 1))p" "$acl_path")

    local missing=()
    local p
    for p in "${required_perms[@]}"; do
        if ! grep -qF "\"${p}\"" <<< "$block"; then
            missing+=("$p")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        echo "  [install] ACL falconone already up-to-date"
        return 0
    fi

    cp "$acl_path" "${acl_path}.bak-${ts}"

    if grep -qE '^[[:space:]]*permissions:[[:space:]]*\[.*\][[:space:]]*$' <<< "$block"; then
        local additions=""
        for p in "${missing[@]}"; do additions="${additions},\"${p}\""; done
        awk -v s="$start_line" -v e="$end_line" -v add="$additions" '
            NR>=s && NR<e && /^[[:space:]]*permissions:[[:space:]]*\[.*\][[:space:]]*$/ {
                sub(/\][[:space:]]*$/, add "]")
            }
            { print }
        ' "$acl_path" > "${acl_path}.tmp" && mv "${acl_path}.tmp" "$acl_path"
    else
        local addition_block=""
        for p in "${missing[@]}"; do addition_block="${addition_block}      - \"${p}\""$'\n'; done
        local insert_line=$(( end_line - 1 ))
        awk -v ins="$insert_line" -v add="$addition_block" '
            { print }
            NR==ins { printf "%s", add }
        ' "$acl_path" > "${acl_path}.tmp" && mv "${acl_path}.tmp" "$acl_path"
    fi

    echo "  [install] Self-heal ACL: falconone permissions updated (+${#missing[@]} added)"
}

# ── ACL self-heal: cve-proxy entry (coderaft-cve-engine sidecar) ────────────
# Same additive-only, idempotent pattern as _falconone_acl_selfheal above.
_cveproxy_acl_selfheal() {
    local acl_path="$1"

    if [ ! -f "$acl_path" ]; then
        echo "  [install] ACL self-heal: $acl_path not found — skipping (vault not provisioned yet)"
        return 0
    fi

    if grep -qE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*cve-proxy[[:space:]]*$' "$acl_path"; then
        echo "  [install] ACL cve-proxy already present"
        return 0
    fi

    local ts
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"
    cp "$acl_path" "${acl_path}.bak-${ts}"
    cat >> "$acl_path" <<'CVEPROXYACL'

  - name: cve-proxy
    cert_san: "cve-proxy.coderaft.local"
    permissions:
      - "read:cve-proxy/*"
      - "write:cve-proxy/*"
CVEPROXYACL
    echo "  [install] Self-heal ACL: cve-proxy entry created"
}

# ── Vault client cert self-heal (any product whose cert was never
# generated, e.g. falconone/cve-proxy on installs provisioned before they
# shipped) — additive-only, requires client-ca.key to still be present.
_vault_client_cert_selfheal() {
    local name="$1" san="$2"
    local tls_dir="${INSTALL_DIR}/vault-tls"

    if [ -f "${tls_dir}/${name}-client.crt" ]; then
        return 0
    fi
    if [ ! -f "${tls_dir}/client-ca.key" ] || [ ! -f "${tls_dir}/client-ca.crt" ]; then
        echo "  [update] Cert self-heal: ${tls_dir}/client-ca.key missing — cannot mint ${name}-client cert (needs a full CA rotation, not a self-heal)"
        return 0
    fi

    echo "  [update] Cert self-heal: generating vault-tls/${name}-client (was missing)"
    if command -v openssl &>/dev/null; then
        ( cd "$tls_dir" && \
          openssl req -newkey rsa:2048 -nodes -sha256 \
              -keyout "${name}-client.key" -out "${name}-client.csr" \
              -subj "/CN=${san}" 2>/dev/null && \
          openssl x509 -req -days 3650 -sha256 \
              -in "${name}-client.csr" -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
              -out "${name}-client.crt" \
              -extfile <(printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE" "$san") \
              2>/dev/null && \
          rm -f "${name}-client.csr" && \
          chmod 600 "${name}-client.key" "${name}-client.crt" )
    else
        local abs_tls_dir
        abs_tls_dir="$(cd "$tls_dir" && pwd)"
        docker run --rm -i \
            -v "${abs_tls_dir}:/work" \
            alpine:3.20 sh -c "
                set -e
                apk add --no-cache openssl >/dev/null
                cd /work
                openssl req -newkey rsa:2048 -nodes -sha256 \
                    -keyout '${name}-client.key' -out '${name}-client.csr' \
                    -subj '/CN=${san}' 2>/dev/null
                printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE' '${san}' > /tmp/client.ext
                openssl x509 -req -days 3650 -sha256 \
                    -in '${name}-client.csr' -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
                    -out '${name}-client.crt' -extfile /tmp/client.ext 2>/dev/null
                rm -f '${name}-client.csr'
                chmod 600 '${name}-client.key' '${name}-client.crt'
            " 2>&1
    fi
}

# ── Vault migration (D4) ─────────────────────────────────────────────────
# Runs ONCE when the vault container is absent from the compose stack.
# Phases: 4a detect → 4b backup → 4c key bootstrap → 4d pull+start vault →
#         4e migrate secrets → 4f rollback on any failure → 4g sentinel →
#         4h write CODERAFT_VAULT_* into .env.
# All legacy stores are kept intact (7-day grace); no purge happens here.
echo ""
echo "  Checking vault migration status..."

_vault_migration_needed() {
    # 4a: skip if sentinel exists OR vault container is running
    if [ -f "${INSTALL_DIR}/vault-data/.migrated" ]; then
        echo "  ✓ Vault migration already complete (sentinel found)"
        return 1
    fi
    if (cd "${INSTALL_DIR}" 2>/dev/null && docker compose ps coderaft-vault 2>/dev/null | grep -q "running"); then
        echo "  ✓ coderaft-vault already running — skipping migration"
        return 1
    fi
    # If vault service is in docker-compose.yml it means install.sh already
    # ran with vault support — check if the keys dir is missing instead.
    if [ ! -f "${INSTALL_DIR}/vault-keys/age.key" ]; then
        echo "  Vault master key absent — migration required"
        return 0
    fi
    return 0
}

_vault_migration_needed || true
_VAULT_NEEDS_MIGRATION=0
if ! [ -f "${INSTALL_DIR}/vault-data/.migrated" ] && \
   ! (cd "${INSTALL_DIR}" 2>/dev/null && docker compose ps coderaft-vault 2>/dev/null | grep -q "running") 2>/dev/null; then
    _VAULT_NEEDS_MIGRATION=1
fi

if [ "${_VAULT_NEEDS_MIGRATION}" = "1" ]; then
    echo "  Running vault migration..."

    # ── 4b Pre-flight backup (atomic — fail-fast) ─────────────────────────
    _VAULT_TS=$(date -u +"%Y%m%dT%H%M%SZ")
    _VAULT_BAK="${INSTALL_DIR}/backups/migrate-vault-${_VAULT_TS}"
    mkdir -p "${_VAULT_BAK}"
    echo "  Backup directory: ${_VAULT_BAK}"

    _bak_fail() {
        echo "  ✗ Pre-flight backup failed at: $1" >&2
        echo "  Vault migration aborted — no changes made." >&2
        exit 1
    }

    # Copy flat files
    [ -f "${INSTALL_DIR}/.env" ]              && cp "${INSTALL_DIR}/.env"              "${_VAULT_BAK}/env"              || _bak_fail ".env"
    [ -f "${INSTALL_DIR}/.env.enc" ]          && cp "${INSTALL_DIR}/.env.enc"          "${_VAULT_BAK}/env.enc"          || true
    [ -f "${INSTALL_DIR}/.coderaft-age.key" ] && cp "${INSTALL_DIR}/.coderaft-age.key" "${_VAULT_BAK}/age.key"          || true

    # Postgres auth_config dump
    if (cd "${INSTALL_DIR}" 2>/dev/null && docker compose ps postgres 2>/dev/null | grep -q "running") 2>/dev/null; then
        cd "${INSTALL_DIR}" && docker compose exec -T postgres \
            pg_dump -U coderaft -t auth_config coderaft < /dev/null 2>/dev/null \
            > "${_VAULT_BAK}/auth_config.sql" || true
        cd - >/dev/null
    fi

    # Docker cp for container-side files (best-effort — containers may not be running)
    (cd "${INSTALL_DIR}" 2>/dev/null && docker compose ps ravenscan 2>/dev/null | grep -q "running") 2>/dev/null && \
        (cd "${INSTALL_DIR}" && docker compose cp "ravenscan:.ravenscan/ravenscan.db" "${_VAULT_BAK}/ravenscan.db" 2>/dev/null || true)
    (cd "${INSTALL_DIR}" 2>/dev/null && docker compose ps dashboard-api 2>/dev/null | grep -q "running") 2>/dev/null && {
        cd "${INSTALL_DIR}"
        docker compose cp "dashboard-api:/data/vault.enc"    "${_VAULT_BAK}/dashboard-vault.enc" 2>/dev/null || true
        docker compose cp "dashboard-api:/data/admin_token"  "${_VAULT_BAK}/admin_token"         2>/dev/null || true
        cd - >/dev/null
    }
    echo "  ✓ Pre-flight backup complete"

    # ── 4c Key bootstrap ──────────────────────────────────────────────────
    if [ ! -f "${INSTALL_DIR}/vault-keys/age.key" ]; then
        echo "  Generating vault master key..."
        mkdir -p "${INSTALL_DIR}/vault-keys" "${INSTALL_DIR}/vault-tls" "${INSTALL_DIR}/vault-config"
        if ! command -v age-keygen &>/dev/null; then
            echo "  ✗ age-keygen required for vault bootstrap — install from https://github.com/FiloSottile/age/releases" >&2
            exit 1
        fi
        age-keygen -o "${INSTALL_DIR}/vault-keys/age.key" 2>/dev/null
        chmod 400 "${INSTALL_DIR}/vault-keys/age.key"

        # Recovery phrase
        _VAULT_RECOVERY=""
        if [ "${CODERAFT_TEST_MODE:-0}" != "1" ]; then
            _VAULT_PRIV=$(grep '^AGE-SECRET-KEY-' "${INSTALL_DIR}/vault-keys/age.key" 2>/dev/null || true)
            if [ -n "$_VAULT_PRIV" ]; then
                _VAULT_RECOVERY=$(echo "$_VAULT_PRIV" | \
                    docker run --rm -i ghcr.io/liamj74/coderaft-vault:latest \
                        -mnemonic-from-key /dev/stdin 2>/dev/null || true)
            fi
        fi
        if [ -z "$_VAULT_RECOVERY" ]; then
            _VAULT_PUB=$(grep '# public key:' "${INSTALL_DIR}/vault-keys/age.key" 2>/dev/null | awk '{print $NF}' || true)
            _VAULT_RECOVERY="[FALLBACK] fingerprint: ${_VAULT_PUB}"
        fi

        echo ""
        echo "  ╔══════════════════════════════════════════════════════════════════╗"
        echo "  ║   *** VAULT RECOVERY PHRASE — WRITE THIS DOWN NOW ***           ║"
        echo "  ╚══════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "    ${_VAULT_RECOVERY}"
        echo ""

        if [ "${CODERAFT_TEST_MODE:-0}" = "1" ]; then
            _VAULT_CONFIRM_REPLY="CONFIRMED"
        else
            printf "  Type CONFIRMED to continue: "
            read -r _VAULT_CONFIRM_REPLY
        fi
        if [ "$_VAULT_CONFIRM_REPLY" != "CONFIRMED" ]; then
            echo "  Aborted. vault-keys/age.key kept in place."
            exit 1
        fi

        # B12/B11 fix: generate mTLS PKI with correct filenames (client-ca.crt,
        # vault.crt) and correct ACL field names (name, cert_san, permissions).
        # If openssl is absent on host, use alpine container fallback.
        if [ ! -f "${INSTALL_DIR}/vault-tls/client-ca.crt" ]; then
            _old_pwd="$PWD"
            cd "${INSTALL_DIR}"
            _vault_gen_tls_update
            cd "$_old_pwd"
        fi
    fi

    # ── 4d Pull and start vault ────────────────────────────────────────────
    _VAULT_ROLLBACK() {
        echo "  ✗ Vault migration failed — rolling back..." >&2
        (cd "${INSTALL_DIR}" 2>/dev/null && docker compose down 2>/dev/null) || true
        # Restore flat files
        [ -f "${_VAULT_BAK}/env" ]   && cp "${_VAULT_BAK}/env"   "${INSTALL_DIR}/.env"
        [ -f "${_VAULT_BAK}/env.enc" ] && cp "${_VAULT_BAK}/env.enc" "${INSTALL_DIR}/.env.enc"
        [ -f "${_VAULT_BAK}/age.key" ] && cp "${_VAULT_BAK}/age.key" "${INSTALL_DIR}/.coderaft-age.key"
        # Restore postgres
        if [ -s "${_VAULT_BAK}/auth_config.sql" ] && \
           (cd "${INSTALL_DIR}" 2>/dev/null && docker compose up -d postgres 2>/dev/null); then
            sleep 5
            (cd "${INSTALL_DIR}" && docker compose exec -T postgres \
                psql -U coderaft coderaft < "${_VAULT_BAK}/auth_config.sql" > /dev/null 2>&1 || true)
        fi
        # Remove vault from compose if present (revert)
        if grep -q 'coderaft-vault:' "${INSTALL_DIR}/docker-compose.yml" 2>/dev/null; then
            python3 -c "
import re, sys
txt = open('${INSTALL_DIR}/docker-compose.yml').read()
# Remove coderaft-vault service block and vault_data volume and coderaft-vault-net network
# Simple approach: warn operator to manually remove
print('  ⚠ Remove coderaft-vault service from docker-compose.yml manually', file=sys.stderr)
" 2>/dev/null || echo "  ⚠ Remove coderaft-vault from docker-compose.yml manually" >&2
        fi
        (cd "${INSTALL_DIR}" 2>/dev/null && docker compose up -d 2>/dev/null) || true
        echo ""
        echo "  Rollback complete. Backup is at: ${_VAULT_BAK}" >&2
        echo "  The legacy secrets stores are intact." >&2
        exit 1
    }

    # cosign verify if available and STRICT_COSIGN_VERIFY=1
    if [ "${CODERAFT_TEST_MODE:-0}" != "1" ]; then
        if command -v cosign &>/dev/null && [ "${STRICT_COSIGN_VERIFY:-}" = "1" ]; then
            cosign verify \
                --certificate-identity-regexp="^https://github.com/LiamJ74/" \
                --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
                "ghcr.io/liamj74/coderaft-vault:latest" > /dev/null 2>&1 || {
                echo "  ✗ cosign verify failed for coderaft-vault (STRICT_COSIGN_VERIFY=1)" >&2
                exit 1
            }
        fi
        docker pull ghcr.io/liamj74/coderaft-vault:latest 2>/dev/null || _VAULT_ROLLBACK
    fi

    # Inject test-mode failure point 4d
    if [ "${CODERAFT_TEST_FAIL:-}" = "4d" ]; then
        echo "  [TEST] Injecting failure at step 4d"
        _VAULT_ROLLBACK
    fi

    # B-VAULT-OVERRIDE-DUP (2026-06-10): install.sh writes the full
    # `coderaft-vault:` service into the main docker-compose.yml. Loading a
    # second file that redefines the service merges security_opt lists →
    # duplicate `no-new-privileges:true` → compose v2 rejects with
    # "items at 0 and 1 are equal". Skip override entirely when main already
    # has the service.
    _VAULT_OVERRIDE="${INSTALL_DIR}/docker-compose.vault.yml"
    _VAULT_IN_MAIN=0
    if [ -f "${INSTALL_DIR}/docker-compose.yml" ] && \
       grep -Eq '^[[:space:]]*coderaft-vault:[[:space:]]*$' "${INSTALL_DIR}/docker-compose.yml"; then
        _VAULT_IN_MAIN=1
        if [ -f "$_VAULT_OVERRIDE" ]; then
            mv -f "$_VAULT_OVERRIDE" "${_VAULT_OVERRIDE}.bak" 2>/dev/null || true
        fi
    fi
    if [ "$_VAULT_IN_MAIN" -eq 0 ] && [ ! -f "$_VAULT_OVERRIDE" ]; then
        cat > "$_VAULT_OVERRIDE" << 'VAULTOVERRIDE'
# Generated by update.sh vault migration. Do not edit by hand.
networks:
  coderaft-vault-net:
    internal: true

volumes:
  vault_data:

services:
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
VAULTOVERRIDE
    fi

    # Compose args for vault-related calls. Skip the override when the main
    # file already defines `coderaft-vault:` (B-VAULT-OVERRIDE-DUP).
    if [ "$_VAULT_IN_MAIN" -eq 1 ]; then
        _VAULT_COMPOSE_ARGS=(-f "${INSTALL_DIR}/docker-compose.yml")
    else
        _VAULT_COMPOSE_ARGS=(-f "${INSTALL_DIR}/docker-compose.yml" -f "${INSTALL_DIR}/docker-compose.vault.yml")
    fi

    # B9 fix: explicit stop+rm guarantees the container reloads cert/config
    # from bind mounts. --force-recreate alone has been observed to leave
    # a Running container in Docker Desktop with stale certs in memory.
    (cd "${INSTALL_DIR}" && docker compose "${_VAULT_COMPOSE_ARGS[@]}" stop coderaft-vault 2>/dev/null || true)
    (cd "${INSTALL_DIR}" && docker compose "${_VAULT_COMPOSE_ARGS[@]}" rm -f coderaft-vault 2>/dev/null || true)
    (cd "${INSTALL_DIR}" && docker compose "${_VAULT_COMPOSE_ARGS[@]}" up -d coderaft-vault 2>/dev/null) || _VAULT_ROLLBACK

    # Detect compose project name (determines Docker network for sidecar)
    _VAULT_PROJECT=$(docker inspect coderaft-coderaft-vault-1 \
        --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
    [ -z "$_VAULT_PROJECT" ] && _VAULT_PROJECT="coderaft"
    _VAULT_NETWORK="${_VAULT_PROJECT}_coderaft-vault-net"
    _ABS_TLS_DIR="$(cd "${INSTALL_DIR}/vault-tls" && pwd)"

    # B6/B7 fix: vault image is distroless — NO docker compose exec ... sh.
    # Use curlimages/curl sidecar on the vault network with the dashboard-api
    # client cert for mTLS (RequireAndVerifyClientCert is enforced by vault).
    _vault_curl_update() {
        local method="$1" path="$2" body="${3:-}"
        local curl_args=(
            "run" "--rm"
            "--user" "0:0"
            "--network" "$_VAULT_NETWORK"
            "-v" "${_ABS_TLS_DIR}:/tls:ro"
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

    # Wait for vault to be reachable (any TLS handshake, even sealed)
    echo "  Waiting for vault to be reachable..."
    _VAULT_HEALTHY=0
    _LAST_SEALED="true"
    for _i in $(seq 1 20); do
        _HEALTH=$(_vault_curl_update "GET" "/v1/health" 2>/dev/null || true)
        if echo "$_HEALTH" | grep -q '"sealed":'; then
            _VAULT_HEALTHY=1
            echo "$_HEALTH" | grep -q '"sealed":false' && _LAST_SEALED="false" || _LAST_SEALED="true"
            break
        fi
        sleep 3
    done
    if [ "$_VAULT_HEALTHY" = "0" ]; then
        echo "  ✗ coderaft-vault did not respond to TLS probes" >&2
        _VAULT_ROLLBACK
    fi

    # B10 fix: unseal if sealed (1 share = base64-encoded age key file bytes)
    if [ "$_LAST_SEALED" = "true" ]; then
        echo "  Vault is sealed — sending unseal request..."
        _SHARE_B64=$(base64 < "${INSTALL_DIR}/vault-keys/age.key" | tr -d '\n')
        _UNSEAL_BODY="{\"shares\":[\"${_SHARE_B64}\"]}"
        _UNSEAL_RESP=$(_vault_curl_update "POST" "/v1/unseal" "$_UNSEAL_BODY" 2>/dev/null || true)
        if ! echo "$_UNSEAL_RESP" | grep -qE '"ok"\s*:\s*true|"sealed"\s*:\s*false'; then
            echo "  Unseal response: $_UNSEAL_RESP" >&2
            _VAULT_ROLLBACK
        fi
        echo "  ✓ Vault unsealed"
    fi

    # Final health check — must say sealed:false
    _FINAL_HEALTH=$(_vault_curl_update "GET" "/v1/health" 2>/dev/null || true)
    if ! echo "$_FINAL_HEALTH" | grep -q '"sealed":false'; then
        echo "  Final health: $_FINAL_HEALTH" >&2
        echo "  ✗ Vault still sealed after unseal call" >&2
        _VAULT_ROLLBACK
    fi
    echo "  ✓ coderaft-vault is healthy"

    # ── 4e Migrate secrets one at a time ─────────────────────────────────
    # B6 fix: NEVER use `docker compose exec coderaft-vault sh` — distroless image
    # has no shell. Use curlimages/curl sidecar (_vault_curl_update defined above).
    _vault_set() {
        local name="$1" value="$2"
        [ -z "$value" ] && return 0  # skip empty
        local body
        body=$(printf '{"name":"%s","value":"%s"}' "$name" "$value")
        local resp
        resp=$(_vault_curl_update "POST" "/v1/secret/set" "$body" 2>/dev/null || true)
        echo "$resp" | grep -q '"ok":true'
    }

    # Helper: read a secret back to verify round-trip
    _vault_get() {
        local name="$1"
        local body
        body=$(printf '{"name":"%s"}' "$name")
        local resp
        resp=$(_vault_curl_update "POST" "/v1/secret/get" "$body" 2>/dev/null || true)
        echo "$resp" | grep -o '"value":"[^"]*"' | cut -d'"' -f4 || true
    }

    # Read secrets from .env
    _env_val() {
        grep -E "^[[:space:]]*$1=" "${INSTALL_DIR}/.env" 2>/dev/null \
            | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs 2>/dev/null || true
    }

    # Inject test-mode failure point 4e
    if [ "${CODERAFT_TEST_FAIL:-}" = "4e" ]; then
        echo "  [TEST] Injecting failure at step 4e"
        _VAULT_ROLLBACK
    fi

    echo "  Migrating secrets to vault..."
    _VAULT_MIGRATE_OK=1

    # a. LICENSE_KEY
    _LK=$(_env_val LICENSE_KEY)
    if [ -n "$_LK" ]; then
        _vault_set "license_key" "$_LK" || { _VAULT_MIGRATE_OK=0; echo "  ✗ Failed to migrate license_key" >&2; }
        _READBACK=$(_vault_get "license_key")
        [ "$_READBACK" = "$_LK" ] || { _VAULT_MIGRATE_OK=0; echo "  ✗ Round-trip verify failed: license_key" >&2; }
    fi

    # b-f. Infrastructure / product secrets from .env
    for _SECRET_MAP in \
        "POSTGRES_PASSWORD:postgres_password" \
        "REDIS_PASSWORD:redis_password" \
        "DASHBOARD_SECRET:dashboard_secret_legacy" \
        "NEO4J_PASSWORD:neo4j_password" \
        "RAVENSCAN_SECRET_KEY:ravenscan_secret_key" \
        "RAVENSCAN_CAPTURE_TOKEN:ravenscan_capture_token" \
        "RAVENSCAN_LICENSE_KEY:ravenscan_license_key" \
        "REDFOX_MASTER_PASSPHRASE:redfox_master_passphrase" \
        "REDFOX_JWT_PRIVATE_KEY:redfox_jwt_private_key" \
        "REDFOX_JWT_PUBLIC_KEY:redfox_jwt_public_key" \
        "REDFOX_GW_SESSION_SECRET:redfox_gw_session_secret" \
        "REDFOX_LICENSE_KEY:redfox_license_key"; do
        _ENV_KEY="${_SECRET_MAP%%:*}"
        _VAULT_KEY="${_SECRET_MAP##*:}"
        _VAL=$(_env_val "$_ENV_KEY")
        if [ -n "$_VAL" ]; then
            if _vault_set "$_VAULT_KEY" "$_VAL"; then
                _RB=$(_vault_get "$_VAULT_KEY")
                if [ "$_RB" != "$_VAL" ]; then
                    _VAULT_MIGRATE_OK=0
                    echo "  ✗ Round-trip verify failed: ${_VAULT_KEY}" >&2
                fi
            else
                _VAULT_MIGRATE_OK=0
                echo "  ✗ Failed to migrate: ${_VAULT_KEY}" >&2
            fi
        fi
    done

    if [ "$_VAULT_MIGRATE_OK" = "0" ]; then
        _VAULT_ROLLBACK
    fi
    echo "  ✓ Secrets migrated and verified"

    # ── 4g Sentinel ───────────────────────────────────────────────────────
    # B6 fix: distroless vault has no shell — cannot docker exec /bin/sh.
    # Write the host-side sentinel (update.ps1 pattern: vault-data/.migrated).
    mkdir -p "${INSTALL_DIR}/vault-data"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${INSTALL_DIR}/vault-data/.migrated" 2>/dev/null || true
    echo "  ✓ Migration sentinel written"

    # ── 4h Write CODERAFT_VAULT_* into .env ──────────────────────────────
    _add_env_if_missing_update() {
        local key="$1" val="$2"
        if ! grep -q "^${key}=" "${INSTALL_DIR}/.env" 2>/dev/null; then
            printf '%s=%s\n' "$key" "$val" >> "${INSTALL_DIR}/.env"
        fi
    }
    _add_env_if_missing_update "CODERAFT_VAULT_URL"      "https://coderaft-vault:8200"
    _add_env_if_missing_update "CODERAFT_VAULT_AZURE"    "0"
    _add_env_if_missing_update "CODERAFT_VAULT_LICENSE"  "0"
    _add_env_if_missing_update "CODERAFT_VAULT_PRODUCTS" "0"
    _add_env_if_missing_update "CODERAFT_VAULT_JWT"      "0"
    chmod 600 "${INSTALL_DIR}/.env" 2>/dev/null || true
    echo "  ✓ CODERAFT_VAULT_* vars written to .env"
    echo ""
    echo "  Vault migration complete."
    echo "  Legacy stores retained for 7-day grace period."
    echo "  The dashboard will show a banner to purge them after 7 days of stable operation."
    echo ""
fi

_vault_gen_tls_update() {
    # B12/B11 fix: correct cert filenames (client-ca.crt, vault.crt) and
    # correct ACL field names (name, cert_san, permissions — NOT san/role/allow).
    # B7 fix: server cert SAN includes localhost + 127.0.0.1 for mTLS hostname verify.
    # No-ops if already present (idempotent).
    [ -f "vault-tls/client-ca.crt" ] && [ -f "vault-tls/vault.crt" ] && return 0
    mkdir -p vault-tls vault-config
    chmod 700 vault-tls

    if command -v openssl &>/dev/null; then
        openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
            -keyout vault-tls/client-ca.key -out vault-tls/client-ca.crt \
            -subj "/CN=coderaft-vault-ca" \
            -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
        chmod 600 vault-tls/client-ca.key vault-tls/client-ca.crt

        openssl req -newkey rsa:2048 -nodes -sha256 \
            -keyout vault-tls/vault.key -out vault-tls/vault.csr \
            -subj "/CN=coderaft-vault" 2>/dev/null
        openssl x509 -req -days 3650 -sha256 \
            -in vault-tls/vault.csr \
            -CA vault-tls/client-ca.crt -CAkey vault-tls/client-ca.key -CAcreateserial \
            -out vault-tls/vault.crt \
            -extfile <(printf "subjectAltName=DNS:coderaft-vault,DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE") 2>/dev/null
        rm -f vault-tls/vault.csr
        chmod 600 vault-tls/vault.crt vault-tls/vault.key

        for _pair in "dashboard-api:dashboard-api.coderaft.local" \
                     "entraguard:entraguard.coderaft.local" \
                     "ravenscan:ravenscan.coderaft.local" \
                     "redfox:redfox.coderaft.local" \
                     "falconone:falconone.coderaft.local" \
                     "cve-proxy:cve-proxy.coderaft.local"; do
            _n="${_pair%%:*}"; _s="${_pair##*:}"
            openssl req -newkey rsa:2048 -nodes -sha256 \
                -keyout "vault-tls/${_n}-client.key" \
                -out    "vault-tls/${_n}-client.csr" \
                -subj   "/CN=${_s}" 2>/dev/null
            openssl x509 -req -days 3650 -sha256 \
                -in "vault-tls/${_n}-client.csr" \
                -CA vault-tls/client-ca.crt -CAkey vault-tls/client-ca.key -CAcreateserial \
                -out "vault-tls/${_n}-client.crt" \
                -extfile <(printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE" "$_s") 2>/dev/null
            rm -f "vault-tls/${_n}-client.csr"
            if [ "$_n" = "falconone" ] || [ "$_n" = "cve-proxy" ]; then
                # falconone-api / coderaft-cve-proxy run distroless nonroot
                # (uid 65532) — 600 would be unreadable. See update.ps1 for
                # the same fix.
                chmod 644 "vault-tls/${_n}-client.crt" "vault-tls/${_n}-client.key"
            else
                chmod 600 "vault-tls/${_n}-client.crt" "vault-tls/${_n}-client.key"
            fi
        done
    else
        # Fallback: alpine container (no host openssl dep)
        local abs_tls_dir
        abs_tls_dir="$(cd vault-tls && pwd)"
        cat <<'SCRIPT' | docker run --rm -i -v "${abs_tls_dir}:/work" alpine:3.20 sh 2>&1
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
printf "subjectAltName=DNS:coderaft-vault,DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE" > /tmp/server.ext
openssl x509 -req -days 3650 -sha256 \
    -in vault.csr -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
    -out vault.crt -extfile /tmp/server.ext 2>/dev/null
rm -f vault.csr
for pair in "dashboard-api:dashboard-api.coderaft.local" "entraguard:entraguard.coderaft.local" "ravenscan:ravenscan.coderaft.local" "redfox:redfox.coderaft.local" "falconone:falconone.coderaft.local" "cve-proxy:cve-proxy.coderaft.local"; do
    n="${pair%%:*}"; s="${pair##*:}"
    openssl req -newkey rsa:2048 -nodes -sha256 -keyout "${n}-client.key" -out "${n}-client.csr" -subj "/CN=${s}" 2>/dev/null
    printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE" "$s" > /tmp/client.ext
    openssl x509 -req -days 3650 -sha256 -in "${n}-client.csr" -CA client-ca.crt -CAkey client-ca.key -CAcreateserial -out "${n}-client.crt" -extfile /tmp/client.ext 2>/dev/null
    rm -f "${n}-client.csr"
done
chmod 600 *.key 2>/dev/null || true
# falconone-api / coderaft-cve-proxy nonroot fix — see rationale above.
chmod 644 falconone-client.key falconone-client.crt 2>/dev/null || true
chmod 644 cve-proxy-client.key cve-proxy-client.crt 2>/dev/null || true
SCRIPT
    fi

    # FalconOne relay signal-server key (mint-on-boot pattern).
    # falconone-relay mounts certs/falconone-signal-server.key → /keys/.
    # If the host path is absent, Docker creates a directory → fatal
    # "signal server key: is a directory". Pre-create an empty file so
    # the relay can mint the Ed25519 key on first boot.
    mkdir -p certs
    if [ -d "certs/falconone-signal-server.key" ]; then
        rm -rf "certs/falconone-signal-server.key"
    fi
    [ -f "certs/falconone-signal-server.key" ] || touch "certs/falconone-signal-server.key"

    # FalconOne agents mTLS PKI (falconone-tls/) — bug #170. See
    # _falconone_tls_bootstrap definition above for the extended-SAN +
    # self-heal logic (this call covers first-time provisioning; the
    # unconditional call after this migration block covers already-migrated
    # installs).
    _falconone_tls_bootstrap "${INSTALL_DIR}"

    # vault config.yaml — correct cert file paths (vault.crt / client-ca.crt)
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

    # B11 fix: correct ACL field names (name, cert_san, permissions)
    cat > vault-config/acl.yaml << 'ACLEOF'
# coderaft-vault ACL — field names: name, cert_san, permissions (NOT san/role/allow)
clients:
  - name: dashboard-api
    cert_san: "dashboard-api.coderaft.local"
    permissions: ["*"]
  - name: entraguard
    cert_san: "entraguard.coderaft.local"
    permissions: ["read:azure_*","read:license_key","read:entraguard_*","read:platform/identity/oidc"]
  - name: ravenscan
    cert_san: "ravenscan.coderaft.local"
    permissions: ["read:ravenscan_*","read:neo4j_*","read:license_key","read:platform/identity/oidc"]
  - name: redfox
    cert_san: "redfox.coderaft.local"
    permissions: ["read:redfox_*","read:license_key","read:platform/identity/oidc"]
  - name: falconone
    cert_san: "falconone.coderaft.local"
    permissions: ["read:license_key","read:falconone_*","read:platform/identity/oidc","sign:falconone_agent_cert","read:falconone/nvd_api_key","read:falconone/audit_hmac_key","write:falconone/audit_hmac_key","read:falconone/pki/agents-ca/cert","read:pki/falconone-agents-ca*","write:pki/falconone-agents-ca*"]
  - name: cve-proxy
    cert_san: "cve-proxy.coderaft.local"
    permissions: ["read:cve-proxy/*", "write:cve-proxy/*"]
ACLEOF
    chmod 600 vault-config/acl.yaml
}

# ── FalconOne mTLS PKI + ACL self-heal (#170 / #172) ─────────────────────────
# Runs unconditionally on EVERY update, independent of the one-time vault
# migration gate above, so already-migrated installs (_VAULT_NEEDS_MIGRATION
# = 0) still get the extended-SAN falconone-tls cert and any missing ACL
# permissions healed.
_falconone_tls_bootstrap "${INSTALL_DIR}"
_falconone_acl_selfheal "${INSTALL_DIR}/vault-config/acl.yaml"

# ── cve-proxy vault client cert + ACL self-heal ──────────────────────────────
# coderaft-cve-proxy is a shared platform sidecar, not tied to any single
# product license — self-healed unconditionally, same as falconone above.
# (Mirrors install.sh; was previously missing here, so updates never grew
# the cve-proxy client cert/ACL entry on already-bootstrapped installs.)
_vault_client_cert_selfheal "falconone" "falconone.coderaft.local"
_vault_client_cert_selfheal "cve-proxy" "cve-proxy.coderaft.local"
_cveproxy_acl_selfheal "${INSTALL_DIR}/vault-config/acl.yaml"

# ── Banking-grade plaintext .env handling ──────────────────────────────────
# B-PLAINTEXT-PURGE (2026-06-14): The previous block deleted .env when an
# encrypted .env.enc was present AND matched. Looks "banking-grade" but
# breaks the platform: docker-compose v2 reads only .env (plaintext) for
# variable substitution — it does NOT decrypt .env.enc. Purging on this
# update left POSTGRES_PASSWORD / REDIS_PASSWORD / DASHBOARD_SECRET /
# HOST_PROJECT_DIR empty → redis healthcheck failed (no AUTH) → every
# dependent service refused to start. Liam had to manually restore from
# the backup .bak to recover.
#
# The real "no plaintext at rest" goal needs an init container or a
# vault-backed secrets driver (planned in #16 audit bancaire). Until that
# is shipped, .env stays on disk with mode 0600 — file-system-level
# protection — and .env.enc remains the authoritative audit-trail copy.
echo ""
echo "  Banking-grade secret check..."
if [ -f "$INSTALL_DIR/.env" ]; then
    chmod 600 "$INSTALL_DIR/.env" 2>/dev/null || true
    if [ -f "$INSTALL_DIR/.env.enc" ]; then
        # Belt-and-braces: keep a daily snapshot of the plaintext so an
        # operator-side mistake can be reverted within 24h.
        BAK_DIR="$INSTALL_DIR/dashboard_data"
        mkdir -p "$BAK_DIR"
        BAK_FILE="$BAK_DIR/env-snapshot-$(date +%Y%m%d).bak"
        if [ ! -f "$BAK_FILE" ]; then
            cp "$INSTALL_DIR/.env" "$BAK_FILE" 2>/dev/null || true
            chmod 600 "$BAK_FILE" 2>/dev/null || true
        fi
        find "$BAK_DIR" -name 'env-snapshot-*.bak' -mtime +7 -delete 2>/dev/null || true
        echo "  ✓ .env protected (chmod 600) + .env.enc audit copy + daily snapshot in $BAK_DIR"
    else
        echo "  ✓ .env protected (chmod 600)"
    fi
fi

# ── Host capture sanity check (Live Capture / Frame Analyzer) ─────────────
# When the operator picked native capture (CODERAFT_HOST_OS=windows|macos),
# Ravenscan expects a host daemon on 127.0.0.1:7777 reachable via
# host.docker.internal. We probe it from inside an alpine one-shot — if the
# probe fails we *warn* (never block: the host may simply be powered off
# during the update window, or the operator may not have run the wizard
# yet). The user can fix this from the dashboard's Setup → Live Capture tab.
echo ""
echo "  Live Capture sanity check..."
HOST_OS_VALUE=""
if [ -f .env ]; then
    HOST_OS_VALUE=$(grep -E '^\s*CODERAFT_HOST_OS\s*=' .env 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]' | xargs)
fi
case "$HOST_OS_VALUE" in
    windows|macos)
        # Curl --connect-timeout keeps the probe under 4s on offline hosts.
        if docker run --rm --add-host=host.docker.internal:host-gateway \
            curlimages/curl:8.10.1 -fsS --connect-timeout 3 --max-time 4 \
            "http://host.docker.internal:7777/health" >/dev/null 2>&1; then
            echo "  ✓ Native capture daemon reachable (CODERAFT_HOST_OS=$HOST_OS_VALUE)"
        else
            echo "  ⚠ CODERAFT_HOST_OS=$HOST_OS_VALUE but the native daemon is not answering on 127.0.0.1:7777."
            echo "     Frame Analyzer may show empty captures. Open the dashboard → Setup → Live Capture"
            echo "     to (re)install the host daemon. Continuing the update."
        fi
        ;;
    linux|"")
        # No-op: Linux uses the in-Docker sidecar; missing var = default behaviour.
        ;;
    *)
        echo "  ⚠ CODERAFT_HOST_OS='$HOST_OS_VALUE' is not a recognised value (windows|macos|linux). Ignored."
        ;;
esac

# ── Mandatory pre-update backup ───────────────────────────────────────────
# If pg_dump fails → block the update (no backup = no update).
echo ""
echo "  Pre-update backup..."
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/preupdate-${TIMESTAMP}.sql.gz"

if docker compose ps postgres --quiet 2>/dev/null | grep -q .; then
    # `< /dev/null` is CRITICAL: without it, `docker compose exec -T` inherits
    # stdin, and when the updater is launched via `curl … | bash`, stdin = pipe
    # containing the rest of the script that bash has not read yet. docker exec
    # drains those bytes → bash hits EOF prematurely and the script exits
    # silently after "Backup saved" (no error, no rollback).
    if docker compose exec -T postgres pg_dumpall -U coderaft < /dev/null 2>/dev/null | gzip > "$BACKUP_FILE"; then
        echo "  Backup saved: $BACKUP_FILE"
    else
        echo "  ERROR: pg_dump failed. Update cancelled (no backup = no update)."
        echo "  Check that the postgres container is healthy: docker compose ps"
        exit 1
    fi
else
    echo "  PostgreSQL not detected — backup skipped (dashboard without DB)."
fi

# ── Capture recovery snapshot via dashboard-api ───────────────────────────
echo "  Capturing recovery snapshot..."
if [ -n "$ADMIN_TOKEN" ]; then
    curl -fsS -X POST "$DASHBOARD_API/api/dashboard/recovery/snapshots" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -d '{"reason":"pre-update"}' > /dev/null \
        && echo "    Snapshot saved." \
        || echo "    Snapshot failed (auto-snapshot will run again at next deploy)."
else
    echo "    [warn] ADMIN_TOKEN not found — snapshot skipped."
    echo "    (set ADMIN_TOKEN env, or place token in $INSTALL_DIR/.env, /etc/coderaft/admin_token, ~/.coderaft/admin_token, or /run/secrets/admin_token)"
fi

# ── Compare digests before pulling ────────────────────────────────────────
# Avoids pulling unnecessarily when nothing has changed on GHCR.
# Fallback: if skopeo is missing, use docker pull --quiet + compare the ID.
echo ""
echo "  Checking for available updates..."

COMPOSE_ARGS=()
if [ -f "./docker-compose.override.yml" ]; then
    COMPOSE_ARGS=(-f ./docker-compose.yml -f ./docker-compose.override.yml)
fi
# Include vault override after migration so `up -d --remove-orphans` does
# not silently nuke the coderaft-vault container.
# B-VAULT-OVERRIDE-DUP (2026-06-10): only load the override when the main
# compose file does NOT already define `coderaft-vault:` — otherwise
# security_opt lists are concatenated and compose v2 rejects the merge.
if { [ -f "./docker-compose.vault.yml" ] || [ -f "./vault-data/.migrated" ]; } && \
   ! grep -Eq '^[[:space:]]*coderaft-vault:[[:space:]]*$' "./docker-compose.yml" 2>/dev/null; then
    if [ ${#COMPOSE_ARGS[@]} -eq 0 ]; then
        COMPOSE_ARGS=(-f ./docker-compose.yml)
    fi
    COMPOSE_ARGS+=(-f ./docker-compose.vault.yml)
fi

IMAGES_TO_UPDATE=()

while IFS= read -r img; do
    [ -z "$img" ] && continue
    # Fetch local digest (Image ID sha256:...)
    local_digest=$(docker inspect "$img" --format '{{.Id}}' 2>/dev/null || echo "missing")

    if [ "$local_digest" = "missing" ]; then
        echo "    $img: not present locally → will pull"
        IMAGES_TO_UPDATE+=("$img")
        continue
    fi

    # Try skopeo first (more reliable)
    if command -v skopeo &>/dev/null; then
        remote_digest=$(skopeo inspect "docker://$img" 2>/dev/null | grep -o '"Digest":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
    else
        # Fallback: dry-run pull (docker pull --quiet compares the image ID).
        # Tag the current image, pull, then compare IDs.
        remote_digest=""
    fi

    if [ -n "$remote_digest" ] && [ "$remote_digest" = "$local_digest" ]; then
        echo "    $img: up to date"
    else
        echo "    $img: update available"
        IMAGES_TO_UPDATE+=("$img")
    fi
done < <(docker compose "${COMPOSE_ARGS[@]}" config --images 2>/dev/null)

if [ ${#IMAGES_TO_UPDATE[@]} -eq 0 ]; then
    echo ""
    echo "  Everything is up to date. No action needed."
    echo ""
    exit 0
fi

echo ""
echo "  ${#IMAGES_TO_UPDATE[@]} image(s) to update."

# ── Refresh license keys (drift "superseded") ─────────────────────────────
# When the License Server resigns a license (e.g. feature added, extension,
# key rotation), the server returns 403 "License has been superseded by a
# newer version" for any request using the old key. The product-side fix
# prioritizes DB > env, but on a fresh deploy or after a volume reset, only
# the env key exists. So we refresh it here, in-place in
# docker-compose.override.yml, BEFORE `docker compose up`.
#
# Strategy: POST /api/licenses/validate with the local key; if the response
# contains a different `latest_license_key`, write it into the override
# (with a .bak backup). We never fail the update because of this (License
# Server down → continue with the local key; the runtime will handle 403).
refresh_license() {
    local env_var="$1"   # LICENSE_KEY / RAVENSCAN_LICENSE_KEY / REDFOX_LICENSE_KEY
    local override_file="$INSTALL_DIR/docker-compose.override.yml"
    local env_file="$INSTALL_DIR/.env"

    # Read current key from .env first (source of truth read by
    # dashboard-api), fall back to override.yml. This ensures we always
    # validate the OLDEST stale key that's still on disk and propagate the
    # refreshed value to all stores — even when override.yml was already
    # rotated by a previous run but .env wasn't.
    local current_key=""
    if [ -f "$env_file" ] && grep -qE "^[[:space:]]*${env_var}=" "$env_file"; then
        current_key=$(grep -E "^[[:space:]]*${env_var}=" "$env_file" \
            | head -1 \
            | sed -E "s/^[[:space:]]*${env_var}=//" \
            | tr -d '"' | tr -d "'" | xargs)
    fi
    if [ -z "$current_key" ] && [ -f "$override_file" ] && grep -qE "^[[:space:]]*-?[[:space:]]*${env_var}=" "$override_file"; then
        current_key=$(grep -E "^[[:space:]]*-?[[:space:]]*${env_var}=" "$override_file" \
            | head -1 \
            | sed -E "s/^[[:space:]]*-?[[:space:]]*${env_var}=//" \
            | tr -d '"' | tr -d "'" | xargs)
    fi
    [[ -z "$current_key" || "$current_key" == "UNCONFIGURED" ]] && return 0

    local server="${LICENSE_SERVER_URL:-https://license.coderaft.io}"
    local response
    response=$(curl -s --max-time 10 -X POST "${server}/api/licenses/validate" \
        -H "Content-Type: application/json" \
        -d "{\"license_key\":\"$current_key\"}" 2>/dev/null) || return 0
    [[ -z "$response" ]] && return 0

    local latest=""
    if command -v jq &>/dev/null; then
        latest=$(echo "$response" | jq -r '.latest_license_key // empty' 2>/dev/null)
    else
        latest=$(echo "$response" \
            | grep -oE '"latest_license_key"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | head -1 \
            | sed -E 's/.*"latest_license_key"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    fi

    if [[ -n "$latest" && "$latest" != "$current_key" ]]; then
        # 1. override.yml — replace ALL occurrences (entraguard-api +
        #    entraguard-worker may share the same key across services).
        cp "$override_file" "${override_file}.bak"
        awk -v var="$env_var" -v key="$latest" '
            {
                pat = "^[[:space:]]*-?[[:space:]]*" var "="
                if ($0 ~ pat) {
                    match($0, /^[[:space:]]*-?[[:space:]]*/)
                    pad = substr($0, 1, RLENGTH)
                    print pad var "=" key
                    next
                }
                print
            }
        ' "${override_file}.bak" > "$override_file"

        # 2. .env (host) — dashboard-api reads this directly, and compose
        #    interpolation pulls ${LICENSE_KEY} from here too. Without this
        #    sync, override.yml has the new key but dashboard-api keeps
        #    seeing the old one and license.json never refreshes.
        local env_file="$INSTALL_DIR/.env"
        if [ -f "$env_file" ] && grep -qE "^[[:space:]]*${env_var}=" "$env_file"; then
            cp "$env_file" "${env_file}.bak.$(date +%s)" 2>/dev/null || true
            awk -v var="$env_var" -v key="$latest" '
                {
                    pat = "^[[:space:]]*" var "="
                    if ($0 ~ pat) {
                        print var "=" key
                        next
                    }
                    print
                }
            ' "${env_file}" > "${env_file}.tmp" && mv "${env_file}.tmp" "${env_file}"
        fi

        # 3. .env.enc (sops) — re-encrypt if present so the next
        #    dashboard-api boot reads the fresh key from the encrypted
        #    source. Best-effort; banking-grade purge happens later.
        if [ -f "$INSTALL_DIR/.env.enc" ] && command -v sops >/dev/null 2>&1; then
            local age_key="${SOPS_AGE_KEY_FILE:-$INSTALL_DIR/.coderaft-age.key}"
            [ ! -f "$age_key" ] && [ -f "/etc/coderaft/age.key" ] && age_key="/etc/coderaft/age.key"
            if [ -f "$age_key" ] && [ -f "$INSTALL_DIR/.env" ]; then
                SOPS_AGE_KEY_FILE="$age_key" sops --encrypt --input-type dotenv --output-type dotenv "$INSTALL_DIR/.env" > "$INSTALL_DIR/.env.enc.tmp" 2>/dev/null \
                    && mv "$INSTALL_DIR/.env.enc.tmp" "$INSTALL_DIR/.env.enc" \
                    || rm -f "$INSTALL_DIR/.env.enc.tmp"
            fi
        fi

        echo "  🔄 License refreshed for ${env_var}"
        return 1  # signal: restart needed
    fi
    return 0
}

refresh_all_licenses() {
    echo ""
    echo "  ▶ Checking for license drift..."
    local restart_needed=0
    for var in LICENSE_KEY RAVENSCAN_LICENSE_KEY REDFOX_LICENSE_KEY; do
        refresh_license "$var" || restart_needed=1
    done
    if [ "$restart_needed" -eq 0 ]; then
        echo "  ✅ All licenses are up to date"
    else
        echo "  ⚠️  At least one license was refreshed; services will be restarted"
    fi
    return 0
}

refresh_all_licenses || true

# ── Renew local HTTPS certs if older than 80 days ─────────────────────────
# Preserve user-provided certs untouched. Only auto-renew the ones we
# generated (mkcert) before they hit mkcert's 825d expiry. Failure is
# non-fatal — the dashboard remains reachable on http://localhost:3000.
renew_local_https() {
    local cert="$INSTALL_DIR/caddy_certs/coderaft.local.pem"
    local key="$INSTALL_DIR/caddy_certs/coderaft.local-key.pem"
    [ -f "$cert" ] || return 0
    [ -f "$key" ]  || return 0
    if find "$cert" -mtime -80 2>/dev/null | grep -q .; then
        return 0
    fi
    if ! command -v mkcert &>/dev/null; then
        echo "  ⚠ mkcert absent — cannot renew local HTTPS certs (still valid until mkcert default 825d)."
        return 0
    fi
    echo "  Renewing local HTTPS cert (>80d old)…"
    mkcert \
        -cert-file "$cert" \
        -key-file  "$key" \
        coderaft.local "*.coderaft.local" localhost 127.0.0.1 ::1 >/dev/null 2>&1 \
        && chmod 600 "$key" \
        && echo "  ✓ Local HTTPS cert renewed" \
        || echo "  ⚠ Cert renewal failed — keeping previous cert"
}

renew_local_https || true

# ── AGGRESSIVE Docker image cache invalidation ────────────────────────────
# Docker Desktop multi-arch bug: when a new manifest list is pushed to GHCR,
# `docker pull` may report "Image is up to date" even though the local and
# remote digests differ. This is because Docker Desktop caches the
# tag→digest resolution.
#
# Fix: for each Coderaft image, stop the containers using it, force-untag
# AND remove the image by ID. The next pull is then forced to re-resolve
# the remote manifest list and actually download.
echo "  Aggressive Coderaft image cache invalidation..."
for img in "${IMAGES_TO_UPDATE[@]}"; do
    case "$img" in
        ghcr.io/liamj74/*)
            # 1. Stop containers running on this image
            container_ids=$(docker ps -q --filter "ancestor=$img" 2>/dev/null || true)
            if [ -n "$container_ids" ]; then
                docker stop $container_ids >/dev/null 2>&1 || true
                docker rm -f $container_ids >/dev/null 2>&1 || true
            fi
            # 2. Untag (releases the :latest name)
            docker rmi -f "$img" >/dev/null 2>&1 || true
            # 3. Also remove by ID (in case the image survives untagged)
            image_ids=$(docker images --format '{{.ID}}' "$img" 2>/dev/null || true)
            if [ -n "$image_ids" ]; then
                echo "$image_ids" | while read -r iid; do
                    [ -n "$iid" ] && docker rmi -f "$iid" >/dev/null 2>&1 || true
                done
            fi
            ;;
    esac
done

# ── Pull and recreate ─────────────────────────────────────────────────────
# Note: `--pull always` on `up` retried a per-service GHCR manifest check at
# redeploy time, which caused timeouts on slow connections. We now rely on
# the `docker rmi -f` + `docker compose pull` above to guarantee that the
# :latest tag points to the new image before `up`.
echo "  Downloading new images..."
docker compose "${COMPOSE_ARGS[@]}" pull \
    && docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate --remove-orphans

# ── Post-update healthcheck ───────────────────────────────────────────────
echo ""
echo "  Post-update health check..."
HEALTH_OK=1
HEALTH_URL="$DASHBOARD_API/api/health"

for i in $(seq 1 "$HEALTHCHECK_RETRIES"); do
    # -sS without -f: capture the HTTP code even on 4xx/5xx instead of an
    # exit code !=0 which would concatenate "0" (gave "5020" instead of "502").
    HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 500 ]; then
        echo "  Dashboard API healthy (HTTP $HTTP_CODE) after ${i} attempt(s)."
        HEALTH_OK=0
        break
    fi
    echo "  Attempt $i/$HEALTHCHECK_RETRIES — HTTP $HTTP_CODE. Waiting ${HEALTHCHECK_DELAY}s..."
    sleep "$HEALTHCHECK_DELAY"
done

if [ "$HEALTH_OK" -ne 0 ]; then
    echo ""
    echo "  ERROR: healthcheck failed after $HEALTHCHECK_RETRIES attempts."
    echo "  Triggering automatic rollback..."
    if [ -x "./rollback.sh" ]; then
        bash ./rollback.sh
    else
        echo "  rollback.sh not found. Manual rollback required."
        echo "  Command: docker compose down && docker compose up -d"
    fi
    exit 1
fi

# ── Post-update notification ──────────────────────────────────────────────
if [ -n "$ADMIN_TOKEN" ]; then
    curl -fsS -X POST "$DASHBOARD_API/api/platform/update/notify" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -d '{"status":"done","source":"update.sh"}' > /dev/null 2>&1 || true
fi

echo ""
echo "  Update successful! Dashboard: http://localhost:3000"
echo "  If something went wrong: ./rollback.sh"
echo "  (or: curl -fsSL https://install.coderaft.io/rollback | bash)"
