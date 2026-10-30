#!/bin/bash
#
# CodeRaft Caddy TLS certificate watchdog (Linux/macOS) — standalone,
# cron-scheduled counterpart to the pre/post-update check already shipped
# inside update.sh (2026-08-13). See update.sh for the full incident
# writeup (Liam locked out with net::ERR_CERT_DATE_INVALID after ~4 weeks
# of continuous `caddy` uptime with no update.sh run in between).
#
# THE GAP THIS CLOSES: the update.sh check only runs when a human (or some
# external automation) actually executes update.sh. A real customer install
# that nobody touches for weeks never runs update.sh, so it never got that
# protection either — same failure mode Liam hit, just with no admin
# available to unblock it with a manual `docker compose restart caddy`.
# This script is the exact same detection+self-heal logic (copied
# verbatim, not reinvented — see get_caddy_cert_days_remaining /
# test_caddy_cert_expiry_and_self_heal below, unchanged from update.sh),
# wired to run once a day via cron, independent of update.sh ever being
# invoked.
#
# Installed by install.sh on a fresh install, and self-healed by update.sh
# on every run (existing installs get the cron entry added retroactively
# the next time they update — see update.sh's `--register-task` call).
#
# Usage:
#   bash check-caddy-cert.sh                  # run the check once (also what cron calls)
#   bash check-caddy-cert.sh --register-task  # (idempotent) install/refresh the daily cron entry
#   bash check-caddy-cert.sh --uninstall-task # remove the cron entry
#
# Deliberately NOT `set -e`: this is a background monitoring script. A
# transient failure in one sub-step (network hiccup on the self-update
# fetch, docker briefly unavailable) must never abort silently mid-script
# with no log — every step below handles its own failure explicitly.
set -u

# ── Resolve INSTALL_DIR ──────────────────────────────────────────────────
# Same layout as update.sh/install.sh: this script lives flat at the root
# of the install directory (next to docker-compose.yml, .env, update.sh).
# Default to the directory containing THIS file (not $PWD) since cron
# invokes commands with an unspecified/minimal CWD — the crontab entry
# installed below also passes an explicit absolute path as a second layer
# of safety, but this default keeps `bash check-caddy-cert.sh` correct
# even when run manually from elsewhere.
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
INSTALL_DIR="${INSTALL_DIR:-$(dirname "$SCRIPT_PATH")}"
cd "$INSTALL_DIR" 2>/dev/null || {
    echo "[check-caddy-cert] ERROR: install dir '$INSTALL_DIR' not accessible" >&2
    exit 1
}

CRON_MARKER="# coderaft-caddy-cert-watchdog"

# ── Detail log file (2026-08-13) ─────────────────────────────────────────
# update.ps1/install.ps1 write one dated file per run under logs/ via
# Write-DetailLog, keeping the last N. update.sh/install.sh never adopted
# that (bash side just echoes to stdout, normally read live in a
# terminal) — but this script has NO terminal, it's invoked by cron, so
# without a log file its output goes nowhere. Bring the same convention to
# the bash side for this one script: logs/certcheck-<timestamp>.log,
# pruned to the last 30 (~1 month of daily runs).
LOG_DIR="$INSTALL_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="${TMPDIR:-/tmp}"
CERTCHECK_LOG="$LOG_DIR/certcheck-$(date +%Y%m%d_%H%M%S).log"
: > "$CERTCHECK_LOG" 2>/dev/null || CERTCHECK_LOG="/dev/null"
log() {
    local line
    line="[$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)] $*"
    echo "$line"
    echo "$line" >> "$CERTCHECK_LOG" 2>/dev/null || true
}
# Prune old logs (best-effort, never fatal).
find "$LOG_DIR" -maxdepth 1 -name 'certcheck-*.log' -type f -print0 2>/dev/null \
    | xargs -0 ls -1t 2>/dev/null | tail -n +31 | while IFS= read -r old; do
    rm -f "$old" 2>/dev/null || true
done

