# Local HTTPS for the CodeRaft Dashboard

The CodeRaft installer ships with a local HTTPS reverse proxy so the
dashboard is reachable at `https://coderaft.local` instead of the plain
`http://localhost:3000`. This avoids browser HTTPS warnings and keeps
the dashboard on the same security model as a production deployment
(secure cookies, OAuth/OIDC redirects, mixed-content rules…).

> **TL;DR**: the installer auto-installs `mkcert`, generates a locally
> trusted certificate, drops a `Caddyfile` next to your `docker-compose.yml`,
> and adds `coderaft.local` to your hosts file. If anything fails the
> platform falls back to `http://localhost:3000` — nothing is broken,
> only HTTPS is unavailable.

---

## Architecture

```
   Browser
     │  https://coderaft.local
     ▼
 ┌────────────────────────┐
 │  caddy:2-alpine        │  ← terminates TLS (mkcert cert mounted RO)
 │  reverse_proxy → :3000 │
 └──────────┬─────────────┘
            │ http://dashboard:3000
            ▼
 ┌────────────────────────┐
 │  dashboard (nginx SPA) │
 └────────────────────────┘
```

Two services run side by side:

| Service     | Port (host)          | Purpose                                           |
|-------------|----------------------|---------------------------------------------------|
| `caddy`     | `127.0.0.1:443`, `:80` | TLS terminator, redirects HTTP → HTTPS          |
| `dashboard` | `127.0.0.1:3000`     | Plain HTTP fallback (kept for backward compat)    |

Both ports are bound to **loopback only** (`127.0.0.1`) — nothing is
exposed on your LAN. The Caddy admin API is also disabled
(`admin off`) and `auto_https off` prevents Caddy from trying to
issue public ACME certs.

---

## What the installer does

1. **Generates `Caddyfile`** next to `docker-compose.yml` with a
   reverse-proxy block for `coderaft.local`, the wildcard
   `*.coderaft.local` (so `entraguard.coderaft.local`,
   `ravenscan.coderaft.local`, `redfox.coderaft.local` all work for
   per-product cookie scoping), plus an HTTP fallback on `:80`.
2. **Installs `mkcert`** if missing
   - macOS: `brew install mkcert nss`
   - Linux (Debian/Ubuntu): `apt-get install libnss3-tools mkcert`
   - Windows: `choco install mkcert` (falls back to `scoop install mkcert`)
3. **Runs `mkcert -install`** which adds a per-machine root CA to:
   - the system trust store (macOS Keychain / Linux `/etc/ssl/certs` / Windows root store)
   - Firefox's NSS store (when `nss` / `libnss3-tools` is present)
4. **Generates the cert** with all relevant SANs:
   ```
   mkcert \
     -cert-file caddy_certs/coderaft.local.pem \
     -key-file  caddy_certs/coderaft.local-key.pem \
     coderaft.local "*.coderaft.local" localhost 127.0.0.1 ::1
   ```
   Cert is valid 825 days (mkcert default).
5. **Updates `/etc/hosts`** (or `C:\Windows\System32\drivers\etc\hosts`)
   with:
   ```
   127.0.0.1 coderaft.local entraguard.coderaft.local ravenscan.coderaft.local redfox.coderaft.local # coderaft-platform
   ```

If any step fails (no Homebrew, no admin password, etc.), the installer
prints a warning and continues. You can still open
`http://localhost:3000` — the platform works exactly as before.

---

## Setup variants

### macOS

```bash
brew install mkcert nss   # nss = Firefox trust store
curl -fsSL https://install.coderaft.io | bash
```

The script will run `mkcert -install` (which prompts for your sudo
password once to write the root CA) and update `/etc/hosts` (sudo again).

### Linux (Debian/Ubuntu)

```bash
sudo apt install libnss3-tools mkcert
curl -fsSL https://install.coderaft.io | bash
```

### Windows (PowerShell)

Run PowerShell **as Administrator** so the script can write to
`C:\Windows\System32\drivers\etc\hosts`. mkcert is installed via Chocolatey
(or Scoop):

```powershell
# As Administrator
choco install mkcert -y
irm https://install.coderaft.io/win | iex
```

If you launch a non-elevated shell, the installer prints the line you
need to add to your hosts file manually.

---

## Disabling local HTTPS

