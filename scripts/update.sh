#!/bin/bash
#
# CodeRaft updater
#
# Self-updates from the installer repo, puis compare les digests avant de
# tirer les nouvelles images. Si quelque chose casse, lance rollback.sh.
#
set -e

DASHBOARD_API="${DASHBOARD_API:-http://localhost:3000}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"
BACKUP_DIR="${BACKUP_DIR:-./dashboard_data/backups}"
HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-30}"
HEALTHCHECK_DELAY="${HEALTHCHECK_DELAY:-3}"

# ── Détection plateforme Docker ────────────────────────────────────────────
# Docker Desktop Mac M-series résout strictement linux/arm64/v8 par défaut,
# ce qui échoue sur les manifests qui exposent juste linux/arm64. Idem
# diverses versions Docker Engine. On force DOCKER_DEFAULT_PLATFORM en
# fonction de l'arch hôte pour court-circuiter ce bug.
if [ -z "$DOCKER_DEFAULT_PLATFORM" ]; then
    HOST_ARCH=$(uname -m 2>/dev/null || echo "")
    case "$HOST_ARCH" in
        arm64|aarch64) export DOCKER_DEFAULT_PLATFORM="linux/arm64" ;;
        x86_64|amd64)  export DOCKER_DEFAULT_PLATFORM="linux/amd64" ;;
    esac
fi

