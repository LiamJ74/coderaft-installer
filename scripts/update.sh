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
INSTALL_DIR="${INSTALL_DIR:-$PWD}"

# ── Auto-discovery du ADMIN_TOKEN ─────────────────────────────────────────
# Ordre de priorité :
#   1. Variable d'env $ADMIN_TOKEN (déjà set au-dessus)
#   2. Fichiers .env (INSTALL_DIR, /etc/coderaft, ~/.coderaft)
#   3. Token files plain (un seul mot)
#   4. Docker secret monté
# Si rien trouvé → continue, le snapshot/notify sont skip avec warning.
# IMPORTANT : ne JAMAIS echo le token découvert.
discover_admin_token() {
    if [ -n "${ADMIN_TOKEN:-}" ]; then
        printf '%s' "$ADMIN_TOKEN"
        return 0
    fi
    local env_file val
    for env_file in "$INSTALL_DIR/.env" "/etc/coderaft/.env" "$HOME/.coderaft/.env"; do
        if [ -f "$env_file" ] && [ -r "$env_file" ]; then
            val=$(grep -E '^[[:space:]]*ADMIN_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]')
            if [ -n "$val" ]; then
                printf '%s' "$val"
                return 0
            fi
        fi
    done
    local token_file
    for token_file in "/etc/coderaft/admin_token" "$HOME/.coderaft/admin_token" "/run/secrets/admin_token"; do
        if [ -f "$token_file" ] && [ -r "$token_file" ]; then
            val=$(tr -d '[:space:]' < "$token_file" 2>/dev/null)
            if [ -n "$val" ]; then
                printf '%s' "$val"
                return 0
            fi
        fi
    done
    return 1
}

if [ -z "$ADMIN_TOKEN" ]; then
    if discovered=$(discover_admin_token); then
        ADMIN_TOKEN="$discovered"
    fi
    unset discovered
fi

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
    # `< /dev/null` est CRITIQUE : sans ça, `docker compose exec -T` hérite de
    # stdin, et quand l'updater est lancé via `curl … | bash`, stdin = pipe
    # contenant le reste du script que bash n'a pas encore lu. docker exec
    # drain ces bytes → bash atteint EOF prématurément et le script exit
    # silencieusement après "Backup enregistré" (sans erreur, sans rollback).
    if docker compose exec -T postgres pg_dumpall -U coderaft < /dev/null 2>/dev/null | gzip > "$BACKUP_FILE"; then
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
    echo "    [warn] ADMIN_TOKEN introuvable — snapshot skipped."
    echo "    (set ADMIN_TOKEN env, or place token in $INSTALL_DIR/.env, /etc/coderaft/admin_token, ~/.coderaft/admin_token, or /run/secrets/admin_token)"
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

