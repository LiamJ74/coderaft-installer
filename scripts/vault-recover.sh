#!/bin/bash
# vault-recover.sh — recovery-phrase path: reconstruct vault-keys/age.key
#                    from the 24-word BIP39 mnemonic, then restart the vault.
#
# Usage:
#   vault-recover.sh
#   (prompts the operator for the 24 words)
#
# The vault container reads vault-keys/age.key at start — once the key file
# is restored, restarting the container re-unseals the vault.
#
# Requirements: docker (for the -mnemonic-to-key sub-command), age-keygen
# (to validate the reconstructed key format).
#
# TODO (Phase 1 follow-up): verify the -mnemonic-to-key sub-command is
# implemented in coderaft-vault before production use.

set -e

INSTALL_DIR="${INSTALL_DIR:-$PWD}"

echo ""
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║              coderaft-vault — Recovery Mode                     ║"
echo "  ╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  This procedure reconstructs vault-keys/age.key from your 24-word"
echo "  recovery phrase and restarts the vault container."
echo ""
echo "  IMPORTANT: This replaces the existing vault-keys/age.key file."
echo "  Make sure you have a recent backup before continuing."
echo ""

# Prompt for phrase (no echo)
if command -v stty &>/dev/null; then
    stty -echo 2>/dev/null || true
fi
printf "  Enter your 24-word recovery phrase (words separated by spaces):\n  "
read -r RECOVERY_PHRASE
if command -v stty &>/dev/null; then
    stty echo 2>/dev/null || true
    echo ""
fi

if [ -z "$RECOVERY_PHRASE" ]; then
    echo "  ✗ No phrase entered. Aborting." >&2
    exit 1
fi

WORD_COUNT=$(echo "$RECOVERY_PHRASE" | wc -w | tr -d ' ')
if [ "$WORD_COUNT" -lt 12 ]; then
    echo "  ✗ Recovery phrase looks too short ($WORD_COUNT words). BIP39 phrases are 12 or 24 words." >&2
    exit 1
fi

echo "  Reconstructing age key from recovery phrase..."

# Backup existing key if present
if [ -f "${INSTALL_DIR}/vault-keys/age.key" ]; then
    TS=$(date -u +"%Y%m%dT%H%M%SZ")
    cp "${INSTALL_DIR}/vault-keys/age.key" "${INSTALL_DIR}/vault-keys/age.key.bak-${TS}"
    echo "  Existing key backed up to: vault-keys/age.key.bak-${TS}"
fi

# Reconstruct via vault container CLI sub-command
# TODO (Phase 1 follow-up): verify -mnemonic-to-key exists in coderaft-vault image
mkdir -p "${INSTALL_DIR}/vault-keys"
RECONSTRUCTED_KEY=$(echo "${RECOVERY_PHRASE}" | \
    docker run --rm -i ghcr.io/liamj74/coderaft-vault:latest \
        -mnemonic-to-key /dev/stdin 2>/dev/null || true)

if [ -z "$RECONSTRUCTED_KEY" ]; then
    echo ""
    echo "  ⚠ -mnemonic-to-key sub-command not available (Phase 1 TODO)." >&2
    echo "    If the vault image does not yet implement this sub-command, restore" >&2
    echo "    vault-keys/age.key from a secure backup (encrypted USB / 1Password)." >&2
    exit 1
fi

# Validate key format (should start with AGE-SECRET-KEY-)
if ! echo "$RECONSTRUCTED_KEY" | grep -q '^AGE-SECRET-KEY-'; then
    echo "  ✗ Reconstructed key does not look like an age private key." >&2
    echo "    Double-check the recovery phrase and try again." >&2
    exit 1
fi

# Write the key
printf '%s\n' "$RECONSTRUCTED_KEY" > "${INSTALL_DIR}/vault-keys/age.key"
chmod 400 "${INSTALL_DIR}/vault-keys/age.key"
echo "  ✓ vault-keys/age.key restored"

# Restart vault container
echo "  Restarting coderaft-vault..."
(cd "${INSTALL_DIR}" && docker compose restart coderaft-vault 2>/dev/null) || \
(cd "${INSTALL_DIR}" && docker compose up -d coderaft-vault 2>/dev/null)

# Wait for healthy
_VAULT_HEALTHY=0
for _i in $(seq 1 20); do
    _HEALTH=$(cd "${INSTALL_DIR}" && docker compose exec -T coderaft-vault \
        /bin/sh -c 'wget -qO- http://localhost:8200/v1/health 2>/dev/null' 2>/dev/null || true)
    if echo "$_HEALTH" | grep -q '"sealed":false'; then
        _VAULT_HEALTHY=1
        break
    fi
    sleep 3
done

if [ "$_VAULT_HEALTHY" = "1" ]; then
    echo "  ✓ coderaft-vault is healthy and unsealed"
    echo ""
    echo "  Recovery complete."
else
    echo ""
    echo "  ⚠ Vault restarted but did not become healthy within 60s."
    echo "    Check logs: docker compose logs coderaft-vault"
    exit 1
fi
