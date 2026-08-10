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

# ── F-037 (2026-07-31): installer self-integrity check (SHA256) ─────────────
# Goal: detect a script tampered with in transit or at rest between
# publication and execution (e.g. a MITM proxy, a compromised CDN edge, or a
# stale/corrupted cache rewriting the response to
# `curl https://install.coderaft.io/install.sh`) before a single command
# from this file runs.
#
# Mechanism: recompute this script's own SHA256 — excluding the
# EXPECTED_SHA256 line itself, to avoid the chicken-and-egg problem of a
# file needing to embed a hash of its own content — and compare it against
# the digest published at install.sh.sha256, a sidecar file served
# alongside this one but generated/updated independently (see
# scripts/generate-install-checksums.sh, run at every release cut).
# EXPECTED_SHA256 below is a secondary, embedded offline pin: a frozen
# snapshot of the hash taken at the same time as the last regeneration,
# used only as a fallback when the network fetch of the published digest
# fails outright (fully offline environment, endpoint down). Regenerate
# both together with scripts/generate-install-checksums.sh whenever this
# file changes — never edit either by hand.
#
# KNOWN LIMITATION (a structural bash limit, not a bug in this check): when
# this file is piped straight into an interpreter —
# `curl -fsSL https://install.coderaft.io/install.sh | bash`, this file's
# own documented usage at the top of this header — "$0" is literally the
# string "bash", not a path to this script's bytes, and stdin has already
# been consumed by bash parsing the script by the time this code runs. A
# script cannot read "itself" back out of a pipe once its interpreter has
# started consuming it. Under that invocation (and under process
# substitution, e.g. `bash <(curl ...)`) the check below degrades to a
# clear warning instead of silently pretending to protect the user. It IS
# fully effective for the safer download-then-run flow:
#   curl -fsSL https://install.coderaft.io/install.sh -o install.sh
#   bash install.sh          # self-checks against install.sh.sha256
# See deploy/docs/installer-integrity-verification.md for the full
# writeup, threat model, and the (separate, not-yet-scheduled) work needed
# to make the public `install.coderaft.io` endpoint actually serve this
# monorepo's install.sh/install.sh.sha256 at all — today it still proxies
# the legacy `coderaft-installer` repo.
EXPECTED_SHA256="78e6b7dd25189572428c605da781eeb6f1e8f747de16d7a36c465b805d9f704a"

# CODERAFT_INSTALL_SHA256_URL is overridable purely so this mechanism can be
# tested end-to-end against a throwaway local HTTP server instead of the
# live production endpoint (see deploy/docs/installer-integrity-verification.md,
# "Testing" section). Real installs never need to set it.
CODERAFT_INSTALL_SHA256_URL="${CODERAFT_INSTALL_SHA256_URL:-https://install.coderaft.io/install.sh.sha256}"

_coderaft_sha256_stdin() {
    if command -v sha256sum &>/dev/null; then
        sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 | awk '{print $1}'
    elif command -v openssl &>/dev/null; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        return 1
    fi
}

_coderaft_self_verify() {
    if [ -n "${SKIP_SELF_VERIFY:-}" ]; then
        echo "  ⚠ SKIP_SELF_VERIFY set — installer integrity check bypassed (dev only)." >&2
        return 0
    fi

    # "$0" only points to this script's real bytes when it was invoked as a
    # file (bash install.sh / sh install.sh / ./install.sh). Under a raw
    # pipe or process substitution it is "bash"/"sh"/a drained fd — not a
    # regular, re-readable file. See the KNOWN LIMITATION note above.
    if [ ! -f "$0" ] || [ ! -r "$0" ]; then
        echo "" >&2
        echo "  ⚠ Installer integrity check skipped: this script has no readable file" >&2
        echo "    path to hash (running from a pipe — see deploy/docs/" >&2
        echo "    installer-integrity-verification.md). For a verified install:" >&2
        echo "" >&2
        echo "      curl -fsSL https://install.coderaft.io/install.sh -o install.sh" >&2
        echo "      bash install.sh" >&2
        echo "" >&2
        return 0
    fi

    local actual
    actual="$(sed '/^EXPECTED_SHA256=/d' "$0" | _coderaft_sha256_stdin)" || actual=""
    if [ -z "$actual" ]; then
        echo "  ⚠ Installer integrity check skipped: no sha256sum/shasum/openssl available (or hashing failed) to check this script." >&2
        return 0
    fi

    local published=""
    published="$(curl -fsSL --max-time 10 "$CODERAFT_INSTALL_SHA256_URL" 2>/dev/null | tr -d '[:space:]')" || published=""

    local expected="$published"
    local source="install.sh.sha256 (network)"
    if [ -z "$expected" ]; then
        if [ -n "$EXPECTED_SHA256" ]; then
            expected="$EXPECTED_SHA256"
            source="embedded offline pin"
            echo "  ⚠ Could not reach ${CODERAFT_INSTALL_SHA256_URL} — falling back to the embedded offline pin." >&2
        else
            echo "  ⚠ Could not reach ${CODERAFT_INSTALL_SHA256_URL} and no embedded pin is set — skipping integrity check." >&2
            return 0
        fi
    fi

    if [ "$actual" != "$expected" ]; then
        echo "" >&2
        echo "  FATAL: installer integrity check failed" >&2
        echo "    computed (local) : ${actual}" >&2
        echo "    expected (${source}): ${expected}" >&2
        echo "" >&2
        echo "  This script's content does not match its published digest — it may" >&2
        echo "  have been tampered with in transit or at rest. Aborting." >&2
        echo "  Set SKIP_SELF_VERIFY=1 to bypass (development only)." >&2
        echo "" >&2
        exit 1
    fi

    echo "  ✓ Installer integrity verified (SHA256 matches ${source})"
}

_coderaft_self_verify

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

# ── install-config.env: install-time / public config, NEVER encrypted ──────
# Task #150 (2026-07-31): HOST_PROJECT_DIR / CODERAFT_HOST_OS / CODERAFT_HOST_ARCH
# are not secrets — they used to be written straight into .env, which then got
# swept into .env.enc by SOPS below, conflating install-time topology with real
# credentials (root cause referenced literally as #150 in dashboard-api's own
# comments). They now live in their own plaintext file, mode 600, that is
# NEVER passed to `sops --encrypt`. docker-compose interpolation reads it via
# `--env-file install-config.env --env-file .env` (see every `docker compose`
# invocation below and in start.sh/stop.sh/update.sh).
upsert_install_config() {
    local key="$1" val="$2"
    if [ -f install-config.env ] && grep -q "^${key}=" install-config.env 2>/dev/null; then
        grep -v "^${key}=" install-config.env > install-config.env.tmp \
            && printf '%s=%s\n' "$key" "$val" >> install-config.env.tmp \
            && mv install-config.env.tmp install-config.env
    else
        printf '%s=%s\n' "$key" "$val" >> install-config.env
    fi
    # Defense-in-depth: `> file.tmp && mv` creates file.tmp under the current
    # umask, not the original mode — belt-and-braces even though every call
    # site today already re-asserts chmod 600 right after.
    chmod 600 install-config.env 2>/dev/null || true
}

# Task #148 (2026-07-31): postgres migrates to Docker's native `secrets:` +
# POSTGRES_PASSWORD_FILE (the official postgres image already supports this)
# instead of a plaintext POSTGRES_PASSWORD= env var baked into Config.Env.
# Unlike `.env` (read client-side by the `docker compose` CLI process running
# INSIDE dashboard-api's own container — proven safe on a tmpfs, see the
# dashboard-api service's `tmpfs:` mount below), a compose `secrets: file:`
# source IS resolved by the actual Docker DAEMON as a literal bind-mount
# source (confirmed experimentally 2026-07-31: a secrets file living only on
# a container-internal tmpfs made `docker compose up` fail on the daemon side
# with "bind source path does not exist") — so this file MUST live on real,
# persistent, host-visible disk, same tree as docker-compose.yml itself.
# Written here (mirroring the .env bootstrap right below) so it already
# exists before the very first `docker compose up` — postgres's `secrets:`
# block would otherwise fail outright on a truly fresh install.
write_postgres_secret_file() {
    local pg_pw="$1"
    mkdir -p secrets
    chmod 700 secrets
    printf '%s' "$pg_pw" > secrets/postgres_password
    chmod 600 secrets/postgres_password
}

# Task #219 (2026-07-31, logical follow-up of #148 Phase 3): redis has no
# native `_FILE` env var convention like postgres's image does, but its
# entrypoint is a real shell (redis:7-alpine, unlike the distroless vault) —
# so `--requirepass` is read from this file via a `sh -c` command override
# instead (see the redis service block below). Same host-visible-disk
# constraint as postgres's secrets file: Compose's non-swarm `secrets: file:`
# is resolved by the Docker DAEMON itself.
write_redis_secret_file() {
    local redis_pw="$1"
    mkdir -p secrets
    chmod 700 secrets
    printf '%s' "$redis_pw" > secrets/redis_password
    chmod 600 secrets/redis_password
}

if [ -f ".env" ] && grep -q '^POSTGRES_PASSWORD=' .env 2>/dev/null; then
    # Existing install. Always (re)write HOST_PROJECT_DIR with the current
    # install dir — the location may have changed since the previous install,
    # and a stale or missing value breaks docker-compose interpolation
    # (warning + empty bind-mount path → dashboard-api cannot reach .env.enc
    # → fake "first run").
    touch install-config.env
    upsert_install_config HOST_PROJECT_DIR "${ABSOLUTE_INSTALL_DIR}"
    # Backfill CODERAFT_HOST_OS/ARCH from install-config.env if already there
    # (re-run of the new installer), else from .env (upgrade from a version
    # that still wrote them there), else from the OS/arch detected above.
    if grep -q '^CODERAFT_HOST_OS=' install-config.env 2>/dev/null; then
        :
    elif grep -q '^CODERAFT_HOST_OS=' .env 2>/dev/null; then
        upsert_install_config CODERAFT_HOST_OS "$(grep '^CODERAFT_HOST_OS=' .env | head -1 | cut -d= -f2-)"
        upsert_install_config CODERAFT_HOST_ARCH "$(grep '^CODERAFT_HOST_ARCH=' .env | head -1 | cut -d= -f2- || echo "${CODERAFT_ARCH}")"
    else
        upsert_install_config CODERAFT_HOST_OS "${CODERAFT_OS}"
        upsert_install_config CODERAFT_HOST_ARCH "${CODERAFT_ARCH}"
    fi
    # Strip any legacy copies from .env now that install-config.env is authoritative.
    if grep -qE '^(HOST_PROJECT_DIR|CODERAFT_HOST_OS|CODERAFT_HOST_ARCH)=' .env 2>/dev/null; then
        grep -vE '^(HOST_PROJECT_DIR|CODERAFT_HOST_OS|CODERAFT_HOST_ARCH)=' .env > .env.tmp \
            && mv .env.tmp .env
    fi
    chmod 600 .env install-config.env
    # Task #148: upgrade from a pre-#148 install never had secrets/postgres_password —
    # backfill it from the EXISTING .env value so postgres's `secrets:` block
    # (added by this version) resolves to the SAME password postgres already
    # has, instead of a fresh one that would mismatch the running cluster.
    if [ ! -f secrets/postgres_password ]; then
        write_postgres_secret_file "$(grep '^POSTGRES_PASSWORD=' .env | head -1 | cut -d= -f2-)"
        echo "  ✓ secrets/postgres_password backfilled from existing .env (task #148)"
    fi
    # Task #219: same backfill, redis.
    if [ ! -f secrets/redis_password ] && grep -q '^REDIS_PASSWORD=' .env 2>/dev/null; then
        write_redis_secret_file "$(grep '^REDIS_PASSWORD=' .env | head -1 | cut -d= -f2-)"
        echo "  ✓ secrets/redis_password backfilled from existing .env (task #219)"
    fi
    # Backward compat: legacy install without .env.enc — show warning in dashboard
    if [ ! -f "${AGE_KEY_LOCAL}" ] && [ ! -f "${AGE_KEY_PATH}" ]; then
        echo "  ⚠ Legacy install detected: no age key found."
        echo "    Secrets are currently stored as plaintext in .env."
        echo "    Run the Setup Wizard to migrate to encrypted .env.enc."
    fi
    echo "  ✓ Existing config preserved"
