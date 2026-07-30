# Coderaft Platform — Deployment Topologies

**Applies to**: Coderaft Platform (unified installer)
**Date**: 2026-06-19

---

## Overview

The Coderaft platform supports three deployment topologies, chosen during the Setup Wizard (`deployment-mode` step). The wizard collects and persists your choice, then generates a `docker-compose.<topology>.yml` override file. **Multi-node deployment is manual** — the wizard does not SSH to other nodes or run commands on your behalf.

| Topology | License | Use case | Compose file |
|----------|---------|----------|--------------|
| Single-node | Any | SMB, dev, demo | `docker-compose.yml` (no override) |
| HA cluster | Enterprise (`ha_cluster` feature) | Enterprise production | `docker-compose.yml` + `docker-compose.ha.yml` |
| Air-gap | Any | Defense, regulated, offline | `docker-compose.yml` + `docker-compose.airgap.yml` |

---

## Single-node

### Description

Everything runs on one Docker host. PostgreSQL, Redis, Neo4j, the dashboard and all product containers share the same machine.

### Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 cores | 8 cores |
| RAM | 4 GB | 8 GB |
| Disk | 20 GB SSD | 100 GB SSD |
| OS | Ubuntu 22.04 / Debian 12 / RHEL 9 / macOS 14 | |
| Docker | Engine 24+ with Compose v2 | |

### Installation

```bash
# 1. Run the one-liner installer
curl -fsSL https://install.coderaft.io | bash

# 2. Follow the Setup Wizard in the browser (default: http://localhost:3000)
#    - Choose "Single-node" in the Deployment Topology step

# 3. No compose override needed. Docker Compose uses docker-compose.yml directly.
docker compose up -d
```

### Failure characteristics

- **RTO**: ~2-5 minutes (manual Docker restart)
- **RPO**: data since last backup (use the built-in backup feature)
- **Backup**: use Settings → Backup to configure off-host restic backups

---

## HA Cluster

### Description

Active-active platform across 2-3 Linux hosts. Survives a single node failure with automatic Redis failover and semi-automatic PostgreSQL promotion.

**Requires** the `ha_cluster` feature (Enterprise tier). Contact sales@coderaft.io.

### Requirements

| Resource | Per node | |
|----------|----------|--|
| CPU | 8 cores | min 4 |
| RAM | 16 GB | min 8 GB |
| Disk | 100 GB SSD | min 50 GB |
| Network | 1 Gbps between nodes | |
| OS | Ubuntu 22.04 / Debian 12 | |
| Docker | Engine 24+ with Compose v2 | |

### Architecture summary

- **PostgreSQL**: primary (writes) + 1-2 standbys (streaming replication, `synchronous_commit=on`, RPO=0)
- **Redis**: 1 master + 2 replicas + 3 Sentinels (quorum=2, auto-failover RTO ~15 s)
- **dashboard-api**: 2 stateless instances behind Nginx upstream
- **Keepalived VIP (VRRP)**: single floating IP, fails over between nodes within seconds

See [ha-architecture.md](../../../coderaft-platform/docs/ha-architecture.md) for full topology diagrams.

### Installation runbook

```bash
# === On ALL nodes ===

# 1. Clone the platform repository
git clone https://github.com/LiamJ74/coderaft-platform /opt/coderaft
cd /opt/coderaft

# 2. Copy and configure .env
cp .env.example .env
# Set: POSTGRES_PASSWORD, PG_REPLICATION_PASSWORD, REDIS_PASSWORD,
#      NEO4J_PASSWORD, DASHBOARD_SECRET, REDFOX_JWT_SECRET

# 3. Set node role in .env
#    On primary:   NODE_ROLE=primary
#    On standbys:  NODE_ROLE=standby
#                  PG_PRIMARY_HOST=<primary-ip>
#                  REDIS_MASTER_HOST=<primary-ip>
echo "NODE_ROLE=primary" >> .env         # primary node only

# === On the PRIMARY node ===

# 4. Install the platform using the HA override
docker compose -f docker-compose.yml -f templates/docker-compose.ha.yml up -d

# 5. Run the Setup Wizard at http://<primary-ip>:3000
#    - Select "HA cluster" topology
#    - Enter node hostnames
#    - Click "Validate topology" (expects at least primary reachable)
#    - Click "Continue" — this saves config and writes docker-compose.ha.yml

# === On STANDBY node(s) ===

# 6. Apply the same compose files
docker compose -f docker-compose.yml -f templates/docker-compose.ha.yml up -d

# === On ALL nodes ===

# 7. Configure Keepalived (optional but recommended for VIP failover)
apt install keepalived
# Edit /etc/keepalived/keepalived.conf — set VIRTUAL_IP, INTERFACE, STATE, PRIORITY
# See: https://coderaft.io/docs/platform/keepalived
systemctl enable --now keepalived
```

