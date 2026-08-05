#!/bin/bash
# vault-recover.sh — unseal ceremony helper: prompts an operator for a
# threshold of Shamir shares and submits them to the running vault's
# POST /v1/unseal.
#
# AUDIT-SECU-2026-08-04 (Vault H1): this used to reconstruct
# vault-keys/age.key from a 24-word BIP39 mnemonic via a `-mnemonic-to-key`
# vault CLI sub-command that was never actually implemented (it always fell
# through to a "not available" error). That whole model is gone: there is
# no more on-disk master key file, no more recovery phrase. The vault
# generates its own master key once (POST /v1/init) and splits it into real
# Shamir shares; "recovery" of a sealed vault is simply re-running the
# unseal ceremony with a threshold of those ORIGINAL shares. If fewer than
# the threshold can be gathered, the vault's data is permanently
# unrecoverable — there is no back door.
#
# Usage:
#   vault-recover.sh
#   (prompts the operator for shares, one per line, blank line to finish)

set -e

INSTALL_DIR="${INSTALL_DIR:-$PWD}"

echo ""
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║              coderaft-vault — Unseal Ceremony                    ║"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  This submits Shamir shares to POST /v1/unseal on the running vault."
echo "  You need a THRESHOLD number of shares from THIS vault's own"
echo "  POST /v1/init response (default: 3 of 5) — shares from a different"
echo "  vault will not work, and there is no way to reconstruct a share."
echo ""

SHARES=()
echo "  Enter each share (base64), one per line. Press Enter on an empty"
echo "  line when you have entered enough (you'll be told if you need more):"
while true; do
    if command -v stty &>/dev/null; then stty -echo 2>/dev/null || true; fi
    printf "  Share %d: " "$((${#SHARES[@]} + 1))"
    IFS= read -r SHARE_LINE || true
    if command -v stty &>/dev/null; then stty echo 2>/dev/null || true; echo ""; fi
    [ -z "$SHARE_LINE" ] && break
    SHARES+=("$SHARE_LINE")
done

if [ "${#SHARES[@]}" -eq 0 ]; then
    echo "  ✗ No shares entered. Aborting." >&2
    exit 1
fi

# Detect compose project name (determines Docker network name)
VAULT_PROJECT=$(docker inspect coderaft-coderaft-vault-1 \
    --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
[ -z "$VAULT_PROJECT" ] && VAULT_PROJECT="coderaft"
VAULT_NETWORK="${VAULT_PROJECT}_coderaft-vault-net"

ABS_TLS_DIR="$(cd "${INSTALL_DIR}/vault-tls" && pwd)"

_vault_curl_recover() {
    local method="$1" path="$2" body="${3:-}"
    local curl_args=(
        "run" "--rm"
        "--user" "0:0"
        "--network" "$VAULT_NETWORK"
        "-v" "${ABS_TLS_DIR}:/tls:ro"
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

# Build the JSON shares array via python3 if available (safe escaping);
# fall back to a manual join (shares are base64 — no embedded quotes/newlines
# expected, but python3 is preferred when present).
if command -v python3 &>/dev/null; then
    UNSEAL_BODY=$(python3 -c '
import json, sys
print(json.dumps({"shares": sys.argv[1:]}))
' "${SHARES[@]}")
else
    JOINED=""
    for s in "${SHARES[@]}"; do
        [ -n "$JOINED" ] && JOINED="${JOINED},"
        JOINED="${JOINED}\"${s}\""
    done
    UNSEAL_BODY="{\"shares\":[${JOINED}]}"
fi

echo "  Submitting ${#SHARES[@]} share(s) to POST /v1/unseal..."
UNSEAL_RESP=$(_vault_curl_recover "POST" "/v1/unseal" "$UNSEAL_BODY" 2>/dev/null || true)
echo "  Response: $UNSEAL_RESP"

if echo "$UNSEAL_RESP" | grep -qE '"ok"\s*:\s*true'; then
    echo "  ✓ Vault unsealed"
elif echo "$UNSEAL_RESP" | grep -qE '"progress"'; then
    echo "  ⚠ Not enough shares yet — re-run this script and enter the remaining share(s)."
    echo "    Shares already submitted are NOT remembered between separate runs of this"
    echo "    script if the vault process restarts in between; submit them all in one run."
    exit 1
else
    echo "  ✗ Unseal failed — see response above (wrong shares, or vault not yet" >&2
    echo "    initialized — run POST /v1/init first if this is a brand new vault)." >&2
    exit 1
fi

# Final health check
FINAL_HEALTH=$(_vault_curl_recover "GET" "/v1/health" 2>/dev/null || true)
if echo "$FINAL_HEALTH" | grep -q '"sealed":false'; then
    echo "  ✓ coderaft-vault is healthy and unsealed"
    echo ""
    echo "  Recovery complete."
else
    echo ""
    echo "  ⚠ Unseal reported success but health check does not confirm sealed:false." >&2
    echo "    Health: $FINAL_HEALTH" >&2
    exit 1
fi