else
    echo "  Generating secrets..."
    PG_PASSWORD_BOOTSTRAP="$(gen_hex 24)"
    REDIS_PASSWORD_BOOTSTRAP="$(gen_hex 24)"
    cat > .env << ENVFILE
# CodeRaft Dashboard — $(date -u +"%Y-%m-%d")
POSTGRES_PASSWORD=${PG_PASSWORD_BOOTSTRAP}
REDIS_PASSWORD=${REDIS_PASSWORD_BOOTSTRAP}
DASHBOARD_SECRET=$(gen_hex 32)
RAVENSCAN_CAPTURE_TOKEN=$(gen_hex 32)
ENVFILE
    chmod 600 .env
    # Task #148: same value as .env's POSTGRES_PASSWORD above, materialized
    # as a standalone file for postgres's `secrets:`/POSTGRES_PASSWORD_FILE —
    # both must agree at the container's very first initdb.
    write_postgres_secret_file "${PG_PASSWORD_BOOTSTRAP}"
    unset PG_PASSWORD_BOOTSTRAP
    # Task #219: same idea, redis.
    write_redis_secret_file "${REDIS_PASSWORD_BOOTSTRAP}"
    unset REDIS_PASSWORD_BOOTSTRAP
    cat > install-config.env << CONFIGFILE
# CodeRaft — install-time / public config (NOT a secret, NEVER SOPS-encrypted)
# $(date -u +"%Y-%m-%d")
HOST_PROJECT_DIR=${ABSOLUTE_INSTALL_DIR}
CODERAFT_HOST_OS=${CODERAFT_OS}
CODERAFT_HOST_ARCH=${CODERAFT_ARCH}
CONFIGFILE
    chmod 600 install-config.env
    echo "  ✓ Secrets generated"
    echo "  ✓ install-config.env generated"
fi

# Every `docker compose` invocation from here on must read BOTH files —
# install-config.env (plaintext config) first, then .env (secrets) so a
# stray key collision (should never happen, see #150 var lists) resolves in
# favor of the secrets file. Order has no practical effect today since the
# two files are disjoint by construction.
COMPOSE_ENV_ARGS=(--env-file install-config.env --env-file .env)

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

    # ── Step 2: Generate mTLS PKI (D3) ──────────────────────────────────────
    # AUDIT-SECU-2026-08-04 (Vault H1 follow-up): this used to be "Step 2:
    # Compute BIP39 recovery phrase" / "Step 3: Display recovery phrase with
    # big warning" — a `docker run ... -mnemonic-from-key` call that NEVER
    # existed as a real coderaft-vault sub-command (confirmed against
    # cmd/coderaft-vault/main.go: the binary only accepts -config and
    # -health-check), always silently fell through to a raw key-fingerprint
    # placeholder, and displayed that under a banner claiming "This 24-word
    # phrase is the ONLY way to recover your vault" — factually false even
    # before this fix (the fingerprint isn't a recovery mechanism at all) and
    # doubly so now: coderaft-vault no longer reads vault-keys/age.key for
    # ANYTHING (keyprovider.NewAgeMasterKeyProvider() is stateless — see
    # coderaft-vault/internal/keyprovider). Removed entirely rather than
    # patched, per the "KNOWN FOLLOW-UP" this file already flagged in
    # vault_check_seal_state() above. vault-keys/age.key itself is still
    # generated (see Step 1) purely as this function's own "already
    # bootstrapped" idempotency marker — update.sh/vault_seed_bootstrap_secrets
    # key off its presence — but it is not, and was never really, a vault
    # recovery secret.
    #
    # The REAL recovery mechanism is the Shamir ceremony (POST /v1/init once
    # the vault container is actually running, POST /v1/unseal with a
    # threshold of the returned shares) — it cannot run yet at this point in
    # the script (the vault container doesn't exist until later). Once it is
    # up, vault_check_seal_state() below prints the exact commands and this
    # is also documented in deploy/docs/vault.md ("Init + unseal ceremony").
    echo ""
    echo "  ℹ Vault master key bootstrap complete (vault-keys/age.key)."
    echo "    This is NOT a vault recovery secret — coderaft-vault generates"
    echo "    its own master key internally and splits it into real Shamir"
    echo "    shares the first time an operator runs the init ceremony"
    echo "    (POST /v1/init) against the running container. This script will"
    echo "    print the exact commands once the vault is up. WRITE DOWN and"
    echo "    separately distribute every share when that happens — it is"
    echo "    the ONLY way to recover the vault; there is no other back door."
    echo ""

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
    _vault_client_cert "falconone"      "falconone.coderaft.local"
    _vault_client_cert "cve-proxy"      "cve-proxy.coderaft.local"

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
rm -f vault.csr /tmp/server.ext
for pair in "dashboard-api:dashboard-api.coderaft.local" \
            "entraguard:entraguard.coderaft.local" \
            "ravenscan:ravenscan.coderaft.local" \
            "redfox:redfox.coderaft.local" \
            "falconone:falconone.coderaft.local" \
            "cve-proxy:cve-proxy.coderaft.local"; do
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
    rm -f "${name}-client.csr" /tmp/client.ext
done
chmod 600 *.key 2>/dev/null || true
# falconone-api / coderaft-cve-proxy nonroot fix (distroless uid 65532).
chmod 644 falconone-client.key falconone-client.crt 2>/dev/null || true
chmod 644 cve-proxy-client.key cve-proxy-client.crt 2>/dev/null || true
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
    permissions: ["read:azure_*","read:license_key","read:entraguard_*","read:platform/identity/oidc"]

  - name: ravenscan
    cert_san: "ravenscan.coderaft.local"
    permissions: ["read:ravenscan_*","read:neo4j_*","read:license_key","read:platform/identity/oidc"]

  - name: redfox
    cert_san: "redfox.coderaft.local"
    permissions: ["read:redfox_*","read:license_key","read:platform/identity/oidc","read:platform/identity/graph-tools","read:redfox/connections/*","write:redfox/connections/*","delete:redfox/connections/*","read:redfox/k8s/*","write:redfox/k8s/*","delete:redfox/k8s/*"]

  - name: falconone
    cert_san: "falconone.coderaft.local"
    permissions: ["read:license_key","read:falconone_*","read:platform/identity/oidc","sign:falconone_agent_cert","read:falconone/nvd_api_key","read:falconone/audit_hmac_key","write:falconone/audit_hmac_key","read:falconone/pki/agents-ca/cert","read:pki/falconone-agents-ca*","write:pki/falconone-agents-ca*","read:falconone/scripts_ca*","write:falconone/scripts_ca*"]

  - name: cve-proxy
    cert_san: "cve-proxy.coderaft.local"
    permissions: ["read:cve-proxy/*", "write:cve-proxy/*"]
ACLEOF
    chmod 600 vault-config/acl.yaml

    echo "  ✓ Vault mTLS PKI generated"
    echo "    CA:      vault-tls/client-ca.crt"
    echo "    Server:  vault-tls/vault.{crt,key}"
    echo "    Clients: vault-tls/{dashboard-api,entraguard,ravenscan,redfox,falconone,cve-proxy}-client.{crt,key}"
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
    if [ "$name" = "falconone" ] || [ "$name" = "cve-proxy" ]; then
        # falconone-api / coderaft-cve-proxy run distroless nonroot
        # (uid 65532) — 600 would be unreadable. See update.sh for the same fix.
        chmod 644 "vault-tls/${name}-client.crt" "vault-tls/${name}-client.key"
    else
        chmod 600 "vault-tls/${name}-client.crt" "vault-tls/${name}-client.key"
    fi
}

# ── FalconOne agents mTLS PKI (#170) ─────────────────────────────────────────
# Distinct CA/leaf from the vault client PKI above: falconone-tls/agents-ca.crt
# is the pool of ClientCAs falconone-api trusts for inbound agent mTLS, and
# falconone-tls/server.crt is the leaf falconone-api presents on :8443 to its
# own Windows agents. Bug #170: server.crt's SAN only ever had
# [localhost, falconone-api] — remote agents connecting via
# https://<public-hostname>:8443/agent/v1 failed hostname verification.
# Self-healing: the CA is preserved if it already exists (regenerating it
# would break trust for any agent already enrolled); only the leaf is
# regenerated, and only when it's missing the "coderaft.local" SAN.
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
    rm -f server.csr /tmp/server.ext
fi
chmod 644 *.crt *.key 2>/dev/null || true
FOSCRIPT
        sed -i.tmp "s/__FO_SAN_LIST__/${fo_sans}/" "$fo_script_file" && rm -f "${fo_script_file}.tmp"
        docker run --rm -v "${fo_script_file}:/script.sh:ro" -v "${abs_fo_tls_dir}:/work" alpine:3.20 sh /script.sh 2>&1
        rm -f "$fo_script_file"
    fi
    echo "  ✓ FalconOne agents PKI written (SAN: ${fo_sans})"
}

# ── Backup rotation (security hardening, 2026-07-31) ─────────────────────────
# Every self-heal path below does `cp X X.bak-<timestamp>` before touching X
# (acl.yaml, and in update.sh also docker-compose.yml/override.yml). On a
# deployment that runs unattended for months/years across many install/update
# runs, these accumulate without bound. Keep only the $2 most recent (default
# 5) backups sharing $1's basename; delete anything older. Safe/idempotent:
# a no-op when there are $2 or fewer.
_rotate_backups() {
    local base_path="$1" keep="${2:-5}"
    local dir base
    dir="$(dirname "$base_path")"
    base="$(basename "$base_path")"
    ls -t "${dir}/${base}".bak-* 2>/dev/null | tail -n "+$((keep + 1))" | while IFS= read -r f; do
        rm -f -- "$f"
    done
}

# ── ACL self-heal: falconone entry/permissions (#172) ────────────────────────
# The static acl.yaml written by _vault_write_config only runs once (its
# caller, vault_bootstrap_tls, returns early when vault-tls already exists —
# see the "already exists — skipping" guards above). That means any install
# that provisioned vault before this fix shipped will never get the
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
        "read:falconone/scripts_ca*"
        "write:falconone/scripts_ca*"
    )

    local ts
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"

    if ! grep -qE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*falconone[[:space:]]*$' "$acl_path"; then
        cp "$acl_path" "${acl_path}.bak-${ts}"
        _rotate_backups "$acl_path"
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
      - "read:falconone/scripts_ca*"
      - "write:falconone/scripts_ca*"
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
    _rotate_backups "$acl_path"

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

