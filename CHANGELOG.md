# Changelog

All notable changes to the Coderaft Installer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed — TLS : mkcert supprimé, Caddy internal CA (2026-07-20)
- **mkcert retiré entièrement** (`install.sh` + `install.ps1`) : plus de
  cascade winget→choco→scoop→GitHub Release. Caddy génère lui-même son CA
  (`tls internal`) au premier démarrage, dans le volume `caddy_data`
  (**à préserver entre installs** — sinon les endpoints qui trustaient
  l'ancien CA cassent).
- Caddyfile **templatisé par env vars** : `CODERAFT_TLS_SITES`,
  `CADDY_TLS_MODE_ARGS` (`internal` | `/certs/wildcard.crt /certs/wildcard.key`
  | `<email ACME>`), `CODERAFT_HOSTNAME`, `CADDY_BIND_ADDR`. Les 3 modes TLS
  (auto-signé / wildcard client / Let's Encrypt) se pilotent depuis le
  Setup Wizard du dashboard (dashboard-api réécrit `.env` et recrée caddy).
- Après `docker compose up` : attente (30 s max) de
  `/data/caddy/pki/authorities/local/root.crt`, export via
  `docker compose cp`, installation dans le trust store OS
  (Import-Certificate / security add-trusted-cert / update-ca-certificates).
- Migration : un Caddyfile legacy référençant `coderaft.local.pem` est
  backupé en `Caddyfile.mkcert.bak` puis regénéré.
- Nouveau test d'intégration : `tests/test-tls-caddy-modes.sh` (validation
  des 3 modes + handshake TLS live contre caddy:2-alpine réel).
- Docs : `docs/local-https.md` réécrit (internal CA, GPO/Intune push,
  troubleshooting).

### Fixed — Windows install (2026-07-16)
- `install.ps1` : `docker-proxy` ACL `VOLUMES: 1` (au lieu de `0`) — sans ça
  `docker compose up` échoue avec `403 PR--` sur `/volumes/*` quand
  dashboard-api tente de créer les volumes nommés des produits.
- `install.ps1` : garantir que `.coderaft-age.key` existe comme **fichier**
  avant `docker compose up`. Sans ça Docker créait un directory au path
  du bind-mount et dashboard-api crashloopait sur
  `age-keygen: /keys/age.key: is a directory`. Si un stale directory
  traîne d'une install précédente ratée, il est supprimé et remplacé.
- `install.ps1` : ajouter **winget** (natif Windows 10/11 —
  `FiloSottile.mkcert`) en premier dans la cascade d'install mkcert,
  puis **fallback binaire direct GitHub Release** (`mkcert.exe` téléchargé
  dans `caddy_certs\`) en dernier recours. Sans ça, sur les postes sans
  Chocolatey/Scoop, Caddy restart-loop indéfiniment sur
  `/certs/coderaft.local.pem: no such file or directory`.
- `install.sh` : même fix `VOLUMES: 1` symétrique.

## [Unreleased] - 2026-06-19

### Changed
- Installer deploys **5-product Coderaft Suite** (WolfGuard, Ravenscan, RedFox Bastion, MantisStrike — stub, FalconOne — stub)
- Vault mTLS PKI: `mantisstrike-client.{crt,key}` and `falconone-client.{crt,key}` generated when products are activated
- All vault client certs receive `read:platform/identity/oidc` ACL permission
- `setup-identity` wizard step added: global OIDC configuration written to Coderaft Vault `platform/identity/oidc`
- `setup-redfox` wizard step no longer includes OIDC (delegated to `setup-identity`)

### Added — Local HTTPS (caddy + mkcert)
- `install.sh` / `install.ps1` provisionnent désormais un reverse proxy
  Caddy (`caddy:2-alpine`) en plus du dashboard, avec :
  - HTTPS sur `https://coderaft.local` (cert mkcert, racine de confiance
    locale, zéro warning navigateur)
  - HTTP redirect `:80` → `:443` pour `coderaft.local` et le wildcard
  - Fallback `:80` plain HTTP vers `dashboard:3000` (compat retrograde)
  - Ports bindés sur `127.0.0.1` uniquement, `auto_https off`, `admin off`
- mkcert auto-install :
  - macOS : `brew install mkcert nss`
  - Linux/Debian : `apt install libnss3-tools mkcert`
  - Windows : `choco install mkcert` (fallback `scoop install mkcert`)
- `/etc/hosts` (Windows : `C:\Windows\System32\drivers\etc\hosts`) :
  ajout automatique de `coderaft.local` et des sous-domaines produits
  (`entraguard.coderaft.local`, `ravenscan.coderaft.local`,
  `redfox.coderaft.local`) via `sudo` / Administrator
- `Caddyfile` généré à côté de `docker-compose.yml` (idempotent)
- `caddy_certs/` (cert + clé montés RO dans le container, chmod 600)
- Volumes `caddy_data` et `caddy_config` ajoutés
- Variables d'opt-out : `CODERAFT_SKIP_HTTPS=1`, `CODERAFT_SKIP_HOSTS=1`
- Fallback transparent : si mkcert ou hosts file échoue, on garde
  `http://localhost:3000` (rien de cassé)
- `start.sh` / `start.ps1` détectent l'état HTTPS et ouvrent la bonne URL
- `scripts/update.sh` / `scripts/update.ps1` :
  - Préservent les certs existants
  - Renouvellement automatique si > 80 jours (mkcert default 825d)
  - Échec non-bloquant
- `docs/local-https.md` : architecture, setup, troubleshooting Windows,
  rotation, désactivation, comparaison vs oauth2-proxy/Traefik

### Added — Feature #39 Migration installs existants vers SOPS+age
- `scripts/migrate-to-sops.sh` (nouveau) — script bash idempotent Linux/macOS :
  - Self-update depuis GitHub raw au lancement (pattern identique à `update.sh`)
  - Détecte `.env` en clair dans le cwd (exit 0 si absent)
  - Installe `age-keygen` et `sops` si absents (download depuis GitHub releases)
  - Génère `/etc/coderaft/age.key` (chmod 400, owner root) si inexistant
  - Backup chiffré GPG via `gpg --symmetric --cipher-algo AES256` vers `dashboard_data/migration-backup-{ts}.env.gpg`
  - Passphrase via `$CODERAFT_BACKUP_PASS` (CI/CD) ou `read -s` interactif avec confirmation
  - Passphrase effacée de la mémoire bash après usage (`unset`)
  - Chiffrement SOPS : `sops --encrypt --age {pub} --output .env.enc .env`
  - Vérification intégrité par déchiffrement + `diff` — ABORT si différence (`.env` conservé)
  - Suppression `.env` uniquement si vérification OK
  - Migration `redfox-certs/jwt.key` vers file mount si référencé comme env var dans `docker-compose.override.yml`
  - Audit log dans `dashboard_data/migration.log`
- `scripts/migrate-to-sops.ps1` (nouveau) — équivalent PowerShell Windows :
  - Même logique que le script bash
  - Clé age dans `C:\ProgramData\coderaft\age.key` avec ACL `BUILTIN\Administrators` only
  - Passphrase via `Read-Host -AsSecureString` (jamais en clair dans terminal)
  - Vérification déchiffrement via `Compare-Object`
  - Fallback manuel documenté si `gpg.exe` absent (Gpg4win)
- `docs/secrets-management.md` — mise à jour avec section complète "Migrer un install existant" :
  - Commandes one-liner Linux et Windows
  - Checklist avant migration
  - Procédure de vérification du backup GPG
  - Recovery procedure (3 cas : age.key accessible, backup GPG seulement, aucun des deux)
  - Variables d'environnement de contrôle
  - Avertissement passphrase perdue

