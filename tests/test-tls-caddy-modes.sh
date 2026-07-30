#!/bin/bash
# =============================================================================
# Integration test — Caddyfile TLS template (internal / wildcard / acme)
#
# Extracts the Caddyfile template embedded in install.sh, then, against a
# real caddy:2-alpine container:
#   1. `caddy validate` for the three TLS modes (env-driven)
#   2. internal mode live: root CA generated at
#      /data/caddy/pki/authorities/local/root.crt within 30s, TLS handshake
#      on SNI coderaft.local serves a Caddy Local Authority cert
#   3. wildcard mode live: an uploaded *.corp.com cert is the one actually
#      served for SNI sec.corp.com
#
# Requires: docker, openssl. Run from anywhere:
#   bash tests/test-tls-caddy-modes.sh
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
CONTAINER="coderaft-caddy-tlstest"
trap 'docker rm -f ${CONTAINER} >/dev/null 2>&1 || true; rm -rf "${WORK_DIR}"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1" >&2; }

# ── Extract the Caddyfile template from install.sh ──────────────────────────
awk '/^    cat > Caddyfile << .CADDY.$/{flag=1;next} /^CADDY$/{flag=0} flag' \
    "${REPO_DIR}/install.sh" > "${WORK_DIR}/Caddyfile"
[ -s "${WORK_DIR}/Caddyfile" ] && ok "Caddyfile template extracted from install.sh" \
    || { fail "Could not extract Caddyfile template"; exit 1; }
grep -q 'CADDY_TLS_MODE_ARGS' "${WORK_DIR}/Caddyfile" && ok "template is env-driven (CADDY_TLS_MODE_ARGS)" \
    || fail "template misses CADDY_TLS_MODE_ARGS placeholder"
grep -q 'mkcert\|coderaft.local.pem' "${WORK_DIR}/Caddyfile" \
    && fail "template still references mkcert certs" \
    || ok "no mkcert reference in template"

# ── Test wildcard cert fixture ───────────────────────────────────────────────
mkdir -p "${WORK_DIR}/certs"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${WORK_DIR}/certs/wildcard.key" -out "${WORK_DIR}/certs/wildcard.crt" \
    -days 365 -subj "/CN=*.corp.com" \
    -addext "subjectAltName=DNS:*.corp.com,DNS:corp.com" >/dev/null 2>&1
chmod 600 "${WORK_DIR}/certs/wildcard.key"

validate() {
    local label="$1"; shift
    if docker run --rm -v "${WORK_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "${WORK_DIR}/certs:/certs:ro" "$@" \
        caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile 2>&1 | grep -q "Valid configuration"; then
        ok "caddy validate — ${label}"
    else
        fail "caddy validate — ${label}"
    fi
}

# ── 1. Static validation, three modes ────────────────────────────────────────
validate "mode internal (defaults)"
validate "mode wildcard" \
    -e CODERAFT_HOSTNAME=sec.corp.com \
    -e "CODERAFT_TLS_SITES=sec.corp.com, *.sec.corp.com" \
    -e "CADDY_TLS_MODE_ARGS=/certs/wildcard.crt /certs/wildcard.key"
validate "mode acme" \
    -e CODERAFT_HOSTNAME=sec.corp.com \
    -e "CODERAFT_TLS_SITES=sec.corp.com" \
    -e "CADDY_TLS_MODE_ARGS=ops@corp.com"

# ── 2. Live internal mode: CA generation + handshake ────────────────────────
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" \
    -v "${WORK_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -p 127.0.0.1:18443:443 caddy:2-alpine >/dev/null

CA_READY=0
for i in $(seq 1 15); do
    if docker exec "${CONTAINER}" test -f /data/caddy/pki/authorities/local/root.crt 2>/dev/null; then
        CA_READY=1; break
    fi
    sleep 2
done
[ "${CA_READY}" = "1" ] && ok "internal CA generated at the installer-expected path (<30s)" \
    || fail "internal CA not generated within 30s"

docker cp "${CONTAINER}:/data/caddy/pki/authorities/local/root.crt" "${WORK_DIR}/root.crt" >/dev/null 2>&1
openssl x509 -in "${WORK_DIR}/root.crt" -noout -subject 2>/dev/null | grep -q "Caddy Local Authority" \
    && ok "exported root.crt is a Caddy Local Authority root" \
    || fail "exported root.crt is not a valid CA cert"

ISSUER=$(echo | openssl s_client -connect 127.0.0.1:18443 -servername coderaft.local 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null || true)
echo "${ISSUER}" | grep -q "Caddy Local Authority" \
    && ok "TLS handshake (SNI coderaft.local) served an internal-CA cert" \
    || fail "TLS handshake did not serve an internal-CA cert (issuer: ${ISSUER})"
docker rm -f "${CONTAINER}" >/dev/null 2>&1

# ── 3. Live wildcard mode: uploaded cert is actually served ──────────────────
docker run -d --name "${CONTAINER}" \
    -v "${WORK_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "${WORK_DIR}/certs:/certs:ro" \
    -e CODERAFT_HOSTNAME=sec.corp.com \
    -e "CODERAFT_TLS_SITES=sec.corp.com, *.sec.corp.com" \
    -e "CADDY_TLS_MODE_ARGS=/certs/wildcard.crt /certs/wildcard.key" \
    -p 127.0.0.1:18443:443 caddy:2-alpine >/dev/null
sleep 3

SERVED_SUBJECT=$(echo | openssl s_client -connect 127.0.0.1:18443 -servername sec.corp.com 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null || true)
echo "${SERVED_SUBJECT}" | grep -q '\*.corp.com' \
    && ok "wildcard mode serves the uploaded *.corp.com certificate" \
    || fail "wildcard mode served the wrong cert (subject: ${SERVED_SUBJECT})"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" = "0" ]
