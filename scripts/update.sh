#!/bin/bash
#
# CodeRaft updater
#
# Self-updates from the installer repo, then captures a pre-update recovery
# snapshot before pulling new images. If something breaks, run rollback.sh.
#
set -e

DASHBOARD_API="${DASHBOARD_API:-http://localhost:3001}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"

echo "  Updating CodeRaft..."

# ── Self-update both update.sh and rollback.sh ─────────────────────────────
echo "  Checking for script updates..."
for name in update.sh rollback.sh; do
    LATEST=$(curl -fsSL "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/$name" 2>/dev/null)
    if [ -n "$LATEST" ] && [ ${#LATEST} -gt 50 ]; then
        echo "$LATEST" > "$name.tmp"
        if ! cmp -s "$name" "$name.tmp" 2>/dev/null; then
            mv "$name.tmp" "$name" && chmod +x "$name"
            echo "  $name refreshed"
        else
            rm -f "$name.tmp"
        fi
    fi
done

# ── Pre-update recovery snapshot ───────────────────────────────────────────
# The dashboard-api auto-snapshots on every deploy, but a manual snapshot
# before the image pull gives a clearer rollback target.
echo "  Capturing pre-update recovery snapshot..."
if [ -n "$ADMIN_TOKEN" ]; then
    curl -fsS -X POST "$DASHBOARD_API/api/dashboard/recovery/snapshots" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -d '{"reason":"pre-update"}' > /dev/null \
        && echo "    snapshot saved" \
        || echo "    snapshot failed (continuing — auto-snapshot still runs on next deploy)"
else
    echo "    skipped (set ADMIN_TOKEN to enable; auto-snapshot still runs on next deploy)"
fi

# ── Pull and recreate ──────────────────────────────────────────────────────
docker compose pull && docker compose up -d --force-recreate --remove-orphans
echo ""
echo "  Updated! Dashboard: http://localhost:3000"
echo "  If something is broken: ./rollback.sh (or curl -fsSL https://install.coderaft.io/rollback | bash)"