# ── ACL self-heal: mantisstrike entry/permissions (Phase 1 platform wiring,
# same pattern as _falconone_acl_selfheal above) ─────────────────────────────
# The static acl.yaml written by _vault_write_config predates MantisStrike
# and has no `mantisstrike` entry — this self-heal is additive-only,
# idempotent, and safe on every install/update run (fresh installs included:
# it runs unconditionally right after vault_bootstrap, same as falconone's
# own self-heal). Permissions mirror the CURRENT real
# coderaft-vault/configs/acl.yaml (verified directly against that file,
# 2026-08-04) — deliberately NOT copying _vault_write_config's stale
# embedded template above, which still includes the since-removed (2026-07-
# 31) `read:license_key` grant.
_mantisstrike_acl_selfheal() {
    local acl_path="$1"

    if [ ! -f "$acl_path" ]; then
        echo "  [install] ACL self-heal: $acl_path not found — skipping (vault not provisioned yet)"
        return 0
    fi

    local required_perms=(
        "read:mantisstrike_*"
        "read:platform/identity/oidc"
        "read:platform/identity/graph-tools"
    )

    local ts
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"

    if ! grep -qE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*mantisstrike[[:space:]]*$' "$acl_path"; then
        cp "$acl_path" "${acl_path}.bak-${ts}"
        _rotate_backups "$acl_path"
        cat >> "$acl_path" <<'MANTISSTRIKEACL'

  - name: mantisstrike
    cert_san: "mantisstrike.coderaft.local"
    permissions:
      - "read:mantisstrike_*"
      - "read:platform/identity/oidc"
      - "read:platform/identity/graph-tools"
MANTISSTRIKEACL
        echo "  [install] Self-heal ACL: mantisstrike permissions updated (+${#required_perms[@]} added, entry created)"
        return 0
    fi

    local start_line end_line
    start_line=$(grep -nE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*mantisstrike[[:space:]]*$' "$acl_path" | head -1 | cut -d: -f1)
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
        echo "  [install] ACL mantisstrike already up-to-date"
        return 0
    fi

    cp "$acl_path" "${acl_path}.bak-${ts}"
    _rotate_backups "$acl_path"

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

    echo "  [install] Self-heal ACL: mantisstrike permissions updated (+${#missing[@]} added)"
}

# ── ACL self-heal: redfox connections/k8s vault-backed credentials ──────────
# Zero-Knowledge Credential Architecture Palier 1
# (coderaft-platform/docs/redfox-zero-knowledge-scoping.md): target
# connection credentials and k8s cluster auth data move from RedFox's own
# Postgres into this vault, under redfox/connections/* and redfox/k8s/*.
# Same additive-only, idempotent merge-into-existing-entry pattern as
# _falconone_acl_selfheal above — any install provisioned before this ships
# already has a "redfox" entry (it existed for platform/identity/oidc), so
# without this it would never gain the new permissions.
_redfox_acl_selfheal() {
    local acl_path="$1"

    if [ ! -f "$acl_path" ]; then
        echo "  [install] ACL self-heal: $acl_path not found — skipping (vault not provisioned yet)"
        return 0
    fi

    local required_perms=(
        "read:license_key"
        "read:redfox_*"
        "read:platform/identity/oidc"
        "read:platform/identity/graph-tools"
        "read:redfox/connections/*"
        "write:redfox/connections/*"
        "delete:redfox/connections/*"
        "read:redfox/k8s/*"
        "write:redfox/k8s/*"
        "delete:redfox/k8s/*"
    )

    local ts
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"

    if ! grep -qE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*redfox[[:space:]]*$' "$acl_path"; then
        cp "$acl_path" "${acl_path}.bak-${ts}"
        _rotate_backups "$acl_path"
        cat >> "$acl_path" <<'REDFOXACL'

  - name: redfox
    cert_san: "redfox.coderaft.local"
    permissions:
      - "read:license_key"
      - "read:redfox_*"
      - "read:platform/identity/oidc"
      - "read:platform/identity/graph-tools"
      - "read:redfox/connections/*"
      - "write:redfox/connections/*"
      - "delete:redfox/connections/*"
      - "read:redfox/k8s/*"
      - "write:redfox/k8s/*"
      - "delete:redfox/k8s/*"
REDFOXACL
        echo "  [install] Self-heal ACL: redfox permissions updated (+${#required_perms[@]} added, entry created)"
        return 0
    fi

    local start_line end_line
    start_line=$(grep -nE '^[[:space:]]*-[[:space:]]*name:[[:space:]]*redfox[[:space:]]*$' "$acl_path" | head -1 | cut -d: -f1)
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
        echo "  [install] ACL redfox already up-to-date"
        return 0
    fi

    cp "$acl_path" "${acl_path}.bak-${ts}"
    _rotate_backups "$acl_path"

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

    echo "  [install] Self-heal ACL: redfox permissions updated (+${#missing[@]} added)"
}

# ── ACL self-heal: cve-proxy entry (coderaft-cve-engine sidecar) ────────────
# Same additive-only, idempotent pattern as _falconone_acl_selfheal above —
# any install provisioned before this ships never gets the cve-proxy entry
# otherwise, since vault_bootstrap_tls's static acl.yaml write only runs once.
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
    _rotate_backups "$acl_path"
    cat >> "$acl_path" <<'CVEPROXYACL'

  - name: cve-proxy
    cert_san: "cve-proxy.coderaft.local"
    permissions:
      - "read:cve-proxy/*"
      - "write:cve-proxy/*"
CVEPROXYACL
    echo "  [install] Self-heal ACL: cve-proxy entry created"
}

# ── Vault client cert self-heal (any product whose cert was never generated,
# e.g. falconone/cve-proxy on installs provisioned before they shipped) ─────
# Additive-only: does nothing to certs that already exist. Requires the CA
# private key (vault-tls/client-ca.key) to still be present — deliberately
# does NOT attempt a full CA rotation (that's a separate, disruptive
# operation, not a self-heal). Silently no-ops with a clear message if the
# CA key is gone, rather than failing the whole install/update.
_vault_client_cert_selfheal() {
    local name="$1" san="$2"

    if [ -f "vault-tls/${name}-client.crt" ]; then
        return 0
    fi
    if [ ! -f vault-tls/client-ca.key ] || [ ! -f vault-tls/client-ca.crt ]; then
        echo "  [install] Cert self-heal: vault-tls/client-ca.key missing — cannot mint ${name}-client cert (needs a full CA rotation, not a self-heal)"
        return 0
    fi

    echo "  [install] Cert self-heal: generating vault-tls/${name}-client (was missing)"
    if command -v openssl &>/dev/null; then
        _vault_client_cert "$name" "$san"
    else
        local abs_tls_dir
        abs_tls_dir="$(cd vault-tls && pwd)"
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
                rm -f '${name}-client.csr' /tmp/client.ext
                if [ '${name}' = 'falconone' ] || [ '${name}' = 'cve-proxy' ]; then
                    chmod 644 '${name}-client.key' '${name}-client.crt'
                else
                    chmod 600 '${name}-client.key' '${name}-client.crt'
                fi
            " 2>&1
    fi
}

vault_bootstrap

# ── FalconOne mTLS PKI + ACL self-heal (#170 / #172) ─────────────────────────
# Always run, independent of vault_bootstrap's internal "already exists —
# skipping" guards, so a re-run of this installer on an existing install
# still gets the extended-SAN falconone-tls cert and any missing ACL
# permissions healed.
_falconone_tls_bootstrap "$PWD"
_falconone_acl_selfheal "vault-config/acl.yaml"

# ── MantisStrike vault client cert + ACL self-heal (Phase 1 platform wiring,
# same pattern as falconone above) ───────────────────────────────────────────
_vault_client_cert_selfheal "mantisstrike" "mantisstrike.coderaft.local"
_mantisstrike_acl_selfheal "vault-config/acl.yaml"

# ── RedFox connections/k8s vault-backed credentials ACL self-heal ───────────
# Zero-Knowledge Credential Architecture Palier 1 — see _redfox_acl_selfheal
# above. redfox's client cert already exists (provisioned for
# platform/identity/oidc), so no _vault_client_cert_selfheal call is needed
# here — only the ACL entry needs the new permissions.
_redfox_acl_selfheal "vault-config/acl.yaml"

# ── cve-proxy vault client cert + ACL self-heal ──────────────────────────────
# coderaft-cve-proxy is a shared platform sidecar (in front of the central
# coderaft-cve-engine), not tied to any single product license — self-healed
# unconditionally, same as falconone above.
_vault_client_cert_selfheal "falconone" "falconone.coderaft.local"
_vault_client_cert_selfheal "cve-proxy" "cve-proxy.coderaft.local"
_cveproxy_acl_selfheal "vault-config/acl.yaml"

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
#
# F-017 (seccomp, re-verified 2026-07-31): every service below relies on
# Docker's IMPLICIT default seccomp profile — deliberately NOT written as
# `security_opt: [seccomp=default]`. That literal string is NOT a Docker
# keyword; the daemon parses whatever follows `seccomp=` as a PATH to a
# custom profile JSON file, so `seccomp=default` fails outright with
# `opening seccomp profile (default) failed: open default: no such file or
# directory` (re-confirmed live against this exact Docker version,
# 2026-07-31 — a prior session hit and reverted the same mistake, this
# re-check just confirms it's still true rather than trusting the old
# note). Omitting `seccomp:` from `security_opt:` entirely is the correct
# way to keep the default profile; it is already a strong default (blocks
# ~44 dangerous syscalls including `mount`/`unshare`/`clone3` variants) and
# no service here has demonstrated a need to loosen or further restrict it —
# the one exception (`ravenscan-capture`, raw packet capture) explicitly
# opts OUT via `seccomp:unconfined` for documented libpcap syscall needs,
# see that service below.

