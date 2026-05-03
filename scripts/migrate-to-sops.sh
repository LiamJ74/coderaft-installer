#!/usr/bin/env bash
# =============================================================================
# CodeRaft Platform — Migration secrets legacy vers SOPS + age
# Usage : bash migrate-to-sops.sh   (depuis le répertoire d'install)
#
# Idempotent : peut être relancé sans risque si la première exécution échoue.
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
      echo "  [migrate] Nouvelle version disponible ($_REMOTE_VER). Mise à jour..."
      chmod +x "$_TMP_SCRIPT"
      exec env CODERAFT_SKIP_SELF_UPDATE=1 bash "$_TMP_SCRIPT" "$@"
    fi
  fi
  rm -f "$_TMP_SCRIPT"
fi

# ── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
fatal()   { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }
headline(){ echo -e "\n  ${YELLOW}──${NC} $*"; }

# ── Constantes ────────────────────────────────────────────────────────────────
AGE_KEY_DIR="/etc/coderaft"
AGE_KEY_PATH="${AGE_KEY_DIR}/age.key"
AGE_PUB_PATH="${AGE_KEY_DIR}/age.pub"
SOPS_VERSION="v3.8.1"
AGE_VERSION="v1.2.1"
DATA_DIR="${CODERAFT_DATA_DIR:-./dashboard_data}"
BACKUP_PASS_ENV="${CODERAFT_BACKUP_PASS:-}"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  CodeRaft — Migration secrets SOPS+age   ║"
echo "  ║  (v${SCRIPT_VERSION})                            ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── 1. Détecter .env clair ───────────────────────────────────────────────────
headline "Détection .env"
if [ ! -f ".env" ]; then
  info "Aucun fichier .env trouvé. Aucune migration nécessaire."
  exit 0
fi

if [ -f ".env.enc" ] && [ ! -f ".env" ]; then
  info "Migration déjà effectuée (.env.enc présent, .env absent)."
  exit 0
fi

# Si .env.enc existe ET .env aussi → "mixed", on continue quand même
if [ -f ".env.enc" ]; then
  warn "Les deux .env et .env.enc sont présents — vérification de cohérence..."
fi

info ".env détecté. Lancement de la migration..."

# ── 2. Vérifier/installer age ─────────────────────────────────────────────────
headline "Vérification binaires"
install_age() {
  echo "  Téléchargement de age ${AGE_VERSION}..."
  case "$(uname -s)" in
    Darwin) _AGE_OS="darwin" ;;
    Linux)  _AGE_OS="linux"  ;;
    *)      fatal "OS non supporté : $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) _AGE_ARCH="arm64" ;;
    x86_64|amd64)  _AGE_ARCH="amd64" ;;
    *)             fatal "Architecture non supportée : $(uname -m)" ;;
  esac
  _TMP="$(mktemp -d)"
  trap 'rm -rf "$_TMP"' EXIT
  curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-${_AGE_OS}-${_AGE_ARCH}.tar.gz" \
      -o "${_TMP}/age.tar.gz" || fatal "Impossible de télécharger age"
  tar -xzf "${_TMP}/age.tar.gz" -C "${_TMP}"
  sudo install -m 755 "${_TMP}/age/age-keygen" /usr/local/bin/age-keygen \
    || fatal "Impossible d'installer age-keygen (sudo requis)"
  info "age-keygen installé"
}

install_sops() {
  echo "  Téléchargement de sops ${SOPS_VERSION}..."
  case "$(uname -s)" in
    Darwin) _SOPS_OS="darwin" ;;
    Linux)  _SOPS_OS="linux"  ;;
    *)      fatal "OS non supporté pour sops : $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) _SOPS_ARCH="arm64" ;;
    x86_64|amd64)  _SOPS_ARCH="amd64" ;;
    *)             fatal "Architecture non supportée pour sops : $(uname -m)" ;;
  esac
  _SOPS_BIN="sops-${SOPS_VERSION}.${_SOPS_OS}.${_SOPS_ARCH}"
  curl -fsSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/${_SOPS_BIN}" \
      -o "/tmp/sops" || fatal "Impossible de télécharger sops"
  sudo install -m 755 /tmp/sops /usr/local/bin/sops \
    || fatal "Impossible d'installer sops (sudo requis)"
  rm -f /tmp/sops
  info "sops installé"
}

