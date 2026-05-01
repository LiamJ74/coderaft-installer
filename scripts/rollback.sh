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
#
# To get an ADMIN_TOKEN: sign in to the dashboard and copy the JWT from the
# coderaft_token cookie or from the localStorage token field.
#
set -e

DASHBOARD_API="${DASHBOARD_API:-http://localhost:3000}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"

if [ -z "$ADMIN_TOKEN" ]; then
    echo "ERROR: ADMIN_TOKEN env var is required."
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
    LIST=$(curl -fsS "${auth[@]}" "$DASHBOARD_API/api/dashboard/recovery/snapshots" 2>/dev/null || echo "")
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
RESULT=$(curl -fsS -X POST "${auth[@]}" \
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