# ── Argument parsing ──────────────────────────────────────────────────────
MODE="check"
for arg in "$@"; do
    case "$arg" in
        --register-task) MODE="register" ;;
        --uninstall-task) MODE="unregister" ;;
        --periodic-cron) MODE="check" ;;   # explicit marker used by the installed cron line itself
        *) ;;
    esac
done

# ── cron (un)registration ─────────────────────────────────────────────────
# Same pattern already used in this repo for a comparable "install a daily
# cron job, idempotently, uninstallable" need:
# products/entraguard/backend/scripts/standalone-agent/agent.sh
# (install_cron/CRON_TAG) — reused here rather than inventing a different
# convention. crontab's own "read-modify-write whole crontab" model makes
# `grep -v "$CRON_MARKER"` before re-adding the line the natural way to
# stay idempotent across repeated install.sh/update.sh runs: it always
# strips any previous copy of our line before appending the current one,
# so re-running never duplicates it.
register_cron_task() {
    if ! command -v crontab &>/dev/null; then
        echo "  [warn] crontab not found on this host — cannot install the periodic Caddy certificate watchdog."
        echo "         Run it manually once a day instead: bash \"$SCRIPT_PATH\""
        return 0
    fi
    local entry="0 9 * * * INSTALL_DIR='$INSTALL_DIR' /bin/bash '$SCRIPT_PATH' --periodic-cron >/dev/null 2>&1 $CRON_MARKER"
    local existing
    existing="$(crontab -l 2>/dev/null || true)"
    if echo "$existing" | grep -qF "$entry"; then
        echo "  ✓ Caddy cert watchdog cron entry already up to date."
        return 0
    fi
    # Strip any previous copy of our line (path/schedule may have changed
    # across a re-install) before adding the current one — this is what
    # keeps repeated install.sh/update.sh runs idempotent instead of
    # piling up duplicate lines.
    { echo "$existing" | grep -vF "$CRON_MARKER"; echo "$entry"; } | grep -v '^$' | crontab -
    echo "  ✓ Caddy cert watchdog cron entry installed/refreshed (daily, 09:00 local time)."
}

unregister_cron_task() {
    if ! command -v crontab &>/dev/null; then return 0; fi
    local existing
    existing="$(crontab -l 2>/dev/null || true)"
    echo "$existing" | grep -vF "$CRON_MARKER" | crontab - 2>/dev/null || true
    echo "  Caddy cert watchdog cron entry removed."
}

if [ "$MODE" = "register" ]; then
    register_cron_task
    exit 0
fi
if [ "$MODE" = "unregister" ]; then
    unregister_cron_task
    exit 0
fi

# ── Below: MODE=check (the actual periodic run, e.g. from cron) ─────────

# ── Concurrency guard #1: is a real update.sh currently running? ────────
# The periodic check must never race update.sh's own `docker compose pull
# && up -d --force-recreate` — restarting caddy mid-recreate could produce
# confusing transient errors. Detected by process inspection rather than a
# new shared lock file that update.sh would need to be taught to hold
# (higher risk: that file is large, delicate, and already shipped/tested —
# this check works without touching a single line of it). The bracket
# trick `[u]pdate\.sh` keeps this pgrep call from matching its own
# invocation (which never contains that literal pattern anyway, but the
# convention is kept for safety/clarity).
# `pgrep` is present on virtually every real Linux/macOS host this targets,
# but this repo's own convention (see `timeout`/`gtimeout`, `skopeo` guards
# elsewhere) is to soft-fallback rather than add a hard new binary
# dependency — `ps` is POSIX-mandated and always present.
update_sh_running=0
if command -v pgrep &>/dev/null; then
    pgrep -f '[u]pdate\.sh' >/dev/null 2>&1 && update_sh_running=1
else
    ps -eo args 2>/dev/null | grep -q '[u]pdate\.sh' && update_sh_running=1