services:
  # Caddy HTTPS reverse proxy.
  # TLS mode is env-driven (Setup Wizard → dashboard-api writes .env and
  # recreates this service):
  #   internal (default) — Caddy's own CA signs the cert (replaces mkcert,
  #                        2026-07). CA root lives in the caddy_data volume:
  #                        PRESERVE that volume or agents lose trust.
  #   wildcard           — customer cert uploaded to ./caddy_certs/
  #   acme               — Let's Encrypt (public deployments)
  caddy:
    image: caddy:2-alpine
    depends_on:
      dashboard: { condition: service_started }
    ports:
      # CADDY_BIND_ADDR is widened to 0.0.0.0 by the Exposure wizard step.
      - "${CADDY_BIND_ADDR:-127.0.0.1}:443:443"
      - "${CADDY_BIND_ADDR:-127.0.0.1}:80:80"
    environment:
      - CODERAFT_HOSTNAME=${CODERAFT_HOSTNAME:-coderaft.local}
      - CODERAFT_TLS_SITES=${CODERAFT_TLS_SITES:-coderaft.local, *.coderaft.local}
      - CADDY_TLS_MODE_ARGS=${CADDY_TLS_MODE_ARGS:-internal}
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
    # Phase 2 hardening (2026-07-31): verified live in a throwaway compose
    # project — caddy:2-alpine's default image runs as root and needs
    # exactly ONE capability back after `cap_drop: [ALL]` to keep binding
    # :80/:443 (both <1024): NET_BIND_SERVICE. No CHOWN/SETUID/SETGID needed
    # (unlike the `dashboard` nginx service below) — caddy doesn't fork a
    # privilege-dropped worker pool the way nginx's `user nginx;` directive
    # does. Confirmed a full boot + `curl` 200 still works with this exact
    # cap set.
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    # `/data`/`/config` stay the existing named volumes above (cert/state
    # persistence — do NOT tmpfs them, see the big comment atop this service
    # about CA trust). `/tmp` is the only additional writable path caddy
    # needs under a read_only root; verified live (autosave.json still wrote
    # to /data, no other FS errors in the log).
    read_only: true
    tmpfs: [/tmp]
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
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
      - LICENSE_SERVER_URL=https://license.coderaft.io
    # Security hardening (2026-07-31): DASHBOARD_SECRET removed from this
    # service's env — it was PURE DEAD CODE here. This "dashboard" container
    # is nginx serving a static Vite build (see repo root Dockerfile:
    # node build → nginx:1.27-alpine, no app server, no envsubst templating
    # of nginx.conf), it never reads any env var at runtime. Confirmed no
    # `process.env.DASHBOARD_SECRET` reference anywhere reachable from this
    # image before removing — dashboard-api (below) is the one that actually
    # resolves DASHBOARD_SECRET, and it does so from Coderaft Vault directly
    # (lib/session-auth.js), never from this env var either. Removing a
    # plaintext secret an image doesn't consume closes a `docker inspect`
    # exposure window at zero functional cost.
    # B-DASHBOARD-NET (2026-06-23): nginx inside this image proxies
    # /api/entraguard/, /api/ravenscan/, /api/redfox/ to the product
    # containers on coderaft-frontend / coderaft-backend.
    networks: [default, coderaft-frontend, coderaft-backend]
    security_opt: [no-new-privileges:true]
    # Phase 2 hardening (2026-07-31): verified live in a throwaway compose
    # project. This image's baked-in nginx.conf sets `user nginx;` — the
    # master process starts as root (this image sets no `USER`) and needs
    # CAP_CHOWN (to fix up `/var/cache/nginx/*_temp` ownership) + CAP_SETUID/
    # CAP_SETGID (to drop the worker processes to the `nginx` account) before
    # it can serve anything; confirmed `cap_drop: [ALL]` alone fails startup
    # with `chown("/var/cache/nginx/client_temp", 101) failed (1: Operation
    # not permitted)`, and adding exactly these 3 caps back fixes it (curl
    # 200 afterwards). No NET_BIND_SERVICE needed — this image only listens
    # on :3000 internally (confirmed via its own conf.d/coderaft.conf), never
    # a privileged port.
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    read_only: true
    tmpfs: [/tmp, /var/cache/nginx, /var/run]
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:3000/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
    restart: unless-stopped

  # F-003 (2026-06-21): ACL sidecar for the Docker socket. dashboard-api
  # talks through this instead of mounting /var/run/docker.sock directly,
  # so it cannot call POST /exec, /volumes, /secrets, /swarm.
  docker-proxy:
    image: tecnativa/docker-socket-proxy:0.3.0
    container_name: coderaft-docker-proxy
    environment:
      CONTAINERS: 1
      IMAGES: 1
      NETWORKS: 1
      SERVICES: 1
      TASKS: 1
      INFO: 1
      VERSION: 1
      POST: 1
      # F-003 follow-up (2026-07-16): VOLUMES=1 required so `docker compose up`
      # can read/create named volumes for the product services (confirmed
      # 2026-07-31: removing VOLUMES=1 in a throwaway compose project makes
      # `docker compose up` fail outright with "denied" on POST
      # /volumes/create for every named volume — postgres_data, redis_data,
      # vault_data, dashboard_data, etc. — so this stays required).
      #
      # CORRECTED (2026-07-31, was inaccurate): the comment that used to sit
      # here claimed a privileged `Binds:[/:/host]` mount via POST
      # /containers/create was "still blocked" by this proxy. That is FALSE —
      # docker-socket-proxy (tecnativa/docker-socket-proxy) authorizes purely
      # by HTTP method + URL path (its ACL categories are things like
      # CONTAINERS/POST/VOLUMES), never by inspecting the JSON BODY of the
      # request. With POST=1 and CONTAINERS=1 already set (required for
      # `docker compose up` to create ANY container), a POST
      # /containers/create carrying `HostConfig.Binds:["/:/host"]` sails
      # through this proxy exactly like a normal container-create call — the
      # bind-mount privilege escalation is a property of what's IN the
      # request, which this proxy does not look at.
      #
      # Residual risk this creates: dashboard-api's OWN `/host-compose` mount
      # (see the dashboard-api service below) is a READ-WRITE bind of this
      # entire install directory, and dashboard-api legitimately WRITES
      # docker-compose.override.yml there itself (generateOverrideToDir(),
      # to add/remove product containers per license). If dashboard-api were
      # ever compromised (RCE in the Node process), the attacker already has
      # everything needed to add a malicious `Binds:["/:/host"]` (or worse)
      # to that override file and then trigger `docker compose up` through
      # this exact proxy — which would honor it, since POST/CONTAINERS/
      # VOLUMES are already granted for the legitimate deploy/update/rollback
      # flows. This is NOT a new hole introduced by this proxy; it is an
      # inherent consequence of dashboard-api being the thing that actually
      # authors and executes compose plans for this platform — closing it
      # completely would require a full compose-plan validator (parse the
      # generated YAML, allow-list volume sources/binds before ever handing
      # it to `docker compose up`) that does not exist today and is
      # deliberately OUT OF SCOPE for this pass (real engineering effort, not
      # a config tweak — tracked as a follow-up, not silently accepted as
      # "fine"). What IS mitigated below: the broad `.:/host-compose` bind no
      # longer redundantly exposes vault-keys/vault-tls/.coderaft-age.key
      # (see the dashboard-api service's `tmpfs:` entries) — shrinking what
      # an RCE in dashboard-api can reach, without touching the
      # deploy/update/rollback-critical override-file write path itself.
      VOLUMES: 1
      # F-003 follow-up 2 (2026-07-22): `docker compose pull` on a multi-arch
      # image (mandatory for every Coderaft product image) queries
      # GET /distribution/{name}/json to resolve the manifest for the local
      # platform BEFORE pulling. That endpoint is its own ACL category in
      # docker-socket-proxy — gated purely by GET, independent of POST — so
      # without it every per-product update failed with
      # "docker compose failed (code 1): denied" even though IMAGES=1 and
      # POST=1 were already set. Read-only manifest metadata, same exposure
      # class as IMAGES=1: no RCE surface, EXEC/SECRETS/SWARM/NODES stay 0.
      DISTRIBUTION: 1
      EXEC: 0
      SECRETS: 0
      SWARM: 0
      NODES: 0
      ALLOW_START: 1
      ALLOW_STOP: 1
      ALLOW_RESTARTS: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      # F-014 (2026-07-31): a prior session's note ("read_only:true shadows
      # haproxy template") had given up on read_only for this service — its
      # docker-entrypoint.sh templates /usr/local/etc/haproxy/haproxy.cfg
      # from the ACL env vars above at every boot, `sed`-ing it from a
      # `haproxy.cfg.template` file baked into the SAME directory. A plain
      # `tmpfs:` mount there (always empty, unlike a named volume) wipes that
      # template out from under it — confirmed live: `sed: ... .template: No
      # such file or directory`. A NAMED VOLUME instead of tmpfs fixes it:
      # Docker copies the image's existing directory contents (including the
      # template) into an empty named volume on first mount, so the template
      # survives and the entrypoint can still write haproxy.cfg alongside it.
      # Verified live end-to-end: proxy started clean, and a real
      # `GET /version` through it returned 200 with genuine Docker Engine
      # version info.
      - docker_proxy_haproxy_cfg:/usr/local/etc/haproxy
    networks:
      - docker-proxy-net
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [CHOWN, SETGID, SETUID, NET_BIND_SERVICE]
    read_only: true
    tmpfs: [/tmp, /var/run]
    mem_limit: 128m
    memswap_limit: 128m
    mem_reservation: 32m
    cpus: 0.5
    restart: unless-stopped

  dashboard-api:
    image: ghcr.io/liamj74/coderaft-dashboard-api:latest
    networks:
      - default
      - coderaft-vault-net
      - docker-proxy-net
      # B-BACKEND-NET (2026-07-16): postgres + redis live on the isolated
      # coderaft-backend network (see PR #12). Without joining this net,
      # dashboard-api resolves `postgres` to nothing and every DB call
      # throws `getaddrinfo EAI_AGAIN postgres`.
      - coderaft-backend
    # B-IPV6-KILL (2026-07-22): Docker Desktop on Windows/macOS gives the
    # container an IPv6 stack with no upstream route; some libraries still
    # `dns.lookup({family:6})` despite NODE_OPTIONS. Kill IPv6 at the sysctl
    # level so no lookup can even resolve to an AAAA — root-caused after
    # Entra callback surfaced ENETUNREACH on 2603:1027:*.
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=1
      - net.ipv6.conf.default.disable_ipv6=1
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
      docker-proxy: { condition: service_started }
    environment:
      # F-003 (2026-06-21): talk to Docker via the scoped proxy, not the raw
      # socket. Blocks POST /exec, /volumes, /secrets, /swarm.
      - DOCKER_HOST=tcp://docker-proxy:2375
      # B15 (2026-05-19): Node.js résout IPv6 d'abord par défaut. Le container
      # Docker n'a pas d'IPv6 → ENETUNREACH → fallback IPv4 lent ou timeout
      # sur les appels sortants (license.coderaft.io, login.microsoftonline.com).
      # Force IPv4-first.
      - NODE_OPTIONS=--dns-result-order=ipv4first
      - LICENSE_SERVER_URL=https://license.coderaft.io
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      # Security hardening (2026-07-31): DASHBOARD_SECRET removed — dead code
      # here too. dashboard-api's own process resolves it directly from
      # Coderaft Vault (lib/session-auth.js's resolveDashboardSecret(), with a
      # local-disk cache fallback), never from process.env.DASHBOARD_SECRET —
      # confirmed via a full grep of dashboard-api/ for real (non-comment)
      # reads before removing. The OTHER products (WolfGuard/Ravenscan/
      # RedFox/FalconOne) that verify JWTs signed with this same secret get
      # it from a Docker `secrets:` file now (dashboard-api's own compose
      # generation, generateOverrideToDir() — see #<security-hardening
      # 2026-07-31> for the full migration of the 7 remaining plaintext
      # secrets to files).
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
      # F-003: /var/run/docker.sock mount REMOVED — replaced by
      # tcp://docker-proxy:2375 over the docker-proxy-net network.
      - dashboard_data:/data
      - .:/host-compose
      # Age private key for SOPS decryption (legacy — kept for backward compat).
      # The installer creates the host file at .coderaft-age.key on first run.
      - ./.coderaft-age.key:/keys/age.key:ro
      # Vault mTLS client cert for dashboard-api (B12: correct filenames)
      - ./vault-tls/client-ca.crt:/vault-tls/client-ca.crt:ro
      - ./vault-tls/dashboard-api-client.crt:/vault-tls/dashboard-api-client.crt:ro
      - ./vault-tls/dashboard-api-client.key:/vault-tls/dashboard-api-client.key:ro
      # Security hardening (2026-07-31, docker-socket-proxy comment fix
      # follow-up): the broad `.:/host-compose` bind above gives dashboard-api
      # RW access to the ENTIRE install directory, redundantly including
      # vault-keys/ (unseal material), vault-tls/ (mTLS private keys) and
      # .coderaft-age.key (SOPS decryption key) — none of which
      # dashboard-api's own code ever reads via CONTAINER_COMPOSE_DIR/
      # /host-compose (confirmed via a full grep of server.js: it only
      # touches docker-compose*.yml, install-config.env, .env.enc, secrets/,
      # nginx-tls.conf, certbot/ under that path — it reads the real secrets
      # via the narrow, purpose-specific RO mounts above instead). Blanking
      # these three paths inside THIS container's view shrinks what an RCE
      # in dashboard-api can reach, at zero functional cost. Bind-mounting
      # /dev/null over a FILE works to blank it (reads as empty); tmpfs only
      # works over DIRECTORIES (verified: tmpfs on a file path fails outright
      # with "not a directory" — that's why .coderaft-age.key uses the
      # /dev/null bind below instead of a tmpfs entry). Verified
      # experimentally 2026-07-31 in an isolated throwaway compose project:
      # `ls /host-compose` still lists everything (docker-compose.yml,
      # secrets/, harmless files) with normal RW, `ls /host-compose/vault-keys`
      # and `/vault-tls` come back empty, `cat /host-compose/.coderaft-age.key`
      # returns nothing — while deploy/restart/rollback/backup (which only
      # ever touch the OTHER paths under /host-compose) are unaffected.
      - /dev/null:/host-compose/.coderaft-age.key
    # Task #148 (banking-grade runtime exposure reduction, 2026-07-31): the
    # *working* .env (resolved secret VALUES, passed to `docker compose
    # --env-file`) is written here instead of the persistent bind-mounted
    # /host-compose (the `.:/host-compose` volume above). tmpfs is private to
    # THIS container — wiped on every restart/recreate — and does NOT need to
    # be host-daemon-visible: the `docker compose` CLI runs INSIDE this same
    # container (docker-cli-compose baked into the image, talking to the
    # daemon over tcp://docker-proxy:2375), and --env-file is interpolated
    # client-side by that CLI process, never resolved by the daemon itself.
    # Confirmed experimentally 2026-07-31 in an isolated throwaway compose
    # project (see #148 report).
    tmpfs:
      - /run/coderaft-env:size=1m,mode=0700,uid=0
      # Shadow vault-keys/vault-tls inside the broad /host-compose bind — see
      # the long comment on the volumes: block above.
      - /host-compose/vault-keys:mode=0000,uid=0,size=1m
      - /host-compose/vault-tls:mode=0000,uid=0,size=1m
      # Phase 2 hardening (2026-07-31), added alongside `read_only: true`
      # below:
      #   - /tmp: dashboard-api's own server.js stages 3 things here via
      #     os.tmpdir() — the Ravenscan capture-host installer zip and the
      #     GPO/Intune CA-push zip (both small, a few MB) and, more
      #     importantly, the restic DISASTER-RECOVERY RESTORE scratch dir
      #     (`backup.js`'s `restore()`), which could be multi-gigabyte for a
      #     full platform restore. Rather than size a RAM-backed tmpfs to
      #     cover a worst-case multi-GB restore (risking host OOM under
      #     memory pressure instead of a clean ENOSPC), the two restore call
      #     sites (POST /api/dashboard/backup/restore-platform and
      #     /api/dashboard/backup/restore in server.js) were changed to
      #     target a scratch dir under the disk-backed `/data` volume
      #     instead of falling through to backup.js's own `/tmp` default —
      #     so this tmpfs only ever needs to hold the two small zips.
      #     512M is generous headroom for those.
      #   - /etc/coderaft: a SEPARATE, legacy local age-key generation path
      #     (AGE_KEY_PATH, unrelated to the vault-tls mTLS certs above)
      #     that self-heals with `mkdir -p /etc/coderaft && age-keygen` on
      #     boot if missing — confirmed live this fails with `ENOENT: no such
      #     file or directory, mkdir '/etc/coderaft'` under read_only without
      #     this tmpfs (and confirmed it succeeds fine once added). This key
      #     was already effectively ephemeral before this change too — no
      #     volume mounts /etc/coderaft today, so every container recreation
      #     already regenerated it from scratch even pre-read_only.
      #   - restic's own metadata cache (`RESTIC_CACHE_DIR`, backup.js) was
      #     ALSO redirected to `/data/.restic-cache` (disk-backed, not tmpfs)
      #     for the same reason as the restore scratch dir above — verified
      #     live that restic hard-fails ("unable to open cache: mkdir
      #     /root/.cache: read-only file system") without this, since this
      #     container runs as root with HOME=/root.
      - /tmp:size=512m
      - /etc/coderaft
    security_opt: [no-new-privileges:true]
    # F-011/F-014 (2026-07-31): verified live — a full boot (real /data +
    # /host-compose mounts, DASHBOARD_SECRET set) reached `listening on port
    # 3001` and GET /healthz → 200 unchanged with ALL caps dropped. No
    # cap_add needed (this image runs as root by design — Docker socket/CLI
    # access — but doesn't do any setuid/chown dance at its own startup).
    cap_drop: [ALL]
    read_only: true
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:3001/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    mem_limit: 1g
    memswap_limit: 1g
    mem_reservation: 256m
    cpus: 2
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
    #
    # F-004 re-verified (2026-07-31, Phase 2 hardening pass): core/vault/
    # Dockerfile's final stage IS already `gcr.io/distroless/static-debian12:
    # nonroot` with `USER nonroot:nonroot` (uid/gid 65532) — the image itself
    # defaults to non-root. This `user: "0:0"` override at the compose layer
    # is what actually forces it back to root at runtime, and that's
    # deliberate, not an oversight: `./vault-keys` (the age master key,
    # chmod 400) and `./vault-tls` (server/client certs+keys, chmod 600) are
    # HOST bind-mounts created by install.sh under whatever UID/permissions
    # invoked it (not necessarily root, not necessarily uid 65532 either) —
    # Docker bind-mounts pass host UID/GID through literally, with no
    # remapping unless userns-remap is enabled (F-038, separately deferred —
    # see STATUS.md, itself a stack-wide daemon change). Re-chowning those
    # host files to 65532 would need CAP_CHOWN on the INSTALLING user, which
    # a non-root `curl | bash` install does not have (chown to an arbitrary
    # UID is root-only on Linux) — so it can't be done generically across
    # every deployment shape this installer supports. Loosening the host
    # file permissions instead (group/world-readable) to let a non-root
    # container UID read them would weaken the actual host-level protection
    # of the vault's own master key, which is a worse trade than the current
    # one. This is the SAME conclusion two prior sessions reached for the
    # (now-migrated-away) legacy coderaft-vault repo — re-confirmed here
    # against the monorepo's actual Dockerfile + install.sh, not just
    # inherited from old notes. Left unchanged; `cap_drop: [ALL]` below is
    # the compensating control.
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
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
    restart: unless-stopped

  # ── coderaft-cve-proxy ───────────────────────────────────────────────────
  # Internal sidecar in front of the shared coderaft-cve-engine
  # (cve.coderaft.io): holds the ONE bearer key for this deployment (read
  # from vault at boot) and forwards CVE/KEV/EPSS/MSRC lookups from any
  # product on coderaft-backend. No host port published — reachable only as
  # coderaft-cve-proxy:8092 inside the docker network. Not tied to any
  # product license (shared platform service, like coderaft-vault).
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
      # ACCEPTED RESIDUAL RISK (security hardening pass, 2026-07-31): every
      # OTHER consumer of XPRODUCT_INTERNAL_TOKEN/DASHBOARD_SECRET/etc. in
      # this deployment was migrated to a Docker-native `secrets:` file (see
      # dashboard-api/server.js's generateOverrideToDir() + the shell
      # entrypoint.sh loaders / Go envOrFile() helpers in each product repo).
      # coderaft-cve-proxy could NOT be migrated the same way:
      #   1. Its source lives in a separate, currently-unmigrated repo not
      #      available in this monorepo — no code we can add native
      #      `_FILE`/`_PATH` support to.
      #   2. It already already reads this token straight off the vault at
      #      boot for its OWN bearer key ("holds the ONE bearer key for this
      #      deployment", per the comment above) — extending that same
      #      vault-mTLS read to XPRODUCT_INTERNAL_TOKEN instead of an env var
      #      is the RIGHT fix, but requires a code change in that other repo.
      #   3. It is a distroless static image (confirmed: `docker run
      #      --entrypoint sh ghcr.io/liamj74/coderaft-cve-proxy:latest` fails
      #      with "sh: executable file not found") — no shell-wrapper
      #      workaround is possible either.
      # Until cve-proxy's own repo adds vault-native or file-based reading of
      # this token, it stays a plaintext `environment:` value (visible via
      # `docker inspect`) — a real, deliberate, documented gap, not an
      # oversight.
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
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: coderaft
      # Task #148 (2026-07-31): migrated to Docker's native `secrets:` — the
      # official postgres image already supports POSTGRES_PASSWORD_FILE, so
      # the resolved value no longer appears in `docker inspect`/Config.Env.
      # The file is materialized by install.sh (first boot) and by
      # dashboard-api's generateOverrideToDir() (every subsequent regen) at
      # ./secrets/postgres_password — see the `secrets:` top-level block below.
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      POSTGRES_DB: coderaft
      POSTGRES_INITDB_ARGS: "--data-checksums"
    secrets:
      - postgres_password
    # F-025 (2026-07-31): restrict auth to scram-sha-256 only, and reject any
    # connection from outside the pinned coderaft-backend subnet
    # (172.28.42.0/24 — see the `coderaft-backend` network's `ipam:` config
    # below) at the pg_hba layer itself, not just Docker network isolation.
    # Verified live in a throwaway compose project: a peer container ON the
    # pinned subnet connects fine over scram-sha-256; a peer on a SEPARATE
    # docker network gets a hard `pg_hba.conf rejects connection ... no
    # encryption` — confirms the reject rule actually fires, not just that
    # the allow rule works.
    command:
      - postgres
      - -c
      - hba_file=/etc/postgresql/pg_hba.conf
      - -c
      - password_encryption=scram-sha-256
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./postgres/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
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
    # B-PRODUCT-DB-NET (2026-06-23): products (entraguard, ravenscan, redfox)
    # are added dynamically by dashboard-api and attached to coderaft-backend.
    # Without postgres also on that network their first DNS lookup of
    # "postgres" returns ENOENT and alembic migrations crash with
    # "Name or service not known".
    networks: [coderaft-backend]
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    mem_limit: 1g
    memswap_limit: 1g
    mem_reservation: 256m
    cpus: 2
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    # Task #219 (2026-07-31, logical follow-up of #148 Phase 3): redis has
    # no native `_FILE` env var convention like postgres's image does — read
    # the password from the mounted secrets file via a shell command
    # override instead (redis:7-alpine is a real shell image, unlike the
    # distroless vault). `user: "999:1000"` pins the container to the
    # image's own unprivileged `redis` account directly (its built-in
    # UID:GID) — the stock entrypoint only auto-drops root to that user for
    # its OWN default `redis-server ...` CMD path, and skips that step for
    # any other command (including this `sh -c` override), which would
    # otherwise silently run as root. No persistent volume is mounted for
    # this service, so there is no ownership/chown concern from bypassing
    # the image's startup fixup step.
    user: "999:1000"
    command: ["sh", "-c", "redis-server --requirepass \"$(cat /run/secrets/redis_password)\" --maxmemory 128mb"]
    healthcheck:
      test: ["CMD-SHELL", "redis-cli --no-auth-warning -a \"$(cat /run/secrets/redis_password)\" ping"]
      interval: 5s
      timeout: 5s
      retries: 5
    secrets:
      - redis_password
    # B-PRODUCT-DB-NET: same reason as postgres — product workers also
    # connect to redis://redis:6379 and must resolve the hostname.
    networks: [coderaft-backend]
    # F-011/F-014 (2026-07-31): verified live — PING/SET/BGSAVE all still
    # work with ALL caps dropped + read_only root + no extra tmpfs. redis:
    # 7-alpine's own Dockerfile declares `VOLUME /data` — Docker always gives
    # it a writable volume (anonymous here, since no explicit `/data` bind is
    # declared) regardless of the read_only root fs, which is what BGSAVE's
    # periodic RDB snapshot writes into; confirmed a manual `BGSAVE` still
    # says "Background saving started"/"DB saved on disk" under this config.
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    read_only: true
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
    restart: unless-stopped

