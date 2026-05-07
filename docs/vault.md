# coderaft-vault — Operator Guide

**Phase**: 0.5 — Vault integration wired into the oneliner installer.

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
| `entraguard-client.{crt,key}` | EntraGuard client cert (azure_*, license_key, entraguard_*) |
| `ravenscan-client.{crt,key}` | Ravenscan client cert (ravenscan_*, neo4j_*) |
| `redfox-client.{crt,key}` | RedFox client cert (redfox_*) |

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
4. **Migrates 13 secrets** from `.env` to the vault with round-trip
   verification.
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
| 0.5 (this) | Vault deployed from oneliner; existing installs migrate on update |
| 1 | dashboard-api migrates `auth_config` (Azure creds) to vault |
| 2 | LICENSE_KEY lifecycle moves to vault |
| 3 | Per-product secret stores replaced with vault client |
| 4 | Vault becomes JWT issuer (admin_token) |
| 5 | Remove SOPS/.env.enc path; one vault, one master key |
