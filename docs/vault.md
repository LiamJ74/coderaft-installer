# coderaft-vault — Operator Guide

**Phase**: 3 (in progress) — dashboard-api's own secret store
(`dashboard-api/vault.js`, `/data/vault.enc`) has been replaced by a Coderaft
Vault client (task #149, 2026-07-31): `generateOverrideToDir()` reads/writes
every product secret through the vault's `/v1/secret/*` API instead of the
internal encrypted KV file. Per-product secret handling in WolfGuard /
Ravenscan / RedFox themselves is unaffected by this change and remains
tracked separately (see §7.2 point 7 of
`coderaft-platform/SECRETS-FILE-MOUNTS-PLAN-2026-07-31.md`).

---

## What is coderaft-vault?

A dedicated container (`ghcr.io/liamj74/coderaft-vault:latest`, multi-arch
amd64+arm64) that owns every secret used by the Coderaft platform. Products
authenticate via mTLS client certificates and read/write secrets through an
internal HTTPS API. No product container has a direct connection to the
database encryption keys or the vault storage file.

Architecture overview:

```
coderaft-vault (internal network: coderaft-vault-net, port 8200)
    ↑ mTLS client cert
    |
dashboard-api  entraguard-*  ravenscan  redfox-*
```

The vault file (`/data/vault.db`) is AES-256-GCM encrypted at rest.  
The master key is stored age-encrypted in `./vault-keys/age.key`.

---

## Recovery phrase

At first install the installer:

1. Generates `./vault-keys/age.key` (age private key, mode 0400).
2. Calls the vault container to derive a **24-word BIP39 mnemonic** from that key.
3. Displays the phrase **once** in a bordered box.
4. Blocks until the operator types `CONFIRMED` (all caps).

**The recovery phrase is the only way to rebuild `vault-keys/age.key` if the
file is lost or corrupted.** Store it in:

- An encrypted USB drive (recommended)
- 1Password or Bitwarden vault
- A physical safe

Do NOT store it in plaintext on the host, in a chat, or in a cloud note.

**If both `vault-keys/age.key` AND the recovery phrase are lost, all
encrypted secrets are permanently unrecoverable.** There is no back door.

---

## mTLS PKI layout

The installer generates a self-signed CA and per-product client certificates
in `./vault-tls/`:

| File | Description |
|------|-------------|
| `ca.crt` / `ca.key` | Root CA (self-signed, 10y, mode 0600) |
| `server.crt` / `server.key` | Vault server cert (SAN=coderaft-vault) |
| `dashboard-api-client.{crt,key}` | Admin client cert (can list+read+write all) |
| `entraguard-client.{crt,key}` | WolfGuard client cert (azure_*, license_key, entraguard_*) |
| `ravenscan-client.{crt,key}` | Ravenscan client cert (ravenscan_*, neo4j_*) |
| `redfox-client.{crt,key}` | RedFox client cert (redfox_*) |
| `mantisstrike-client.{crt,key}` | MantisStrike client cert (mantisstrike_*) — generated when product activated |
| `falconone-client.{crt,key}` | FalconOne client cert (falconone_*) — generated when product activated |

All 5 products also receive `read:platform/identity/oidc` ACL permission — see [Platform Identity Architecture](../../coderaft-platform/docs/identity-architecture.md).

ACL rules live in `./vault-config/acl.yaml`.

To rotate a client cert, delete the relevant files and re-run the installer.
The CA and server cert will be reused; only the requested client cert is
regenerated.

---

## Update path (existing installs)

When `update.sh` or `update.ps1` detects the vault container is absent, it
runs an automatic migration:

1. **Pre-flight backup** — copies `.env`, `.env.enc`, `.coderaft-age.key`,
   dumps `auth_config` from Postgres, copies `ravenscan.db`, `vault.enc`,
   and `admin_token` to `./backups/migrate-vault-<UTC-timestamp>/`.
2. **Recovery phrase gate** — same as fresh install.
3. **Pulls and starts** the vault container (cosign verify if
   `STRICT_COSIGN_VERIFY=1`).
4. **Migrates 20 secrets** from `.env` to the vault with round-trip
   verification (task #149, 2026-07-31: added `tenant_encryption_key`,
   `azure_client_secret`, `redfox_jwt_secret`, `redfox_oidc_client_secret`,
   `xproduct_internal_token`, `admin_token`, `cloudflare_tunnel_token` — real
   secrets that existed in `.env` but were not yet protected by this path).
5. **Writes `.migrated` sentinel** on success. Re-runs are no-ops.
6. **7-day grace** — legacy stores are NOT purged automatically.  
   The dashboard shows a banner after 7 days; one operator click completes
   the purge (separate ticket).

**Rollback path**: if any migration step fails, the script restores all
backups and restarts the stack in its pre-migration state. The backup
directory path is printed in red.

---

## Setting a secret post-install

```bash
# Linux/macOS
bash <(curl -fsSL https://install.coderaft.io/vault-set) license_key 'ENC-v1-...'

# From the install directory
bash scripts/vault-set.sh license_key 'ENC-v1-...'

# Windows
irm https://install.coderaft.io/vault-set.ps1 -OutFile vault-set.ps1
.\vault-set.ps1 -Name license_key -Value 'ENC-v1-...'
```

---

## Recovering from a lost vault-keys/age.key

If `vault-keys/age.key` is lost or corrupted and the vault fails to unseal:

```bash
# Linux/macOS
bash <(curl -fsSL https://install.coderaft.io/vault-recover)

# From the install directory
bash scripts/vault-recover.sh

# Windows
irm https://install.coderaft.io/vault-recover.ps1 -OutFile vault-recover.ps1
.\vault-recover.ps1
```

The script prompts for the 24-word recovery phrase (no echo), reconstructs
`vault-keys/age.key`, backs up the existing file with a timestamp, and
restarts the vault container.

**Phase 1 follow-up**: the `-mnemonic-to-key` sub-command in the vault image
must be verified before relying on this path in production. If the sub-command
is absent, restore `vault-keys/age.key` from a manual backup.

---

## Runtime exposure reduction (task #148, 2026-07-31)

Two follow-ups to the Phase 3 dashboard-api-as-vault-client migration, both
about *where secret VALUES sit on disk*, not about which store is
authoritative (Coderaft Vault remains the sole authority for both):

1. **The working `.env`** (rendered secret values, passed to `docker compose
   --env-file`) now lives on a **tmpfs private to the dashboard-api
   container** (`/run/coderaft-env`, mounted via `tmpfs:` on the
   `dashboard-api` service) instead of the persistent bind-mounted install
   directory. It is wiped on every container restart/recreation and
   regenerated fresh from Coderaft Vault + `install-config.env` on the next
   boot/deploy — never a durable copy at rest. This is safe because
   `--env-file` is interpolated **client-side** by the `docker compose` CLI
   process, which runs *inside* the dashboard-api container itself (baked-in
   `docker-cli-compose`, talking to the daemon over the socket/proxy) — the
   Docker daemon never needs to resolve that path itself. Confirmed
   experimentally: a tmpfs mounted only inside the orchestrating container,
   never bind-mounted to any real host path, was read correctly by
   `docker compose --env-file <tmpfs-path>` and the resulting container's
   `Config.Env` showed the correctly interpolated value.
2. **`postgres` migrated to Docker's native `secrets:` + `POSTGRES_PASSWORD_FILE`**
   — the official image already supports it, so `POSTGRES_PASSWORD` no
   longer appears in `docker inspect`'s `Config.Env` for the postgres
   container. Unlike `.env`, this file (`./secrets/postgres_password`) **is**
   resolved by the Docker daemon itself as a literal bind-mount source (a
   container-internal-only tmpfs fails here with "bind source path does not
   exist" — confirmed experimentally), so it stays on the persistent,
   host-visible install directory, next to `docker-compose.yml`. Written by
   `install.sh` on first boot and self-healed into existing installs by
   `update.sh`, always seeded from the CURRENTLY ACTIVE `.env` value (never a
   freshly generated one) so an already-initialized postgres cluster's real
   credential is never orphaned by the migration.

**Suggested order for the rest of the `secrets:` migration** (per-product,
each touches application entrypoint code, budgeted separately): redis →
`CLOUDFLARE_TUNNEL_TOKEN` → RedFox JWT/passphrase (file-mount pattern already
precedented via `REDFOX_JWT_KEY_PATH`) → `DASHBOARD_SECRET`/
`XPRODUCT_INTERNAL_TOKEN` → the rest. Out of scope for #148.

**Known gap confirmed while doing this work**: the "7-day grace, then a
dashboard banner to purge legacy stores" behavior described in the Update
path section above is **only documented, not implemented**. `update.sh`
writes the `vault-data/.migrated` sentinel with a UTC timestamp, but no
dashboard-api route or frontend component reads that file to drive a purge
banner or automated purge — grep of `apps/shell/src` and `dashboard-api/`
for `.migrated`/`vault-data` turns up nothing beyond the one comment in
`server.js` explaining why `generateOverrideToDir()` deliberately does NOT
do this migration itself. Tracked as a separate follow-up, not implemented
here.

---

## Test-mode install

Set `CODERAFT_TEST_MODE=1` to auto-accept the `CONFIRMED` prompt and skip
actual image pulls (useful for CI and local dev):

```bash
mkdir -p /tmp/coderaft-test && cd /tmp/coderaft-test
CODERAFT_TEST_MODE=1 bash /path/to/install.sh
docker compose -f docker-compose.yml config --quiet   # validate YAML
docker compose up -d coderaft-vault
curl -sk http://localhost:8200/v1/health || \
  docker compose exec coderaft-vault wget -qO- http://localhost:8200/v1/health
# expected: {"sealed":false,"version":"..."}
```

To test the rollback path:

```bash
CODERAFT_TEST_MODE=1 CODERAFT_TEST_FAIL=4e bash scripts/update.sh
# confirms backup was created, vault service removed from active stack,
# stack restored to pre-migration state
```

---

## Phase roadmap

| Phase | Scope |
|-------|-------|
| 0.5 | Vault deployed from oneliner; existing installs migrate on update |
| 1 | dashboard-api migrates `auth_config` (Azure creds) to vault |
| 2 | LICENSE_KEY lifecycle moves to vault — done, 2026-07-28 (#166) |
| 3 (this, in progress) | Per-product secret stores replaced with vault client — dashboard-api's own store done (#149, 2026-07-31); runtime exposure reduction done (#148, 2026-07-31: working `.env` on tmpfs, postgres on `secrets:`/POSTGRES_PASSWORD_FILE — see below); WolfGuard/Ravenscan/RedFox's own per-product stores AND their `secrets:` migration still pending |
| 4 | Vault becomes JWT issuer (admin_token) |
| 5 | Remove SOPS/.env.enc path; one vault, one master key |