networks:
  # Internal network for vault ↔ product communication. No external port.
  coderaft-vault-net:
    internal: true
  # F-003 (2026-06-21): private network for the docker-socket-proxy. Only
  # dashboard-api joins it — external access to the daemon stays impossible.
  docker-proxy-net:
    internal: true
  # B-PRODUCT-DB-NET: backend network shared by data services (postgres,
  # redis, neo4j) and the dynamically-deployed products.
  # F-025 (2026-07-31): subnet PINNED (not left to Docker's auto-allocation)
  # so postgres/pg_hba.conf below can hard-code the exact CIDR it trusts —
  # otherwise a stack teardown+recreate could get a different auto-assigned
  # subnet from Docker's pool and silently lock every product out of
  # Postgres. Chosen to avoid the common Docker default-pool range
  # (172.17-172.20.0.0/16, where `docker0`/other local stacks often already
  # sit — see the RAVENSCAN_HOST_PORT comment above re: spineart-traefik
  # collisions) and to not collide with this repo's OTHER already-used
  # ranges (coderaft-vault-net/docker-proxy-net/coderaft-frontend/default —
  # see update.sh / dashboard-api for any of those pinned similarly).
  coderaft-backend:
    ipam:
      config:
        - subnet: 172.28.42.0/24
  # B-DASHBOARD-NET: frontend network where the dashboard nginx and the
  # product HTTP listeners (entraguard-api, ravenscan, redfox-api) meet.
  coderaft-frontend: {}

