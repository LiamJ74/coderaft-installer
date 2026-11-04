#!/bin/bash
#
# CodeRaft image digest snapshot (F-012, 2026-07-31)
#
# Resolves every container image actually referenced by this deployment
# (the base docker-compose.yml install.sh writes, PLUS the per-product
# images dashboard-api's PRODUCT_SERVICES generates into
# docker-compose.override.yml) to its current immutable sha256 digest, and
# writes them to ./digests.env as PIN_<NAME>_DIGEST=sha256:... lines.
#
# THIS SCRIPT DOES NOT REWRITE ANY COMPOSE FILE. It is a snapshot/audit tool:
#   - run it to see exactly which digest each `:latest`/tagged reference
#     resolves to right now (supply-chain audit, "what am I actually
#     running", vulnerability-scan-by-digest, incident response).
#   - the resulting digests.env can be diffed between two runs to see which
#     images changed between deploys.
#
# WHY THIS ISN'T WIRED INTO `image: ...@sha256:...` IN THE COMPOSE FILES YET
# (the doc's suggested end-state) — documented instead of half-done:
#   deploy/scripts/update.sh already has a mature, battle-tested
#   digest-vs-local-image-ID comparison loop (see its "Compare digests
#   before pulling" section) that decides which images need pulling, PLUS a
#   Docker-Desktop-multi-arch-cache-bug workaround (force-untag + remove by
#   ID before re-pulling). That loop's `IMAGES_TO_UPDATE` list comes from
#   `docker compose config --images`, which only produces a MUTABLE tag
#   (`ghcr.io/liamj74/foo:latest`) today. If the compose files instead
#   pinned `ghcr.io/liamj74/foo@sha256:OLDDIGEST`, that same command would
#   just keep echoing the OLD pinned digest forever — `docker compose pull`
#   never re-resolves a digest reference against the registry the way it
#   re-resolves a tag, so update.sh's whole "is there a new version"
#   question would need to become "resolve :latest's CURRENT remote digest
#   via skopeo/registry API, compare to what's pinned in the compose file,
#   and if different, rewrite the pin (both the base docker-compose.yml
#   install.sh owns AND dashboard-api's generateOverrideToDir(), which emits
#   the product images) before pulling" — a real behavioural change to a
#   93KB, heavily field-tested script (and to server.js's PRODUCT_SERVICES
#   image strings), not a config tweak. That rewrite needs its own careful
#   pass + rollback testing, which is out of scope for this hardening pass.
#   Landing a HALF-pinned compose (some images frozen forever because
#   nothing ever refreshes their digest) would be worse than the current
#   mutable-tag state — it would silently stop delivering security patches
#   for exactly the images someone pinned "for security". This script exists
#   so that follow-up work has real tooling to build on, without introducing
#   that regression today.
#
# Usage:
#   ./pin-image-digests.sh                 # writes ./digests.env
#   ./pin-image-digests.sh /path/to/dir     # writes <dir>/digests.env
#
set -euo pipefail

OUT_DIR="${1:-.}"
OUT="${OUT_DIR}/digests.env"

# The exact, real image list this deployment references today — kept in
# sync manually with deploy/install.sh (base compose heredoc) and
# dashboard-api/server.js's PRODUCT_SERVICES (per-product images). Re-derive
# with:
#   grep -ohE '^\s*image: "?[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+"?' \
#     deploy/install.sh dashboard-api/server.js | sed 's/.*image: //' | tr -d '"' | sort -u
IMAGES=(
  # Base platform (deploy/install.sh)
  "caddy:2-alpine"
  "postgres:16-alpine"
  "redis:7-alpine"
  "tecnativa/docker-socket-proxy:0.3.0"
  "ghcr.io/liamj74/coderaft-dashboard:latest"
  "ghcr.io/liamj74/coderaft-dashboard-api:latest"
  "ghcr.io/liamj74/coderaft-vault:latest"
  "ghcr.io/liamj74/coderaft-cve-proxy:latest"
  # WolfGuard (dashboard-api/server.js PRODUCT_SERVICES["entra-audit"])
  "ghcr.io/liamj74/entraguard-api:latest"
  "neo4j:5-community"
  # Ravenscan (PRODUCT_SERVICES["secaudit"])
  "ghcr.io/liamj74/ravenscan:latest"
  "ghcr.io/liamj74/ravenscan-pdf:latest"
  "ghcr.io/liamj74/ravenscan-capture:latest"
  # RedFox (PRODUCT_SERVICES["redfox"])
  "alpine:3.20"
  "ghcr.io/liamj74/redfox-api:latest"
  "ghcr.io/liamj74/redfox-web:0.2.0"
  "ghcr.io/liamj74/redfox-proxy:0.2.0"
  "ghcr.io/liamj74/redfox-gateway:0.2.0"
  # FalconOne (PRODUCT_SERVICES["falconone"])
  "ghcr.io/liamj74/falconone-api:latest"
  "ghcr.io/liamj74/falconone-reports:latest"
  "ghcr.io/liamj74/falconone-relay:latest"
)

resolve_digest() {
  local img="$1"
  local digest=""
  # Prefer `docker buildx imagetools inspect` — resolves the REMOTE manifest
  # digest (works for multi-arch manifest lists) without needing the image
  # pulled locally first.
  if command -v docker &>/dev/null; then
    digest=$(docker buildx imagetools inspect "$img" --format '{{json .Manifest}}' 2>/dev/null \
      | grep -o '"digest":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  fi
  if [ -z "$digest" ] && command -v skopeo &>/dev/null; then
    digest=$(skopeo inspect "docker://$img" 2>/dev/null \
      | grep -o '"Digest":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  fi
  if [ -z "$digest" ]; then
    # Last-resort local fallback: only reflects what's pulled on THIS host,
    # not necessarily the current registry HEAD — flagged in the output.
    if docker image inspect "$img" &>/dev/null; then
      digest=$(docker image inspect "$img" --format '{{index .RepoDigests 0}}' 2>/dev/null | cut -d@ -f2 || true)
      [ -n "$digest" ] && digest="${digest} (LOCAL-ONLY, not verified against registry)"
    fi
  fi
  echo "$digest"
}

mkdir -p "$OUT_DIR"
: > "$OUT"
echo "# Generated by deploy/scripts/pin-image-digests.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT"
echo "# Snapshot/audit only — NOT wired into any compose file. See the header" >> "$OUT"
echo "# comment in that script for why." >> "$OUT"

fail_count=0
for img in "${IMAGES[@]}"; do
  name=$(echo "$img" | tr '/:.' '___' | tr '[:lower:]' '[:upper:]')
  digest=$(resolve_digest "$img")
  if [ -z "$digest" ]; then
    echo "  ⚠ could not resolve digest for $img (not reachable / not pulled locally)" >&2
    echo "PIN_${name}_DIGEST=" >> "$OUT"
    fail_count=$((fail_count + 1))
  else
    echo "  ✓ $img -> $digest"
    echo "PIN_${name}_DIGEST=${digest}" >> "$OUT"
  fi
done

echo ""
echo "Wrote $OUT (${#IMAGES[@]} images, ${fail_count} unresolved)"
[ "$fail_count" -gt 0 ] && exit 1 || exit 0
