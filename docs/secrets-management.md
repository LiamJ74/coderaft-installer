# Coderaft — Secrets Management (SOPS + age)

## Pourquoi SOPS + age ?

Les produits Coderaft ciblent des environnements bancaires et SOC 2.  
La règle stricte est : **aucun secret en clair sur disque** (`feedback_no_plaintext_secrets`).

- **SOPS** (Secrets OPerationS) chiffre les fichiers `.env` au repos sans modifier leur structure.
- **age** est le backend de chiffrement : rapide, sans configuration, clés Ed25519.
- Résultat : le fichier `.env.enc` est versionnable dans Git. La clé `age.key` ne quitte jamais le serveur.

---

## Architecture

```
/etc/coderaft/age.key      ← clé privée age (chmod 400, hors Git, backup obligatoire)
/etc/coderaft/age.pub      ← clé publique correspondante (dans age.key, ligne "# public key:")
.env.enc                   ← fichier chiffré (dans Git, commit et versioning OK)
.env                       ← gitignored, généré au boot par sops --decrypt
```

Au démarrage de chaque conteneur produit, l'entrypoint détecte si `/run/secrets/age.key` et `.env.enc` sont présents, et décrypte automatiquement.

---

## Workflow développeur — modifier un secret

```bash
# Éditer un secret dans .env.enc (sops ouvre l'éditeur, déchiffre/rechiffre auto)
export SOPS_AGE_KEY_FILE=/etc/coderaft/age.key
sops .env.enc

# Alternative : décrypter manuellement pour inspection
sops --decrypt .env.enc > .env.tmp && cat .env.tmp && rm .env.tmp
```

**Ne jamais commiter `.env` (clair).** Seul `.env.enc` doit être dans Git.

---

## Créer un .env.enc initial (nouveau produit ou migration)

```bash
# 1. Obtenir la clé publique age
AGE_PUB=$(grep "# public key:" /etc/coderaft/age.key | awk '{print $NF}')

# 2. Préparer un .env à partir de .env.example
cp .env.example .env
# Remplir les valeurs dans .env

# 3. Chiffrer
sops --encrypt --age "$AGE_PUB" \
     --output .env.enc \
     .env

# 4. Vérifier
sops --decrypt .env.enc | head

# 5. Supprimer le .env en clair
rm .env

# 6. Commiter .env.enc
git add .env.enc && git commit -m "secrets: chiffrement SOPS initial"
```

---

## Boot avec .env.enc

L'entrypoint de chaque produit gère automatiquement le déchiffrement :

```bash
# Test manuel (sans Docker)
export SOPS_AGE_KEY_FILE=/etc/coderaft/age.key
sops --decrypt .env.enc > .env && source .env

# Avec Docker Compose (mount de la clé)
docker compose --env-file <(sops --decrypt .env.enc) up
```

---

## Backup de la clé age

La clé `age.key` est **le seul moyen de déchiffrer les secrets**. Sa perte est irréversible.

**Procédure de backup recommandée :**

```bash
# Chiffrer la clé age avec GPG sur une clé USB
gpg --symmetric --cipher-algo AES256 /etc/coderaft/age.key
# → copier age.key.gpg sur USB chiffré hors réseau

# Vérifier le backup
gpg --decrypt /media/usb/age.key.gpg | diff - /etc/coderaft/age.key
```

Stocker dans 2 endroits physiques distincts (ex : coffre + USB bancaire client).

---

## Recovery — si age.key est perdu

**Scénario catastrophe** : age.key perdu et aucun backup.

1. Les secrets chiffrés dans `.env.enc` sont **définitivement inaccessibles**.
2. Procéder à une rotation complète :
   - Générer une nouvelle clé age : `age-keygen -o /etc/coderaft/age.key`
   - Réinitialiser tous les secrets dans les produits (Setup Wizard)
   - Re-chiffrer tous les `.env.enc` avec la nouvelle clé
   - Révoquer les anciens credentials Azure / Redis / Postgres côté fournisseur

---

## Rotation des secrets (sans changer les valeurs)

La rotation SOPS re-wraps la DEK (Data Encryption Key) sans modifier les valeurs :

```bash
export SOPS_AGE_KEY_FILE=/etc/coderaft/age.key
sops rotate -i .env.enc
```

Pour ajouter une deuxième clé age (accès multi-opérateur) :

```bash
AGE_PUB_NEW="age1xxxx..."
sops --rotate --add-age "$AGE_PUB_NEW" -i .env.enc
```

---

## Migrer un install existant (legacy → SOPS)

Les installs existantes **sans** `.env.enc` continuent de fonctionner avec leur `.env` en clair.  
Le dashboard affiche un bandeau jaune tant que des secrets en clair sont détectés.

### Migration automatique (recommandée)

**Linux / macOS :**

```bash
# Depuis le répertoire d'install coderaft/
curl -fsSL https://install.coderaft.io/migrate | bash
```

**Windows (PowerShell admin) :**