if ! command -v age-keygen &>/dev/null; then
  install_age
else
  info "age-keygen trouvé : $(command -v age-keygen)"
fi

if ! command -v sops &>/dev/null; then
  install_sops
else
  info "sops trouvé : $(command -v sops)"
fi

# ── 3. Clé age ───────────────────────────────────────────────────────────────
headline "Clé age"
if [ -f "${AGE_KEY_PATH}" ]; then
  info "Clé age existante trouvée : ${AGE_KEY_PATH}"
else
  echo "  Génération de la clé age (sudo requis)..."
  sudo mkdir -p "${AGE_KEY_DIR}"
  sudo age-keygen -o "${AGE_KEY_PATH}" 2>/dev/null \
    || fatal "Impossible de générer la clé age"
  sudo chmod 400 "${AGE_KEY_PATH}"
  sudo chown root:root "${AGE_KEY_PATH}" 2>/dev/null || true
  info "Clé age générée : ${AGE_KEY_PATH}"
fi

# Extraire la clé publique
AGE_PUB=$(sudo grep "# public key:" "${AGE_KEY_PATH}" | awk '{print $NF}')
if [ -z "$AGE_PUB" ]; then
  fatal "Impossible d'extraire la clé publique age depuis ${AGE_KEY_PATH}"
fi
echo "$AGE_PUB" | sudo tee "${AGE_PUB_PATH}" > /dev/null
sudo chmod 444 "${AGE_PUB_PATH}"
info "Clé publique : ${AGE_PUB}"

# ── 4. Backup GPG du .env original ───────────────────────────────────────────
headline "Backup GPG du .env"
mkdir -p "${DATA_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_PATH="${DATA_DIR}/migration-backup-${TS}.env.gpg"

if ! command -v gpg &>/dev/null; then
  warn "gpg non trouvé — le backup chiffré GPG est ignoré."
  warn "ATTENTION : Conservez manuellement une copie de .env hors-ligne avant de continuer."
  read -r -p "  Continuer sans backup GPG ? [oui/NON] : " _CONFIRM
  if [ "${_CONFIRM}" != "oui" ]; then
    fatal "Migration annulée par l'utilisateur."
  fi
else
  # Récupérer la passphrase
  if [ -n "${BACKUP_PASS_ENV}" ]; then
    _PASSPHRASE="${BACKUP_PASS_ENV}"
  else
    # shellcheck disable=SC2162
    read -r -s -p "  Passphrase pour le backup GPG (ne sera PAS stockée) : " _PASSPHRASE
    echo ""
    # shellcheck disable=SC2162
    read -r -s -p "  Confirmer la passphrase : " _PASSPHRASE2
    echo ""
    if [ "${_PASSPHRASE}" != "${_PASSPHRASE2}" ]; then
      fatal "Les passphrases ne correspondent pas."
    fi
  fi

  if [ -z "${_PASSPHRASE}" ]; then
    fatal "La passphrase ne peut pas être vide. Abandon."
  fi

  gpg --batch --yes \
      --passphrase-fd 3 \
      --cipher-algo AES256 \
      --compress-algo none \
      --symmetric \
      --output "${BACKUP_PATH}" \
      .env \
      3< <(printf '%s' "${_PASSPHRASE}") \
    || fatal "Échec du backup GPG"

  unset _PASSPHRASE _PASSPHRASE2
  info "Backup GPG créé : ${BACKUP_PATH}"
  warn "IMPORTANT : Conservez la passphrase hors-ligne (coffre, gestionnaire de mots de passe)."
  warn "           Passphrase perdue = backup inaccessible = perte des secrets si migration cassée."
fi

# ── 5. Chiffrement SOPS ───────────────────────────────────────────────────────
headline "Chiffrement SOPS"
sops --encrypt \
     --age "${AGE_PUB}" \
     --output .env.enc \
     .env \
  || fatal "Échec du chiffrement SOPS"
info ".env.enc créé"