Two opt-out env vars, both honored by `install.sh` and `install.ps1`:

| Variable                | Effect                                                |
|-------------------------|-------------------------------------------------------|
| `CODERAFT_SKIP_HTTPS=1` | Don't install mkcert / don't generate certs.          |
| `CODERAFT_SKIP_HOSTS=1` | Don't touch `/etc/hosts`.                             |

When either is set, Caddy still runs but only the `:80` fallback block
is active (proxying to dashboard:3000), so `http://localhost:3000` and
`http://localhost` keep working.

---

## Renewal & rotation

mkcert certs are valid 825 days. The updater scripts
(`scripts/update.sh`, `scripts/update.ps1`) check the cert's mtime on
every run; if it's older than **80 days**, the cert is regenerated
in-place. The Caddy container picks up the new cert on the next
reload (`docker compose up -d --force-recreate`).

To force a rotation manually:

```bash
mkcert \
  -cert-file caddy_certs/coderaft.local.pem \
  -key-file  caddy_certs/coderaft.local-key.pem \
  coderaft.local "*.coderaft.local" localhost 127.0.0.1 ::1
docker compose up -d --force-recreate caddy
```

To revoke the local CA entirely (and get rid of the trust on this
machine):

```bash
mkcert -uninstall      # removes the root CA from all trust stores
rm -rf caddy_certs/    # removes the per-deploy cert
```

---

## Troubleshooting

### Browser still shows "Not Secure"

Most likely the root CA wasn't installed in **your browser's** trust
store. mkcert handles the OS store automatically, but Firefox uses NSS:

- macOS / Linux: install `nss` (`brew install nss` /
  `apt install libnss3-tools`) **before** running `mkcert -install`.
- Chrome/Edge use the OS store directly — restart the browser after
  `mkcert -install`.

### "ERR_CERT_AUTHORITY_INVALID" right after install

Restart the browser. Some Chromium-based browsers cache the previous
TLS state for an open tab.

### `mkcert -install` asks for sudo password

That's expected once per machine — it copies the root CA to the
system trust store. If you can't grant sudo, set `CODERAFT_SKIP_HTTPS=1`
and stick with `http://localhost:3000`.

### Windows: hosts file unchanged

PowerShell wasn't elevated. Either:

1. Re-run the installer from an Administrator PowerShell, or
2. Add the line manually:
   ```
   127.0.0.1 coderaft.local entraguard.coderaft.local ravenscan.coderaft.local redfox.coderaft.local # coderaft-platform
   ```
   then restart the browser.

### `https://coderaft.local` doesn't resolve

The hosts file wasn't updated. Test resolution:

```bash
ping coderaft.local
# expected: 127.0.0.1
```

If it fails, append the line above (sudo / Administrator required).

### Port 443 already in use

Another local service holds 443 (e.g. another nginx, Skype on old
Windows). Stop it or remap Caddy in `docker-compose.yml`:

```yaml
ports:
  - "127.0.0.1:8443:443"
```

Then access the dashboard at `https://coderaft.local:8443`.

### Caddy keeps restarting

Check that `caddy_certs/coderaft.local.pem` and `coderaft.local-key.pem`
exist and are readable. Caddy logs:

```bash
docker compose logs caddy
```

If the certs are missing, Caddy still binds `:80` (HTTP fallback) but
the HTTPS site definition fails. Re-run mkcert (see "Renewal").

---

## Why caddy + mkcert (and not oauth2-proxy / Traefik / etc.)

- **caddy** is a single static binary, cross-platform, with a 4-line
  config for our use case. No bespoke modules, no LetsEncrypt for a
  local-only deployment.
- **mkcert** is the simplest way to get a *trusted* local cert without
  asking users to click "Advanced → Proceed unsafely" every time.
- **oauth2-proxy** would be overkill — the dashboard is single-tenant,
  authenticates via the License Server / OIDC against Entra, and isn't
  exposed beyond loopback.
- **Traefik** is great but adds operational complexity (file provider,
  static + dynamic config, dashboard, etc.) that we don't need for a
  local reverse proxy.

If you outgrow this setup (multi-host deployment, public hostname,
real ACME), swap caddy for the same image with a different `Caddyfile`
that uses `tls user@example.com` and remove the mkcert pieces.
