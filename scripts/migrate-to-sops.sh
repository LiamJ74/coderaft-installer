#!/usr/bin/env bash
# =============================================================================
# CodeRaft Platform — Migrate legacy secrets to SOPS + age
# Usage: bash migrate-to-sops.sh   (from the install directory)
#
# Idempotent: can be safely re-run if the first execution fails.
# =============================================================================

set -euo pipefail

SCRIPT_VERSION="1.0.0"
GITHUB_RAW="https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/migrate-to-sops.sh"

# ── Self-update ──────────────────────────────────────────────────────────────
if [ "${CODERAFT_SKIP_SELF_UPDATE:-0}" != "1" ]; then
  _TMP_SCRIPT="$(mktemp)"
  if curl -fsSL --max-time 10 "$GITHUB_RAW" -o "$_TMP_SCRIPT" 2>/dev/null; then
    _REMOTE_VER=$(grep '^SCRIPT_VERSION=' "$_TMP_SCRIPT" | head -1 | cut -d'"' -f2)
    if [ -n "$_REMOTE_VER" ] && [ "$_REMOTE_VER" != "$SCRIPT_VERSION" ]; then
      echo "  [migrate] New version available ($_REMOTE_VER). Updating..."
      chmod +x "$_TMP_SCRIPT"
      exec env CODERAFT_SKIP_SELF_UPDATE=1 bash "$_TMP_SCRIPT" "$@"
    fi
  fi
  rm -f "$_TMP_SCRIPT"
fi

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
fatal()   { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }
headline(){ echo -e "\n  ${YELLOW}──${NC} $*"; }

# ── Constants ────────────────────────────────────────────────────────────────
AGE_KEY_DIR="/etc/coderaft"
AGE_KEY_PATH="${AGE_KEY_DIR}/age.key"
AGE_PUB_PATH="${AGE_KEY_DIR}/age.pub"
SOPS_VERSION="v3.8.1"
AGE_VERSION="v1.2.1"
DATA_DIR="${CODERAFT_DATA_DIR:-./dashboard_data}"
BACKUP_PASS_ENV="${CODERAFT_BACKUP_PASS:-}"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  CodeRaft — SOPS+age secrets migration   ║"
echo "  ║  (v${SCRIPT_VERSION})                            ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── 1. Detect plaintext .env ─────────────────────────────────────────────────
headline ".env detection"
if [ ! -f ".env" ]; then
  info "No .env file found. No migration needed."
  exit 0
fi

if [ -f ".env.enc" ] && [ ! -f ".env" ]; then
  info "Migration already done (.env.enc present, .env absent)."
  exit 0
fi

# If .env.enc exists AND so does .env → "mixed", continue anyway
if [ -f ".env.enc" ]; then
  warn "Both .env and .env.enc are present — running consistency check..."
fi

info ".env detected. Starting migration..."

# ── 2. Check/install age ─────────────────────────────────────────────────────
headline "Binary check"
install_age() {
  echo "  Downloading age ${AGE_VERSION}..."
  case "$(uname -s)" in
    Darwin) _AGE_OS="darwin" ;;
    Linux)  _AGE_OS="linux"  ;;
    *)      fatal "Unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) _AGE_ARCH="arm64" ;;
    x86_64|amd64)  _AGE_ARCH="amd64" ;;
    *)             fatal "Unsupported architecture: $(uname -m)" ;;
  esac
  _TMP="$(mktemp -d)"
  trap 'rm -rf "$_TMP"' EXIT
  curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-${_AGE_OS}-${_AGE_ARCH}.tar.gz" \
      -o "${_TMP}/age.tar.gz" || fatal "Could not download age"
  tar -xzf "${_TMP}/age.tar.gz" -C "${_TMP}"
  sudo install -m 755 "${_TMP}/age/age-keygen" /usr/local/bin/age-keygen \
    || fatal "Could not install age-keygen (sudo required)"
  info "age-keygen installed"
}