# ── 6. Vérification du déchiffrement ─────────────────────────────────────────
headline "Vérification intégrité"
_VERIFY_TMP="$(mktemp)"
trap 'rm -f "${_VERIFY_TMP}"' EXIT
SOPS_AGE_KEY_FILE="${AGE_KEY_PATH}" \
  sudo -E sops --decrypt .env.enc > "${_VERIFY_TMP}" \
  || fatal "Impossible de déchiffrer .env.enc — abandon (le .env est conservé)"

if ! diff -q "${_VERIFY_TMP}" .env > /dev/null 2>&1; then
  warn "Différence détectée entre .env et déchiffrement de .env.enc !"
  diff "${_VERIFY_TMP}" .env || true
  fatal "Vérification échouée — le .env est conservé intact. Vérifiez manuellement."
fi
rm -f "${_VERIFY_TMP}"
info "Vérification OK : le déchiffrement est identique au .env original"

# ── 7. Suppression du .env ────────────────────────────────────────────────────
headline "Suppression .env en clair"
rm .env
info ".env supprimé (seul .env.enc reste sur disque)"

# ── 8. Migration RedFox jwt.key ───────────────────────────────────────────────
headline "Migration RedFox jwt.key"
REDFOX_CERT_DIR="./redfox-certs"
REDFOX_JWT_KEY="${REDFOX_CERT_DIR}/jwt.key"
OVERRIDE_FILE="./docker-compose.override.yml"

if [ -f "${REDFOX_JWT_KEY}" ]; then
  # Vérifier que le fichier est référencé comme var env dans override
  if [ -f "${OVERRIDE_FILE}" ] && grep -q "REDFOX_JWT_KEY" "${OVERRIDE_FILE}" 2>/dev/null; then
    info "jwt.key détecté et référencé comme env var. Migration vers file mount..."
    # Créer répertoire secrets Docker si nécessaire
    mkdir -p "${REDFOX_CERT_DIR}"
    # Supprimer l'ancienne entrée env et ajouter un volume mount
    # Pattern sûr : sed in-place avec backup
    _OV_BAK="${OVERRIDE_FILE}.pre-migration-${TS}"
    cp "${OVERRIDE_FILE}" "${_OV_BAK}"
    # Remplacer REDFOX_JWT_KEY=... par REDFOX_JWT_KEY_PATH=/run/secrets/jwt.key
    sed -i.bak \
      's|REDFOX_JWT_KEY=.*|REDFOX_JWT_KEY_PATH=/run/secrets/jwt.key|g' \
      "${OVERRIDE_FILE}"
    rm -f "${OVERRIDE_FILE}.bak"

    # Ajouter le volume mount si pas déjà présent
    if ! grep -q "redfox-certs/jwt.key" "${OVERRIDE_FILE}" 2>/dev/null; then
      warn "Ajout manuel du volume mount jwt.key requis dans ${OVERRIDE_FILE}."
      warn "Ajoutez sous le service redfox-api :"
      warn "  volumes:"
      warn "    - ./redfox-certs/jwt.key:/run/secrets/jwt.key:ro"
    fi

    chmod 400 "${REDFOX_JWT_KEY}"
    info "jwt.key converti en file mount (REDFOX_JWT_KEY_PATH=/run/secrets/jwt.key)"
  else
    info "jwt.key trouvé mais pas référencé comme env var — aucune action requise."
  fi
else
  info "Pas de redfox-certs/jwt.key — aucune action requise."
fi

# ── 9. Audit log ─────────────────────────────────────────────────────────────
mkdir -p "${DATA_DIR}"
_SECRET_COUNT=$(wc -l < .env.enc 2>/dev/null || echo "?")
echo "[migrate] migrated at ${TS} | sops+age | secrets_lines=${_SECRET_COUNT}" \
  >> "${DATA_DIR}/migration.log"
info "Audit log mis à jour : ${DATA_DIR}/migration.log"

# ── Résumé ────────────────────────────────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║           Migration terminée avec succès             ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf  "  ║  .env.enc      : %-36s║\n" "$(pwd)/.env.enc"
printf  "  ║  Clé age       : %-36s║\n" "${AGE_KEY_PATH}"
if [ -f "${BACKUP_PATH}" ]; then
printf  "  ║  Backup GPG    : %-36s║\n" "${BACKUP_PATH}"
fi
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  IMPORTANT : Sauvegardez la clé age hors-ligne !    ║"
echo "  ║  gpg --symmetric /etc/coderaft/age.key              ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
