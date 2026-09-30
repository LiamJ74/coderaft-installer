#!/bin/bash
# vault-set.sh — post-install helper to write a secret into coderaft-vault.
#
# Usage:
#   vault-set.sh <secret-name> <secret-value>
#
# The vault is on coderaft-vault-net (internal Docker network, no route from
# the host), and its own image is distroless (no shell/wget/curl to exec
# into directly — confirmed 2026-09-17, this script used to exec into
# coderaft-vault itself over plain HTTP localhost, which stopped working the
# moment that image went distroless). Instead we exec into dashboard-api,
# which already has curl AND the mTLS client cert/key it uses for its own
# normal Vault operations (mounted at /vault-tls/), and is on
# coderaft-vault-net too — this is the exact same call
# vaultPlatform.setSecretResult() makes from dashboard-api's own JS, just
# triggered by hand.
#
# Requires: docker, a running dashboard-api container.

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

# Verify dashboard-api is running (it's our path to the vault — see header)
if ! (cd "${INSTALL_DIR}" 2>/dev/null && docker compose ps dashboard-api 2>/dev/null | grep -q "Up"); then
    echo "  ✗ dashboard-api is not running." >&2
    echo "    Start it with: cd ${INSTALL_DIR} && docker compose up -d dashboard-api" >&2
    exit 1
fi

# Escape the value for JSON: replace backslash, then double-quote
_ESCAPED_VALUE=$(printf '%s' "${SECRET_VALUE}" | sed 's/\\/\\\\/g; s/"/\\"/g')

BODY="{\"name\":\"${SECRET_NAME}\",\"value\":\"${_ESCAPED_VALUE}\"}"

echo "  Setting secret: ${SECRET_NAME}..."
RESP=$(cd "${INSTALL_DIR}" && docker compose exec -T dashboard-api \
    sh -c "curl -s \
        --cacert /vault-tls/client-ca.crt \
        --cert /vault-tls/dashboard-api-client.crt \
        --key /vault-tls/dashboard-api-client.key \
        --header 'Content-Type: application/json' \
        --data '${BODY}' \
        https://coderaft-vault:8200/v1/secret/set" 2>/dev/null || true)

if echo "$RESP" | grep -q '"ok":true'; then
    echo "  ✓ Secret '${SECRET_NAME}' stored in vault"
else
    echo "  ✗ vault set failed. Response: ${RESP}" >&2
    exit 1
fi