volumes:
  postgres_data:
  dashboard_data:
  caddy_data:
  caddy_config:
  vault_data:
  # F-014 (2026-07-31): named volume (not tmpfs) so the docker-socket-proxy
  # image's baked-in haproxy.cfg.template survives under read_only:true —
  # see the docker-proxy service's `volumes:` comment above.
  docker_proxy_haproxy_cfg:

# Task #148 (2026-07-31): postgres's password, Docker-native file-based
# secret. Must be a real path resolvable by the Docker DAEMON itself (unlike
# .env's --env-file, this is a literal bind-mount source, not client-side
# interpolation) — ./secrets/postgres_password, relative to this file's
# directory (= --project-directory = HOST_PROJECT_DIR). Written by install.sh
# on first boot and kept in sync by dashboard-api's generateOverrideToDir().
secrets:
  postgres_password:
    file: ./secrets/postgres_password
  # Task #219 (2026-07-31): same idea, redis — see the redis service's
  # `secrets:`/`user:`/`command:` above and write_redis_secret_file() above.
  redis_password:
    file: ./secrets/redis_password
COMPOSE

# ── postgres/pg_hba.conf (F-025, 2026-07-31) ─────────────────────────────────
# scram-sha-256-only auth, restricted to the pinned coderaft-backend subnet
# (172.28.42.0/24 — see the `coderaft-backend` network's `ipam:` block in the
# docker-compose.yml heredoc above; the two MUST stay in sync, which is why
# both are hard-coded to the same literal here rather than one being derived
# from the other — this installer has no templating step between the two
# files). Verified in a throwaway compose project: a peer container on the
# pinned subnet connects fine; a peer on a different docker network gets a
# hard `pg_hba.conf rejects connection ... no encryption`.
#
# Idempotent — like vault_bootstrap()/Caddyfile below, only written if
# missing, so an operator's manual edits (e.g. adding a read replica's
# `hostssl replication ... cert` line) survive `update.sh` re-runs.
mkdir -p postgres
if [ ! -f postgres/pg_hba.conf ]; then
    cat > postgres/pg_hba.conf << 'PGHBA'
# Coderaft — managed by deploy/install.sh (F-025). scram-sha-256 only.
# TYPE    DATABASE  USER  ADDRESS           METHOD

# Unix socket (inside the postgres container itself, e.g. an operator
# `docker compose exec postgres psql`).
local     all       all                     scram-sha-256

# coderaft-backend Docker network only — every consumer (dashboard-api,
# entraguard-api/worker/beat, ravenscan, redfox-api/gateway, falconone-*)
# joins this network; nothing outside it can reach postgres:5432 at all
# (no host port is published), so this is defense-in-depth on top of that
# network-level isolation, not the only control.
host      all       all   172.28.42.0/24    scram-sha-256

# Default deny — anything that isn't the exact subnet above (e.g. a stray
# container mistakenly joined to more than one network) is rejected here,
# not silently allowed by falling through to a permissive default.
host      all       all   0.0.0.0/0         reject
host      all       all   ::/0              reject
PGHBA
    chmod 644 postgres/pg_hba.conf
fi

# ── Caddyfile (env-templated TLS: internal CA / wildcard / ACME) ─────────────
# The TLS mode is driven by env placeholders resolved at Caddy start:
#   CODERAFT_TLS_SITES   site list (apex only in ACME mode — HTTP-01 cannot
#                        issue wildcards)
#   CADDY_TLS_MODE_ARGS  "internal" | "/certs/wildcard.crt /certs/wildcard.key"
#                        | "<acme-contact-email>"
# dashboard-api (Setup Wizard → TLS step) updates .env and recreates caddy.
#
# Migration 2026-07: mkcert removed. A legacy Caddyfile referencing
# coderaft.local.pem is backed up and regenerated (the old mkcert certs in
# caddy_certs/ are simply ignored by the new template).
if [ -f Caddyfile ] && grep -q "coderaft.local.pem" Caddyfile 2>/dev/null; then
    echo "  Migrating legacy mkcert Caddyfile → Caddy internal CA (backup: Caddyfile.mkcert.bak)"
    mv Caddyfile Caddyfile.mkcert.bak
fi
if [ ! -f Caddyfile ]; then
    cat > Caddyfile << 'CADDY'
{
    # Admin API stays off (security). auto_https stays ON: Caddy manages the
    # certificate for the configured sites (internal CA by default).
    admin off
    servers {
        # Trust X-Forwarded-* from private-range proxies (Exposure step:
        # "external reverse proxy" mode).
        trusted_proxies static private_ranges
    }
}

# F-007 (2026-07-31): baseline security headers for every site block.
#
# F-036 (2026-07-31) evaluated and closed WITHOUT a code change to the CSP
# below — investigated live in a throwaway compose (caddy:2-alpine is
# actually v2.11.4; verified against caddyserver/caddy's tplcontext.go), not
# just the indicative snippet in REMEDIATION-PROMPT-2026-06-20.md:
#   - Caddy has NO built-in nonce template function (checked the real
#     http.handlers.templates function list: include/readFile/import/
#     httpInclude/stripHTML/markdown/env/placeholder/fileExists/httpError/
#     humanize/maybe/pathEscape — no `nonce`). A dynamic per-request nonce
#     would need a custom xcaddy build with a third-party plugin — real
#     ongoing maintenance cost for what `dashboard` is: a pure static Vite
#     SPA served by nginx (no per-request HTML generation at all — see the
#     comment on the `dashboard` service below), so there's no natural place
#     to even mint/thread a nonce server-side.
#   - Even if we had nonces, they only cover <script>/<style> ELEMENTS —
#     never a `style=""` ATTRIBUTE. That's the actual gap here: bundled
#     @xterm/xterm (RedFox SSH/RDP terminal sessions) calls
#     `element.setAttribute("style", ...)` for cell/selection highlighting,
#     confirmed present in the shipped bundle (grep dist/assets/*.js for
#     `_addStyle`/`setAttribute("style"`). Per the CSP spec (confirmed via
#     MDN), that call is blocked by style-src unless 'unsafe-inline' is
#     present — no nonce or hash can except a dynamically-set attribute.
#     Dropping 'unsafe-inline' from style-src would silently break every
#     RedFox terminal session. style-src is left as-is.
#   - script-src already has NO 'unsafe-inline' (shipped tonight in F-007)
#     and needed no change — but verifying it live (see "Vérification" in
#     the F-036 task) surfaced a real regression: apps/shell/index.html had
#     an inline <script> (dark/light theme pre-paint init) with no
#     nonce/hash, so Chrome was silently blocking it
#     ("script-src 'self'" refuses inline execution) — the pre-paint theme
#     class was never applied. Fixed by externalizing it to
#     apps/shell/public/theme-init.js (same-origin external file, no CSP
#     exception needed). Confirmed fixed: document.documentElement.className
#     was empty before, "light"/"dark" after, in the same throwaway compose.
#   - Separately discovered (NOT fixed here, flagged for its own ticket):
#     FalconOne Remote Assist's protobufjs Root (`hbb.RendezvousMessage` /
#     `hbb.NatType`, the RustDesk-compatible wire protocol, #139) builds its
#     message constructors via runtime `new Function(...)` codegen at module
#     load — this throws
#     "EvalError: ... 'unsafe-eval' is not an allowed source" under the
#     current script-src, every page load, independent of any user action.
#     This looks like a live break of Remote Assist signal/relay encoding
#     introduced by tonight's F-007 CSP. Needs either protobufjs static
#     codegen (`pbjs --target static-module`, no runtime eval) or a scoped
#     fix — NOT an "add unsafe-eval" fix, that would undo the hardening.
(coderaft_security) {
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "DENY"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
        Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'"
        Cross-Origin-Opener-Policy "same-origin"
        Cross-Origin-Resource-Policy "same-origin"
        -Server
        -X-Powered-By
    }
}

# Platform sites. TLS mode injected from .env by the Setup Wizard:
#   internal (default) — Caddy self-signed CA (root.crt downloadable from
#                        the dashboard: Setup → TLS → Download CA / GPO pack)
#   wildcard           — tls /certs/wildcard.crt /certs/wildcard.key
#   acme               — tls <email> (Let's Encrypt, public deployments)
{$CODERAFT_TLS_SITES:coderaft.local, *.coderaft.local} {
    import coderaft_security
    tls {$CADDY_TLS_MODE_ARGS:internal}
    reverse_proxy dashboard:3000 {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
    }
}

# HTTP → HTTPS redirect for the platform hostnames
http://{$CODERAFT_HOSTNAME:coderaft.local}, http://*.{$CODERAFT_HOSTNAME:coderaft.local} {
    redir https://{host}{uri} permanent
}