```powershell
# Depuis le répertoire d'install coderaft\
irm https://install.coderaft.io/migrate.ps1 | iex
```

Le script est **idempotent** : si la première exécution échoue à mi-chemin, relancez-le sans risque.

### Ce que fait le script

1. Vérifie que `.env` est présent (sinon exit 0 — pas de migration nécessaire)
2. Installe `age-keygen` et `sops` si absents
3. Génère `/etc/coderaft/age.key` (Linux) ou `C:\ProgramData\coderaft\age.key` (Windows) si inexistant
4. Crée un **backup chiffré GPG** du `.env` original dans `dashboard_data/migration-backup-{ts}.env.gpg`
5. Chiffre `.env` avec `sops --age` → `.env.enc`
6. Vérifie que le déchiffrement est identique au `.env` original (abort si différence)
7. Supprime `.env` uniquement si la vérification est OK
8. Migre `redfox-certs/jwt.key` vers file mount si référencé en env var
9. Écrit un audit log dans `dashboard_data/migration.log`

### Avant de migrer — checklist

- [ ] Faire un snapshot VM ou backup manuel si possible
- [ ] Avoir accès à un gestionnaire de mots de passe pour stocker la passphrase GPG
- [ ] S'assurer que la stack est arrêtée (`docker compose down`) ou que redémarrer après migration est prévu

### Backup — procédure de vérification

```bash
# Vérifier que le backup GPG est lisible
gpg --decrypt dashboard_data/migration-backup-*.env.gpg | head -3
# Doit afficher les premières lignes du .env original
```

### Recovery — si la migration est cassée (`.env` supprimé mais `.env.enc` illisible)

Si `age.key` est accessible :

```bash
SOPS_AGE_KEY_FILE=/etc/coderaft/age.key sops --decrypt .env.enc > .env
docker compose up -d
```

Si `age.key` est perdu mais le backup GPG existe :

```bash
gpg --decrypt dashboard_data/migration-backup-*.env.gpg > .env
# Puis relancer la migration avec la nouvelle clé age
```

Si ni `age.key` ni backup :
1. Secrets définitivement perdus — rotation complète requise
2. `age-keygen -o /etc/coderaft/age.key`
3. Re-run du Setup Wizard pour reconfigurer les produits

### Variables d'environnement

| Variable | Effet |
|---|---|
| `CODERAFT_BACKUP_PASS` | Passphrase GPG (non-interactive, CI/CD) |
| `CODERAFT_DATA_DIR` | Répertoire pour logs et backup (défaut : `./dashboard_data`) |
| `CODERAFT_SKIP_SELF_UPDATE` | `1` pour désactiver le self-update du script |

> **Avertissement** : Passphrase GPG perdue = backup inaccessible. En cas de perte simultanée de `age.key` et de la passphrase GPG, les secrets sont **définitivement inaccessibles**. Stockez la passphrase dans un gestionnaire de mots de passe sécurisé (Bitwarden, 1Password, Vault).

---

## Compatibilité backward

Les installs existantes **sans** `.env.enc` continuent de fonctionner avec leur `.env` en clair.  
Le dashboard affiche un avertissement : "Secrets non chiffrés — migrez vers SOPS via le Setup Wizard."

Pour migrer une install legacy (méthode manuelle) :

```bash
# Depuis le répertoire d'install
AGE_PUB=$(grep "# public key:" /etc/coderaft/age.key | awk '{print $NF}')

cp .env .env.bak
sops --encrypt --age "$AGE_PUB" --output .env.enc .env
rm .env  # seul .env.enc reste sur disque
```

---

## Compatibilité multi-arch

Le binaire sops est téléchargé dans chaque Dockerfile selon `${TARGETARCH}` (amd64 / arm64).

**Note QEMU arm64** : le build `--platform linux/arm64` via QEMU est lent (~5x) mais fonctionnel.  
Les binaires sops arm64 Linux sont disponibles depuis la v3.8.0. Pas de bug connu sur arm64.

---

## Variables d'environnement de contrôle

| Variable | Valeur | Effet |
|----------|--------|-------|
| `SOPS_AGE_KEY_FILE` | chemin vers age.key | Utilisé par sops et les entrypoints |
| `AGE_KEY_PATH` | `/etc/coderaft/age.key` | Chemin dashboard-api (peut être surchargé) |
| `APP_ENV` | `production` | Ravenscan : bloque démarrage si CAPTURE_TOKEN vide |

---

## Fichiers concernés par produit

| Produit | .env.enc | entrypoint | sops dans Dockerfile |
|---------|----------|-----------|----------------------|
| EntraGuard | `/opt/app/.env.enc` | `entrypoint.sh` | Stage `sops-downloader` |
| Ravenscan | `~/.ravenscan/.env.enc` | `entrypoint.sh` | Stage `sops-downloader` |
| RedFox API | `/etc/redfox/.env.enc` | `apps/api/entrypoint.sh` | Stage `sops-downloader` |
| License Server | `/app/.env.enc` | `entrypoint.sh` | Stage `sops-downloader` |