### PostgreSQL failover (manual — MVP)

```bash
# 1. Confirm primary is unreachable
docker exec postgres pg_isready -h <primary-ip> -U coderaft

# 2. On the standby node, promote it to primary
docker exec postgres pg_ctl promote -D /var/lib/postgresql/data

# 3. Update PG_PRIMARY_HOST in .env on all other nodes and restart
sed -i "s/PG_PRIMARY_HOST=.*/PG_PRIMARY_HOST=<new-primary-ip>/" .env
docker compose -f docker-compose.yml -f templates/docker-compose.ha.yml up -d --force-recreate
```

### Failure characteristics

| Scenario | RTO | RPO | Recovery |
|----------|-----|-----|----------|
| Single node down | ~60 s (Redis auto) / 5-10 min (PG manual) | 0 (sync replication) | Automatic (Redis), manual (PG) |
| Both nodes down | Full outage | 0 | Restart both |

---

## Air-gap

### Description

No internet access. All Docker images are pulled from a mirrored local registry. The License Server is verified offline. Telemetry and update checks are disabled.

Compatible with single-node or HA topology (stack both overlays).

### Requirements

- A local OCI-compatible registry (Harbor, Nexus, Zot, registry:2)
- Coderaft images mirrored to the local registry
- An offline license bundle (contact sales@coderaft.io)

### Image mirroring

```bash
# Install crane (https://github.com/google/go-containerregistry)
REGISTRY="harbor.internal/coderaft"
TAG="latest"

images=(
  "coderaft-dashboard-api"
  "coderaft-entraguard"
  "coderaft-ravenscan"
  "coderaft-redfox-api"
  "coderaft-redfox-proxy"
  "coderaft-redfox-gateway"
  "coderaft-postgres"
  "coderaft-redis"
  "coderaft-neo4j"
  "coderaft-nginx"
)

for img in "${images[@]}"; do
  crane copy "ghcr.io/liamj74/${img}:${TAG}" "${REGISTRY}/${img}:${TAG}"
done
```

### Installation runbook

```bash
# 1. Set variables in .env
LOCAL_REGISTRY="harbor.internal/coderaft"
AIRGAP_LICENSE_PATH="/opt/coderaft/offline-license.tar.gz"

# 2. Copy offline license bundle
scp coderaft-offline-license.tar.gz root@<host>:/opt/coderaft/

# 3. Deploy
docker compose -f docker-compose.yml -f templates/docker-compose.airgap.yml up -d

# 4. Run the Setup Wizard
#    - Select "Air-gap" topology
#    - Enter local registry URL and offline license path
#    - Click "Validate topology" to test registry reachability
```

### Updates in air-gap mode

```bash
# 1. Download new image bundle (via secure file transfer — USB, SFTP, etc.)
#    Request from: sales@coderaft.io

# 2. Load images to Docker
docker load -i coderaft-<version>.tar.gz

# 3. Push to local registry
for img in $(docker images --format "{{.Repository}}:{{.Tag}}" | grep coderaft); do
  crane push $img ${LOCAL_REGISTRY}/${img}
done

# 4. Re-deploy
docker compose -f docker-compose.yml -f templates/docker-compose.airgap.yml up -d
```

---

## Changing topology after initial setup

The Setup Wizard can be re-run from **Settings → Deployment → Re-run Wizard**. The new topology config is persisted and a new compose override file is generated. Apply manually.

---

## Limitations (MVP Phase 1)

- The wizard **collects** topology config but does **not** auto-deploy to remote nodes.
- PostgreSQL failover is **manual** (no Patroni integration yet — Phase 2).
- Air-gap NVD CVE database seeding is **manual** (`scripts/load-nvd-offline.sh` — TBD).
- The compose override files are **starting points** — review before production use.

---

## Support

- Topology questions: contact@coderaft.io
- Enterprise HA setup: sales@coderaft.io