# Fallback: anything else (IP access, localhost) stays on plain HTTP and
# proxies to the dashboard. This keeps `http://localhost:3000` working
# transparently and avoids breaking existing flows.
:80 {
    import coderaft_security
    reverse_proxy dashboard:3000
}
CADDY
    echo "  ✓ Caddyfile generated (TLS: Caddy internal CA)"
fi

# ── Trust the active Caddy CA (mode-aware, #187) ────────────────────────────
# Caddy runs in one of 3 TLS modes (Setup Wizard TLS 3-modes, task #133):
#   (1) `tls internal`             → PKI root at /data/caddy/pki/authorities/local/root.crt
#   (2) `tls /certs/...pem <key>`  → mkcert / self-signed / setup-wizard leaf; the leaf
#                                    is the trust anchor for endpoint agents
#   (3) `tls email@example.com`    → Let's Encrypt; globally trusted, no export needed
# Detect the mode from the running Caddyfile and adapt. Failure is non-fatal
# (dashboard also serves the active CA + GPO push package: Setup → TLS).
trust_caddy_ca() {
    if [ "${CODERAFT_SKIP_HTTPS:-0}" = "1" ]; then
        echo "  CODERAFT_SKIP_HTTPS=1 — skipping CA trust setup"
        return 0
    fi

    # Detect the active TLS mode. task #187: this used to `cat` the running
    # Caddyfile and regex-match a literal `tls internal`/`tls /certs/...`/
    # `tls user@host` line -- but the Caddyfile itself only ever contains
    # the UNEXPANDED `tls {$CADDY_TLS_MODE_ARGS:internal}` placeholder on
    # disk (Caddy substitutes its own `{$VAR:default}` syntax internally at
    # config-parse time, it never rewrites the file), so every regex missed
    # on every install regardless of the actual mode. Read the same
    # CADDY_TLS_MODE_ARGS value install-config.env/.env actually set
    # instead of trying to out-guess Caddy's templating from the raw file.
    local tls_mode_args
    tls_mode_args="$(grep -h '^CADDY_TLS_MODE_ARGS=' install-config.env .env 2>/dev/null | tail -1 | cut -d= -f2-)"
    tls_mode_args="${tls_mode_args:-internal}"
    local tls_mode="unknown"
    if [ "$tls_mode_args" = "internal" ]; then
        tls_mode="internal"
    elif echo "$tls_mode_args" | grep -qE '^/certs/\S+\.(crt|pem)\s+/certs/\S+\.(key|pem)$'; then
        tls_mode="file"
    elif echo "$tls_mode_args" | grep -qE '^[a-zA-Z0-9._+-]+@\S+'; then
        tls_mode="letsencrypt"
    fi

    case "$tls_mode" in
        letsencrypt)
            echo "  Caddy TLS mode: Let's Encrypt (public trust — nothing to install)"
            return 0
            ;;
        file)
            # File-based cert: use the leaf on the host as the trust anchor.
            local leaf=""
            for c in certs/coderaft.local.pem certs/coderaft.pem certs/server.pem; do
                if [ -f "$c" ]; then leaf="$c"; break; fi
            done
            if [ -z "$leaf" ]; then
                echo "  ⚠ Caddy TLS mode 'file' detected but no active leaf cert found under ./certs/ — cannot install trust."
                return 1
            fi
            cp -f "$leaf" caddy-root.crt
            echo "  Caddy TLS mode: file ($(basename "$leaf") acts as trust anchor)"
            ;;
        internal)
            local ca_container_path="/data/caddy/pki/authorities/local/root.crt"
            echo "  Waiting for Caddy to generate its internal CA (max 30s)…"
            local i ca_ready=0
            for i in $(seq 1 15); do
                if docker compose "${COMPOSE_ENV_ARGS[@]}" exec -T caddy test -f "$ca_container_path" >/dev/null 2>&1; then
                    ca_ready=1
                    break
                fi
                sleep 2
            done
            if [ "$ca_ready" = "0" ]; then
                echo "  ⚠ Caddy internal CA not found after 30s — browsers will warn on https://coderaft.local."
                echo "    Download it later from the dashboard: Setup → TLS → Download CA."
                return 1
            fi
            if ! docker compose "${COMPOSE_ENV_ARGS[@]}" cp "caddy:${ca_container_path}" caddy-root.crt >/dev/null 2>&1; then
                echo "  ⚠ Could not export the Caddy root CA — skipping trust install."
                return 1
            fi
            ;;
        *)
            echo "  ⚠ Could not detect Caddy TLS mode from Caddyfile — skipping CA trust install."
            echo "    (task #187: report your Caddyfile so we can improve detection)"
            return 1
            ;;
    esac

    echo "  Installing the Coderaft root CA into the system trust store (may prompt for sudo)…"
    case "${CODERAFT_OS}" in
        macos)
            if sudo security add-trusted-cert -d -r trustRoot \
                -k /Library/Keychains/System.keychain caddy-root.crt >/dev/null 2>&1; then
                echo "  ✓ CA trusted (System keychain)"
            else
                echo "  ⚠ Could not add the CA to the System keychain — trust it manually:"
                echo "      sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-root.crt"
            fi
            ;;
        linux)
            if [ -d /usr/local/share/ca-certificates ] && command -v update-ca-certificates &>/dev/null; then
                if sudo cp caddy-root.crt /usr/local/share/ca-certificates/coderaft-caddy-root.crt >/dev/null 2>&1 \
                    && sudo update-ca-certificates >/dev/null 2>&1; then
                    echo "  ✓ CA trusted (update-ca-certificates)"
                else
                    echo "  ⚠ update-ca-certificates failed — trust caddy-root.crt manually."
                fi
            elif [ -d /etc/pki/ca-trust/source/anchors ] && command -v update-ca-trust &>/dev/null; then
                if sudo cp caddy-root.crt /etc/pki/ca-trust/source/anchors/coderaft-caddy-root.crt >/dev/null 2>&1 \
                    && sudo update-ca-trust >/dev/null 2>&1; then
                    echo "  ✓ CA trusted (update-ca-trust)"
                else
                    echo "  ⚠ update-ca-trust failed — trust caddy-root.crt manually."
                fi
            else
                echo "  ⚠ No known CA trust tool found — trust caddy-root.crt manually."
            fi
            echo "    Note: Firefox uses its own store — enable security.enterprise_roots.enabled."
            ;;
        *)
            echo "  ⚠ Unknown OS — trust caddy-root.crt manually."
            ;;
    esac
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

# Hosts entry no longer depends on mkcert certs — coderaft.local must resolve
# for the default (internal CA) TLS mode to be reachable by name.
ensure_hosts_entry || true

# Helper scripts
# Task #150: both env files are always passed explicitly — install-config.env
# (plaintext config) + .env (secrets, plaintext or SOPS-managed depending on
# migration state) — so compose interpolation never silently loses either.
cat > start.sh << 'EOF'
#!/bin/bash
echo "Starting CodeRaft..."
docker compose --env-file install-config.env --env-file .env up -d
if grep -q "coderaft.local" /etc/hosts 2>/dev/null; then
    echo "  Dashboard: https://coderaft.local"
else
    echo "  Dashboard: http://localhost:3000"
fi
EOF

cat > stop.sh << 'EOF'
#!/bin/bash
echo "Stopping CodeRaft..."
docker compose --env-file install-config.env --env-file .env down
echo "  Done."
EOF

curl -fsSL "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/update.sh" -o update.sh 2>/dev/null || cat > update.sh << 'EOF'
#!/bin/bash
echo "Updating CodeRaft..."
docker compose --env-file install-config.env --env-file .env pull && docker compose --env-file install-config.env --env-file .env up -d --force-recreate --remove-orphans
# Reconciliation pass (mirrors the fix in the real update.sh, B-OVERRIDE-RACE
# 2026-08-07): dashboard-api regenerates docker-compose.override.yml on its
# own boot as a self-heal for stale product lists, but that happens AFTER
# the 'up' above already computed its plan from the OLD file, so
# --remove-orphans can silently drop product containers with nothing left
# to bring them back. Wait for dashboard-api's own confirmation log line,
# then re-run 'up -d' (no --force-recreate) so anything the corrected
# override adds gets created without needlessly recreating what already
# runs.
for i in $(seq 1 30); do
    docker compose --env-file install-config.env --env-file .env logs dashboard-api 2>&1 | grep -q "override.yml refreshed for products:" && break
    sleep 2
done
docker compose --env-file install-config.env --env-file .env up -d
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

# ── Vault seal-state check (fresh install) ───────────────────────────────────
# B6/B7 fix: vault image is distroless — no shell, no wget. NEVER use
# `docker compose exec coderaft-vault sh -c`. Use a curlimages/curl sidecar
# on the coderaft-vault-net network with the dashboard-api client cert.
#
# AUDIT-SECU-2026-08-04 (Vault H1): coderaft-vault no longer auto-unseals and
# no longer treats vault-keys/age.key as a submittable "share" — unsealing
# now requires a REAL Shamir ceremony (default 3-of-5 shares, generated by
# the vault itself at POST /v1/init and never persisted anywhere), which by
# design NO unattended script can complete on its own. This function
# (formerly vault_unseal_fresh) therefore no longer attempts to unseal the
# vault — it only polls for reachability and prints the operator's next
# steps. A sealed vault after install is EXPECTED, not a failure: every
# product will show "vault unavailable" (fail-closed) until an operator
# completes the ceremony.
#
# RESOLVED (2026-08-04, deploy-scripts-no-autounseal follow-up): the
# vault_bootstrap() BIP39/mnemonic block this comment used to describe (fake
# "recovery phrase" banner, `-mnemonic-from-key` sub-command that never
# existed) has been removed outright — see vault_bootstrap()'s Step 2 above.
# vault-keys/age.key is still generated there purely as an idempotency
# marker; it is never read by the vault for anything. This function remains
# the single accurate source of ceremony instructions, printed once the
# vault container is actually reachable. Auto-running POST /v1/init inline
# during install (so a fresh install could display real shares immediately
# instead of waiting for the operator to run it separately afterwards) was
# considered and deliberately NOT done here — it would silently perform a
# security-critical, one-time-only action (a vault can only ever be
# initialized once) on every fresh install with no operator confirmation of
# WHO is present to receive which share, which cuts against the entire
# point of a multi-operator ceremony. Left as a possible future UX
# improvement, not a bug.
vault_check_seal_state() {
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

    if [ "$last_sealed" = "false" ]; then
        echo "  ✓ coderaft-vault is already initialized and unsealed"
        return 0
    fi

    echo ""
    echo "  ────────────────────────────────────────────────────────────────"
    echo "  Vault is SEALED. This is expected — Coderaft Vault requires a"
    echo "  real, human, multi-operator Shamir ceremony (default: 3 of 5"
    echo "  shares) before it will hold or serve ANY secret. No script can"
    echo "  complete this unattended, by design (AUDIT-SECU-2026-08-04)."
    echo ""
    echo "  An operator must run, from this directory:"
    echo ""
    echo "    # 1) ONE TIME ONLY per vault (skip if already run before):"
    echo "    docker run --rm --user 0:0 --network ${vault_network} \\"
    echo "      -v \"\$(cd vault-tls && pwd)\":/tls:ro curlimages/curl:latest \\"
    echo "      --cert /tls/dashboard-api-client.crt --key /tls/dashboard-api-client.key \\"
    echo "      --cacert /tls/client-ca.crt -sS -X POST https://coderaft-vault:8200/v1/init"
    echo "    # -> WRITE DOWN the returned shares, one per operator, then:"
    echo ""
    echo "    # 2) EVERY time the vault starts sealed (every restart/reboot):"
    echo "    docker run --rm --user 0:0 --network ${vault_network} \\"
    echo "      -v \"\$(cd vault-tls && pwd)\":/tls:ro curlimages/curl:latest \\"
    echo "      --cert /tls/dashboard-api-client.crt --key /tls/dashboard-api-client.key \\"
    echo "      --cacert /tls/client-ca.crt -sS -X POST https://coderaft-vault:8200/v1/unseal \\"
    echo "      -H 'Content-Type: application/json' -d '{\"shares\":[\"<share1>\",\"<share2>\",\"<share3>\"]}'"
    echo ""
    echo "  Until this runs, every product shows \"vault unavailable\" — that"
    echo "  is fail-closed behavior, not a crash."
    echo "  ────────────────────────────────────────────────────────────────"
    echo ""
    return 1
}