fi
if [ "$update_sh_running" = "1" ]; then
    log "update.sh appears to be running right now — skipping this cycle to avoid racing a live update. Will retry on the next scheduled run."
    exit 0
fi

# ── Self-update (2026-08-13) ──────────────────────────────────────────────
# Same convention update.sh/rollback.sh already use for themselves: this
# script self-refreshes from the installer repo before running, with a
# re-exec guard against infinite loops. Particularly important HERE:
# unlike update.sh (re-fetched every time a human runs an update), this
# script's whole point is to keep running unattended for weeks/months via
# cron with nobody re-triggering install.sh/update.sh in between — so it
# needs its OWN refresh path to ever receive a bugfix.
#
# Deliberately placed BEFORE the lock-directory guard below (not after,
# unlike a first draft of this script): `exec` replaces this process's
# image outright — it does NOT run pending `trap ... EXIT` handlers, since
# there is no normal shell exit, just a fresh program image taking over
# the same PID. A lock acquired before this `exec` would never be
# released by the old identity, and the freshly re-exec'd copy (running
# this same script from the top) would immediately see its own orphaned
# lock and skip its run thinking another instance was active. Self-update
# first, lock second, avoids that entirely: by the time any lock exists,
# no further `exec` can happen in this run.
if [ -z "${CODERAFT_CERTCHECK_REEXEC:-}" ]; then
    LATEST="$(curl -fsSL "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/check-caddy-cert.sh" 2>/dev/null)"
    if [ -n "$LATEST" ] && [ ${#LATEST} -gt 50 ]; then
        echo "$LATEST" > "$SCRIPT_PATH.tmp"
        if ! cmp -s "$SCRIPT_PATH" "$SCRIPT_PATH.tmp" 2>/dev/null; then
            mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
            log "check-caddy-cert.sh refreshed — re-running the updated version."
            export CODERAFT_CERTCHECK_REEXEC=1
            exec bash "$SCRIPT_PATH" --periodic-cron
        else
            rm -f "$SCRIPT_PATH.tmp"
        fi
    fi
fi

# ── Concurrency guard #2: another check-caddy-cert.sh run already active? ─
# Belt-and-suspenders against double cron entries / an overlapping manual
# run. `mkdir` is atomic (single syscall) so this is a safe test-and-set
# even against a genuinely concurrent second invocation. Stale-lock
# reclaim after 5 minutes covers a run that crashed before cleanup (the
# entire check+restart+reread cycle normally completes in a few seconds).
LOCK_DIR="$INSTALL_DIR/.coderaft-certcheck.lock"
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi
    local lock_mtime lock_age
    lock_mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
    lock_age=$(( $(date +%s) - lock_mtime ))
    if [ "$lock_age" -gt 300 ]; then
        log "[warn] Stale lock ($LOCK_DIR, age ${lock_age}s) — reclaiming."
        rmdir "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null && return 0
    fi
    return 1
}
if ! acquire_lock; then
    log "Another check-caddy-cert.sh run holds the lock — skipping this cycle."
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# ── docker compose file/env selection ─────────────────────────────────────
# Verbatim copy of update.sh's own COMPOSE_ARGS construction (same file
# selection logic, same variable name) — needed so `docker compose
# restart caddy` below targets the exact same compose project update.sh
# would.
COMPOSE_ARGS=()
if [ -f "./docker-compose.override.yml" ]; then
    COMPOSE_ARGS=(-f ./docker-compose.yml -f ./docker-compose.override.yml)
fi
if { [ -f "./docker-compose.vault.yml" ] || [ -f "./vault-data/.migrated" ]; } && \
   ! grep -Eq '^[[:space:]]*coderaft-vault:[[:space:]]*$' "./docker-compose.yml" 2>/dev/null; then
    if [ ${#COMPOSE_ARGS[@]} -eq 0 ]; then
        COMPOSE_ARGS=(-f ./docker-compose.yml)
    fi
    COMPOSE_ARGS+=(-f ./docker-compose.vault.yml)
fi
COMPOSE_ARGS+=(--env-file ./install-config.env --env-file ./.env)

# ── PROACTIVE Caddy TLS certificate expiry detection ─────────────────────
# Copied VERBATIM from update.sh (2026-08-13 commit) — same function
# names, same logic, same 14-day warning window. Do not fork the
# detection algorithm here; if it needs to change, change it in update.sh
# and mirror the change here (same duplication convention update.sh/
# update.ps1 already use relative to each other).
get_caddy_cert_days_remaining() {
    local sni="${1:-coderaft.local}"
    local timeout_bin=""
    if command -v timeout &>/dev/null; then
        timeout_bin="timeout 6"
    elif command -v gtimeout &>/dev/null; then
        timeout_bin="gtimeout 6"
    fi
    local end_date=""
    end_date=$($timeout_bin openssl s_client -connect 127.0.0.1:443 -servername "$sni" </dev/null 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2) || true
    if [ -z "$end_date" ]; then
        return 1
    fi
    local end_epoch=""
    end_epoch=$(date -d "$end_date" +%s 2>/dev/null) || true
    if [ -z "$end_epoch" ]; then
        # BSD/macOS date fallback — openssl enddate format e.g. "Aug 13 12:00:00 2026 GMT"
        end_epoch=$(date -j -f "%b %d %T %Y %Z" "$end_date" +%s 2>/dev/null) || true
    fi
    if [ -z "$end_epoch" ]; then
        return 1
    fi
    local now_epoch
    now_epoch=$(date +%s)
    echo $(( (end_epoch - now_epoch) / 86400 ))
    return 0
}

test_caddy_cert_expiry_and_self_heal() {
    local phase="${1:-periodic}"
    local warn_days=14
    local hostname_for_check="coderaft.local"
    if [ -f "${INSTALL_DIR}/.env" ] && grep -qE '^\s*CODERAFT_HOSTNAME\s*=' "${INSTALL_DIR}/.env"; then
        local candidate=""
        candidate=$(grep -E '^\s*CODERAFT_HOSTNAME\s*=' "${INSTALL_DIR}/.env" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs) || true
        [ -n "$candidate" ] && hostname_for_check="$candidate"
    fi
    log "Checking Caddy TLS certificate expiry (${phase}, host=${hostname_for_check})..."
    if ! command -v openssl &>/dev/null; then
        log "[warn] openssl not found on this host — cannot check Caddy certificate expiry, skipping."
        return 0
    fi
    local days=""
    days=$(get_caddy_cert_days_remaining "$hostname_for_check") || true
    if [ -z "$days" ]; then
        log "[warn] Could not check Caddy certificate (not reachable on 127.0.0.1:443, or platform not deployed yet) — skipping."
        return 0
    fi
    if [ "$days" -le "$warn_days" ]; then
        if [ "$days" -lt 0 ]; then
            log "[warn] Certificat Caddy EXPIRÉ depuis $(( -1 * days )) jour(s) — redémarrage préventif du service caddy."
        else
            log "[warn] Certificat Caddy expirant dans ${days} jour(s) — redémarrage préventif du service caddy."
        fi
        docker compose "${COMPOSE_ARGS[@]}" restart caddy >/dev/null 2>&1 || true
        sleep 3
        local days_after=""
        days_after=$(get_caddy_cert_days_remaining "$hostname_for_check") || true
        if [ -n "$days_after" ] && [ "$days_after" -gt "$days" ]; then
            log "Caddy redémarré — certificat désormais valide ${days_after} jour(s)."
        else
            log "[warn] Redémarrage effectué mais l'expiration ne semble pas avoir progressé (valeur relue: ${days_after:-inconnue}). Vérifier: docker compose logs caddy"
        fi
    else
        log "Certificat Caddy valide encore ${days} jour(s)."
    fi
    return 0
}

test_caddy_cert_expiry_and_self_heal "periodic (cron)" || true
log "check-caddy-cert.sh run complete. Log: $CERTCHECK_LOG"
