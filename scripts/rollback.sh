#!/bin/bash
#
# CodeRaft rollback
#
# Restores a previous deployment by re-running containers with the image IDs
# recorded in a recovery snapshot. Volumes are preserved so client data
# (audits, scans, sessions, encrypted secrets vault) is untouched.
#
# Usage:
#   ADMIN_TOKEN=<token> ./rollback.sh                 # interactive
#   ADMIN_TOKEN=<token> ./rollback.sh <snapshot-id>   # non-interactive
#   ./rollback.sh                                     # auto-discovers a token
#                                                      # (see discover_admin_token
#                                                      # below) — this is the
#                                                      # path update.sh's
#                                                      # automatic-rollback-on-
#                                                      # failed-healthcheck uses.
#
# To get an ADMIN_TOKEN manually: sign in to the dashboard and copy the JWT
# from the coderaft_token cookie or from the localStorage token field.
#
set -e

DASHBOARD_API="${DASHBOARD_API:-http://localhost:3000}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"
INSTALL_DIR="${INSTALL_DIR:-$PWD}"

# install-config.env: same host-level interpolation file update.sh uses (see
# its own comment for the full rationale) — needed here too because the
# auto-discovery step below runs `docker compose exec`, which requires every
# ${VAR:?...} in docker-compose.yml to resolve even for a read-only `exec`.
INSTALL_CONFIG_PATH="${INSTALL_DIR}/install-config.env"
touch "$INSTALL_CONFIG_PATH" 2>/dev/null || true
chmod 600 "$INSTALL_CONFIG_PATH" 2>/dev/null || true
COMPOSE_ENV_ARGS=(--env-file "$INSTALL_CONFIG_PATH" --env-file "${INSTALL_DIR}/.env")

# ── ADMIN_TOKEN auto-discovery ────────────────────────────────────────────
# Mirrors update.sh's discover_admin_token() (kept in sync manually — see
# that script for the identical, authoritative version of this comment).
#
# Root cause fix (2026-09, live incident): update.sh already auto-discovers
# an ADMIN_TOKEN (this same function) before running, but only stored it in
# its own *shell variable* — never exported it — so when it shelled out to
# `bash ./rollback.sh` on a failed post-update healthcheck, the child process
# started with an empty environment and rollback.sh (which back then had no
# discovery logic of its own) failed immediately with "ADMIN_TOKEN required",
# meaning the "automatic" rollback could never actually run unattended.
# update.sh/update.ps1 now also export/propagate the token they resolved
# into the rollback child process (defense in depth) — but rollback.sh is
# made self-sufficient here too, so it authenticates on its own whether it's
# invoked by update.sh's auto-rollback path or run standalone by an operator.
#
# Priority order:
#   1. $ADMIN_TOKEN env var (already set above — explicit override always wins)
#   2. .env files (INSTALL_DIR, /etc/coderaft, ~/.coderaft)
#   3. Plain token files (single word)
#   4. Mounted Docker secret
#   5. Auto-read /data/admin_token from the running dashboard-api container —
#      the "CLI admin token": a long-lived (365d) global_admin JWT that
#      dashboard-api mints for itself at boot specifically for this kind of
#      local automation (see server.js's ensureCliAdminToken() — "a
#      host-trusted maintenance credential used by update.sh/install.sh,
#      never a browser session"). Only reachable via `docker compose exec`
#      on THIS host — it is never served over HTTP or otherwise exposed to
#      the network, so this discovery path cannot be triggered remotely.
# If nothing is found → the existing hard error below fires, same as before.
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
    if (cd "$INSTALL_DIR" 2>/dev/null && docker compose "${COMPOSE_ENV_ARGS[@]}" ps --services 2>/dev/null | grep -q '^dashboard-api$'); then
        val=$(cd "$INSTALL_DIR" && docker compose "${COMPOSE_ENV_ARGS[@]}" exec -T dashboard-api cat /data/admin_token 2>/dev/null < /dev/null | tr -d '[:space:]')
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

if [ -z "$ADMIN_TOKEN" ]; then
    echo "ERROR: ADMIN_TOKEN env var is required."
    echo
    echo "Auto-discovery also failed (no .env, no token file, and either the"
    echo "dashboard-api container isn't running or /data/admin_token wasn't"
    echo "readable yet)."
    echo
    echo "Sign in to the dashboard (http://localhost:3000), open the browser"
    echo "dev tools, copy the value of the 'coderaft_token' cookie, then run:"
    echo
    echo "    ADMIN_TOKEN=<your-token> ./rollback.sh"
    exit 1
fi

auth=(-H "Authorization: Bearer $ADMIN_TOKEN")

if [ -n "${1-}" ]; then
    TARGET_ID="$1"
else
    echo "  Available snapshots (newest first):"
    # --max-time 10: mirrors rollback.ps1's Invoke-RestMethod -TimeoutSec 10 for
    # this same snapshot-list GET.
    LIST=$(curl -fsS --max-time 10 "${auth[@]}" "$DASHBOARD_API/api/dashboard/recovery/snapshots" 2>/dev/null || echo "")
    if [ -z "$LIST" ]; then
        echo "  ERROR: could not reach $DASHBOARD_API/api/dashboard/recovery/snapshots"
        echo "         (is the stack running? is your token valid?)"
        exit 1
    fi
    echo "$LIST" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read() or "{}")
snaps = data.get("snapshots", [])
if not snaps:
    print("  No snapshots available.")
    sys.exit(2)
for i, s in enumerate(snaps, 1):
    print(f"  {i}. {s[\"id\"]}  reason={s[\"reason\"]}  products={s[\"products\"]}  services={s[\"service_count\"]}")
' || exit $?
    echo
    read -rp "  Snapshot id to roll back to: " TARGET_ID
fi

if [ -z "$TARGET_ID" ]; then
    echo "  ERROR: no snapshot id provided."
    exit 1
fi

echo
echo "  Rolling back to snapshot $TARGET_ID ..."
# --max-time 60: mirrors rollback.ps1's Invoke-RestMethod -TimeoutSec 60 for
# this same rollback POST (synchronous — recreates containers and waits for
# the full result, so it needs more headroom than a status poll).
RESULT=$(curl -fsS --max-time 60 -X POST "${auth[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$TARGET_ID\"}" \
    "$DASHBOARD_API/api/dashboard/recovery/rollback")

echo "$RESULT" | python3 -c '
import json, sys
r = json.loads(sys.stdin.read() or "{}")
if r.get("ok"):
    restored = r.get("restored", [])
    skipped = r.get("skipped", [])
    print(f"  Rollback OK — {len(restored)} container(s) restored, {len(skipped)} skipped.")
    for x in skipped:
        print(f"    skipped {x[\"service\"]}: {x[\"reason\"]}")
else:
    print(f"  Rollback failed: {r.get(\"error\", \"unknown\")}")
    sys.exit(1)
'

echo
echo "  Check container state with: docker compose ps"