# ── Self-update both update.sh and rollback.sh (with re-exec) ──────────────
if [ -z "$CODERAFT_UPDATE_REEXEC" ]; then
    echo "  Vérification des mises à jour du script..."
    REFRESHED=0
    for name in update.sh rollback.sh; do
        LATEST=$(curl -fsSL "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/$name" 2>/dev/null)
        if [ -n "$LATEST" ] && [ ${#LATEST} -gt 50 ]; then
            echo "$LATEST" > "$name.tmp"
            if ! cmp -s "$name" "$name.tmp" 2>/dev/null; then
                mv "$name.tmp" "$name" && chmod +x "$name"
                echo "  $name rafraîchi"
                [ "$name" = "update.sh" ] && REFRESHED=1
            else
                rm -f "$name.tmp"
            fi
        fi
    done
    if [ "$REFRESHED" = "1" ] && [ -x "./update.sh" ]; then
        echo "  Re-exec du script mis à jour..."
        export CODERAFT_UPDATE_REEXEC=1
        exec bash ./update.sh "$@"
    fi
fi

# ── Backup pré-update obligatoire ─────────────────────────────────────────
# Si pg_dump échoue → on bloque l'update (pas de backup = pas d'update).
echo ""
echo "  Sauvegarde pré-update..."
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/preupdate-${TIMESTAMP}.sql.gz"

if docker compose ps postgres --quiet 2>/dev/null | grep -q .; then
    if docker compose exec -T postgres pg_dumpall -U coderaft 2>/dev/null | gzip > "$BACKUP_FILE"; then
        echo "  Backup enregistré : $BACKUP_FILE"
    else
        echo "  ERREUR : pg_dump échoué. Mise à jour annulée (pas de backup = pas d'update)."
        echo "  Vérifiez que le container postgres est sain : docker compose ps"
        exit 1
    fi
else
    echo "  PostgreSQL non détecté — backup ignoré (dashboard sans DB)."
fi

# ── Capture du snapshot de recovery via dashboard-api ─────────────────────
echo "  Capture du snapshot de recovery..."
if [ -n "$ADMIN_TOKEN" ]; then
    curl -fsS -X POST "$DASHBOARD_API/api/dashboard/recovery/snapshots" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -d '{"reason":"pre-update"}' > /dev/null \
        && echo "    Snapshot sauvegardé." \
        || echo "    Snapshot échoué (l'auto-snapshot reste actif au prochain deploy)."
else
    echo "    Ignoré (définir ADMIN_TOKEN pour activer)."
fi

# ── Comparaison des digests avant de pull ─────────────────────────────────
# Évite de pull inutilement quand rien n'a changé sur GHCR.
# Fallback : si skopeo absent, utiliser docker pull --quiet + comparer l'ID.
echo ""
echo "  Vérification des mises à jour disponibles..."

COMPOSE_ARGS=()
if [ -f "./docker-compose.override.yml" ]; then
    COMPOSE_ARGS=(-f ./docker-compose.yml -f ./docker-compose.override.yml)
fi

IMAGES_TO_UPDATE=()

while IFS= read -r img; do
    [ -z "$img" ] && continue
    # Récupérer le digest local (Image ID sha256:...)
    local_digest=$(docker inspect "$img" --format '{{.Id}}' 2>/dev/null || echo "missing")

    if [ "$local_digest" = "missing" ]; then
        echo "    $img : non présent localement → will pull"
        IMAGES_TO_UPDATE+=("$img")
        continue
    fi

    # Tentative avec skopeo (plus fiable)
    if command -v skopeo &>/dev/null; then
        remote_digest=$(skopeo inspect "docker://$img" 2>/dev/null | grep -o '"Digest":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
    else
        # Fallback : pull en dry-run (docker pull --quiet compare l'image ID)
        # On tag l'image actuelle, pull, puis compare les IDs
        remote_digest=""
    fi

    if [ -n "$remote_digest" ] && [ "$remote_digest" = "$local_digest" ]; then
        echo "    $img : à jour"
    else
        echo "    $img : mise à jour disponible"
        IMAGES_TO_UPDATE+=("$img")
    fi
done < <(docker compose "${COMPOSE_ARGS[@]}" config --images 2>/dev/null)

if [ ${#IMAGES_TO_UPDATE[@]} -eq 0 ]; then
    echo ""
    echo "  Tout est à jour. Aucune action nécessaire."
    echo ""
    exit 0
fi

echo ""
echo "  ${#IMAGES_TO_UPDATE[@]} image(s) à mettre à jour."

# ── Invalidation du cache de tag Docker ───────────────────────────────────
# Bug Docker Desktop : `docker compose pull` télécharge la nouvelle image
# mais le tag :latest reste sur l'Image ID en cache local. `up --pull always`
# ne suffit pas toujours. On force l'untag des images Coderaft avant pull
# pour que le pull suivant écrive vraiment la nouvelle image sous le tag.
echo "  Invalidation du cache de tag local pour les images Coderaft..."
for img in "${IMAGES_TO_UPDATE[@]}"; do
    case "$img" in
        ghcr.io/liamj74/*)
            # -f permet le untag même si un container running utilise l'image
            # (l'image reste tant que le container tourne ; le tag est juste libéré)
            docker rmi -f "$img" >/dev/null 2>&1 || true
            ;;
    esac
done

# ── Pull et récréation ────────────────────────────────────────────────────
echo "  Téléchargement des nouvelles images..."
docker compose "${COMPOSE_ARGS[@]}" pull \
    && docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate --remove-orphans --pull always

# ── Healthcheck post-update ───────────────────────────────────────────────
echo ""
echo "  Vérification de santé post-update..."
HEALTH_OK=1
HEALTH_URL="$DASHBOARD_API/api/health"

for i in $(seq 1 "$HEALTHCHECK_RETRIES"); do
    # -sS sans -f : on capture le HTTP code même sur 4xx/5xx au lieu d'avoir
    # un exit code !=0 qui concatène "0" derrière (donnait "5020" au lieu de "502").
    HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 500 ]; then
        echo "  Dashboard API healthy (HTTP $HTTP_CODE) après ${i} tentative(s)."
        HEALTH_OK=0
        break
    fi
    echo "  Tentative $i/$HEALTHCHECK_RETRIES — HTTP $HTTP_CODE. Attente ${HEALTHCHECK_DELAY}s..."
    sleep "$HEALTHCHECK_DELAY"
done

if [ "$HEALTH_OK" -ne 0 ]; then
    echo ""
    echo "  ERREUR : healthcheck échoué après $HEALTHCHECK_RETRIES tentatives."
    echo "  Déclenchement du rollback automatique..."
    if [ -x "./rollback.sh" ]; then
        bash ./rollback.sh
    else
        echo "  rollback.sh introuvable. Rollback manuel requis."
        echo "  Commande : docker compose down && docker compose up -d"
    fi
    exit 1
fi

# ── Notification post-update ──────────────────────────────────────────────
if [ -n "$ADMIN_TOKEN" ]; then
    curl -fsS -X POST "$DASHBOARD_API/api/platform/update/notify" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -d '{"status":"done","source":"update.sh"}' > /dev/null 2>&1 || true
fi

echo ""
echo "  Mise à jour réussie ! Dashboard : http://localhost:3000"
echo "  En cas de problème : ./rollback.sh"
echo "  (ou : curl -fsSL https://install.coderaft.io/rollback | bash)"