install_sops() {
  echo "  Downloading sops ${SOPS_VERSION}..."
  case "$(uname -s)" in
    Darwin) _SOPS_OS="darwin" ;;
    Linux)  _SOPS_OS="linux"  ;;
    *)      fatal "Unsupported OS for sops: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) _SOPS_ARCH="arm64" ;;
    x86_64|amd64)  _SOPS_ARCH="amd64" ;;
    *)             fatal "Unsupported architecture for sops: $(uname -m)" ;;
  esac
  _SOPS_BIN="sops-${SOPS_VERSION}.${_SOPS_OS}.${_SOPS_ARCH}"
  curl -fsSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/${_SOPS_BIN}" \
      -o "/tmp/sops" || fatal "Could not download sops"
  sudo install -m 755 /tmp/sops /usr/local/bin/sops \
    || fatal "Could not install sops (sudo required)"
  rm -f /tmp/sops
  info "sops installed"
}

if ! command -v age-keygen &>/dev/null; then
  install_age
else
  info "age-keygen found: $(command -v age-keygen)"
fi

if ! command -v sops &>/dev/null; then
  install_sops
else
  info "sops found: $(command -v sops)"
fi

# ── 3. age key ───────────────────────────────────────────────────────────────
headline "age key"
if [ -f "${AGE_KEY_PATH}" ]; then
  info "Existing age key found: ${AGE_KEY_PATH}"
else
  echo "  Generating age key (sudo required)..."
  sudo mkdir -p "${AGE_KEY_DIR}"
  sudo age-keygen -o "${AGE_KEY_PATH}" 2>/dev/null \
    || fatal "Could not generate the age key"
  sudo chmod 400 "${AGE_KEY_PATH}"
  sudo chown root:root "${AGE_KEY_PATH}" 2>/dev/null || true
  info "age key generated: ${AGE_KEY_PATH}"
fi

# Extract the public key
AGE_PUB=$(sudo grep "# public key:" "${AGE_KEY_PATH}" | awk '{print $NF}')
if [ -z "$AGE_PUB" ]; then
  fatal "Could not extract age public key from ${AGE_KEY_PATH}"
fi
echo "$AGE_PUB" | sudo tee "${AGE_PUB_PATH}" > /dev/null
sudo chmod 444 "${AGE_PUB_PATH}"
info "Public key: ${AGE_PUB}"

# ── 4. GPG backup of the original .env ───────────────────────────────────────
headline "GPG backup of .env"
mkdir -p "${DATA_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_PATH="${DATA_DIR}/migration-backup-${TS}.env.gpg"

if ! command -v gpg &>/dev/null; then
  warn "gpg not found — encrypted GPG backup is skipped."
  warn "WARNING: Manually keep an offline copy of .env before continuing."
  read -r -p "  Continue without GPG backup? [yes/NO]: " _CONFIRM
  if [ "${_CONFIRM}" != "yes" ]; then
    fatal "Migration cancelled by user."
  fi
else
  # Get the passphrase
  if [ -n "${BACKUP_PASS_ENV}" ]; then
    _PASSPHRASE="${BACKUP_PASS_ENV}"
  else
    # shellcheck disable=SC2162
    read -r -s -p "  Passphrase for the GPG backup (will NOT be stored): " _PASSPHRASE
    echo ""
    # shellcheck disable=SC2162
    read -r -s -p "  Confirm the passphrase: " _PASSPHRASE2
    echo ""
    if [ "${_PASSPHRASE}" != "${_PASSPHRASE2}" ]; then
      fatal "Passphrases do not match."
    fi
  fi

  if [ -z "${_PASSPHRASE}" ]; then
    fatal "Passphrase cannot be empty. Aborting."
  fi

  gpg --batch --yes \
      --passphrase-fd 3 \
      --cipher-algo AES256 \
      --compress-algo none \
      --symmetric \
      --output "${BACKUP_PATH}" \
      .env \
      3< <(printf '%s' "${_PASSPHRASE}") \
    || fatal "GPG backup failed"

  unset _PASSPHRASE _PASSPHRASE2
  info "GPG backup created: ${BACKUP_PATH}"
  warn "IMPORTANT: Keep the passphrase offline (vault, password manager)."
  warn "          Lost passphrase = backup inaccessible = secrets lost if the migration breaks."
fi

# ── 5. SOPS encryption ───────────────────────────────────────────────────────
headline "SOPS encryption"
sops --encrypt \
     --age "${AGE_PUB}" \
     --output .env.enc \
     .env \
  || fatal "SOPS encryption failed"
