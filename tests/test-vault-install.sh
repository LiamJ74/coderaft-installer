#!/bin/bash
# test-vault-install.sh — test suite for the vault integration (D8).
#
# This test validates the vault bootstrap path by running install.sh in
# CODERAFT_TEST_MODE=1, which:
#   - auto-accepts the CONFIRMED prompt
#   - skips actual product image pulls (vault image still pulled unless
#     CODERAFT_SKIP_VAULT_PULL=1 is also set)
#
# The test also validates:
#   - emitted docker-compose.yml parses cleanly
#   - vault-keys/age.key and vault-tls/ca.crt are generated
#   - all 4 client certs are present with correct SANs
#   - vault-config/acl.yaml is written
#   - CODERAFT_VAULT_URL appears in .env
#
# Usage:
#   bash tests/test-vault-install.sh
#
# Requirements:
#   - Docker (to run vault container for SAN verification)
#   - age-keygen (auto-downloaded by installer if absent)
#   - openssl (for cert verification)
#   - docker compose v2
#
# To also test a live vault start:
#   CODERAFT_TEST_LIVE=1 bash tests/test-vault-install.sh
#
# To test rollback path (failure injected at step 4e):
#   CODERAFT_TEST_ROLLBACK=1 bash tests/test-vault-install.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

_pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
_fail() { echo "  [FAIL] $1" >&2; FAIL=$((FAIL + 1)); }
_section() { echo ""; echo "── $1 ──────────────────────────────────────────────────"; }

cleanup() {
    if [ "${CODERAFT_KEEP_TEST_DIR:-0}" != "1" ]; then
        rm -rf "${TEST_DIR}"
    else
        echo ""
        echo "  Test directory kept at: ${TEST_DIR}"
    fi
}
trap cleanup EXIT

echo ""
echo "  coderaft-vault installer tests"
echo "  Test directory: ${TEST_DIR}"

# ── Static checks ─────────────────────────────────────────────────────────────
_section "bash -n syntax checks"

for script in \
    "${REPO_ROOT}/install.sh" \
    "${REPO_ROOT}/scripts/update.sh" \
    "${REPO_ROOT}/scripts/vault-set.sh" \
    "${REPO_ROOT}/scripts/vault-recover.sh"; do
    if bash -n "$script" 2>/dev/null; then
        _pass "bash -n $script"
    else
        _fail "bash -n $script"
    fi
done

_section "shellcheck -S error"

if command -v shellcheck &>/dev/null; then
    for script in \
        "${REPO_ROOT}/install.sh" \
        "${REPO_ROOT}/scripts/update.sh" \
        "${REPO_ROOT}/scripts/vault-set.sh" \
        "${REPO_ROOT}/scripts/vault-recover.sh"; do
        if shellcheck -S error "$script" 2>/dev/null; then
            _pass "shellcheck $script"
        else
            _fail "shellcheck $script"
        fi
    done
else
    echo "  [SKIP] shellcheck not installed"
fi

# ── Fresh install (CODERAFT_TEST_MODE=1) ──────────────────────────────────────
_section "Fresh install (test mode)"

echo "  Running install.sh in ${TEST_DIR}..."
export CODERAFT_TEST_MODE=1
export CODERAFT_SKIP_HTTPS=1
export CODERAFT_SKIP_HOSTS=1
export SKIP_NATIVE_CAPTURE=1
export SKIP_COSIGN_VERIFY=1
export INSTALL_DIR="${TEST_DIR}"

# The installer CDs into INSTALL_DIR internally; we run it from there
# to simulate the real oneliner `cd coderaft && bash install.sh` flow.
cd "${TEST_DIR}"
bash "${REPO_ROOT}/install.sh" > "${TEST_DIR}/install.log" 2>&1
INSTALL_RC=$?
cd "${REPO_ROOT}"

if [ "$INSTALL_RC" -eq 0 ]; then
    _pass "install.sh exit code 0"
else
    _fail "install.sh exit code ${INSTALL_RC} (see ${TEST_DIR}/install.log)"
fi

# Verify generated files
[ -f "${TEST_DIR}/docker-compose.yml" ] && _pass "docker-compose.yml exists" || _fail "docker-compose.yml missing"
[ -f "${TEST_DIR}/.env" ]               && _pass ".env exists"               || _fail ".env missing"
[ -f "${TEST_DIR}/vault-keys/age.key" ] && _pass "vault-keys/age.key exists" || _fail "vault-keys/age.key missing"
[ -f "${TEST_DIR}/vault-tls/ca.crt" ]   && _pass "vault-tls/ca.crt exists"   || _fail "vault-tls/ca.crt missing"
[ -f "${TEST_DIR}/vault-tls/server.crt" ] && _pass "vault-tls/server.crt exists" || _fail "vault-tls/server.crt missing"
[ -f "${TEST_DIR}/vault-config/acl.yaml" ] && _pass "vault-config/acl.yaml exists" || _fail "vault-config/acl.yaml missing"

# Key permissions
if [ -f "${TEST_DIR}/vault-keys/age.key" ]; then
    PERMS=$(stat -c '%a' "${TEST_DIR}/vault-keys/age.key" 2>/dev/null || stat -f '%OLp' "${TEST_DIR}/vault-keys/age.key" 2>/dev/null || echo "unknown")
    [ "$PERMS" = "400" ] && _pass "vault-keys/age.key perms 0400" || _fail "vault-keys/age.key perms: ${PERMS} (want 400)"
fi