# ── Vault bootstrap-secrets seeding (fresh install race fix) ────────────────
# Task #218 (2026-07-31): this script generates POSTGRES_PASSWORD/
# REDIS_PASSWORD/DASHBOARD_SECRET/RAVENSCAN_CAPTURE_TOKEN above (either fresh,
# or preserved from a previous run — see the .env generation block) and
# secrets/postgres_password is what postgres's OWN initdb actually uses.
# Coderaft Vault, however, had no seed at all until now: dashboard-api's
# vaultEnsure() (generateOverrideToDir(), the Coderaft Vault client since
# #149) is the FIRST thing to ever write these keys into the vault, and it
# only runs later — at the first product deploy, well after this script has
# exited — on a truly fresh install. Finding the vault empty at that point,
# it happily mints its OWN independent random value instead of reusing what
# postgres/redis/the dashboard JWT signer were actually bootstrapped with.
#
# Confirmed experimentally 2026-07-31 (isolated test stack, distinct compose
# project, never the live "coderaft" stack): after a fresh install.sh run,
# Coderaft Vault's postgres_password key was completely absent while
# secrets/postgres_password already held the real value used for postgres's
# initdb; simulating vaultEnsure()'s own generator (crypto.randomBytes(24)
# .toString("hex")) against the empty key produced a DIFFERENT value, exactly
# the divergence this function exists to prevent.
#
# Fix: install.sh becomes the FIRST writer. Called right after the vault is
# up and unsealed, BEFORE postgres (or any other service) starts — so
# Coderaft Vault is always the single, unique source of truth from the very
# first second, never a second independent generator.
#
# get-or-set semantics (never overwrite an existing vault value): mirrors
# vaultEnsure()'s own behavior and update.sh's _vault_set/_vault_get
# migration pattern. This keeps the function idempotent and safe to run on
# every install.sh invocation, including a re-run against an EXISTING
# install where the operator may have already rotated one of these secrets
# via the dashboard (Coderaft Vault holds the rotated value; blindly
# overwriting it with the stale local .env copy would silently undo that
# rotation).
vault_seed_bootstrap_secrets() {
    local vault_age_key="vault-keys/age.key"
    if [ ! -f "$vault_age_key" ]; then
        echo "  ✗ vault-keys/age.key not found — cannot seed vault" >&2
        return 1
    fi

    local vault_project
    vault_project=$(docker inspect coderaft-coderaft-vault-1 \
        --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
    [ -z "$vault_project" ] && vault_project="coderaft"
    local vault_network="${vault_project}_coderaft-vault-net"

    local abs_tls_dir
    abs_tls_dir="$(cd vault-tls && pwd)"

    _vault_curl_seed() {
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

    local seed_failed=0
    local pair env_key vault_key val existing resp
    for pair in \
        "POSTGRES_PASSWORD:postgres_password" \
        "REDIS_PASSWORD:redis_password" \
        "DASHBOARD_SECRET:dashboard_secret" \
        "RAVENSCAN_CAPTURE_TOKEN:ravenscan_capture_token"; do
        env_key="${pair%%:*}"
        vault_key="${pair##*:}"
        val=$(grep "^${env_key}=" .env 2>/dev/null | head -1 | cut -d= -f2-)
        if [ -z "$val" ]; then
            continue
        fi
        existing=$(_vault_curl_seed "POST" "/v1/secret/get" "{\"name\":\"${vault_key}\"}")
        if echo "$existing" | grep -q '"value"[[:space:]]*:'; then
            # Already seeded — either by this exact function on a previous
            # run, or since rotated by the operator via the dashboard. Never
            # overwrite: Coderaft Vault is the sole source of truth once set.
            echo "  ✓ ${vault_key} already present in Coderaft Vault (left untouched)"
            continue
        fi
        resp=$(_vault_curl_seed "POST" "/v1/secret/set" "{\"name\":\"${vault_key}\",\"value\":\"${val}\"}")
        if echo "$resp" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
            echo "  ✓ Seeded ${vault_key} in Coderaft Vault"
        else
            echo "  ✗ Failed to seed ${vault_key} in Coderaft Vault: ${resp}" >&2
            seed_failed=1
        fi
    done
    return $seed_failed
}

if [ "${CODERAFT_TEST_MODE:-0}" = "1" ]; then
    echo ""
    echo "  [CODERAFT_TEST_MODE] Skipping docker compose pull and up"
    echo "  Compose YAML and vault PKI validated — test run complete."
else
    echo ""
    echo "  Pulling platform images..."
    if ! docker compose "${COMPOSE_ENV_ARGS[@]}" pull; then
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
    docker compose "${COMPOSE_ENV_ARGS[@]}" stop coderaft-vault 2>/dev/null || true
    docker compose "${COMPOSE_ENV_ARGS[@]}" rm -f coderaft-vault 2>/dev/null || true
    # Task #218 (2026-07-31): start coderaft-vault ALONE first — it must be
    # up, unsealed, AND seeded with the bootstrap secrets above (or already
    # holding them, on a re-run) BEFORE postgres/redis/dashboard-api are
    # created. Previously the whole stack (postgres included) started in one
    # shot here and unseal only happened afterwards, leaving a window where
    # nothing had ever told Coderaft Vault what value postgres's own initdb
    # was using — see vault_seed_bootstrap_secrets()'s header comment for the
    # full race and its confirmed real-world impact.
    if ! docker compose "${COMPOSE_ENV_ARGS[@]}" up -d coderaft-vault; then
        echo ""
        echo "  ✗ docker compose up coderaft-vault failed. Aborting install."
        echo "    Run 'docker compose logs coderaft-vault' to investigate."
        exit 1
    fi

    echo ""
    echo "  Checking vault seal state..."
    vault_check_seal_state || {
        echo "  ⚠ Vault is sealed — dashboard will show 'vault unavailable' until an"
        echo "    operator completes the ceremony printed above."
    }

    echo ""
    echo "  Seeding bootstrap secrets into Coderaft Vault..."
    vault_seed_bootstrap_secrets || {
        echo "  ⚠ Could not seed one or more bootstrap secrets into Coderaft Vault."
        echo "    dashboard-api will mint its own value(s) on first deploy, which"
        echo "    may then MISMATCH what postgres/redis were actually initialized"
        echo "    with. Re-run the installer once the vault is reachable, or seed"
        echo "    manually — see docs/vault.md."
    }

    # B-OVERRIDE-RACE (install-time variant, found 2026-08-08): a
    # docker-compose.override.yml left on disk from a prior install/dev run
    # can predate the current dashboard-api's ${HOST_PROJECT_DIR} compose-
    # variable convention for bind-mount sources — older generations wrote
    # the resolved (and here, empty-prefixed) host path literally, e.g.
    # falconone-relay's signal-server key mount ending up as the bare
    # `/certs/falconone-signal-server.key` instead of
    # `${HOST_PROJECT_DIR}/certs/falconone-signal-server.key`. Docker Desktop
    # then refuses that mount outright ("is not shared from the host and is
    # not known to Docker"), and since `docker compose up -d` with no
    # service filter computes its WHOLE plan from the override file as it
    # sits on disk before any container starts, the single call aborts
    # before dashboard-api — the only thing that regenerates this file categorically
    # correctly on boot (server.js bootstrap(), logs "override.yml refreshed
    # for products:") — ever gets a chance to fix it. Same root cause update.sh's
    # B-OVERRIDE-RACE reconciliation pass already documents for the
    # --remove-orphans case; here it manifests as a hard failure instead of
    # silent orphan removal. Fix: bring up dashboard-api alone first (it
    # only depends on services already started above), wait for its
    # self-heal log line, THEN bring up everything else — so the full plan
    # is always computed from a freshly-regenerated, correct override file.
    echo ""
    echo "  Starting dashboard-api (regenerates docker-compose.override.yml)..."
    if ! docker compose "${COMPOSE_ENV_ARGS[@]}" up -d dashboard-api; then
        echo ""
        echo "  ✗ docker compose up dashboard-api failed. Aborting install."
        echo "    Run 'docker compose logs dashboard-api' to investigate."
        exit 1
    fi

    OVERRIDE_REFRESH_TIMEOUT=60
    OVERRIDE_REFRESH_POLL=2
    OVERRIDE_REFRESH_ELAPSED=0
    while [ "$OVERRIDE_REFRESH_ELAPSED" -lt "$OVERRIDE_REFRESH_TIMEOUT" ]; do
        if docker compose "${COMPOSE_ENV_ARGS[@]}" logs dashboard-api 2>&1 | grep -q "override.yml refreshed for products:"; then
            echo "  ✓ docker-compose.override.yml regenerated by dashboard-api."
            break
        fi
        sleep "$OVERRIDE_REFRESH_POLL"
        OVERRIDE_REFRESH_ELAPSED=$((OVERRIDE_REFRESH_ELAPSED + OVERRIDE_REFRESH_POLL))
    done
    if [ "$OVERRIDE_REFRESH_ELAPSED" -ge "$OVERRIDE_REFRESH_TIMEOUT" ]; then
        echo "  [warn] Timed out waiting for dashboard-api's override.yml self-heal log line."
        echo "  Expected on a brand-new install with no license activated yet — proceeding."
    fi

    echo ""
    echo "  Starting remaining services..."
    if ! docker compose "${COMPOSE_ENV_ARGS[@]}" up -d; then
        echo ""
        echo "  ✗ docker compose up failed. Aborting install."
        echo "    Run 'docker compose logs' to investigate."
        exit 1
    fi

    echo ""
    echo "  Setting up HTTPS trust (Caddy internal CA)..."
    trust_caddy_ca || true

    echo ""
    echo "  Waiting for dashboard to be ready..."
    sleep 10

    # BANKING-GRADE PURGE — DEFERRED (task #149).
    # An earlier revision purged .env here (banking-grade at-rest goal), but
    # Docker Compose re-interpolates ${VAR} refs on every `docker compose up`
    # (including scheduled restarts, updates, product deploys) — no .env on
    # disk means empty env vars in the containers → whole stack crash-loops.
    # Reintroduce the purge ONLY once dashboard-api regenerates .env from
    # .env.enc before each compose action (or a --env-file explicit pipe is
    # wired everywhere). Until then keep .env at rest with mode 0600 as
    # documented in the same section of update.sh.
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
if grep -q "coderaft.local" /etc/hosts 2>/dev/null; then
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