info ".env.enc created"

# ── 6. Verify decryption ─────────────────────────────────────────────────────
headline "Integrity check"
_VERIFY_TMP="$(mktemp)"
trap 'rm -f "${_VERIFY_TMP}"' EXIT
SOPS_AGE_KEY_FILE="${AGE_KEY_PATH}" \
  sudo -E sops --decrypt .env.enc > "${_VERIFY_TMP}" \
  || fatal "Could not decrypt .env.enc — aborting (.env is preserved)"

if ! diff -q "${_VERIFY_TMP}" .env > /dev/null 2>&1; then
  warn "Difference detected between .env and decrypted .env.enc!"
  diff "${_VERIFY_TMP}" .env || true
  fatal "Verification failed — .env is preserved intact. Check manually."
fi
rm -f "${_VERIFY_TMP}"
info "Verification OK: decryption matches the original .env"

# ── 7. Remove plaintext .env ─────────────────────────────────────────────────
headline "Remove plaintext .env"
rm .env
info ".env removed (only .env.enc remains on disk)"

# ── 8. RedFox jwt.key migration ──────────────────────────────────────────────
headline "RedFox jwt.key migration"
REDFOX_CERT_DIR="./redfox-certs"
REDFOX_JWT_KEY="${REDFOX_CERT_DIR}/jwt.key"
OVERRIDE_FILE="./docker-compose.override.yml"

if [ -f "${REDFOX_JWT_KEY}" ]; then
  # Check that the file is referenced as an env var in the override
  if [ -f "${OVERRIDE_FILE}" ] && grep -q "REDFOX_JWT_KEY" "${OVERRIDE_FILE}" 2>/dev/null; then
    info "jwt.key detected and referenced as env var. Migrating to file mount..."
    # Create the Docker secrets directory if needed
    mkdir -p "${REDFOX_CERT_DIR}"
    # Remove the old env entry and add a volume mount
    # Safe pattern: sed in-place with backup
    _OV_BAK="${OVERRIDE_FILE}.pre-migration-${TS}"
    cp "${OVERRIDE_FILE}" "${_OV_BAK}"
    # Replace REDFOX_JWT_KEY=... with REDFOX_JWT_KEY_PATH=/run/secrets/jwt.key
    sed -i.bak \
      's|REDFOX_JWT_KEY=.*|REDFOX_JWT_KEY_PATH=/run/secrets/jwt.key|g' \
      "${OVERRIDE_FILE}"
    rm -f "${OVERRIDE_FILE}.bak"

    # Add the volume mount if not already present
    if ! grep -q "redfox-certs/jwt.key" "${OVERRIDE_FILE}" 2>/dev/null; then
      warn "Manual addition of jwt.key volume mount required in ${OVERRIDE_FILE}."
      warn "Add under the redfox-api service:"
      warn "  volumes:"
      warn "    - ./redfox-certs/jwt.key:/run/secrets/jwt.key:ro"
    fi

    chmod 400 "${REDFOX_JWT_KEY}"
    info "jwt.key converted to file mount (REDFOX_JWT_KEY_PATH=/run/secrets/jwt.key)"
  else
    info "jwt.key found but not referenced as env var — no action required."
  fi
else
  info "No redfox-certs/jwt.key — no action required."
fi

# ── 9. Audit log ─────────────────────────────────────────────────────────────
mkdir -p "${DATA_DIR}"
_SECRET_COUNT=$(wc -l < .env.enc 2>/dev/null || echo "?")
echo "[migrate] migrated at ${TS} | sops+age | secrets_lines=${_SECRET_COUNT}" \
  >> "${DATA_DIR}/migration.log"
info "Audit log updated: ${DATA_DIR}/migration.log"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Migration completed successfully           ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf  "  ║  .env.enc      : %-36s║\n" "$(pwd)/.env.enc"
printf  "  ║  age key       : %-36s║\n" "${AGE_KEY_PATH}"
if [ -f "${BACKUP_PATH}" ]; then
printf  "  ║  GPG backup    : %-36s║\n" "${BACKUP_PATH}"
fi
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  IMPORTANT: Back up the age key offline!            ║"
echo "  ║  gpg --symmetric /etc/coderaft/age.key              ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