# Vault env vars in .env
if grep -q '^CODERAFT_VAULT_URL=' "${TEST_DIR}/.env" 2>/dev/null; then
    _pass ".env contains CODERAFT_VAULT_URL"
else
    _fail ".env missing CODERAFT_VAULT_URL"
fi

# ── Docker compose YAML validation ────────────────────────────────────────────
_section "docker compose config"

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    # The compose references ${POSTGRES_PASSWORD} etc. — we need a minimal .env.
    # The installer already wrote .env; just run compose config.
    if (cd "${TEST_DIR}" && docker compose -f docker-compose.yml config --quiet 2>/dev/null); then
        _pass "docker compose config --quiet"
    else
        _fail "docker compose config --quiet (YAML invalid)"
    fi
else
    echo "  [SKIP] docker compose not available"
fi

# ── Client cert SAN verification ──────────────────────────────────────────────
_section "Client cert SAN verification"

if command -v openssl &>/dev/null; then
    # Format: "cert_base:expected_san"
    for san_pair in \
        "dashboard-api-client:dashboard-api.coderaft.local" \
        "entraguard-client:entraguard.coderaft.local" \
        "ravenscan-client:ravenscan.coderaft.local" \
        "redfox-client:redfox.coderaft.local"; do
        cert_base="${san_pair%%:*}"
        expected_san="${san_pair##*:}"
        cert_file="${TEST_DIR}/vault-tls/${cert_base}.crt"
        if [ -f "$cert_file" ]; then
            if openssl x509 -in "$cert_file" -text -noout 2>/dev/null | grep -q "DNS:${expected_san}"; then
                _pass "SAN correct for ${cert_base}: ${expected_san}"
            else
                _fail "SAN missing for ${cert_base} (want DNS:${expected_san})"
            fi
        else
            _fail "${cert_base}.crt not found"
        fi
    done
else
    echo "  [SKIP] openssl not available — skipping SAN checks"
fi

# ── Live vault test (optional) ────────────────────────────────────────────────
if [ "${CODERAFT_TEST_LIVE:-0}" = "1" ] && command -v docker &>/dev/null; then
    _section "Live vault start (CODERAFT_TEST_LIVE=1)"

    (cd "${TEST_DIR}" && docker compose up -d coderaft-vault 2>/dev/null) || true
    sleep 12

    VAULT_HEALTH=""
    for _i in $(seq 1 10); do
        VAULT_HEALTH=$(cd "${TEST_DIR}" && docker compose exec -T coderaft-vault \
            /bin/sh -c 'wget -qO- http://localhost:8200/v1/health 2>/dev/null' 2>/dev/null || true)
        echo "$VAULT_HEALTH" | grep -q '"sealed":false' && break
        sleep 3
    done

    if echo "$VAULT_HEALTH" | grep -q '"sealed":false'; then
        _pass "coderaft-vault health: sealed=false"
    else
        _fail "coderaft-vault health check failed: ${VAULT_HEALTH}"
    fi

    # Vault list returns empty (no secrets yet)
    LIST=$(cd "${TEST_DIR}" && docker compose exec -T coderaft-vault \
        /bin/sh -c 'wget -qO- http://localhost:8200/v1/secret/list 2>/dev/null' 2>/dev/null || true)
    if echo "$LIST" | grep -q '"names":\[\]'; then
        _pass "vault list returns empty names array"
    else
        echo "  [INFO] vault list response: ${LIST}"
    fi

    (cd "${TEST_DIR}" && docker compose down 2>/dev/null) || true
fi

# ── Rollback path test (optional) ─────────────────────────────────────────────
if [ "${CODERAFT_TEST_ROLLBACK:-0}" = "1" ]; then
    _section "Rollback path test (CODERAFT_TEST_ROLLBACK=1)"

    # Create a minimal update-scenario: an existing install dir with .env
    UPDATE_TEST_DIR="$(mktemp -d)"
    cp "${TEST_DIR}/.env" "${UPDATE_TEST_DIR}/.env" 2>/dev/null || true
    cp "${TEST_DIR}/docker-compose.yml" "${UPDATE_TEST_DIR}/docker-compose.yml" 2>/dev/null || true
    # Do NOT copy vault-keys/ so migration is triggered

    export INSTALL_DIR="${UPDATE_TEST_DIR}"
    export CODERAFT_TEST_FAIL=4e

    cd "${UPDATE_TEST_DIR}"
    bash "${REPO_ROOT}/scripts/update.sh" > "${UPDATE_TEST_DIR}/update.log" 2>&1 || true
    cd "${REPO_ROOT}"

    # Sentinel must NOT exist (rollback removed it)
    if [ ! -f "${UPDATE_TEST_DIR}/vault-data/.migrated" ]; then
        _pass "Rollback: sentinel absent after injected failure"
    else
        _fail "Rollback: sentinel should not exist after rollback"
    fi

    # .env must be restored
    if [ -f "${UPDATE_TEST_DIR}/.env" ]; then
        _pass "Rollback: .env restored"
    else
        _fail "Rollback: .env missing after rollback"
    fi

    # Backup dir must exist
    if ls "${UPDATE_TEST_DIR}/backups/migrate-vault-"* >/dev/null 2>&1; then
        _pass "Rollback: backup directory created"
    else
        _fail "Rollback: backup directory missing"
    fi

    rm -rf "${UPDATE_TEST_DIR}"
    unset CODERAFT_TEST_FAIL
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════════"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "  Install log: ${TEST_DIR}/install.log"
    exit 1
fi
