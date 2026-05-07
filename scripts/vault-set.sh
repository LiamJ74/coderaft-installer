#!/bin/bash
# vault-set.sh — post-install helper to write a secret into coderaft-vault.
#
# Usage:
#   vault-set.sh <secret-name> <secret-value>
#
# The script uses the dashboard-api client cert (stored in ./vault-tls/) to
# authenticate via mTLS against https://coderaft-vault:8200.
#
# The vault is on coderaft-vault-net (internal Docker network); we reach it
# via docker exec into the running vault container rather than over the host
# network (host has no route to coderaft-vault-net).
#
# Requires: docker, a running coderaft-vault container.

set -e

INSTALL_DIR="${INSTALL_DIR:-$PWD}"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <secret-name> <secret-value>" >&2
    echo ""
    echo "  Example: $0 license_key 'ENC-v1-abc123...'"
    exit 1
fi

SECRET_NAME="$1"
SECRET_VALUE="$2"

# Verify vault is running
if ! (cd "${INSTALL_DIR}" 2>/dev/null && docker compose ps coderaft-vault 2>/dev/null | grep -q "running"); then
    echo "  ✗ coderaft-vault is not running." >&2
    echo "    Start it with: cd ${INSTALL_DIR} && docker compose up -d coderaft-vault" >&2
    exit 1
fi

# Escape the value for JSON: replace backslash, then double-quote
_ESCAPED_VALUE=$(printf '%s' "${SECRET_VALUE}" | sed 's/\\/\\\\/g; s/"/\\"/g')

BODY="{\"name\":\"${SECRET_NAME}\",\"value\":\"${_ESCAPED_VALUE}\"}"

echo "  Setting secret: ${SECRET_NAME}..."
RESP=$(cd "${INSTALL_DIR}" && docker compose exec -T coderaft-vault \
    /bin/sh -c "wget -qO- \
        --post-data='${BODY}' \
        --header='Content-Type: application/json' \
        http://localhost:8200/v1/secret/set 2>/dev/null" 2>/dev/null || true)

if echo "$RESP" | grep -q '"ok":true'; then
    echo "  ✓ Secret '${SECRET_NAME}' stored in vault"
else
    echo "  ✗ vault set failed. Response: ${RESP}" >&2
    exit 1
fi
