#!/bin/bash
echo "  Updating CodeRaft..."

# Self-update: download latest update script
echo "  Checking for script updates..."
LATEST=$(curl -fsSL "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/update.sh" 2>/dev/null)
if [ -n "$LATEST" ] && [ ${#LATEST} -gt 50 ]; then
    echo "$LATEST" > update.sh.tmp
    if ! cmp -s update.sh update.sh.tmp 2>/dev/null; then
        mv update.sh.tmp update.sh && chmod +x update.sh
        echo "  Update script refreshed"
    else
        rm -f update.sh.tmp
    fi
fi

# Pull latest images and recreate containers
docker compose pull && docker compose up -d --force-recreate --remove-orphans
echo "  Updated! Dashboard: http://localhost:3000"