# ── Refresh des clés de licence (drift "superseded") ──────────────────────
# Quand le License Server resigne une licence (ex: ajout de feature, prolongation,
# rotation de clé), le serveur retourne 403 "License has been superseded by a
# newer version" pour toute requête utilisant l'ancienne clé. Le fix produit
# côté backend priorise DB > env, mais sur un déploiement frais ou après reset
# du volume, il n'y a que la clé env. On la rafraîchit donc ici, in-place dans
# docker-compose.override.yml, AVANT le `docker compose up`.
#
# Stratégie : POST /api/licenses/validate avec la clé locale ; si la réponse
# contient `latest_license_key` différent, on l'écrit dans le override (avec
# backup .bak). On ne fail jamais l'update à cause de ça (License Server
# down → on continue avec la clé locale, le runtime gérera le 403).
refresh_license() {
    local env_var="$1"   # LICENSE_KEY / RAVENSCAN_LICENSE_KEY / REDFOX_LICENSE_KEY
    local override_file="$INSTALL_DIR/docker-compose.override.yml"
    [[ ! -f "$override_file" ]] && return 0
    grep -qE "^[[:space:]]*-?[[:space:]]*${env_var}=" "$override_file" || return 0

    local current_key
    current_key=$(grep -E "^[[:space:]]*-?[[:space:]]*${env_var}=" "$override_file" \
        | head -1 \
        | sed -E "s/^[[:space:]]*-?[[:space:]]*${env_var}=//" \
        | tr -d '"' | tr -d "'" | xargs)
    [[ -z "$current_key" || "$current_key" == "UNCONFIGURED" ]] && return 0

    local server="${LICENSE_SERVER_URL:-https://license.coderaft.io}"
    local response
    response=$(curl -s --max-time 10 -X POST "${server}/api/licenses/validate" \
        -H "Content-Type: application/json" \
        -d "{\"license_key\":\"$current_key\"}" 2>/dev/null) || return 0
    [[ -z "$response" ]] && return 0

    local latest=""
    if command -v jq &>/dev/null; then
        latest=$(echo "$response" | jq -r '.latest_license_key // empty' 2>/dev/null)
    else
        latest=$(echo "$response" \
            | grep -oE '"latest_license_key"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | head -1 \
            | sed -E 's/.*"latest_license_key"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    fi

    if [[ -n "$latest" && "$latest" != "$current_key" ]]; then
        cp "$override_file" "${override_file}.bak"
        # awk : remplace TOUTES les occurrences (entraguard-api + entraguard-worker
        # peuvent partager la même clé sur plusieurs services).
        awk -v var="$env_var" -v key="$latest" '
            {
                pat = "^[[:space:]]*-?[[:space:]]*" var "="
                if ($0 ~ pat) {
                    match($0, /^[[:space:]]*-?[[:space:]]*/)
                    pad = substr($0, 1, RLENGTH)
                    print pad var "=" key
                    next
                }
                print
            }
        ' "${override_file}.bak" > "$override_file"
        echo "  🔄 Licence rafraîchie pour ${env_var}"
        return 1  # signal: restart needed
    fi
    return 0
}

refresh_all_licenses() {
    echo ""
    echo "  ▶ Vérification de la dérive de licence..."
    local restart_needed=0
    for var in LICENSE_KEY RAVENSCAN_LICENSE_KEY REDFOX_LICENSE_KEY; do
        refresh_license "$var" || restart_needed=1
    done
    if [ "$restart_needed" -eq 0 ]; then
        echo "  ✅ Toutes les licences sont à jour"
    else
        echo "  ⚠️  Au moins une licence a été rafraîchie ; les services seront redémarrés"
    fi
    return 0
}

refresh_all_licenses || true

# ── Invalidation AGRESSIVE du cache d'image Docker ────────────────────────
# Bug Docker Desktop multi-arch : quand un nouveau manifest list est poussé
# sur GHCR, le `docker pull` peut dire "Image is up to date" alors que le
# digest local et le digest distant diffèrent. C'est parce que Docker Desktop
# garde un cache de la résolution tag→digest.
#
# Fix : pour chaque image Coderaft, on stoppe les containers qui l'utilisent,
# on force le untag AND on supprime l'image par ID. Le pull suivant doit
# alors re-résoudre le manifest list distant et télécharger vraiment.
echo "  Invalidation agressive du cache d'image Coderaft..."
for img in "${IMAGES_TO_UPDATE[@]}"; do
    case "$img" in
        ghcr.io/liamj74/*)
            # 1. Stopper les containers qui tournent sur cette image
            container_ids=$(docker ps -q --filter "ancestor=$img" 2>/dev/null || true)
            if [ -n "$container_ids" ]; then
                docker stop $container_ids >/dev/null 2>&1 || true
                docker rm -f $container_ids >/dev/null 2>&1 || true
            fi
            # 2. Untag (libère le nom :latest)
            docker rmi -f "$img" >/dev/null 2>&1 || true
            # 3. Supprimer aussi par ID (au cas où l'image survit untagged)
            image_ids=$(docker images --format '{{.ID}}' "$img" 2>/dev/null || true)
            if [ -n "$image_ids" ]; then
                echo "$image_ids" | while read -r iid; do
                    [ -n "$iid" ] && docker rmi -f "$iid" >/dev/null 2>&1 || true
                done
            fi
            ;;
    esac
done

# ── Pull et récréation ────────────────────────────────────────────────────
# NB : `--pull always` sur le `up` retentait un manifest check GHCR par service
# au moment du redéploiement, ce qui faisait timeout en cas de connexion lente.
# Désormais on s'appuie sur le `docker rmi -f` + `docker compose pull` ci-dessus
# pour garantir que le tag :latest pointe bien sur la nouvelle image avant `up`.
echo "  Téléchargement des nouvelles images..."
docker compose "${COMPOSE_ARGS[@]}" pull \
    && docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate --remove-orphans

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
