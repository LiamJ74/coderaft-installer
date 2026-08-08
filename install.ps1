# =============================================================================
# CodeRaft Platform — One-line installer (PowerShell)
# Usage: irm https://install.coderaft.io/win | iex
#
# Installs the CodeRaft Dashboard. The dashboard handles everything else:
#   - License activation
#   - Product deployment (EntraGuard, Ravenscan, RedFox)
#   - Configuration & updates
# =============================================================================

$ErrorActionPreference = 'Stop'

# ── F-037 (2026-07-31): installer self-integrity check (SHA256) ─────────────
# Goal: detect a script tampered with in transit or at rest between
# publication and execution (e.g. a MITM proxy, a compromised CDN edge, or a
# stale/corrupted cache rewriting the response to
# `irm https://install.coderaft.io/win`) before a single command from this
# file runs.
#
# Mechanism: recompute this script's own SHA256 — excluding the
# $CoderaftExpectedSha256 line itself, to avoid the chicken-and-egg problem
# of a file needing to embed a hash of its own content — and compare it
# against the digest published at install.ps1.sha256, a sidecar file served
# alongside this one but generated/updated independently (see
# scripts/generate-install-checksums.sh, run at every release cut).
# $CoderaftExpectedSha256 below is a secondary, embedded offline pin: a
# frozen snapshot of the hash taken at the same time as the last
# regeneration, used only as a fallback when the network fetch of the
# published digest fails outright (fully offline environment, endpoint
# down). Regenerate both together with
# scripts/generate-install-checksums.sh whenever this file changes — never
# edit either by hand.
#
# KNOWN LIMITATION (a structural PowerShell limit, not a bug in this
# check): when this file is piped straight into Invoke-Expression —
# `irm https://install.coderaft.io/win | iex`, this file's own documented
# usage at the top of this header — the code executes as a string with no
# backing script file, so $PSCommandPath / $MyInvocation.MyCommand.Path are
# empty. A script cannot read "itself" back out once iex has already
# parsed it from a piped string with no file behind it. Under that
# invocation the check below degrades to a clear warning instead of
# silently pretending to protect the user. It IS fully effective for the
# safer download-then-run flow:
#   irm https://install.coderaft.io/win -OutFile install.ps1
#   .\install.ps1          # self-checks against install.ps1.sha256
# See deploy/docs/installer-integrity-verification.md for the full
# writeup, threat model, and the (separate, not-yet-scheduled) work needed
# to make the public `install.coderaft.io` endpoint actually serve this
# monorepo's install.ps1/install.ps1.sha256 at all — today it still
# proxies the legacy `coderaft-installer` repo.
$CoderaftExpectedSha256 = "a68d915573b1c2c48ad7d8d9315447986b9a06ff8a0184c5eb7bd09334b56fe8"

# CODERAFT_INSTALL_SHA256_URL is overridable purely so this mechanism can be
# tested end-to-end against a throwaway local HTTP server instead of the
# live production endpoint (see deploy/docs/installer-integrity-verification.md,
# "Testing" section). Real installs never need to set it.
$CoderaftInstallSha256Url = if ($env:CODERAFT_INSTALL_SHA256_URL) { $env:CODERAFT_INSTALL_SHA256_URL } else { 'https://install.coderaft.io/install.ps1.sha256' }

function Get-CoderaftSelfHash {
    param([Parameter(Mandatory)][string]$Path)
    # Byte-level read + explicit CRLF->LF normalization (not Get-Content,
    # whose line-ending/encoding auto-detection could silently diverge from
    # the plain byte-oriented `sed`+`sha256sum` pipeline that
    # scripts/generate-install-checksums.sh uses to hash install.sh — this
    # function must stay in lockstep with THAT script's PowerShell branch).
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $normalized = $text -replace "`r`n", "`n"
    $lines = $normalized -split "`n" | Where-Object { $_ -notmatch '^\$CoderaftExpectedSha256\s*=' }
    $joined = [string]::Join("`n", $lines)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
    } finally {
        $hasher.Dispose()
    }
    return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLower()
}

function Test-CoderaftSelfIntegrity {
    if ($env:SKIP_SELF_VERIFY) {
        Write-Host "  ⚠ SKIP_SELF_VERIFY set — installer integrity check bypassed (dev only)." -ForegroundColor Yellow
        return $true
    }

    # $PSCommandPath only points to this script's real file when it was
    # invoked as a file (.\install.ps1, powershell -File install.ps1). Under
    # `irm | iex` there is no backing file. See the KNOWN LIMITATION note
    # above.
    $selfPath = $PSCommandPath
    if (-not $selfPath -and $MyInvocation.MyCommand.Path) { $selfPath = $MyInvocation.MyCommand.Path }

    if (-not $selfPath -or -not (Test-Path -LiteralPath $selfPath -PathType Leaf)) {
        Write-Host ""
        Write-Host "  ⚠ Installer integrity check skipped: this script has no backing file to" -ForegroundColor Yellow
        Write-Host "    hash (running via 'irm | iex' — see deploy/docs/" -ForegroundColor Yellow
        Write-Host "    installer-integrity-verification.md). For a verified install:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "      irm https://install.coderaft.io/win -OutFile install.ps1" -ForegroundColor Yellow
        Write-Host "      .\install.ps1" -ForegroundColor Yellow
        Write-Host ""
        return $true
    }

    $actual = $null
    try {
        $actual = Get-CoderaftSelfHash -Path $selfPath
    } catch {
        Write-Host "  ⚠ Installer integrity check skipped: could not hash this script ($($_.Exception.Message))." -ForegroundColor Yellow
        return $true
    }
    if (-not $actual) {
        Write-Host "  ⚠ Installer integrity check skipped: could not compute local hash." -ForegroundColor Yellow
        return $true
    }

    $published = $null
    try {
        $published = (Invoke-RestMethod -Uri $CoderaftInstallSha256Url -TimeoutSec 10 -ErrorAction Stop).ToString().Trim()
    } catch {
        $published = $null
    }

    $expected = $published
    $source = "install.ps1.sha256 (network)"
    if (-not $expected) {
        if ($CoderaftExpectedSha256) {
            $expected = $CoderaftExpectedSha256
            $source = "embedded offline pin"
            Write-Host "  ⚠ Could not reach $CoderaftInstallSha256Url — falling back to the embedded offline pin." -ForegroundColor Yellow
        } else {
            Write-Host "  ⚠ Could not reach $CoderaftInstallSha256Url and no embedded pin is set — skipping integrity check." -ForegroundColor Yellow
            return $true
        }
    }

    if ($actual -ne $expected) {
        Write-Host ""
        Write-Host "  FATAL: installer integrity check failed" -ForegroundColor Red
        Write-Host "    computed (local)      : $actual" -ForegroundColor Red
        Write-Host "    expected ($source): $expected" -ForegroundColor Red
        Write-Host ""
        Write-Host "  This script's content does not match its published digest — it may" -ForegroundColor Red
        Write-Host "  have been tampered with in transit or at rest. Aborting." -ForegroundColor Red
        Write-Host '  Set $env:SKIP_SELF_VERIFY=1 to bypass (development only).' -ForegroundColor Red
        Write-Host ""
        return $false
    }

    Write-Host "  ✓ Installer integrity verified (SHA256 matches $source)" -ForegroundColor Green
    return $true
}

# Not 'exit' — irm|iex runs this script in the caller's own scope, so exit
# would close their whole shell instead of just ending this script.
if (-not (Test-CoderaftSelfIntegrity)) { return }

$InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { 'coderaft' }

# B-CWD-SANITIZE (2026-07-16): `irm | iex` inherits the caller's CWD.
# When the user runs an elevated PowerShell (or auto-elevates via UAC)
# from another user's profile (e.g. `PS C:\Users\ljsantos\coderaft>` in
# an `Administrator:` window), `System.Diagnostics.Process.Start()`
# fails to launch child processes with Win32 error 0x8007007B ("La
# syntaxe du nom de fichier, de répertoire ou de volume est
# incorrecte.") because CreateProcess can't use the inherited working
# directory for the new process. Also happens after a partial
# `Remove-Item -Recurse -Force .` (shell stranded in a deleted dir)
# or after `icacls /reset` stripped the Administrators ACE from a
# profile subfolder.
#
# We RESPECT the user's choice of install location — the install lands
# in `.\coderaft\` (or $INSTALL_DIR) relative to the current CWD by
# design. So we only fall back to USERPROFILE when the current CWD is
# demonstrably unusable. Detection: try to create + delete a temp
# file in the current directory. If the account can't do that, it
# also can't spawn a child process with this CWD.
$cwdUsable = $false
try {
    $cwdProbe = Join-Path (Get-Location) ".coderaft-cwd-probe-$(Get-Random)"
    New-Item -Path $cwdProbe -ItemType File -Force -ErrorAction Stop | Out-Null
    Remove-Item -Path $cwdProbe -Force -ErrorAction SilentlyContinue
    $cwdUsable = $true
} catch {
    $cwdUsable = $false
}
if (-not $cwdUsable) {
    Write-Host "  ⚠ Current directory ($((Get-Location).Path)) is not writable by this account." -ForegroundColor Yellow
    Write-Host "    Falling back to $env:USERPROFILE. To install in-place instead," -ForegroundColor Yellow
    Write-Host "    launch PowerShell under the account that owns this directory," -ForegroundColor Yellow
    Write-Host "    or fix the ACL and re-run." -ForegroundColor Yellow
    try {
        if ($env:USERPROFILE -and (Test-Path -LiteralPath $env:USERPROFILE)) {
            Set-Location -LiteralPath $env:USERPROFILE -ErrorAction Stop
        } else {
            Set-Location -LiteralPath ($env:SystemDrive + '\') -ErrorAction Stop
        }
    } catch {
        # Last resort: SystemDrive root is world-readable on every
        # Windows install; if even that fails the environment is
        # broken beyond what an installer can fix.
        try { Set-Location -LiteralPath 'C:\' -ErrorAction Stop } catch {}
    }
}

# B-TRANSCRIPT (2026-06-23): capture full PowerShell session to a transcript
# file so that we can diagnose crashes when the console window self-closes
# (happens on `irm | iex` when a `Start-Process -ErrorAction Stop` throws —
# the host treats the script-level exception as terminating and closes the
# window before the user can read the error). Transcript is written to the
# user's TEMP and the path is announced upfront so the operator can mail it
# to support if anything goes wrong.
$CoderaftTranscript = Join-Path $env:TEMP "coderaft-install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
try {
    Start-Transcript -Path $CoderaftTranscript -Force -ErrorAction SilentlyContinue | Out-Null
} catch {
    # Some hosts (older ISE, restricted modes) refuse Start-Transcript; we
    # carry on without it rather than abort — the rest of the script still
    # works, the operator just won't have a post-mortem log.
    $CoderaftTranscript = $null
}

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗"
Write-Host "  ║     CodeRaft Platform — Installer        ║"
Write-Host "  ║   Security. Identity. Access. Unified.   ║"
Write-Host "  ╚══════════════════════════════════════════╝"
Write-Host ""
if ($CoderaftTranscript) {
    Write-Host "  Install log: $CoderaftTranscript"
    Write-Host ""
}

# B-TRAP (2026-06-23): on `irm | iex`, an uncaught terminating exception
# closes the host window before the user can read the error. The trap
# below intercepts it, prints the full ErrorRecord (including the call
# stack), stops the transcript, then re-throws so $LASTEXITCODE is still
# set correctly for any caller. The 5-second sleep gives a real human a
# fighting chance to screenshot the message even on a self-closing host.
trap {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║   INSTALL FAILED — uncaught exception    ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At:    $($_.InvocationInfo.PositionMessage)" -ForegroundColor Yellow
    Write-Host ""
    if ($CoderaftTranscript) {
        Write-Host "  Full transcript saved to: $CoderaftTranscript" -ForegroundColor Yellow
        Write-Host "  Please share this file with support." -ForegroundColor Yellow
        try { Stop-Transcript | Out-Null } catch {}
    }
    Write-Host ""
    Start-Sleep -Seconds 5
    break
}

# ── OS detection ─────────────────────────────────────────────────────────────
# Coderaft itself runs in Docker on every OS. The native capture daemon
# (Ravenscan live packet inspection) is the exception: on Docker Desktop
# (Windows here) containers cannot see the host's real NICs, so we
# install a Windows Service on the host instead. On Linux servers the
# Docker sidecar with network_mode: host works natively.
$CoderaftOS   = "windows"
$CoderaftArch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
$CoderaftNeedsNativeCapture = $true
Write-Host "  Detected: $CoderaftOS/$CoderaftArch"
Write-Host ""

# ── Prerequisites ────────────────────────────────────────────────────────────

function Test-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Host "  ✗ $name is required but not installed." -ForegroundColor Red
        return $false
    }
    Write-Host "  ✓ $name found" -ForegroundColor Green
    return $true
}

Write-Host "  Checking prerequisites..."
# Not 'exit' — irm|iex runs this script in the caller's own scope, so exit
# would close their whole shell instead of just ending this script.
if (-not (Test-Command docker)) { return }
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ✗ 'docker compose' plugin is required." -ForegroundColor Red
    return
}
Write-Host "  ✓ docker compose found" -ForegroundColor Green

# B-DAEMON-CHECK (2026-06-10): `docker compose version` only validates the
# CLI plugin — the daemon may still be unreachable (Docker Desktop not
# started, or switched to Windows containers mode, whose Linux pipe
# `dockerDesktopLinuxEngine` does not exist). `docker info` is the cheapest
# call that round-trips through the daemon: fast when up, clear failure
# when down.
# B-DAEMON-CHECK-STREAMS (2026-06-11): the previous version aimed both
# stdout and stderr at the SAME temp file via Start-Process. Windows can't
# open the same path for two concurrent writers, so the 2nd redirect
# silently fails — the file ends up empty even when docker info succeeds,
# and the `^\s*\d` check rejects every install. Use two distinct files
# and concatenate them when reading.
$dockerInfoOut = Join-Path $env:TEMP "coderaft-docker-info-out-$(Get-Random).log"
$dockerInfoErr = Join-Path $env:TEMP "coderaft-docker-info-err-$(Get-Random).log"
Start-Process -FilePath "docker" -ArgumentList @("info","--format","{{.ServerVersion}}") `
    -NoNewWindow -Wait `
    -RedirectStandardOutput $dockerInfoOut `
    -RedirectStandardError  $dockerInfoErr `
    -ErrorAction SilentlyContinue | Out-Null
$dockerInfoStdout = if (Test-Path $dockerInfoOut) { (Get-Content $dockerInfoOut -Raw -ErrorAction SilentlyContinue) } else { "" }
$dockerInfoStderr = if (Test-Path $dockerInfoErr) { (Get-Content $dockerInfoErr -Raw -ErrorAction SilentlyContinue) } else { "" }
$dockerInfoText  = (("$dockerInfoStdout" + "`n" + "$dockerInfoStderr")).Trim()
Remove-Item -Path $dockerInfoOut,$dockerInfoErr -ErrorAction SilentlyContinue
if ($dockerInfoStdout.Trim() -notmatch '^\d') {
    Write-Host "  ✗ Docker daemon is not reachable." -ForegroundColor Red
    Write-Host ""
    Write-Host "    docker info output:" -ForegroundColor Yellow
    foreach ($line in (($dockerInfoStdout + "`n" + $dockerInfoStderr) -split "`r?`n")) {
        if ($line.Trim()) { Write-Host "    $line" -ForegroundColor DarkYellow }
    }
    Write-Host ""
    if ($dockerInfoText -match 'dockerDesktopLinuxEngine|named pipe') {
        Write-Host "    Docker Desktop appears to be in Windows containers mode." -ForegroundColor Yellow
        Write-Host "    Right-click the Docker tray icon → 'Switch to Linux containers...'" -ForegroundColor Yellow
        Write-Host "    Then re-run this installer." -ForegroundColor Yellow
    } else {
        Write-Host "    Start Docker Desktop and wait for it to be 'Running', then re-run." -ForegroundColor Yellow
    }
    exit 1
}
Write-Host "  ✓ Docker daemon reachable (server $($dockerInfoStdout.Trim()))" -ForegroundColor Green
Write-Host ""

# ── Install ──────────────────────────────────────────────────────────────────

Write-Host "  Installing to: $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir

# Windows Defender: exclude the install dir up-front. Docker Compose extracts
# encrypted secrets (age keys, vault TLS bundles) and lays out product binaries
# under this path — without the exclusion, Defender may quarantine a fresh
# signed executable mid-pull and leave the stack half-deployed. Requires the
# elevated context we already have (self-elevation happens earlier). Wrapped in
# try/catch so a Defender-less system (Server Core, 3rd-party AV, etc.) still
# installs cleanly.
try {
    $Absolute = (Get-Location).Path
    Add-MpPreference -ExclusionPath $Absolute -ErrorAction Stop
    Write-Host "  Windows Defender exclusion added for $Absolute"
} catch {
    Write-Host "  (Windows Defender exclusion skipped: $_)"
}

function New-HexSecret($length) {
    $bytes = New-Object byte[] $length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ''
}

$AbsoluteInstallDir = (Get-Location).Path

# Task #150 (2026-07-31): install-config.env holds install-time / public
# config (HOST_PROJECT_DIR, CODERAFT_HOST_OS, CODERAFT_HOST_ARCH) — never a
# secret, never SOPS-encrypted. Every `docker compose` call below passes
# `--env-file install-config.env --env-file .env` so both are interpolated.
# BUG FIX (2026-08-05, found live on Liam's Windows test machine — see the
# matching comment in deploy/scripts/update.ps1 for the full root-cause writeup
# and a real-pwsh reproduction): `$text -split "..." | Where-Object {...}`
# unwraps to a plain scalar STRING (not a 1-element array) whenever exactly one
# line survives the filter. The next line, `$lines += "$Key=$Value"`, then does
# STRING CONCATENATION instead of array-append, silently gluing the new
# KEY=VALUE pair onto the previous line with zero separator — e.g.
# CODERAFT_HOST_OS=windowsCODERAFT_HOST_ARCH=amd64HOST_PROJECT_DIR=C:\...
# Wrapping the Where-Object result in `@(...)` forces it to always be a real
# array. Get-InstallConfigVar is hardened the same way (first match only) in
# case a file is already corrupted with duplicate lines for the same key.
function Set-InstallConfigVar($Key, $Value) {
    $path = "$(Get-Location)\install-config.env"
    $text = if (Test-Path $path) { [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false)) } else { "" }
    $lines = @($text -split "`r?`n" | Where-Object { $_ -notmatch "^$Key=" -and $_ -ne "" })
    $lines += "$Key=$Value"
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}
function Get-InstallConfigVar($Key) {
    $path = "$(Get-Location)\install-config.env"
    if (-not (Test-Path $path)) { return $null }
    $m = @(Select-String -Path $path -Pattern "^$Key=(.+)$")
    if ($m.Count -ge 1) { return $m[0].Matches.Groups[1].Value }
    return $null
}

# ── Self-heal: repair an ALREADY-corrupted install-config.env ──────────────
# Same repair logic as deploy/scripts/update.ps1's Repair-InstallConfigCorruption
# — detects any physical line containing 2+ of our known "KEY=" markers (the
# corruption signature) and splits it back into one clean line per key, keeping
# the LAST value seen for each key. Called once here, before any Get-/Set-
# InstallConfigVar use below (existing-install branch backfills HOST_PROJECT_DIR/
# CODERAFT_HOST_OS/CODERAFT_HOST_ARCH right after this).
function Repair-InstallConfigCorruption {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return }
    $knownKeys = @("HOST_PROJECT_DIR", "CODERAFT_HOST_OS", "CODERAFT_HOST_ARCH")
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    if (-not $text) { return }
    $rawLines = @($text -split "`r?`n" | Where-Object { $_ -ne "" })
    $markerPattern = "(?:" + (($knownKeys | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")="
    $corruptedFound = $false
    $clean = [ordered]@{}
    foreach ($line in $rawLines) {
        $markerMatches = @([regex]::Matches($line, $markerPattern))
        if ($markerMatches.Count -le 1) {
            $eq = $line.IndexOf('=')
            if ($eq -gt 0) { $clean[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
            continue
        }
        $corruptedFound = $true
        for ($i = 0; $i -lt $markerMatches.Count; $i++) {
            $start = $markerMatches[$i].Index
            $end = if ($i + 1 -lt $markerMatches.Count) { $markerMatches[$i + 1].Index } else { $line.Length }
            $segment = $line.Substring($start, $end - $start)
            $eq = $segment.IndexOf('=')
            if ($eq -gt 0) { $clean[$segment.Substring(0, $eq)] = $segment.Substring($eq + 1) }
        }
    }
    if (-not $corruptedFound) { return }
    $ts = Get-Date -Format "yyyyMMddTHHmmssZ"
    Copy-Item -LiteralPath $Path -Destination "$Path.bak-corrupt-$ts" -ErrorAction SilentlyContinue
    $newLines = @($clean.Keys | ForEach-Object { "$_=$($clean[$_])" })
    [System.IO.File]::WriteAllText($Path, (($newLines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ⚠ install-config.env was corrupted (concatenated values from a known PowerShell array/string bug, now fixed) — repaired automatically." -ForegroundColor Yellow
    Write-Host "    Backup of the corrupted file: $Path.bak-corrupt-$ts"
}
Repair-InstallConfigCorruption -Path "$(Get-Location)\install-config.env"

# ── Detail log file (2026-08-05) ────────────────────────────────────────────
# Same convention as deploy/scripts/update.ps1's Write-DetailLog: internal
# per-product diagnostic detail (ACL self-heal internals, PKI SAN strings)
# goes here instead of the console, which keeps one concise line per phase.
# The path is printed once at the end of the install so it's easy to find.
$LOG_DIR = Join-Path (Get-Location) "logs"
try { New-Item -ItemType Directory -Force -Path $LOG_DIR -ErrorAction Stop | Out-Null } catch { $LOG_DIR = $env:TEMP }
$INSTALL_LOG = Join-Path $LOG_DIR ("install-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
try {
    [System.IO.File]::WriteAllText($INSTALL_LOG, "[$(Get-Date -Format o)] install.ps1 started`n", [System.Text.UTF8Encoding]::new($false))
} catch { }
function Write-DetailLog {
    param([Parameter(ValueFromPipeline = $true)][string]$Message)
    process {
        try { Add-Content -LiteralPath $script:INSTALL_LOG -Value "[$(Get-Date -Format o)] $Message" -Encoding utf8 -ErrorAction SilentlyContinue } catch { }
    }
}
try {
    Get-ChildItem -LiteralPath $LOG_DIR -Filter "install-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

# ── Backup rotation (security hardening, 2026-07-31) — PowerShell parity ────
# Every self-heal path below does Copy-Item $X "$X.bak-<timestamp>" before
# touching $X (acl.yaml; update.ps1 also does this for docker-compose.yml /
# docker-compose.override.yml). On a deployment that runs unattended for
# months/years across many install/update runs, these accumulate without
# bound. Keep only the $Keep most recent (default 5) backups sharing
# $BasePath's name (any `.bak-*` suffix/tag counts against the same budget);
# delete anything older. Safe/idempotent: a no-op when there are $Keep or
# fewer, or none at all.
function Invoke-RotateBackups {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [int]$Keep = 5
    )
    $dir = Split-Path -Path $BasePath -Parent
    if ([string]::IsNullOrEmpty($dir)) { $dir = "." }
    $leaf = Split-Path -Path $BasePath -Leaf
    $backups = Get-ChildItem -LiteralPath $dir -Filter "$leaf.bak-*" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if ($backups -and $backups.Count -gt $Keep) {
        $backups | Select-Object -Skip $Keep | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# Task #148 Phase 3 (2026-07-31, PowerShell parity): postgres migrates to
# Docker's native `secrets:` + POSTGRES_PASSWORD_FILE (the official postgres
# image already supports this) instead of a plaintext POSTGRES_PASSWORD= env
# var baked into Config.Env — mirrors install.sh's write_postgres_secret_file
# (commit 04b2c14). Docker Desktop on Windows runs the Linux daemon in a VM,
# so a non-swarm `secrets: file:` source is resolved exactly like on Linux/
# macOS: the Docker DAEMON itself needs a real, host-visible file at this
# path — same tree as docker-compose.yml — not something that could live on
# a container-internal tmpfs. Written here (mirroring the .env bootstrap
# right below) so it already exists before the very first `docker compose up`.
function Write-PostgresSecretFile($PgPassword) {
    New-Item -ItemType Directory -Force -Path "secrets" | Out-Null
    # No chmod on Windows — rely on the same ACL pattern as vault-keys\age.key
    # (B-VAULT-ACL): keep inheritance ON (Administrators/SYSTEM stay readable,
    # required for Docker Desktop's 9P/plan9 file sharing to bind-mount this
    # into the postgres container) and explicitly add the current user Read.
    $secretPath = Join-Path (Get-Location) "secrets\postgres_password"
    [System.IO.File]::WriteAllText($secretPath, $PgPassword, [System.Text.UTF8Encoding]::new($false))
    try {
        $acl = Get-Acl $secretPath
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            "Read", "Allow")
        $acl.AddAccessRule($rule)
        Set-Acl $secretPath $acl -ErrorAction Stop
    } catch {
        Write-Host "  ⚠ Could not tighten ACL on secrets\postgres_password ($($_.Exception.Message.Trim()))." -ForegroundColor Yellow
        Write-Host "    Postgres will still start; inherited ACL from the parent directory applies." -ForegroundColor Yellow
    }
}

# Task #219 (2026-07-31, PowerShell parity — was previously OUT of sync with
# install.sh's write_redis_secret_file()/commit for this same task): redis
# has no native `_FILE` env var convention like postgres's image, so the
# password is read from this file via a `sh -c` command override in the
# compose service instead (see the `redis:` service below). Same file-write
# pattern as Write-PostgresSecretFile above.
function Write-RedisSecretFile($RedisPassword) {
    New-Item -ItemType Directory -Force -Path "secrets" | Out-Null
    $secretPath = Join-Path (Get-Location) "secrets\redis_password"
    [System.IO.File]::WriteAllText($secretPath, $RedisPassword, [System.Text.UTF8Encoding]::new($false))
    try {
        $acl = Get-Acl $secretPath
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            "Read", "Allow")
        $acl.AddAccessRule($rule)
        Set-Acl $secretPath $acl -ErrorAction Stop
    } catch {
        Write-Host "  ⚠ Could not tighten ACL on secrets\redis_password ($($_.Exception.Message.Trim()))." -ForegroundColor Yellow
        Write-Host "    Redis will still start; inherited ACL from the parent directory applies." -ForegroundColor Yellow
    }
}

if ((Test-Path '.env') -and (Select-String -Path '.env' -Pattern '^POSTGRES_PASSWORD=' -Quiet)) {
    # Fix UTF-8 BOM if present (older installers wrote BOM which breaks Docker Compose)
    $envBytes = [System.IO.File]::ReadAllBytes("$(Get-Location)\.env")
    if ($envBytes.Length -ge 3 -and $envBytes[0] -eq 0xEF -and $envBytes[1] -eq 0xBB -and $envBytes[2] -eq 0xBF) {
        Write-Host "  ⚠ Fixing UTF-8 BOM in .env..." -ForegroundColor Yellow
        $envContent = [System.Text.Encoding]::UTF8.GetString($envBytes, 3, $envBytes.Length - 3)
        [System.IO.File]::WriteAllText("$(Get-Location)\.env", $envContent, [System.Text.UTF8Encoding]::new($false))
    }
    # Existing install: HOST_PROJECT_DIR always (re)written to install-config.env
    # with the current install dir — the location may have changed since the
    # previous install, and a stale or missing value breaks docker-compose
    # interpolation (warning + empty bind-mount path → dashboard-api cannot
    # reach .env.enc → fake "first run").
    Set-InstallConfigVar "HOST_PROJECT_DIR" $AbsoluteInstallDir
    # Backfill CODERAFT_HOST_OS/ARCH: prefer install-config.env if a previous
    # run of this new installer already wrote it, else migrate from .env
    # (upgrade from an older installer version), else fall back to detection.
    if (-not (Get-InstallConfigVar "CODERAFT_HOST_OS")) {
        $legacyOS = (Select-String -Path '.env' -Pattern '^CODERAFT_HOST_OS=(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($legacyOS) {
            Set-InstallConfigVar "CODERAFT_HOST_OS" $legacyOS.Matches.Groups[1].Value
            $legacyArch = (Select-String -Path '.env' -Pattern '^CODERAFT_HOST_ARCH=(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1)
            Set-InstallConfigVar "CODERAFT_HOST_ARCH" $(if ($legacyArch) { $legacyArch.Matches.Groups[1].Value } else { $CoderaftArch })
        } else {
            Set-InstallConfigVar "CODERAFT_HOST_OS" $CoderaftOS
            Set-InstallConfigVar "CODERAFT_HOST_ARCH" $CoderaftArch
        }
    }
    # Strip any legacy copies from .env now that install-config.env is authoritative.
    $envText = [System.IO.File]::ReadAllText("$(Get-Location)\.env", [System.Text.UTF8Encoding]::new($false))
    $envLines = $envText -split "`r?`n" | Where-Object { $_ -notmatch '^(HOST_PROJECT_DIR|CODERAFT_HOST_OS|CODERAFT_HOST_ARCH)=' }
    $envText = (($envLines -join "`n").TrimEnd()) + "`n"
    [System.IO.File]::WriteAllText("$(Get-Location)\.env", $envText, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Existing config preserved (HOST_PROJECT_DIR refreshed)" -ForegroundColor Green
    # Task #148 Phase 3 (PowerShell parity): upgrade from a pre-#148 install
    # never had secrets\postgres_password — backfill it from the EXISTING
    # .env value so postgres's `secrets:` block (added by this version)
    # resolves to the SAME password postgres already has, instead of a fresh
    # one that would mismatch the running cluster.
    if (-not (Test-Path "secrets\postgres_password")) {
        $existingPgPw = (Select-String -Path '.env' -Pattern '^POSTGRES_PASSWORD=(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($existingPgPw) {
            Write-PostgresSecretFile $existingPgPw.Matches.Groups[1].Value
            Write-Host "  ✓ secrets\postgres_password backfilled from existing .env (task #148)" -ForegroundColor Green
        }
    }
    # Task #219 (2026-07-31, PowerShell parity): same backfill for redis —
    # an existing install upgrading to this version needs secrets\redis_password
    # to match the password redis was ALREADY started with, or the
    # `sh -c 'redis-server --requirepass "$(cat /run/secrets/redis_password)"'`
    # override below would start redis with a DIFFERENT password than every
    # client's REDIS_URL (built from the .env value), locking everything out.
    if (-not (Test-Path "secrets\redis_password")) {
        $existingRedisPw = (Select-String -Path '.env' -Pattern '^REDIS_PASSWORD=(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($existingRedisPw) {
            Write-RedisSecretFile $existingRedisPw.Matches.Groups[1].Value
            Write-Host "  ✓ secrets\redis_password backfilled from existing .env (task #219)" -ForegroundColor Green
        }
    }
} else {
    Write-Host "  Generating secrets..."
    $PgPasswordBootstrap = New-HexSecret 24
    $Env = @"
# CodeRaft Dashboard — $(Get-Date -Format 'yyyy-MM-dd')
POSTGRES_PASSWORD=$PgPasswordBootstrap
REDIS_PASSWORD=$(New-HexSecret 24)
DASHBOARD_SECRET=$(New-HexSecret 32)
RAVENSCAN_CAPTURE_TOKEN=$(New-HexSecret 32)
"@
    # Write without BOM — Docker Compose .env parser chokes on UTF-8 BOM
    [System.IO.File]::WriteAllText("$(Get-Location)\.env", $Env, [System.Text.UTF8Encoding]::new($false))
    # Task #148 Phase 3 (PowerShell parity): same value as .env's
    # POSTGRES_PASSWORD above, materialized as a standalone file for
    # postgres's `secrets:`/POSTGRES_PASSWORD_FILE — both must agree at the
    # container's very first initdb.
    Write-PostgresSecretFile $PgPasswordBootstrap
    # Task #219 (2026-07-31, PowerShell parity): same idea for redis — must
    # match the REDIS_PASSWORD line written into $Env just above.
    if ($Env -match '(?m)^REDIS_PASSWORD=(.+)$') {
        Write-RedisSecretFile $Matches[1]
    }
    $ConfigEnv = @"
# CodeRaft — install-time / public config (NOT a secret, NEVER SOPS-encrypted)
# $(Get-Date -Format 'yyyy-MM-dd')
HOST_PROJECT_DIR=$AbsoluteInstallDir
CODERAFT_HOST_OS=$CoderaftOS
CODERAFT_HOST_ARCH=$CoderaftArch
"@
    [System.IO.File]::WriteAllText("$(Get-Location)\install-config.env", $ConfigEnv, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Secrets generated" -ForegroundColor Green
    Write-Host "  ✓ install-config.env generated" -ForegroundColor Green
}

# Every `docker compose` invocation from here on must read BOTH files.
$ComposeEnvArgs = @("--env-file", "install-config.env", "--env-file", ".env")

# Read the capture token back so we can hand it to the native daemon installer.
$RavenscanCaptureToken = (Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_TOKEN=' -Quiet) `
    | ForEach-Object { (Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_TOKEN=(.+)$').Matches.Groups[1].Value }
if (-not $RavenscanCaptureToken) {
    $match = Select-String -Path '.env' -Pattern '^RAVENSCAN_CAPTURE_TOKEN=(.+)$'
    if ($match) { $RavenscanCaptureToken = $match.Matches.Groups[1].Value }
}

# ── Vault master-key bootstrap (D2 + D3) ────────────────────────────────────
# Runs once on fresh install. Skipped if vault-keys\age.key already exists.
# NOTE: openssl is required. On Windows, use openssl.exe from Git for Windows
# (typically at C:\Program Files\Git\usr\bin\openssl.exe or on PATH).
# If openssl is absent, the installer prints a clear error and exits.

function Invoke-VaultBootstrap {
    New-Item -ItemType Directory -Force -Path "vault-keys" | Out-Null
    New-Item -ItemType Directory -Force -Path "vault-tls"  | Out-Null
    New-Item -ItemType Directory -Force -Path "vault-config" | Out-Null

    # ── Step 1: Generate vault age key ──────────────────────────────────────
    # B-VAULT-BOOT (2026-06-09): le `return` anticipé skipait aussi TLS PKI +
    # config.yaml quand age.key existait déjà → vault container fail healthcheck
    # car C:\...\vault-config\config.yaml manquant. Skip uniquement la
    # génération de la key et toujours continuer vers TLS + config.
    if (Test-Path "vault-keys\age.key") {
        Write-Host "  ✓ Vault age key already exists — skipping key generation"
        # B-VAULT-ACL-SELFHEAL (2026-07-16): a stale age.key left over from
        # an earlier install may have an ACL that only grants its original
        # creator Read, which breaks Docker Desktop bind-mount for the
        # coderaft-vault container (`open /keys/age.key: permission
        # denied`). Reset the ACL to inherit from the parent directory
        # so Administrators + SYSTEM (both needed by Docker Desktop)
        # get access again. `/reset` is idempotent and safe on a
        # freshly-generated key.
        try {
            $resetOut = Join-Path $env:TEMP "coderaft-icacls-reset-out-$(Get-Random).log"
            $resetErr = Join-Path $env:TEMP "coderaft-icacls-reset-err-$(Get-Random).log"
            Start-Process -FilePath "icacls" `
                -ArgumentList @("vault-keys\age.key","/reset") `
                -NoNewWindow -Wait `
                -RedirectStandardOutput $resetOut `
                -RedirectStandardError  $resetErr `
                -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -Path $resetOut,$resetErr -ErrorAction SilentlyContinue
        } catch {}
        Invoke-VaultBootstrapTLS
        return
    }

    # Find age-keygen on PATH; auto-download from GitHub releases if absent
    # (mirrors the install.sh behaviour for macOS/Linux).
    $ageKeygen = Get-Command age-keygen -ErrorAction SilentlyContinue
    if (-not $ageKeygen) {
        Write-Host "    age-keygen not on PATH — downloading from GitHub releases..."
        $ageVersion = "v1.2.1"
        $ageArch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
        $ageTmp = Join-Path $env:TEMP "coderaft-age-$(Get-Random)"
        New-Item -ItemType Directory -Force -Path $ageTmp | Out-Null
        $ageZip = Join-Path $ageTmp "age.zip"
        $ageUrl = "https://github.com/FiloSottile/age/releases/download/$ageVersion/age-$ageVersion-windows-$ageArch.zip"
        try {
            Invoke-WebRequest -Uri $ageUrl -OutFile $ageZip -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            Expand-Archive -Path $ageZip -DestinationPath $ageTmp -Force -ErrorAction Stop
            $ageKeygenExe = Get-ChildItem -Path $ageTmp -Filter "age-keygen.exe" -Recurse | Select-Object -First 1
            if (-not $ageKeygenExe) {
                Write-Host "  ✗ age-keygen.exe missing in downloaded archive" -ForegroundColor Red
                exit 1
            }
            $ageKeygen = [pscustomobject]@{ Path = $ageKeygenExe.FullName }
            Write-Host "    ✓ age-keygen downloaded ($($ageKeygen.Path))" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Could not auto-download age-keygen: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    Manual install: https://github.com/FiloSottile/age/releases" -ForegroundColor Red
            exit 1
        }
    }

    # B-VAULT-DEK (2026-06-22): a stale 'coderaft_vault_data' volume from a
    # prior install attempt holds a wrapped DEK that was sealed with the
    # PREVIOUS age key. Generating a fresh age.key here without wiping the
    # volume guarantees "unseal failed: bad master key" because vault tries
    # to unwrap the old DEK with the new key. The age.key is brand new so
    # there's no legitimate data to preserve at this point — wipe.
    #
    # B-VAULT-DEK-NATIVE (2026-06-23): the previous version used
    #   try { $stale = docker volume inspect ... 2>$null } catch {}
    # which CRASHES under PS 5.1: `$ErrorActionPreference = 'Stop'` turns the
    # NativeCommandError emitted by `docker volume inspect <missing>` into a
    # terminating error that the surrounding try/catch does NOT capture (the
    # native-command error surfaces during pipeline binding, not after). Use
    # Start-Process — same pattern as age-keygen below and as enforced by the
    # B20-sweep across this script.
    $volInspectOut = Join-Path $env:TEMP "coderaft-volinspect-stdout-$(Get-Random).txt"
    $volInspectErr = Join-Path $env:TEMP "coderaft-volinspect-stderr-$(Get-Random).txt"
    $volInspectProc = Start-Process -FilePath "docker" `
        -ArgumentList "volume","inspect","coderaft_vault_data" `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $volInspectOut `
        -RedirectStandardError  $volInspectErr `
        -ErrorAction SilentlyContinue
    if ($volInspectProc -and -not $volInspectProc.WaitForExit(60000)) {   # 60s
        Write-Host "  ⚠  Docker command timed out after 60s: docker volume inspect coderaft_vault_data" -ForegroundColor Yellow
        try { $volInspectProc.Kill() } catch {}
    }
    Remove-Item -Path $volInspectOut,$volInspectErr -ErrorAction SilentlyContinue
    if ($volInspectProc.ExitCode -eq 0) {
        Write-Host "  Removing stale coderaft_vault_data volume from a previous install attempt..."
        $volRmOut = Join-Path $env:TEMP "coderaft-volrm-stdout-$(Get-Random).txt"
        $volRmErr = Join-Path $env:TEMP "coderaft-volrm-stderr-$(Get-Random).txt"
        $volRmProc = Start-Process -FilePath "docker" `
            -ArgumentList "volume","rm","-f","coderaft_vault_data" `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $volRmOut `
            -RedirectStandardError  $volRmErr `
            -ErrorAction SilentlyContinue
        Remove-Item -Path $volRmOut,$volRmErr -ErrorAction SilentlyContinue
        if ($volRmProc.ExitCode -eq 0) {
            Write-Host "    ✓ stale vault data removed" -ForegroundColor Green
        } else {
            Write-Host "    ⚠ could not remove coderaft_vault_data — vault unseal may fail with 'bad master key'" -ForegroundColor Yellow
            Write-Host "      Manual fix: docker compose down; docker volume rm coderaft_vault_data; docker compose up -d" -ForegroundColor Yellow
        }
    }

    Write-Host "  Generating vault master key..."
    # B20 (2026-06-09): age-keygen emits "warning: writing secret key to a
    # world-readable file" on stderr because Windows has no POSIX chmod.
    # Neither `2>$null` nor `2>&1 | Out-Null` reliably suppress native-command
    # stderr in PowerShell 5.1 (the default on Windows) — they still surface
    # as NativeCommandError red blocks. The only robust approach is
    # Start-Process with -RedirectStandardError to a temp file we discard.
    # ACL tightening immediately after addresses the underlying "world-readable"
    # concern, so silencing the warning loses nothing.
    $ageStderr = Join-Path $env:TEMP "coderaft-age-stderr-$(Get-Random).txt"
    $ageProc = Start-Process -FilePath $ageKeygen.Path `
        -ArgumentList "-o","vault-keys\age.key" `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardError $ageStderr `
        -ErrorAction Stop
    Remove-Item -Path $ageStderr -ErrorAction SilentlyContinue
    if ($ageProc.ExitCode -ne 0 -or -not (Test-Path "vault-keys\age.key")) {
        Write-Host "  ✗ age-keygen failed (exit $($ageProc.ExitCode))" -ForegroundColor Red
        exit 1
    }
    # Restrict permissions (owner read-only) BUT keep Administrators +
    # SYSTEM readable so Docker Desktop can bind-mount the file into the
    # coderaft-vault container. Docker Desktop on Windows exposes host
    # files via 9P/plan9 and enforces Windows ACL semantics — if the
    # file only grants the user who created it, the container gets
    # `open /keys/age.key: permission denied` even though it runs as
    # root inside its own namespace. Same failure hits any later
    # install that runs under a different Windows account (elevated
    # Administrator vs. the original user).
    # B-VAULT-ACL (2026-07-16): drop SetAccessRuleProtection so
    # inheritance stays ON — the profile parent ACL grants
    # Administrators + SYSTEM by default, which is what we need for
    # Docker + cross-account admin. We still explicitly add the
    # current user Read to cover profiles whose default ACL is
    # locked down. Read-only for everyone means age-keygen output
    # can't be overwritten by an unelevated process.
    try {
        $acl = Get-Acl "vault-keys\age.key"
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            "Read", "Allow")
        $acl.AddAccessRule($rule)
        Set-Acl "vault-keys\age.key" $acl -ErrorAction Stop
    } catch {
        Write-Host "  ⚠ Could not tighten ACL on vault-keys\age.key ($($_.Exception.Message.Trim()))." -ForegroundColor Yellow
        Write-Host "    The vault will still start; inherited ACL from the parent directory applies." -ForegroundColor Yellow
    }

    # ── Step 2: Generate mTLS PKI ────────────────────────────────────────────
    # AUDIT-SECU-2026-08-04 (Vault H1 follow-up): this used to be "Step 2:
    # Compute BIP39 recovery phrase" / "Step 3: Display recovery phrase" — a
    # `docker run ... -mnemonic-from-key` call that NEVER existed as a real
    # coderaft-vault sub-command (confirmed against
    # cmd/coderaft-vault/main.go: the binary only accepts -config and
    # -health-check), always silently fell through to a raw key-fingerprint
    # placeholder, and displayed that under a banner claiming "This 24-word
    # phrase is the ONLY way to recover your vault" — factually false even
    # before this fix (the fingerprint isn't a recovery mechanism at all) and
    # doubly so now: coderaft-vault no longer reads vault-keys\age.key for
    # ANYTHING (keyprovider.NewAgeMasterKeyProvider() is stateless — see
    # coderaft-vault/internal/keyprovider). Removed entirely. vault-keys\age.key
    # itself is still generated (Step 1 above) purely as this function's own
    # "already bootstrapped" idempotency marker — update.ps1/vault seeding key
    # off its presence — but it is not, and was never really, a vault
    # recovery secret.
    #
    # The REAL recovery mechanism is the Shamir ceremony (POST /v1/init once
    # the vault container is actually running, POST /v1/unseal with a
    # threshold of the returned shares) — it cannot run yet at this point in
    # the script (the vault container doesn't exist until later). Once it is
    # up, Invoke-VaultCheckSealState below prints the exact commands, and
    # this is also documented in deploy/docs/vault.md ("Init + unseal
    # ceremony").
    Write-Host ""
    Write-Host "  i Vault master key bootstrap complete (vault-keys\age.key)." -ForegroundColor Cyan
    Write-Host "    This is NOT a vault recovery secret — coderaft-vault generates" -ForegroundColor Cyan
    Write-Host "    its own master key internally and splits it into real Shamir" -ForegroundColor Cyan
    Write-Host "    shares the first time an operator runs the init ceremony" -ForegroundColor Cyan
    Write-Host "    (POST /v1/init) against the running container. This script will" -ForegroundColor Cyan
    Write-Host "    print the exact commands once the vault is up. WRITE DOWN and" -ForegroundColor Cyan
    Write-Host "    separately distribute every share when that happens — it is" -ForegroundColor Cyan
    Write-Host "    the ONLY way to recover the vault; there is no other back door." -ForegroundColor Cyan
    Write-Host ""

    Invoke-VaultBootstrapTLS
}

function Invoke-VaultBootstrapTLS {
    # B12 fix: correct cert filenames (client-ca.crt, vault.crt — NOT ca.crt, server.crt).
    # B11 fix: correct ACL field names (name, cert_san, permissions — NOT san/role/allow).
    # B7  fix: server cert SAN includes localhost + 127.0.0.1 for mTLS hostname verify.
    # NON-NEGOTIABLE: DO NOT require host openssl on Windows. Always use the
    # alpine container approach (same as update.ps1 4c.2) — Git for Windows
    # openssl is not guaranteed on all Windows installs.

    if ((Test-Path "vault-tls\client-ca.crt") -and (Test-Path "vault-tls\vault.crt")) {
        Write-Host "  ✓ Vault mTLS PKI already exists — skipping cert generation"
        return
    }

    Write-Host "  Bootstrapping vault TLS PKI + config (via alpine container)..."
    $tlsDir = "$(Get-Location)\vault-tls"
    $cfgDir = "$(Get-Location)\vault-config"

    # Single shell script run inside alpine — produces all certs at once.
    $opensslScript = @'
set -e
apk add --no-cache openssl >/dev/null
cd /work
# CA (client-ca.crt — exact name expected by vault config.yaml)
openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
    -keyout client-ca.key -out client-ca.crt \
    -subj "/CN=coderaft-vault-ca" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
# Server cert (vault.crt — SAN includes localhost + 127.0.0.1 for mTLS probe)
openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout vault.key -out vault.csr \
    -subj "/CN=coderaft-vault" 2>/dev/null
cat > /tmp/server.ext <<EOF
subjectAltName=DNS:coderaft-vault,DNS:localhost,IP:127.0.0.1
basicConstraints=CA:FALSE
EOF
openssl x509 -req -days 3650 -sha256 \
    -in vault.csr -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
    -out vault.crt -extfile /tmp/server.ext 2>/dev/null
rm -f vault.csr /tmp/server.ext
# Per-product client certs
for pair in "dashboard-api:dashboard-api.coderaft.local" \
            "entraguard:entraguard.coderaft.local" \
            "ravenscan:ravenscan.coderaft.local" \
            "redfox:redfox.coderaft.local" \
            "falconone:falconone.coderaft.local" \
            "cve-proxy:cve-proxy.coderaft.local"; do
    name="${pair%%:*}"
    san="${pair##*:}"
    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout "${name}-client.key" -out "${name}-client.csr" \
        -subj "/CN=${san}" 2>/dev/null
    cat > /tmp/client.ext <<EOF
subjectAltName=DNS:${san}
basicConstraints=CA:FALSE
EOF
    openssl x509 -req -days 3650 -sha256 \
        -in "${name}-client.csr" -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
        -out "${name}-client.crt" -extfile /tmp/client.ext 2>/dev/null
    rm -f "${name}-client.csr" /tmp/client.ext
done
chmod 600 *.key 2>/dev/null || true
# falconone-api / coderaft-cve-proxy run distroless nonroot (uid 65532) —
# 600 would be unreadable.
chmod 644 falconone-client.key falconone-client.crt 2>/dev/null || true
chmod 644 cve-proxy-client.key cve-proxy-client.crt 2>/dev/null || true
'@
    $absTlsDir = (Resolve-Path -LiteralPath $tlsDir -ErrorAction SilentlyContinue)
    if (-not $absTlsDir) {
        New-Item -ItemType Directory -Force -Path $tlsDir | Out-Null
        $absTlsDir = (Resolve-Path -LiteralPath $tlsDir).Path
    } else {
        $absTlsDir = $absTlsDir.Path
    }
    # B20-docker (2026-06-09): the previous form
    #   $opensslScript | & docker run --rm -i ... 2>&1
    # surfaced docker's image-pull progress (and any alpine sh stderr) as a
    # red NativeCommandError block in PowerShell 5.1, alarming users. The
    # only reliable suppression is Start-Process with -RedirectStandardError.
    # We write the script to a temp file, mount it, and run sh against it so
    # we don't need stdin piping.
    $opensslScriptFile = Join-Path $env:TEMP "coderaft-openssl-$(Get-Random).sh"
    # IMPORTANT: write with Unix line endings, otherwise sh barfs on CRLF.
    $opensslScriptLF = $opensslScript -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($opensslScriptFile, $opensslScriptLF, [System.Text.UTF8Encoding]::new($false))

    # Pre-pull alpine silently so `docker run` doesn't emit pull progress on
    # stderr (which PS would still treat as NativeCommandError).
    # NOTE: Start-Process refuses identical stdout/stderr files — must use 2.
    $pullStdout = Join-Path $env:TEMP "coderaft-docker-pull-out-$(Get-Random).log"
    $pullStderr = Join-Path $env:TEMP "coderaft-docker-pull-err-$(Get-Random).log"
    Start-Process -FilePath "docker" -ArgumentList @("pull","alpine:3.20") `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $pullStdout `
        -RedirectStandardError $pullStderr `
        -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path $pullStdout,$pullStderr -ErrorAction SilentlyContinue

    $runStdout = Join-Path $env:TEMP "coderaft-docker-run-out-$(Get-Random).log"
    $runStderr = Join-Path $env:TEMP "coderaft-docker-run-err-$(Get-Random).log"
    $dockerProc = Start-Process -FilePath "docker" -ArgumentList @(
        "run","--rm",
        "-v","${opensslScriptFile}:/script.sh:ro",
        "-v","${absTlsDir}:/work",
        "alpine:3.20","sh","/script.sh"
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $runStdout `
        -RedirectStandardError $runStderr `
        -ErrorAction Stop
    if (Test-Path $runStdout) {
        $stdoutContent = Get-Content $runStdout -ErrorAction SilentlyContinue
        if ($stdoutContent) { $stdoutContent | Out-Host }
    }
    # Discard stderr — known noisy (pull progress, alpine sh diagnostics).
    Remove-Item -Path $runStdout,$runStderr,$opensslScriptFile -ErrorAction SilentlyContinue
    if ($dockerProc.ExitCode -ne 0 -or -not (Test-Path (Join-Path $tlsDir "vault.crt"))) {
        Write-Host "  ✗ Alpine openssl cert generation failed (docker exit $($dockerProc.ExitCode))" -ForegroundColor Red
        exit 1
    }

    # vault config.yaml — correct file paths
    $configYaml = @'
server:
  addr: "0.0.0.0:8200"
  tls_cert: "/tls/vault.crt"
  tls_key:  "/tls/vault.key"
  client_ca: "/tls/client-ca.crt"
storage:
  path: "/data/vault.db"
keys:
  age_key_path: "/keys/age.key"
audit:
  log_path: "/data/audit.log"
acl_path: "/etc/coderaft-vault/acl.yaml"
'@
    [System.IO.File]::WriteAllText((Join-Path $cfgDir "config.yaml"), $configYaml, [System.Text.UTF8Encoding]::new($false))

    # B11 fix: correct ACL field names (name, cert_san, permissions)
    $aclYaml = @'
# coderaft-vault ACL — field names: name, cert_san, permissions (NOT san/role/allow)
clients:
  - name: dashboard-api
    cert_san: "dashboard-api.coderaft.local"
    permissions: ["*"]

  - name: entraguard
    cert_san: "entraguard.coderaft.local"
    permissions: ["read:azure_*","read:license_key","read:entraguard_*","read:platform/identity/oidc"]

  - name: ravenscan
    cert_san: "ravenscan.coderaft.local"
    permissions: ["read:ravenscan_*","read:neo4j_*","read:license_key","read:platform/identity/oidc"]

  - name: redfox
    cert_san: "redfox.coderaft.local"
    permissions: ["read:redfox_*","read:license_key","read:platform/identity/oidc","read:platform/identity/graph-tools","read:redfox/connections/*","write:redfox/connections/*","delete:redfox/connections/*","read:redfox/k8s/*","write:redfox/k8s/*","delete:redfox/k8s/*"]

  - name: falconone
    cert_san: "falconone.coderaft.local"
    permissions: ["read:license_key","read:falconone_*","read:platform/identity/oidc","sign:falconone_agent_cert","read:falconone/nvd_api_key","read:falconone/audit_hmac_key","write:falconone/audit_hmac_key","read:falconone/pki/agents-ca/cert","read:pki/falconone-agents-ca*","write:pki/falconone-agents-ca*","read:falconone/scripts_ca*","write:falconone/scripts_ca*"]

  - name: cve-proxy
    cert_san: "cve-proxy.coderaft.local"
    permissions: ["read:cve-proxy/*", "write:cve-proxy/*"]
'@
    [System.IO.File]::WriteAllText((Join-Path $cfgDir "acl.yaml"), $aclYaml, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Vault mTLS PKI generated (CA + server cert + 6 client certs)" -ForegroundColor Green
}

# ── FalconOne agents mTLS PKI (#170) ─────────────────────────────────────────
# Distinct CA/leaf from the vault client PKI above: falconone-tls\agents-ca.crt
# is the pool of ClientCAs falconone-api trusts for inbound agent mTLS, and
# falconone-tls\server.crt is the leaf falconone-api presents on :8443 to its
# own Windows agents. Bug #170: server.crt's SAN only ever had
# [localhost, falconone-api] — remote agents connecting via
# https://<public-hostname>:8443/agent/v1 failed hostname verification.
# Self-healing: the CA is preserved if it already exists (regenerating it
# would break trust for any agent already enrolled); only the leaf is
# regenerated, and only when it's missing the "coderaft.local" SAN.
function Invoke-FalconOneTlsBootstrap {
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $foTlsDir = Join-Path $InstallDir "falconone-tls"
    New-Item -ItemType Directory -Force -Path $foTlsDir | Out-Null

    $foSanList = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @("DNS:localhost", "DNS:falconone-api", "DNS:coderaft.local")) { $foSanList.Add($s) }
    if ($env:COMPUTERNAME) { $foSanList.Add("DNS:$($env:COMPUTERNAME)") }
    if ($env:CODERAFT_EXTRA_HOSTS) {
        foreach ($h in ($env:CODERAFT_EXTRA_HOSTS -split ",")) {
            $trimmed = $h.Trim()
            if ($trimmed) { $foSanList.Add("DNS:$trimmed") }
        }
    }
    $foSanList.Add("IP:127.0.0.1")
    $foSanString = (($foSanList | Select-Object -Unique) -join ",")

    $foScript = @'
set -e
apk add --no-cache openssl >/dev/null
cd /work
if [ ! -f agents-ca.crt ]; then
    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes -sha256 \
        -keyout agents-ca.key -out agents-ca.crt \
        -subj "/CN=falconone-agents-ca" \
        -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
fi
NEED_REGEN=1
if [ -f server.crt ] && openssl x509 -in server.crt -noout -text 2>/dev/null | grep -q "coderaft.local"; then
    NEED_REGEN=0
fi
if [ "$NEED_REGEN" = "1" ]; then
    openssl req -newkey rsa:2048 -nodes -sha256 \
        -keyout server.key -out server.csr \
        -subj "/CN=falconone-agents" 2>/dev/null
    cat > /tmp/server.ext <<EOF
subjectAltName=__FO_SAN_LIST__
basicConstraints=CA:FALSE
EOF
    openssl x509 -req -days 3650 -sha256 \
        -in server.csr -CA agents-ca.crt -CAkey agents-ca.key -CAcreateserial \
        -out server.crt -extfile /tmp/server.ext 2>/dev/null
    rm -f server.csr /tmp/server.ext
fi
chmod 644 *.crt *.key 2>/dev/null || true
'@
    $foScript = $foScript.Replace("__FO_SAN_LIST__", $foSanString)
    $foScriptFile = Join-Path $env:TEMP "coderaft-fo-tls-$(Get-Random).sh"
    $foScriptLF = $foScript -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($foScriptFile, $foScriptLF, [System.Text.UTF8Encoding]::new($false))
    $absFoTlsDir = (Resolve-Path -LiteralPath $foTlsDir).Path

    Start-Process -FilePath "docker" -ArgumentList @(
        "run", "--rm",
        "-v", "${foScriptFile}:/script.sh:ro",
        "-v", "${absFoTlsDir}:/work",
        "alpine:3.20", "sh", "/script.sh"
    ) -NoNewWindow -Wait -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path $foScriptFile -ErrorAction SilentlyContinue
    Write-DetailLog "FalconOne agents PKI written (SAN: $foSanString)"
}

# ── ACL self-heal: falconone entry/permissions (#172) ────────────────────────
# The static acl.yaml above only runs once (Invoke-VaultBootstrapTLS returns
# early when vault-tls already exists — see the "already exists — skipping"
# guard at its top). That means any install that provisioned vault before
# this fix shipped will never get the falconone entry/permissions rewritten.
# This self-heal is additive-only, idempotent, and safe to call on every
# install/update run: if the "falconone" client entry is missing, it appends
# the full canonical block; if present, it appends only whichever required
# permissions are missing, leaving everything else in the file untouched.
# Backs up acl.yaml before any modification.
function Invoke-FalconOneAclSelfHeal {
    param([Parameter(Mandatory = $true)][string]$AclPath)

    if (-not (Test-Path $AclPath)) {
        Write-DetailLog "[install] ACL self-heal: $AclPath not found — skipping (vault not provisioned yet)"
        return
    }

    $requiredPerms = @(
        "read:license_key",
        "read:falconone_*",
        "read:platform/identity/oidc",
        "sign:falconone_agent_cert",
        "read:falconone/nvd_api_key",
        "read:falconone/audit_hmac_key",
        "write:falconone/audit_hmac_key",
        "read:falconone/pki/agents-ca/cert",
        "read:pki/falconone-agents-ca*",
        "write:pki/falconone-agents-ca*",
        "read:falconone/scripts_ca*",
        "write:falconone/scripts_ca*"
    )

    $lines = @(Get-Content -LiteralPath $AclPath)
    $blockStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-\s*name:\s*falconone\s*$') { $blockStart = $i; break }
    }

    $ts = Get-Date -Format "yyyyMMddTHHmmssZ"

    if ($blockStart -eq -1) {
        Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"
        Invoke-RotateBackups -BasePath $AclPath
        $newBlock = @'

  - name: falconone
    cert_san: "falconone.coderaft.local"
    permissions:
      - "read:license_key"
      - "read:falconone_*"
      - "read:platform/identity/oidc"
      - "sign:falconone_agent_cert"
      - "read:falconone/nvd_api_key"
      - "read:falconone/audit_hmac_key"
      - "write:falconone/audit_hmac_key"
      - "read:falconone/pki/agents-ca/cert"
      - "read:pki/falconone-agents-ca*"
      - "write:pki/falconone-agents-ca*"
      - "read:falconone/scripts_ca*"
      - "write:falconone/scripts_ca*"
'@
        Add-Content -LiteralPath $AclPath -Value $newBlock
        Write-DetailLog "[install] Self-heal ACL: falconone permissions updated (+$($requiredPerms.Count) added, entry created)"
        return
    }

    $blockEnd = $lines.Count
    for ($j = $blockStart + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*-\s*name:\s*\S') { $blockEnd = $j; break }
    }
    $blockText = ($lines[$blockStart..($blockEnd - 1)]) -join "`n"

    $missing = @($requiredPerms | Where-Object { $blockText -notmatch [regex]::Escape("`"$_`"") })

    if ($missing.Count -eq 0) {
        Write-DetailLog "[install] ACL falconone already up-to-date"
        return
    }

    Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"
    Invoke-RotateBackups -BasePath $AclPath

    $permsLineIdx = -1
    for ($k = $blockStart; $k -lt $blockEnd; $k++) {
        if ($lines[$k] -match '^\s*permissions:\s*\[.*\]\s*$') { $permsLineIdx = $k; break }
    }

    if ($permsLineIdx -ge 0) {
        $additions = ($missing | ForEach-Object { "`"$_`"" }) -join ","
        $lines[$permsLineIdx] = $lines[$permsLineIdx] -replace '\]\s*$', ",$additions]"
        $lines | Set-Content -LiteralPath $AclPath -Encoding UTF8
    } else {
        $insertLines = @($missing | ForEach-Object { "      - `"$_`"" })
        $before = if ($blockEnd -gt 0) { $lines[0..($blockEnd - 1)] } else { @() }
        $after  = if ($blockEnd -le $lines.Count - 1) { $lines[$blockEnd..($lines.Count - 1)] } else { @() }
        $merged = @($before + $insertLines + $after)
        $merged | Set-Content -LiteralPath $AclPath -Encoding UTF8
    }

    Write-DetailLog "[install] Self-heal ACL: falconone permissions updated (+$($missing.Count) added)"
}

# ── ACL self-heal: redfox connections/k8s vault-backed credentials ──────────
# Zero-Knowledge Credential Architecture Palier 1
# (coderaft-platform/docs/redfox-zero-knowledge-scoping.md): target
# connection credentials and k8s cluster auth data move from RedFox's own
# Postgres into this vault, under redfox/connections/* and redfox/k8s/*.
# Same additive-only, idempotent merge-into-existing-entry pattern as
# Invoke-FalconOneAclSelfHeal above — any install already has a "redfox"
# entry (it existed for platform/identity/oidc), so without this it would
# never gain the new permissions.
function Invoke-RedfoxAclSelfHeal {
    param([Parameter(Mandatory = $true)][string]$AclPath)

    if (-not (Test-Path $AclPath)) {
        Write-DetailLog "[install] ACL self-heal: $AclPath not found — skipping (vault not provisioned yet)"
        return
    }

    $requiredPerms = @(
        "read:license_key",
        "read:redfox_*",
        "read:platform/identity/oidc",
        "read:platform/identity/graph-tools",
        "read:redfox/connections/*",
        "write:redfox/connections/*",
        "delete:redfox/connections/*",
        "read:redfox/k8s/*",
        "write:redfox/k8s/*",
        "delete:redfox/k8s/*"
    )

    $lines = @(Get-Content -LiteralPath $AclPath)
    $blockStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-\s*name:\s*redfox\s*$') { $blockStart = $i; break }
    }

    $ts = Get-Date -Format "yyyyMMddTHHmmssZ"

    if ($blockStart -eq -1) {
        Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"
        Invoke-RotateBackups -BasePath $AclPath
        $newBlock = @'

  - name: redfox
    cert_san: "redfox.coderaft.local"
    permissions:
      - "read:license_key"
      - "read:redfox_*"
      - "read:platform/identity/oidc"
      - "read:platform/identity/graph-tools"
      - "read:redfox/connections/*"
      - "write:redfox/connections/*"
      - "delete:redfox/connections/*"
      - "read:redfox/k8s/*"
      - "write:redfox/k8s/*"
      - "delete:redfox/k8s/*"
'@
        Add-Content -LiteralPath $AclPath -Value $newBlock
        Write-DetailLog "[install] Self-heal ACL: redfox permissions updated (+$($requiredPerms.Count) added, entry created)"
        return
    }

    $blockEnd = $lines.Count
    for ($j = $blockStart + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*-\s*name:\s*\S') { $blockEnd = $j; break }
    }
    $blockText = ($lines[$blockStart..($blockEnd - 1)]) -join "`n"

    $missing = @($requiredPerms | Where-Object { $blockText -notmatch [regex]::Escape("`"$_`"") })

    if ($missing.Count -eq 0) {
        Write-DetailLog "[install] ACL redfox already up-to-date"
        return
    }

    Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"
    Invoke-RotateBackups -BasePath $AclPath

    $permsLineIdx = -1
    for ($k = $blockStart; $k -lt $blockEnd; $k++) {
        if ($lines[$k] -match '^\s*permissions:\s*\[.*\]\s*$') { $permsLineIdx = $k; break }
    }

    if ($permsLineIdx -ge 0) {
        $additions = ($missing | ForEach-Object { "`"$_`"" }) -join ","
        $lines[$permsLineIdx] = $lines[$permsLineIdx] -replace '\]\s*$', ",$additions]"
        $lines | Set-Content -LiteralPath $AclPath -Encoding UTF8
    } else {
        $insertLines = @($missing | ForEach-Object { "      - `"$_`"" })
        $before = if ($blockEnd -gt 0) { $lines[0..($blockEnd - 1)] } else { @() }
        $after  = if ($blockEnd -le $lines.Count - 1) { $lines[$blockEnd..($lines.Count - 1)] } else { @() }
        $merged = @($before + $insertLines + $after)
        $merged | Set-Content -LiteralPath $AclPath -Encoding UTF8
    }

    Write-DetailLog "[install] Self-heal ACL: redfox permissions updated (+$($missing.Count) added)"
}

# ── ACL self-heal: cve-proxy entry (coderaft-cve-engine sidecar) ────────────
# Same additive-only, idempotent pattern as Invoke-FalconOneAclSelfHeal above.
function Invoke-CveProxyAclSelfHeal {
    param([Parameter(Mandatory = $true)][string]$AclPath)

    if (-not (Test-Path $AclPath)) {
        Write-DetailLog "[install] ACL self-heal: $AclPath not found — skipping (vault not provisioned yet)"
        return
    }

    $lines = @(Get-Content -LiteralPath $AclPath)
    $already = $lines | Where-Object { $_ -match '^\s*-\s*name:\s*cve-proxy\s*$' }
    if ($already) {
        Write-DetailLog "[install] ACL cve-proxy already present"
        return
    }

    $ts = Get-Date -Format "yyyyMMddTHHmmssZ"
    Copy-Item -LiteralPath $AclPath -Destination "${AclPath}.bak-${ts}"
    Invoke-RotateBackups -BasePath $AclPath
    $newBlock = @'

  - name: cve-proxy
    cert_san: "cve-proxy.coderaft.local"
    permissions:
      - "read:cve-proxy/*"
      - "write:cve-proxy/*"
'@
    Add-Content -LiteralPath $AclPath -Value $newBlock
    Write-DetailLog "[install] Self-heal ACL: cve-proxy entry created"
}

# ── Vault client cert self-heal (any product whose cert was never
# generated, e.g. falconone/cve-proxy on installs provisioned before they
# shipped) — additive-only, requires client-ca.key to still be present.
function Invoke-VaultClientCertSelfHeal {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$San
    )

    $tlsDir = Join-Path (Get-Location).Path "vault-tls"
    $certPath = Join-Path $tlsDir "$Name-client.crt"
    if (Test-Path $certPath) { return }

    $caKey = Join-Path $tlsDir "client-ca.key"
    $caCrt = Join-Path $tlsDir "client-ca.crt"
    if (-not (Test-Path $caKey) -or -not (Test-Path $caCrt)) {
        Write-Host "  [install] Cert self-heal: vault-tls\client-ca.key missing — cannot mint $Name-client cert (needs a full CA rotation, not a self-heal)"
        return
    }

    Write-DetailLog "[install] Cert self-heal: generating vault-tls\$Name-client (was missing)"
    $chmodExtra = if ($Name -eq "falconone" -or $Name -eq "cve-proxy") {
        "chmod 644 '$Name-client.key' '$Name-client.crt'"
    } else {
        "chmod 600 '$Name-client.key' '$Name-client.crt'"
    }
    # Same proven pattern as Invoke-VaultBootstrapTLS (B20-docker): script
    # file + Start-Process with explicit redirection, never a bare pipeline
    # to `docker run`, or PowerShell 5.1 surfaces stderr as a scary red
    # NativeCommandError even on success.
    $script = @"
set -e
apk add --no-cache openssl >/dev/null
cd /work
openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout '$Name-client.key' -out '$Name-client.csr' \
    -subj '/CN=$San' 2>/dev/null
printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE' '$San' > /tmp/client.ext
openssl x509 -req -days 3650 -sha256 \
    -in '$Name-client.csr' -CA client-ca.crt -CAkey client-ca.key -CAcreateserial \
    -out '$Name-client.crt' -extfile /tmp/client.ext 2>/dev/null
rm -f '$Name-client.csr' /tmp/client.ext
$chmodExtra
"@
    $scriptFile = Join-Path $env:TEMP "coderaft-cert-selfheal-$(Get-Random).sh"
    $scriptLF = $script -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($scriptFile, $scriptLF, [System.Text.UTF8Encoding]::new($false))

    $runStdout = Join-Path $env:TEMP "coderaft-cert-selfheal-out-$(Get-Random).log"
    $runStderr = Join-Path $env:TEMP "coderaft-cert-selfheal-err-$(Get-Random).log"
    $proc = Start-Process -FilePath "docker" -ArgumentList @(
        "run","--rm",
        "-v","${scriptFile}:/script.sh:ro",
        "-v","${tlsDir}:/work",
        "alpine:3.20","sh","/script.sh"
    ) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $runStdout `
        -RedirectStandardError $runStderr `
        -ErrorAction SilentlyContinue
    Remove-Item -Path $runStdout, $runStderr, $scriptFile -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.ExitCode -ne 0 -or -not (Test-Path $certPath)) {
        Write-DetailLog "[install] Cert self-heal: $Name-client generation failed (non-fatal, retried next run)"
    }
}

Invoke-VaultBootstrap

# ── FalconOne mTLS PKI + ACL self-heal (#170 / #172) ─────────────────────────
# Always run, independent of Invoke-VaultBootstrap's internal "already
# exists — skipping" guards, so a re-run of this installer on an existing
# install still gets the extended-SAN falconone-tls cert and any missing
# ACL permissions healed. (2026-08-05) Console only gets one concise phase
# line — per-product ACL/PKI/cert self-heal detail goes to $INSTALL_LOG via
# Write-DetailLog instead (see the log-file setup near the top of this script).
Write-Host "  Checking vault ACL / PKI provisioning..."
Invoke-FalconOneTlsBootstrap -InstallDir (Get-Location).Path
Invoke-FalconOneAclSelfHeal -AclPath (Join-Path (Get-Location).Path "vault-config\acl.yaml")

# ── RedFox connections/k8s vault-backed credentials ACL self-heal ───────────
# Zero-Knowledge Credential Architecture Palier 1 — see Invoke-RedfoxAclSelfHeal
# above. redfox's client cert already exists (provisioned for
# platform/identity/oidc), so no Invoke-VaultClientCertSelfHeal call is needed.
Invoke-RedfoxAclSelfHeal -AclPath (Join-Path (Get-Location).Path "vault-config\acl.yaml")

# ── cve-proxy vault client cert + ACL self-heal ──────────────────────────────
# coderaft-cve-proxy is a shared platform sidecar (in front of the central
# coderaft-cve-engine), not tied to any single product license.
Invoke-VaultClientCertSelfHeal -Name "falconone" -San "falconone.coderaft.local"
Invoke-VaultClientCertSelfHeal -Name "cve-proxy" -San "cve-proxy.coderaft.local"
Invoke-CveProxyAclSelfHeal -AclPath (Join-Path (Get-Location).Path "vault-config\acl.yaml")
Write-Host "  ✓ Vault ACL / PKI provisioning OK (detail: $INSTALL_LOG)"

# Append CODERAFT_VAULT_* env vars if not already present
$envText = [System.IO.File]::ReadAllText("$(Get-Location)\.env", [System.Text.UTF8Encoding]::new($false))
foreach ($kv in @(
    "CODERAFT_VAULT_URL=https://coderaft-vault:8200",
    "CODERAFT_VAULT_AZURE=0",
    "CODERAFT_VAULT_LICENSE=0",
    "CODERAFT_VAULT_PRODUCTS=0",
    "CODERAFT_VAULT_JWT=0"
)) {
    $k = $kv.Split('=')[0]
    if ($envText -notmatch "(?m)^$k=") {
        $envText = $envText.TrimEnd() + "`n$kv`n"
    }
}
[System.IO.File]::WriteAllText("$(Get-Location)\.env", $envText, [System.Text.UTF8Encoding]::new($false))

# Init DB
[System.IO.File]::WriteAllText("$(Get-Location)\init-db.sql", '-- Product databases are created by the dashboard on demand', [System.Text.UTF8Encoding]::new($false))

# Docker compose — dashboard + vault
Write-Host "  Writing docker-compose.yml..."
$Compose = @'
# CodeRaft Dashboard
# Products are deployed by the dashboard after license activation.
#
# F-017 (seccomp) — PowerShell parity with install.sh: every service below
# relies on Docker's IMPLICIT default seccomp profile, deliberately NOT
# written as `security_opt: [seccomp=default]` — that literal string isn't a
# Docker keyword, it's parsed as a PATH to a custom profile file and fails
# with `opening seccomp profile (default) failed`. Re-confirmed live against
# this Docker version (2026-07-31, same Mac used for install.sh's own
# re-verification — Docker Desktop's daemon behaves identically regardless
# of which install script targets it). Omitting `seccomp:` keeps the strong
# default profile.

services:
  # Caddy HTTPS reverse proxy.
  # TLS mode is env-driven (Setup Wizard → dashboard-api writes .env and
  # recreates this service):
  #   internal (default) — Caddy's own CA signs the cert (replaces mkcert,
  #                        2026-07). CA root lives in the caddy_data volume:
  #                        PRESERVE that volume or agents lose trust.
  #   wildcard           — customer cert uploaded to ./caddy_certs/
  #   acme               — Let's Encrypt (public deployments)
  caddy:
    image: caddy:2-alpine
    depends_on:
      dashboard: { condition: service_started }
    ports:
      # CADDY_BIND_ADDR is widened to 0.0.0.0 by the Exposure wizard step.
      - "${CADDY_BIND_ADDR:-127.0.0.1}:443:443"
      - "${CADDY_BIND_ADDR:-127.0.0.1}:80:80"
    environment:
      - CODERAFT_HOSTNAME=${CODERAFT_HOSTNAME:-coderaft.local}
      - CODERAFT_TLS_SITES=${CODERAFT_TLS_SITES:-coderaft.local, *.coderaft.local}
      - CADDY_TLS_MODE_ARGS=${CADDY_TLS_MODE_ARGS:-internal}
    volumes:
      - ./caddy_certs:/certs:ro
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    # F-015 (2026-07-31, PowerShell parity): install.ps1's caddy had NO
    # healthcheck at all before this — was out of sync with install.sh.
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:80/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    security_opt: [no-new-privileges:true]
    # Phase 2 hardening (2026-07-31) — PowerShell parity with install.sh:
    # verified in a throwaway compose project (same Docker Desktop engine
    # this Windows install targets) that caddy:2-alpine needs exactly
    # NET_BIND_SERVICE back after cap_drop:ALL to keep binding :80/:443.
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    read_only: true
    tmpfs: [/tmp]
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
    restart: unless-stopped

  dashboard:
    image: ghcr.io/liamj74/coderaft-dashboard:latest
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
      dashboard-api: { condition: service_started }
    environment:
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      - LICENSE_SERVER_URL=https://license.coderaft.io
    # Security hardening (2026-07-31): DASHBOARD_SECRET removed from this
    # service's env — pure dead code here (this "dashboard" container is
    # nginx serving a static Vite build, no app server, never reads env vars
    # at runtime). See install.sh for the full rationale (identical compose,
    # kept in sync).
    # B-DASHBOARD-NET (2026-06-23): the nginx inside this image proxies
    # /api/entraguard/, /api/ravenscan/, /api/redfox/ to the product
    # containers. Products live on coderaft-frontend (entraguard/ravenscan)
    # and coderaft-backend (DB-talking services). Without these networks
    # the wizard surfaces "Cannot reach WolfGuard API" (502) even though
    # entraguard-api is healthy. Observed live 2026-06-23 on Windows host.
    networks: [default, coderaft-frontend, coderaft-backend]
    security_opt: [no-new-privileges:true]
    # Phase 2 hardening (2026-07-31) — PowerShell parity with install.sh:
    # this image's nginx.conf sets `user nginx;`, needing CAP_CHOWN (fix up
    # /var/cache/nginx/*_temp ownership) + CAP_SETUID/CAP_SETGID (drop
    # workers to the nginx account) even after cap_drop:ALL. Verified on the
    # macOS testing Mac against the identical image Windows hosts pull.
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    read_only: true
    tmpfs: [/tmp, /var/cache/nginx, /var/run]
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:3000/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
    restart: unless-stopped

  # F-003 (2026-06-21): ACL sidecar for the Docker socket. dashboard-api
  # talks through this instead of mounting /var/run/docker.sock directly,
  # so it cannot call POST /exec, /volumes, /secrets, /swarm.
  # Allowed: list containers/images/networks, start/stop/restart products.
  docker-proxy:
    image: tecnativa/docker-socket-proxy:0.3.0
    container_name: coderaft-docker-proxy
    environment:
      CONTAINERS: 1
      IMAGES: 1
      NETWORKS: 1
      SERVICES: 1
      TASKS: 1
      INFO: 1
      VERSION: 1
      POST: 1
      # F-003 follow-up (2026-07-16): VOLUMES=1 required so `docker compose up`
      # can read/create named volumes for the product services (confirmed
      # 2026-07-31: removing it breaks `docker compose up` outright with
      # "denied" on POST /volumes/create for postgres_data/redis_data/
      # vault_data/dashboard_data/etc — stays required).
      #
      # CORRECTED (2026-07-31, was inaccurate): this comment used to claim a
      # privileged `Binds:[/:/host]` mount via POST /containers/create was
      # "still blocked" here. That's false — docker-socket-proxy authorizes
      # purely by HTTP method + URL path (ACL categories like CONTAINERS/
      # POST/VOLUMES), never by inspecting the request BODY. With POST=1 and
      # CONTAINERS=1 already required for `docker compose up` to create any
      # container at all, a POST /containers/create carrying
      # `HostConfig.Binds:["/:/host"]` passes through identically to a normal
      # container-create call.
      #
      # Residual risk: dashboard-api's `/host-compose` mount (see the
      # dashboard-api service below) is a read-write bind of the whole
      # install directory, and dashboard-api legitimately WRITES
      # docker-compose.override.yml there (generateOverrideToDir()). An RCE
      # in dashboard-api could therefore inject a malicious bind-mount into
      # that override file and trigger `docker compose up` through this same
      # proxy. This is not a hole THIS proxy introduces — it's inherent to
      # dashboard-api authoring and executing compose plans for the
      # platform. Fully closing it needs a compose-plan validator (parse +
      # allow-list before ever calling `docker compose up`) that does not
      # exist today; deliberately out of scope for this pass, tracked as a
      # follow-up rather than silently accepted as safe. What IS mitigated:
      # the broad `.:/host-compose` bind no longer redundantly exposes
      # vault-keys/vault-tls/.coderaft-age.key to dashboard-api (see that
      # service's tmpfs / /dev/null volume entries below).
      VOLUMES: 1
      # #Y1 fix (2026-07-22): DISTRIBUTION=1 required for `docker compose pull`
      # multi-arch. It calls GET /distribution/{name}/json to resolve the right
      # platform manifest before pulling. Read-only registry metadata — same
      # exposure class as IMAGES=1 already granted. EXEC/SECRETS/SWARM stay 0.
      DISTRIBUTION: 1
      EXEC: 0
      SECRETS: 0
      SWARM: 0
      NODES: 0
      ALLOW_START: 1
      ALLOW_STOP: 1
      ALLOW_RESTARTS: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      # F-014 (2026-07-31) — PowerShell parity with install.sh: NAMED VOLUME
      # (not tmpfs) so docker-socket-proxy's baked-in haproxy.cfg.template
      # survives being copied into it on first mount — a plain tmpfs is
      # always empty and would wipe that template out from under the
      # entrypoint's `sed`, confirmed on the macOS testing Mac against this
      # exact image (`sed: ... .template: No such file or directory`).
      - docker_proxy_haproxy_cfg:/usr/local/etc/haproxy
    networks:
      - docker-proxy-net
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [CHOWN, SETGID, SETUID, NET_BIND_SERVICE]
    read_only: true
    tmpfs: [/tmp, /var/run]
    mem_limit: 128m
    memswap_limit: 128m
    mem_reservation: 32m
    cpus: 0.5
    restart: unless-stopped

  dashboard-api:
    image: ghcr.io/liamj74/coderaft-dashboard-api:latest
    networks:
      - default
      - coderaft-vault-net
      - docker-proxy-net
      # B-BACKEND-NET (2026-07-16): postgres + redis live on the isolated
      # coderaft-backend network (see PR #12). Without joining this net,
      # dashboard-api resolves `postgres` to nothing and every DB call
      # throws `getaddrinfo EAI_AGAIN postgres` — table bootstrap fails
      # at startup, and every subsequent request (create-admin, save
      # OIDC config, etc.) returns 500. Observed live 2026-07-16 during
      # setup wizard.
      - coderaft-backend
    # B-IPV6-KILL (2026-07-22): Docker Desktop on Windows/macOS gives the
    # container an IPv6 stack that has no upstream route. Node's default
    # resolver in Node 22+ (`verbatim`) can still return AAAA first, and
    # some libraries do their own `dns.lookup({family:6})`. NODE_OPTIONS
    # and the in-code setDefaultResultOrder() cover *most* callers, but
    # Entra callback (openid-client / passport) still surfaced ENETUNREACH
    # on 2603:1027:*. Killing IPv6 at the sysctl level removes the failure
    # surface entirely — no interface, no lookup, no crash.
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=1
      - net.ipv6.conf.default.disable_ipv6=1
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_healthy }
      # B-VAULT-DEP (2026-06-09): coderaft-vault starts sealed and needs the
      # installer/update script to POST /v1/unseal before it can pass its
      # own healthcheck. With `service_healthy` here, compose would kill the
      # whole stack waiting for vault before the unseal step ever runs.
      # Use `service_started` so dashboard-api boots; it gracefully degrades
      # to "vault unavailable" until unseal completes, then reconnects.
      coderaft-vault: { condition: service_started }
      docker-proxy: { condition: service_started }
    environment:
      # B15 (2026-05-19): Node.js résout IPv6 d'abord par défaut. Le container
      # Docker n'a pas d'IPv6 → ENETUNREACH → fallback IPv4 lent ou timeout
      # sur les appels sortants (license.coderaft.io, login.microsoftonline.com).
      # Force IPv4-first.
      - NODE_OPTIONS=--dns-result-order=ipv4first
      - LICENSE_SERVER_URL=https://license.coderaft.io
      - DATABASE_URL=postgres://coderaft:${POSTGRES_PASSWORD}@postgres:5432/coderaft
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0
      # Security hardening (2026-07-31): DASHBOARD_SECRET removed — dead
      # code here too (dashboard-api resolves it from Coderaft Vault
      # directly, never process.env). See install.sh for full rationale.
      - CONTAINER_COMPOSE_DIR=/host-compose
      - HOST_PROJECT_DIR=${HOST_PROJECT_DIR}
      - COMPOSE_PROJECT_NAME=coderaft
      # F-003 (2026-06-21): talk to Docker via the scoped proxy, not the raw
      # socket. Backported from the runtime compose. Blocks dashboard-api
      # from calling POST /exec, /volumes, /secrets, /swarm.
      - DOCKER_HOST=tcp://docker-proxy:2375
      # NOTE: Phase 0.5 keeps SOPS path for backward compat; Phase 5 removes it.
      - CODERAFT_VAULT_URL=https://coderaft-vault:8200
      # B12 fix: correct vault TLS filenames (client-ca.crt, not ca.crt)
      - CODERAFT_VAULT_CA=/vault-tls/client-ca.crt
      - CODERAFT_VAULT_CLIENT_CERT=/vault-tls/dashboard-api-client.crt
      - CODERAFT_VAULT_CLIENT_KEY=/vault-tls/dashboard-api-client.key
    volumes:
      # F-003 (2026-06-21): /var/run/docker.sock mount REMOVED — replaced by
      # tcp://docker-proxy:2375 over the docker-proxy-net network below.
      - dashboard_data:/data
      - .:/host-compose
      # Age private key for SOPS decryption (legacy — kept for backward compat).
      - ./.coderaft-age.key:/keys/age.key:ro
      # Vault mTLS client cert for dashboard-api (B12: correct filenames)
      - ./vault-tls/client-ca.crt:/vault-tls/client-ca.crt:ro
      - ./vault-tls/dashboard-api-client.crt:/vault-tls/dashboard-api-client.crt:ro
      - ./vault-tls/dashboard-api-client.key:/vault-tls/dashboard-api-client.key:ro
      # Security hardening (2026-07-31) — PowerShell parity with install.sh:
      # blank out the redundant vault-keys/vault-tls/.coderaft-age.key
      # exposure inside the broad `.:/host-compose` bind (dashboard-api's own
      # code never reads these THROUGH /host-compose — confirmed via grep of
      # server.js — it uses the narrow RO mounts above instead). Docker
      # Desktop on Windows runs the Linux daemon in a VM, so `/dev/null` bind
      # + `tmpfs:` over a directory behave identically to Linux/macOS here —
      # same mitigation verified experimentally for install.sh in an isolated
      # throwaway compose project (2026-07-31); no Windows-specific caveat
      # found, though not re-verified on an actual Windows host from this Mac.
      - /dev/null:/host-compose/.coderaft-age.key
    # Task #148 Phase 3 (banking-grade runtime exposure reduction, PowerShell
    # parity with install.sh commit 04b2c14): the *working* .env (resolved
    # secret VALUES, passed to `docker compose --env-file`) is written here
    # instead of the persistent bind-mounted /host-compose (the `.:/host-compose`
    # volume above). tmpfs is private to THIS container — wiped on every
    # restart/recreate — and does NOT need to be host-daemon-visible: the
    # `docker compose` CLI runs INSIDE this same container, and --env-file is
    # interpolated client-side by that CLI process, never resolved by the
    # daemon itself. Docker Desktop on Windows runs the Linux daemon in a VM,
    # so `tmpfs:` behaves identically to Linux/macOS here — same conclusion
    # reached experimentally for install.sh, no Windows-specific caveat found.
    tmpfs:
      - /run/coderaft-env:size=1m,mode=0700,uid=0
      - /host-compose/vault-keys:mode=0000,uid=0,size=1m
      - /host-compose/vault-tls:mode=0000,uid=0,size=1m
      # Phase 2 hardening (2026-07-31) — PowerShell parity with install.sh:
      #   - /tmp: sized for the two small zip-staging paths only (capture-host
      #     installer, GPO/Intune CA-push) — the restic disaster-recovery
      #     restore scratch dir and its cache dir were BOTH redirected to the
      #     disk-backed /data volume in dashboard-api/server.js and backup.js
      #     (see those files for the F-011/F-014 comments), so this tmpfs
      #     never needs to hold a multi-GB restore.
      #   - /etc/coderaft: legacy local age-key self-heal path
      #     (AGE_KEY_PATH) — confirmed on the macOS testing Mac this fails
      #     with `ENOENT ... mkdir '/etc/coderaft'` under read_only without
      #     this tmpfs, and was already ephemeral before this change anyway
      #     (no volume ever mounted it).
      - /tmp:size=512m
      - /etc/coderaft
    security_opt: [no-new-privileges:true]
    # F-011/F-014 (2026-07-31) — PowerShell parity with install.sh: verified
    # on the macOS testing Mac (same image Windows pulls) that a full boot
    # (real /data + /host-compose mounts, DASHBOARD_SECRET set) still reaches
    # `listening on port 3001` and GET /healthz → 200 with ALL caps dropped.
    cap_drop: [ALL]
    read_only: true
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:3001/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    mem_limit: 1g
    memswap_limit: 1g
    mem_reservation: 256m
    cpus: 2
    restart: unless-stopped

  # ── coderaft-vault ──────────────────────────────────────────────────────────
  # Centralised secret store. All products read/write through it via mTLS.
  # Port 8200 is internal-only (coderaft-vault-net). No external exposure.
  coderaft-vault:
    image: ghcr.io/liamj74/coderaft-vault:latest
    # B8 fix: run as root so container can write /data SQLite and read 0600 .key files.
    # Security maintained via cap_drop:ALL + no-new-privileges.
    #
    # F-004 re-verified (2026-07-31) — PowerShell parity with install.sh: the
    # Dockerfile's final stage already defaults to non-root
    # (distroless/static-debian12:nonroot, USER nonroot:nonroot); this
    # `user: "0:0"` compose override is what forces it back to root, and
    # that's deliberate. `.\vault-keys`/`.\vault-tls` are host files whose
    # Windows ACLs are set by THIS installer's own invoking user (not
    # necessarily mappable to uid 65532 inside the Linux VM Docker Desktop
    # runs) — same host-permission-vs-container-uid mismatch as on Linux/
    # macOS, see install.sh for the full reasoning. Left unchanged.
    user: "0:0"
    networks:
      - coderaft-vault-net
    volumes:
      - vault_data:/data
      - ./vault-keys:/keys:ro
      - ./vault-tls:/tls:ro
      - ./vault-config:/etc/coderaft-vault:ro
    healthcheck:
      test: ["CMD", "/coderaft-vault", "-health-check"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
    restart: unless-stopped

  # ── coderaft-cve-proxy ───────────────────────────────────────────────────
  # Internal sidecar in front of the shared coderaft-cve-engine
  # (cve.coderaft.io): holds the ONE bearer key for this deployment (read
  # from vault at boot) and forwards CVE/KEV/EPSS/MSRC lookups from any
  # product on coderaft-backend. No host port published.
  coderaft-cve-proxy:
    image: ghcr.io/liamj74/coderaft-cve-proxy:latest
    networks:
      - coderaft-vault-net
      - coderaft-backend
      - coderaft-frontend
    depends_on:
      coderaft-vault: { condition: service_started }
    environment:
      - CODERAFT_VAULT_URL=https://coderaft-vault:8200
      - CODERAFT_VAULT_CA=/vault-tls/client-ca.crt
      - CODERAFT_VAULT_CLIENT_CERT=/vault-tls/cve-proxy-client.crt
      - CODERAFT_VAULT_CLIENT_KEY=/vault-tls/cve-proxy-client.key
      # ACCEPTED RESIDUAL RISK (2026-07-31) — see install.sh for the full
      # rationale: coderaft-cve-proxy's source isn't in this monorepo (no
      # code we can extend) and it's a distroless static image (no shell to
      # wrap either). Every other secret in this deployment was migrated to
      # a Docker `secrets:` file; this one deliberately could not be.
      - XPRODUCT_INTERNAL_TOKEN=${XPRODUCT_INTERNAL_TOKEN}
    volumes:
      - ./vault-tls/client-ca.crt:/vault-tls/client-ca.crt:ro
      - ./vault-tls/cve-proxy-client.crt:/vault-tls/cve-proxy-client.crt:ro
      - ./vault-tls/cve-proxy-client.key:/vault-tls/cve-proxy-client.key:ro
    healthcheck:
      test: ["CMD", "/coderaft-cve-proxy", "-healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 3
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: coderaft
      # Task #148 Phase 3 (PowerShell parity with install.sh commit 04b2c14):
      # migrated to Docker's native `secrets:` — the official postgres image
      # already supports POSTGRES_PASSWORD_FILE, so the resolved value no
      # longer appears in `docker inspect`/Config.Env. The file is
      # materialized by install.ps1 (first boot, Write-PostgresSecretFile)
      # and by dashboard-api's generateOverrideToDir() (every subsequent
      # regen) at ./secrets/postgres_password — see the `secrets:` top-level
      # block below.
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      POSTGRES_DB: coderaft
      POSTGRES_INITDB_ARGS: "--data-checksums"
    secrets:
      - postgres_password
    # F-025 (2026-07-31) — PowerShell parity with install.sh: scram-sha-256
    # only, restricted to the pinned coderaft-backend subnet
    # (172.28.42.0/24 — see that network's `ipam:` block below; the two MUST
    # stay in sync). Verified in a throwaway compose project on the macOS
    # testing Mac (same Docker Desktop engine Windows hosts use): a peer on
    # the pinned subnet connects fine, a peer on a different docker network
    # gets a hard `pg_hba.conf rejects connection ... no encryption`.
    command:
      - postgres
      - -c
      - hba_file=/etc/postgresql/pg_hba.conf
      - -c
      - password_encryption=scram-sha-256
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./postgres/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
      # init-db.sql is intentionally NOT bind-mounted — when the
      # dashboard-api spawns docker-compose from inside a Linux container
      # against a Windows host, the resolved Windows path contains a
      # drive-letter colon that the daemon rejects ("too many colons").
      # The script was a no-op anyway (just a comment); product databases
      # are created on demand by the dashboard.
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coderaft"]
      interval: 5s
      timeout: 5s
      retries: 5
    # B-PRODUCT-DB-NET (2026-06-23): products (entraguard, ravenscan, redfox)
    # are added dynamically by dashboard-api and attached to coderaft-backend.
    # Without postgres also being on that network, every product's first DNS
    # lookup of "postgres" returns ENOENT and alembic migrations crash with
    # "Name or service not known". Observed live on Windows host 2026-06-23.
    networks: [coderaft-backend]
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    mem_limit: 1g
    memswap_limit: 1g
    mem_reservation: 256m
    cpus: 2
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    # Task #219 (2026-07-31, PowerShell parity — this whole service was OUT
    # OF SYNC with install.sh before this pass: still the plaintext
    # `--requirepass ${REDIS_PASSWORD}` form, visible in full via
    # `docker inspect`'s Config.Cmd on Windows installs). Read the password
    # from the mounted secrets file via a shell command override instead —
    # `user: "999:1000"` pins the container to the image's own unprivileged
    # `redis` account directly, since the stock entrypoint only auto-drops
    # root to that user for its OWN default `redis-server ...` CMD path and
    # skips that step for any other command (this `sh -c` override included),
    # which would otherwise silently run as root.
    user: "999:1000"
    command: ["sh", "-c", "redis-server --requirepass \"$(cat /run/secrets/redis_password)\" --maxmemory 128mb"]
    healthcheck:
      test: ["CMD-SHELL", "redis-cli --no-auth-warning -a \"$(cat /run/secrets/redis_password)\" ping"]
      interval: 5s
      timeout: 5s
      retries: 5
    secrets:
      - redis_password
    # B-PRODUCT-DB-NET: same reason as postgres above — product workers also
    # connect to redis://redis:6379 and must resolve the hostname.
    networks: [coderaft-backend]
    # F-011/F-014 (2026-07-31) — PowerShell parity with install.sh: verified
    # PING/SET/BGSAVE all still work with ALL caps dropped + read_only root
    # + no extra tmpfs — redis:7-alpine's own Dockerfile declares
    # `VOLUME /data`, so Docker always gives it a writable volume regardless
    # of the read_only root fs (what BGSAVE's periodic RDB snapshot uses).
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    read_only: true
    mem_limit: 256m
    memswap_limit: 256m
    mem_reservation: 64m
    cpus: 1
    restart: unless-stopped

networks:
  # Internal network for vault <-> product communication. No external port.
  coderaft-vault-net:
    internal: true
  # F-003 (2026-06-21): private network for the docker-socket-proxy. Only
  # dashboard-api joins it — external access to the daemon stays impossible.
  docker-proxy-net:
    internal: true
  # B-PRODUCT-DB-NET: backend network shared by data services (postgres,
  # redis, neo4j) and the dynamically-deployed products. Declared here so
  # the install.ps1 / install.sh templates can put data services on it
  # without dashboard-api having to compose them.
  # F-025 (2026-07-31) — PowerShell parity with install.sh: subnet PINNED
  # (not left to Docker's auto-allocation) so postgres/pg_hba.conf below can
  # hard-code the exact CIDR it trusts. MUST match install.sh's pinned value
  # exactly — both installers can target the SAME running stack over its
  # lifetime (e.g. an operator switching hosts), and a mismatched subnet
  # here would either lock every product out of Postgres or silently accept
  # a wider range than intended.
  coderaft-backend:
    ipam:
      config:
        - subnet: 172.28.42.0/24
  # B-DASHBOARD-NET: frontend network where the dashboard nginx and the
  # product HTTP listeners (entraguard-api, ravenscan, redfox-api) meet.
  # The dashboard joins it so its proxy can dial /api/<product>/* targets.
  coderaft-frontend: {}

volumes:
  postgres_data:
  dashboard_data:
  caddy_data:
  caddy_config:
  vault_data:
  # F-014 (2026-07-31) — PowerShell parity with install.sh: named volume
  # (not tmpfs) so docker-socket-proxy's baked-in haproxy.cfg.template
  # survives under read_only:true — see that service's `volumes:` comment.
  docker_proxy_haproxy_cfg:

# Task #148 Phase 3 (PowerShell parity with install.sh commit 04b2c14):
# postgres's password, Docker-native file-based secret. Must be a real path
# resolvable by the Docker DAEMON itself (unlike .env's --env-file, this is a
# literal bind-mount source, not client-side interpolation) —
# ./secrets/postgres_password, relative to this file's directory (=
# --project-directory = HOST_PROJECT_DIR). Written by install.ps1 on first
# boot and kept in sync by dashboard-api's generateOverrideToDir().
secrets:
  postgres_password:
    file: ./secrets/postgres_password
  # Task #219 (2026-07-31) — PowerShell parity with install.sh: same idea,
  # redis. This entry was MISSING entirely before this pass (install.ps1's
  # redis service still used the plaintext `${REDIS_PASSWORD}` form) — see
  # Write-RedisSecretFile above and the redis service's `secrets:`/`user:`/
  # `command:` above.
  redis_password:
    file: ./secrets/redis_password
'@
[System.IO.File]::WriteAllText("$(Get-Location)\docker-compose.yml", $Compose, [System.Text.UTF8Encoding]::new($false))

# ── postgres\pg_hba.conf (F-025, 2026-07-31) — PowerShell parity with install.sh
# scram-sha-256-only auth, restricted to the pinned coderaft-backend subnet
# (172.28.42.0/24 — MUST match the `coderaft-backend` network's `ipam:`
# block in $Compose above; the two are hard-coded independently, same as
# install.sh, since there is no templating step between them here either).
# Idempotent — only written if missing, so an operator's manual edits
# survive update.ps1 re-runs.
New-Item -ItemType Directory -Force -Path "postgres" | Out-Null
if (-not (Test-Path "postgres\pg_hba.conf")) {
    $PgHba = @'
# Coderaft — managed by deploy/install.ps1 (F-025). scram-sha-256 only.
# TYPE    DATABASE  USER  ADDRESS           METHOD

# Unix socket (inside the postgres container itself, e.g. an operator
# `docker compose exec postgres psql`).
local     all       all                     scram-sha-256

# coderaft-backend Docker network only — every consumer (dashboard-api,
# entraguard-api/worker/beat, ravenscan, redfox-api/gateway, falconone-*)
# joins this network; nothing outside it can reach postgres:5432 at all
# (no host port is published), so this is defense-in-depth on top of that
# network-level isolation, not the only control.
host      all       all   172.28.42.0/24    scram-sha-256

# Default deny — anything that isn't the exact subnet above (e.g. a stray
# container mistakenly joined to more than one network) is rejected here,
# not silently allowed by falling through to a permissive default.
host      all       all   0.0.0.0/0         reject
host      all       all   ::/0              reject
'@
    [System.IO.File]::WriteAllText("$(Get-Location)\postgres\pg_hba.conf", $PgHba, [System.Text.UTF8Encoding]::new($false))
}

# ── Caddyfile (env-templated TLS: internal CA / wildcard / ACME) ─────────────
# TLS mode is driven by env placeholders resolved at Caddy start:
#   CODERAFT_TLS_SITES   site list (apex only in ACME mode)
#   CADDY_TLS_MODE_ARGS  "internal" | "/certs/wildcard.crt /certs/wildcard.key"
#                        | "<acme-contact-email>"
# dashboard-api (Setup Wizard → TLS step) updates .env and recreates caddy.
$Caddyfile = @'
{
    # Admin API stays off (security). auto_https stays ON: Caddy manages the
    # certificate for the configured sites (internal CA by default).
    admin off
    servers {
        # Trust X-Forwarded-* from private-range proxies (Exposure step:
        # "external reverse proxy" mode).
        trusted_proxies static private_ranges
    }
}

# F-007 (2026-07-31): baseline security headers for every site block.
#
# F-036 (2026-07-31) evaluated and closed WITHOUT a code change to the CSP
# below — investigated live in a throwaway compose (caddy:2-alpine is
# actually v2.11.4; verified against caddyserver/caddy's tplcontext.go), not
# just the indicative snippet in REMEDIATION-PROMPT-2026-06-20.md:
#   - Caddy has NO built-in nonce template function (checked the real
#     http.handlers.templates function list: include/readFile/import/
#     httpInclude/stripHTML/markdown/env/placeholder/fileExists/httpError/
#     humanize/maybe/pathEscape — no `nonce`). A dynamic per-request nonce
#     would need a custom xcaddy build with a third-party plugin — real
#     ongoing maintenance cost for what `dashboard` is: a pure static Vite
#     SPA served by nginx (no per-request HTML generation at all — see the
#     comment on the `dashboard` service below), so there's no natural place
#     to even mint/thread a nonce server-side.
#   - Even if we had nonces, they only cover <script>/<style> ELEMENTS —
#     never a `style=""` ATTRIBUTE. That's the actual gap here: bundled
#     @xterm/xterm (RedFox SSH/RDP terminal sessions) calls
#     `element.setAttribute("style", ...)` for cell/selection highlighting,
#     confirmed present in the shipped bundle (grep dist/assets/*.js for
#     `_addStyle`/`setAttribute("style"`). Per the CSP spec (confirmed via
#     MDN), that call is blocked by style-src unless 'unsafe-inline' is
#     present — no nonce or hash can except a dynamically-set attribute.
#     Dropping 'unsafe-inline' from style-src would silently break every
#     RedFox terminal session. style-src is left as-is.
#   - script-src already has NO 'unsafe-inline' (shipped tonight in F-007)
#     and needed no change — but verifying it live (see "Vérification" in
#     the F-036 task) surfaced a real regression: apps/shell/index.html had
#     an inline <script> (dark/light theme pre-paint init) with no
#     nonce/hash, so Chrome was silently blocking it
#     ("script-src 'self'" refuses inline execution) — the pre-paint theme
#     class was never applied. Fixed by externalizing it to
#     apps/shell/public/theme-init.js (same-origin external file, no CSP
#     exception needed). Confirmed fixed: document.documentElement.className
#     was empty before, "light"/"dark" after, in the same throwaway compose.
#   - Separately discovered (NOT fixed here, flagged for its own ticket):
#     FalconOne Remote Assist's protobufjs Root (`hbb.RendezvousMessage` /
#     `hbb.NatType`, the RustDesk-compatible wire protocol, #139) builds its
#     message constructors via runtime `new Function(...)` codegen at module
#     load — this throws
#     "EvalError: ... 'unsafe-eval' is not an allowed source" under the
#     current script-src, every page load, independent of any user action.
#     This looks like a live break of Remote Assist signal/relay encoding
#     introduced by tonight's F-007 CSP. Needs either protobufjs static
#     codegen (`pbjs --target static-module`, no runtime eval) or a scoped
#     fix — NOT an "add unsafe-eval" fix, that would undo the hardening.
(coderaft_security) {
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "DENY"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
        Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'"
        Cross-Origin-Opener-Policy "same-origin"
        Cross-Origin-Resource-Policy "same-origin"
        -Server
        -X-Powered-By
    }
}

# Platform sites. TLS mode injected from .env by the Setup Wizard.
{$CODERAFT_TLS_SITES:coderaft.local, *.coderaft.local} {
    import coderaft_security
    tls {$CADDY_TLS_MODE_ARGS:internal}
    reverse_proxy dashboard:3000 {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
    }
}

# HTTP → HTTPS redirect for the platform hostnames
http://{$CODERAFT_HOSTNAME:coderaft.local}, http://*.{$CODERAFT_HOSTNAME:coderaft.local} {
    redir https://{host}{uri} permanent
}

# Fallback: anything else (IP access, localhost) stays plain HTTP.
:80 {
    import coderaft_security
    reverse_proxy dashboard:3000
}
'@
# Migration 2026-07: mkcert removed. A legacy Caddyfile referencing
# coderaft.local.pem is backed up and regenerated.
$CaddyfilePath = "$(Get-Location)\Caddyfile"
if ((Test-Path $CaddyfilePath) -and (Select-String -Path $CaddyfilePath -Pattern "coderaft\.local\.pem" -Quiet)) {
    Write-Host "  Migrating legacy mkcert Caddyfile -> Caddy internal CA (backup: Caddyfile.mkcert.bak)"
    Move-Item -Force $CaddyfilePath "$(Get-Location)\Caddyfile.mkcert.bak"
}
if (-not (Test-Path $CaddyfilePath)) {
    [System.IO.File]::WriteAllText($CaddyfilePath, $Caddyfile, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✓ Caddyfile generated (TLS: Caddy internal CA)"
}

# ── Trust the Caddy internal CA (replaces mkcert, 2026-07) ───────────────────
# Caddy (`tls internal`) generates a root CA on first start, stored in the
# caddy_data volume — NEVER delete that volume between installs, or every
# endpoint/agent that trusted the old CA breaks. We export root.crt and
# import it into the Windows LocalMachine\Root store (single UAC prompt when
# not elevated). Failure is non-fatal: the dashboard also serves the CA and
# a GPO push package (Setup → TLS).
function Install-CaddyRootCA {
    if ($env:CODERAFT_SKIP_HTTPS -eq "1") {
        Write-Host "  CODERAFT_SKIP_HTTPS=1 — skipping CA trust setup"
        return $false
    }

    # B20-style native-command handling: Start-Process with split
    # stdout/stderr files (PS 5.1 surfaces native stderr as red
    # NativeCommandError otherwise). Exit code via -PassThru.
    function Invoke-DockerExitCode {
        param([string[]]$Arguments)
        $out = Join-Path $env:TEMP "coderaft-ca-out-$(Get-Random).log"
        $err = Join-Path $env:TEMP "coderaft-ca-err-$(Get-Random).log"
        $proc = Start-Process -FilePath "docker" -ArgumentList $Arguments `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $out `
            -RedirectStandardError $err `
            -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.WaitForExit(60000)) {   # 60s
            Write-Host "  ⚠  Docker command timed out after 60s: docker $($Arguments -join ' ')" -ForegroundColor Yellow
            try { $proc.Kill() } catch {}
        }
        Remove-Item -Path $out,$err -ErrorAction SilentlyContinue
        if ($proc) { return $proc.ExitCode } else { return 1 }
    }

    $caContainerPath = "/data/caddy/pki/authorities/local/root.crt"
    Write-Host "  Waiting for Caddy to generate its internal CA (max 30s)…"
    $caReady = $false
    for ($i = 0; $i -lt 15; $i++) {
        $code = Invoke-DockerExitCode -Arguments (@("compose") + $ComposeEnvArgs + @("exec","-T","caddy","test","-f",$caContainerPath))
        if ($code -eq 0) { $caReady = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $caReady) {
        Write-Host "  ⚠ Caddy CA not found after 30s — browsers will warn on https://coderaft.local." -ForegroundColor Yellow
        Write-Host "    Download it later from the dashboard: Setup → TLS → Download CA." -ForegroundColor Yellow
        return $false
    }

    $caLocal = Join-Path (Get-Location) "caddy-root.crt"
    $cpCode = Invoke-DockerExitCode -Arguments (@("compose") + $ComposeEnvArgs + @("cp","caddy:$caContainerPath",$caLocal))
    if ($cpCode -ne 0 -or -not (Test-Path $caLocal)) {
        Write-Host "  ⚠ Could not export the Caddy root CA — skipping trust install." -ForegroundColor Yellow
        return $false
    }

    # #137 fix: also expose the CA at ./certs/server-ca.pem — mounted into
    # entraguard-api (via PRODUCT_SERVICES) so WolfGuard's /register
    # response returns THIS CA (the one Caddy serves) to endpoint agents
    # instead of the WolfGuard Endpoint CA (used server-side only for
    # signing client certs). Without this the agent's TLS handshake to
    # coderaft.local fails with `x509: certificate signed by unknown
    # authority` on every report.
    try {
        $certsDir = Join-Path (Get-Location) "certs"
        New-Item -ItemType Directory -Force -Path $certsDir | Out-Null
        Copy-Item -LiteralPath $caLocal -Destination (Join-Path $certsDir "server-ca.pem") -Force
        Write-Host "  ✓ Server CA exposed at certs\server-ca.pem for entraguard-api"
    } catch {
        Write-Host "  ⚠ Could not copy CA to certs\server-ca.pem: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $isAdmin = $false
    try {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $isAdmin = $false }

    Write-Host "  Importing the Coderaft root CA into LocalMachine\Root (may prompt for elevation)…"
    if ($isAdmin) {
        try {
            Import-Certificate -FilePath $caLocal -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction Stop | Out-Null
            Write-Host "  ✓ CA trusted (LocalMachine\Root)" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "  ⚠ Import-Certificate failed: $($_.Exception.Message)" -ForegroundColor Yellow
            return $false
        }
    } else {
        # Single UAC prompt — same pattern as the old mkcert -install elevation.
        try {
            $importCmd = "Import-Certificate -FilePath '$caLocal' -CertStoreLocation Cert:\LocalMachine\Root"
            $proc = Start-Process -FilePath "powershell" `
                -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-Command",$importCmd) `
                -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            if ($proc.ExitCode -eq 0) {
                Write-Host "  ✓ CA trusted (LocalMachine\Root)" -ForegroundColor Green
                return $true
            }
            Write-Host "  ⚠ CA import exited with code $($proc.ExitCode) — trust caddy-root.crt manually." -ForegroundColor Yellow
        } catch {
            Write-Host "  ⚠ CA import cancelled or failed — trust caddy-root.crt manually:" -ForegroundColor Yellow
            Write-Host "      Import-Certificate -FilePath caddy-root.crt -CertStoreLocation Cert:\LocalMachine\Root" -ForegroundColor Yellow
        }
        return $false
    }
}

# ── hosts file entries ──────────────────────────────────────────────────────
function Ensure-HostsEntry {
    $hostsFile = "$env:WINDIR\System32\drivers\etc\hosts"
    $marker    = "# coderaft-platform"
    $entry     = "127.0.0.1 coderaft.local entraguard.coderaft.local ravenscan.coderaft.local redfox.coderaft.local $marker"

    if (Test-Path $hostsFile) {
        $existing = Get-Content $hostsFile -ErrorAction SilentlyContinue
        if ($existing -match "coderaft\.local") {
            Write-Host "  ✓ hosts file already contains coderaft.local"
            return
        }
    }

    if ($env:CODERAFT_SKIP_HOSTS -eq "1") {
        Write-Host "  CODERAFT_SKIP_HOSTS=1 — skipping hosts update"
        return
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        try {
            Add-Content -Path $hostsFile -Value $entry -ErrorAction Stop
            Write-Host "  ✓ hosts file updated"
        } catch {
            Write-Host "  ⚠ Could not update hosts file: $_" -ForegroundColor Yellow
            Write-Host "    Add manually to ${hostsFile}:"
            Write-Host "      $entry"
        }
    } else {
        Write-Host "  ⚠ Not running as Administrator — cannot update hosts file." -ForegroundColor Yellow
        Write-Host "    Add the following line to ${hostsFile} (run as admin):"
        Write-Host "      $entry"
    }
}

# Hosts entry no longer depends on mkcert certs — coderaft.local must resolve
# for the default (internal CA) TLS mode to be reachable by name.
Ensure-HostsEntry

# Helper scripts
# Task #150: both env files are always passed explicitly — install-config.env
# (plaintext config) + .env (secrets) — so compose interpolation never
# silently loses either.
Set-Content -Path 'start.ps1' -Value @'
Write-Host "Starting CodeRaft..."
docker compose --env-file install-config.env --env-file .env up -d
$Url = "http://localhost:3000"
if ((Get-Content "$env:WINDIR\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue) -match "coderaft\.local") {
    $Url = "https://coderaft.local"
}
Write-Host "  Dashboard: $Url"
Start-Process $Url
'@ -Encoding UTF8

Set-Content -Path 'stop.ps1' -Value @'
Write-Host "Stopping CodeRaft..."
docker compose --env-file install-config.env --env-file .env down
Write-Host "Done."
'@ -Encoding UTF8

try {
    $u = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/update.ps1" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    [System.IO.File]::WriteAllText("$PWD\update.ps1", $u.Content, [System.Text.Encoding]::UTF8)
} catch {
    Set-Content -Path 'update.ps1' -Value @'
Write-Host "Updating CodeRaft..."
docker compose --env-file install-config.env --env-file .env pull
docker compose --env-file install-config.env --env-file .env up -d --force-recreate --remove-orphans
# Reconciliation pass (mirrors the fix in the real update.ps1, B-OVERRIDE-RACE
# 2026-08-07): dashboard-api regenerates docker-compose.override.yml on its
# own boot as a self-heal for stale product lists, but that happens AFTER
# the 'up' above already computed its plan from the OLD file, so
# --remove-orphans can silently drop product containers with nothing left
# to bring them back. Wait for dashboard-api's own confirmation log line,
# then re-run 'up -d' (no --force-recreate) so anything the corrected
# override adds gets created without needlessly recreating what already
# runs.
$refreshed = $false
for ($i = 0; $i -lt 30; $i++) {
    $logs = & docker compose --env-file install-config.env --env-file .env logs dashboard-api 2>&1 | Out-String
    if ($logs -match "override.yml refreshed for products:") { $refreshed = $true; break }
    Start-Sleep -Seconds 2
}
docker compose --env-file install-config.env --env-file .env up -d
Write-Host "  Updated! Dashboard: http://localhost:3000"
'@ -Encoding UTF8
}

try {
    $r = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/rollback.ps1" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    [System.IO.File]::WriteAllText("$PWD\rollback.ps1", $r.Content, [System.Text.Encoding]::UTF8)
} catch {
    Set-Content -Path 'rollback.ps1' -Value @'
Write-Host "rollback.ps1 placeholder — fetch the real one from https://install.coderaft.io/rollback.ps1"
Write-Host "or run: irm https://install.coderaft.io/rollback.ps1 -OutFile rollback.ps1"
exit 1
'@ -Encoding UTF8
}

# ── Vault seal-state check (fresh install) ───────────────────────────────────
# B6/B7 fix: vault image is distroless — no shell, no wget.
# NEVER `docker compose exec coderaft-vault sh`. Use curlimages/curl sidecar.
#
# AUDIT-SECU-2026-08-04 (Vault H1): coderaft-vault no longer auto-unseals and
# no longer treats vault-keys/age.key as a submittable "share" — unsealing
# now requires a REAL Shamir ceremony (default 3-of-5 shares, generated by
# the vault itself at POST /v1/init and never persisted anywhere), which by
# design NO unattended script can complete on its own. This function
# (formerly Invoke-VaultUnsealFresh) therefore no longer attempts to unseal
# the vault — it only polls for reachability and prints the operator's next
# steps. A sealed vault after install is EXPECTED, not a failure.
#
# RESOLVED (2026-08-04, deploy-scripts-no-autounseal follow-up — see the
# matching comment in deploy/install.sh's vault_check_seal_state): the fake
# recovery-phrase banner this comment used to describe has been removed
# from Invoke-VaultBootstrap's Step 2. vault-keys\age.key is still generated
# there purely as an idempotency marker; it is never read by the vault for
# anything. This function remains the single accurate source of ceremony
# instructions, printed once the vault container is actually reachable.
# Auto-running POST /v1/init inline during install was considered and
# deliberately NOT done — a vault can only ever be initialized once, and
# doing so silently with no operator confirmation of who is present to
# receive which share defeats the point of a multi-operator ceremony. Left
# as a possible future UX improvement, not a bug.
function Invoke-VaultCheckSealState {
    # B-PATH (2026-06-09): during the install run, the CWD can drift
    # (Start-Process child processes, exceptions from -Verb RunAs that
    # restore an unexpected location, etc.) — force-restore CWD to the
    # install dir before resolving any relative paths below.
    if ($script:AbsoluteInstallDir -and (Test-Path $script:AbsoluteInstallDir)) {
        Set-Location -LiteralPath $script:AbsoluteInstallDir
    }

    # Detect compose project name (determines Docker network for sidecar).
    # B20-inspect (2026-06-09): inline `--format '{{ ... "com.docker..." ... }}'`
    # gets mangled by PowerShell native-command argument passing — the double
    # quotes inside the single-quoted string are stripped before reaching
    # docker, leaving `com.docker.compose.project` as a bare token and
    # docker's Go template engine then errors with `function "com" not
    # defined`. Storing the format string in a variable + invoking via
    # Start-Process preserves the quotes and silences any stderr noise.
    $inspectFormat = '{{ index .Config.Labels "com.docker.compose.project" }}'
    $inspectStdout = Join-Path $env:TEMP "coderaft-inspect-out-$(Get-Random).log"
    $inspectStderr = Join-Path $env:TEMP "coderaft-inspect-err-$(Get-Random).log"
    $inspectProc = Start-Process -FilePath "docker" -ArgumentList @(
        "inspect", "coderaft-coderaft-vault-1", "--format", $inspectFormat
    ) -NoNewWindow -PassThru `
        -RedirectStandardOutput $inspectStdout `
        -RedirectStandardError $inspectStderr `
        -ErrorAction SilentlyContinue
    if ($inspectProc -and -not $inspectProc.WaitForExit(60000)) {   # 60s
        Write-Host "  ⚠  Docker command timed out after 60s: docker inspect coderaft-coderaft-vault-1" -ForegroundColor Yellow
        try { $inspectProc.Kill() } catch {}
    }
    $vaultProject = ((Get-Content $inspectStdout -ErrorAction SilentlyContinue) -join "").Trim()
    Remove-Item -Path $inspectStdout,$inspectStderr -ErrorAction SilentlyContinue
    if (-not $vaultProject) { $vaultProject = "coderaft" }
    $vaultNetwork = "${vaultProject}_coderaft-vault-net"
    $absTlsDir = (Resolve-Path -LiteralPath "vault-tls").Path

    # Pre-pull curlimages/curl silently (avoids pull progress on stderr
    # surfacing as NativeCommandError when the curl sidecar is first used).
    $curlPullOut = Join-Path $env:TEMP "coderaft-curl-pull-out-$(Get-Random).log"
    $curlPullErr = Join-Path $env:TEMP "coderaft-curl-pull-err-$(Get-Random).log"
    Start-Process -FilePath "docker" -ArgumentList @("pull","curlimages/curl:latest") `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $curlPullOut `
        -RedirectStandardError $curlPullErr `
        -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path $curlPullOut,$curlPullErr -ErrorAction SilentlyContinue

    function Invoke-VaultCurlFresh {
        param([string]$Method, [string]$Path, [string]$JsonBody = "")
        # B20-vaultcurl (2026-06-09): the previous `& docker @args 2>&1`
        # surfaced docker stderr as NativeCommandError in PowerShell 5.1.
        # Use Start-Process with split stdout/stderr files.
        #
        # B-UNSEAL-BODY (2026-06-09): passing the JSON body inline via
        # `-d $JsonBody` argument got mangled by the PS → docker.exe → curl
        # arg chain — the {, ", } in the JSON were either stripped or
        # double-escaped, and vault replied {"error":"invalid request body"}.
        # Write the body to a temp file and feed it via stdin (-d @- in curl),
        # routed through Start-Process -RedirectStandardInput. This is
        # quote-safe for any JSON payload.
        $dockerArgs = @(
            "run", "--rm"
        )
        if ($JsonBody) { $dockerArgs += @("-i") }  # need stdin for body
        $dockerArgs += @(
            "--user", "0:0",
            "--network", $vaultNetwork,
            "-v", "${absTlsDir}:/tls:ro",
            "curlimages/curl:latest",
            "--cert", "/tls/dashboard-api-client.crt",
            "--key",  "/tls/dashboard-api-client.key",
            "--cacert", "/tls/client-ca.crt",
            "-sS", "-X", $Method,
            "https://coderaft-vault:8200$Path"
        )
        $bodyFile = $null
        if ($JsonBody) {
            $bodyFile = Join-Path $env:TEMP "coderaft-vault-body-$(Get-Random).json"
            [System.IO.File]::WriteAllText($bodyFile, $JsonBody, [System.Text.UTF8Encoding]::new($false))
            $dockerArgs += @("-H", "Content-Type: application/json", "--data-binary", "@-")
        }

        $curlStdout = Join-Path $env:TEMP "coderaft-vault-curl-out-$(Get-Random).log"
        $curlStderr = Join-Path $env:TEMP "coderaft-vault-curl-err-$(Get-Random).log"
        $spArgs = @{
            FilePath               = "docker"
            ArgumentList           = $dockerArgs
            NoNewWindow            = $true
            Wait                   = $true
            RedirectStandardOutput = $curlStdout
            RedirectStandardError  = $curlStderr
            ErrorAction            = "SilentlyContinue"
        }
        if ($bodyFile) { $spArgs['RedirectStandardInput'] = $bodyFile }
        Start-Process @spArgs | Out-Null

        $body = ""
        if (Test-Path $curlStdout) {
            $body = ((Get-Content $curlStdout -ErrorAction SilentlyContinue) -join "")
        }
        Remove-Item -Path $curlStdout,$curlStderr -ErrorAction SilentlyContinue
        if ($bodyFile) { Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue }
        return $body
    }

    Write-Host "  Waiting for vault to be reachable..."
    $vaultReachable = $false
    $lastSealed = "true"
    for ($vi = 1; $vi -le 20; $vi++) {
        try {
            $health = Invoke-VaultCurlFresh -Method "GET" -Path "/v1/health"
            if ($health -match '"sealed":(true|false)') {
                $vaultReachable = $true
                $lastSealed = $Matches[1]
                break
            }
        } catch { }
        if ($vi % 3 -eq 0) { Write-Host "    ... still waiting (attempt $vi/20)" }
        Start-Sleep -Seconds 3
    }

    if (-not $vaultReachable) {
        Write-Host "  ✗ coderaft-vault did not respond to TLS probes" -ForegroundColor Red
        return $false
    }

    if ($lastSealed -eq "false") {
        Write-Host "  ✓ coderaft-vault is already initialized and unsealed" -ForegroundColor Green
        return $true
    }

    Write-Host ""
    Write-Host "  ────────────────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host "  Vault is SEALED. This is expected — Coderaft Vault requires a" -ForegroundColor Yellow
    Write-Host "  real, human, multi-operator Shamir ceremony (default: 3 of 5" -ForegroundColor Yellow
    Write-Host "  shares) before it will hold or serve ANY secret. No script can" -ForegroundColor Yellow
    Write-Host "  complete this unattended, by design (AUDIT-SECU-2026-08-04)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  An operator must run, from this directory (PowerShell):"
    Write-Host ""
    Write-Host "    # 1) ONE TIME ONLY per vault (skip if already run before):"
    Write-Host "    docker run --rm --user 0:0 --network $vaultNetwork ``"
    Write-Host "      -v `"$absTlsDir`:/tls:ro`" curlimages/curl:latest ``"
    Write-Host "      --cert /tls/dashboard-api-client.crt --key /tls/dashboard-api-client.key ``"
    Write-Host "      --cacert /tls/client-ca.crt -sS -X POST https://coderaft-vault:8200/v1/init"
    Write-Host "    # -> WRITE DOWN the returned shares, one per operator, then:"
    Write-Host ""
    Write-Host "    # 2) EVERY time the vault starts sealed (every restart/reboot):"
    Write-Host "    docker run --rm --user 0:0 --network $vaultNetwork ``"
    Write-Host "      -v `"$absTlsDir`:/tls:ro`" curlimages/curl:latest ``"
    Write-Host "      --cert /tls/dashboard-api-client.crt --key /tls/dashboard-api-client.key ``"
    Write-Host "      --cacert /tls/client-ca.crt -sS -X POST https://coderaft-vault:8200/v1/unseal ``"
    Write-Host "      -H 'Content-Type: application/json' -d '{`"shares`":[`"<share1>`",`"<share2>`",`"<share3>`"]}'"
    Write-Host ""
    Write-Host "  Until this runs, every product shows `"vault unavailable`" — that"
    Write-Host "  is fail-closed behavior, not a crash."
    Write-Host "  ────────────────────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host ""
    return $false
}

# ── Vault bootstrap-secrets seeding (fresh install race fix, PowerShell parity) ──
# Task #218 (2026-07-31): this script generates POSTGRES_PASSWORD/
# REDIS_PASSWORD/DASHBOARD_SECRET/RAVENSCAN_CAPTURE_TOKEN above (either
# fresh, or preserved from a previous run) and secrets\postgres_password is
# what postgres's OWN initdb actually uses. Coderaft Vault, however, had no
# seed at all until now: dashboard-api's vaultEnsure() (generateOverrideToDir(),
# the Coderaft Vault client since #149) is the FIRST thing to ever write
# these keys into the vault, and it only runs later — at the first product
# deploy, well after this script has exited — on a truly fresh install.
# Finding the vault empty at that point, it happily mints its OWN independent
# random value instead of reusing what postgres/redis/the dashboard JWT
# signer were actually bootstrapped with. Confirmed experimentally 2026-07-31
# on macOS/bash (isolated test stack, distinct compose project, never the
# live "coderaft" stack) — same code path, same risk on Windows.
#
# Fix: install.ps1 becomes the FIRST writer. Called right after the vault is
# up and unsealed, BEFORE postgres (or any other service) starts.
#
# get-or-set semantics (never overwrite an existing vault value): mirrors
# vaultEnsure()'s own behavior. Idempotent and safe to run on every
# install.ps1 invocation, including a re-run against an EXISTING install
# where the operator may have already rotated one of these secrets via the
# dashboard (Coderaft Vault holds the rotated value; blindly overwriting it
# with the stale local .env copy would silently undo that rotation).
function Invoke-VaultSeedBootstrapSecrets {
    if ($script:AbsoluteInstallDir -and (Test-Path $script:AbsoluteInstallDir)) {
        Set-Location -LiteralPath $script:AbsoluteInstallDir
    }
    $vaultAgeKey = Join-Path (Get-Location) "vault-keys\age.key"
    if (-not (Test-Path $vaultAgeKey)) {
        Write-Host "  ✗ $vaultAgeKey not found — cannot seed vault" -ForegroundColor Red
        return $false
    }

    $inspectFormat = '{{ index .Config.Labels "com.docker.compose.project" }}'
    $inspectStdout = Join-Path $env:TEMP "coderaft-seed-inspect-out-$(Get-Random).log"
    $inspectStderr = Join-Path $env:TEMP "coderaft-seed-inspect-err-$(Get-Random).log"
    $inspectProc = Start-Process -FilePath "docker" -ArgumentList @(
        "inspect", "coderaft-coderaft-vault-1", "--format", $inspectFormat
    ) -NoNewWindow -PassThru `
        -RedirectStandardOutput $inspectStdout `
        -RedirectStandardError $inspectStderr `
        -ErrorAction SilentlyContinue
    if ($inspectProc -and -not $inspectProc.WaitForExit(60000)) {
        try { $inspectProc.Kill() } catch {}
    }
    $vaultProject = ((Get-Content $inspectStdout -ErrorAction SilentlyContinue) -join "").Trim()
    Remove-Item -Path $inspectStdout,$inspectStderr -ErrorAction SilentlyContinue
    if (-not $vaultProject) { $vaultProject = "coderaft" }
    $vaultNetwork = "${vaultProject}_coderaft-vault-net"
    $absTlsDir = (Resolve-Path -LiteralPath "vault-tls").Path

    function Invoke-VaultCurlSeed {
        param([string]$Method, [string]$Path, [string]$JsonBody = "")
        $dockerArgs = @("run", "--rm")
        if ($JsonBody) { $dockerArgs += @("-i") }
        $dockerArgs += @(
            "--user", "0:0",
            "--network", $vaultNetwork,
            "-v", "${absTlsDir}:/tls:ro",
            "curlimages/curl:latest",
            "--cert", "/tls/dashboard-api-client.crt",
            "--key",  "/tls/dashboard-api-client.key",
            "--cacert", "/tls/client-ca.crt",
            "-sS", "-X", $Method,
            "https://coderaft-vault:8200$Path"
        )
        $bodyFile = $null
        if ($JsonBody) {
            $bodyFile = Join-Path $env:TEMP "coderaft-vault-seed-body-$(Get-Random).json"
            [System.IO.File]::WriteAllText($bodyFile, $JsonBody, [System.Text.UTF8Encoding]::new($false))
            $dockerArgs += @("-H", "Content-Type: application/json", "--data-binary", "@-")
        }
        $curlStdout = Join-Path $env:TEMP "coderaft-vault-seed-out-$(Get-Random).log"
        $curlStderr = Join-Path $env:TEMP "coderaft-vault-seed-err-$(Get-Random).log"
        $spArgs = @{
            FilePath               = "docker"
            ArgumentList           = $dockerArgs
            NoNewWindow            = $true
            Wait                   = $true
            RedirectStandardOutput = $curlStdout
            RedirectStandardError  = $curlStderr
            ErrorAction            = "SilentlyContinue"
        }
        if ($bodyFile) { $spArgs['RedirectStandardInput'] = $bodyFile }
        Start-Process @spArgs | Out-Null
        $body = ""
        if (Test-Path $curlStdout) {
            $body = ((Get-Content $curlStdout -ErrorAction SilentlyContinue) -join "")
        }
        Remove-Item -Path $curlStdout,$curlStderr -ErrorAction SilentlyContinue
        if ($bodyFile) { Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue }
        return $body
    }

    $seedFailed = $false
    $pairs = @(
        @{ EnvKey = "POSTGRES_PASSWORD";        VaultKey = "postgres_password" },
        @{ EnvKey = "REDIS_PASSWORD";            VaultKey = "redis_password" },
        @{ EnvKey = "DASHBOARD_SECRET";          VaultKey = "dashboard_secret" },
        @{ EnvKey = "RAVENSCAN_CAPTURE_TOKEN";   VaultKey = "ravenscan_capture_token" }
    )
    foreach ($pair in $pairs) {
        $envKey = $pair.EnvKey
        $vaultKey = $pair.VaultKey
        $match = Select-String -Path '.env' -Pattern "^$envKey=(.+)$" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $match) { continue }
        $val = $match.Matches.Groups[1].Value
        $existing = Invoke-VaultCurlSeed -Method "POST" -Path "/v1/secret/get" -JsonBody "{`"name`":`"$vaultKey`"}"
        if ($existing -match '"value"\s*:') {
            Write-Host "  ✓ $vaultKey already present in Coderaft Vault (left untouched)" -ForegroundColor Green
            continue
        }
        $setBody = "{`"name`":`"$vaultKey`",`"value`":`"$val`"}"
        $resp = Invoke-VaultCurlSeed -Method "POST" -Path "/v1/secret/set" -JsonBody $setBody
        if ($resp -match '"ok"\s*:\s*true') {
            Write-Host "  ✓ Seeded $vaultKey in Coderaft Vault" -ForegroundColor Green
        } else {
            Write-Host "  ✗ Failed to seed $vaultKey in Coderaft Vault: $resp" -ForegroundColor Red
            $seedFailed = $true
        }
    }
    return -not $seedFailed
}

# ── Pull & Start ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  Pulling platform images..."
docker compose @ComposeEnvArgs pull
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  ✗ Image pull failed (exit $LASTEXITCODE). Aborting install." -ForegroundColor Red
    Write-Host "    Check Docker daemon, network connectivity, or GHCR auth." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "  Starting platform..."
# B9 fix: explicit stop+rm for vault container before up so fresh certs
# are picked up from bind mounts (--force-recreate alone can leave a
# Running container with stale certs in Docker Desktop memory).
# B20-compose (2026-06-09): `2>$null | Out-Null` does not suppress
# native-command stderr in PowerShell 5.1; docker emits "No stopped
# containers" on a fresh install and PS surfaces it as red
# NativeCommandError. Use Start-Process with split stdout/stderr files
# to discard the noise silently.
function Invoke-DockerSilent {
    param([string[]]$Arguments)
    $stdout = Join-Path $env:TEMP "coderaft-docker-stdout-$(Get-Random).log"
    $stderr = Join-Path $env:TEMP "coderaft-docker-stderr-$(Get-Random).log"
    Start-Process -FilePath "docker" -ArgumentList $Arguments `
        -NoNewWindow -Wait `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path $stdout,$stderr -ErrorAction SilentlyContinue
}
Invoke-DockerSilent -Arguments (@("compose") + $ComposeEnvArgs + @("stop","coderaft-vault"))
Invoke-DockerSilent -Arguments (@("compose") + $ComposeEnvArgs + @("rm","-f","coderaft-vault"))

# B-AGE-KEY-DIR (2026-07-16): the dashboard-api service bind-mounts
# `./.coderaft-age.key:/keys/age.key:ro`. If the host file does not
# exist when `docker compose up` runs, Docker silently creates a
# DIRECTORY at that host path and mounts it as `/keys/age.key` inside
# the container — dashboard-api then crash-loops with
# `age-keygen: /keys/age.key: is a directory`.
# Ensure the host path is a regular file BEFORE compose up. On a
# fresh install we have no encrypted `.env.enc` yet, so the key
# content is unused — an empty file is enough to prevent Docker from
# creating a directory. If a stale directory is left over from a
# failed previous install attempt, remove it first.
$AgeKeyHost = Join-Path (Get-Location) ".coderaft-age.key"
if (Test-Path $AgeKeyHost -PathType Container) {
    Remove-Item -LiteralPath $AgeKeyHost -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $AgeKeyHost -PathType Leaf)) {
    # Prefer the freshly-generated vault-keys\age.key so SOPS re-encrypt
    # (dashboard-api Settings → Secrets) works out of the box. Fallback
    # to an empty file — dashboard-api only reads the key when .env.enc
    # exists, and .env.enc is not part of a fresh install.
    #
    # B-AGE-ACL (2026-07-16): vault-keys\age.key gets its ACL locked
    # down to the user that created it (SetAccessRuleProtection($true,
    # $false) + a single Read rule for the current identity). If a
    # LATER install runs as a different Windows account — Administrator
    # via UAC elevation, another admin, or a different SamAccountName —
    # Copy-Item throws "Access to the path is denied" even though the
    # process is elevated (Windows ACLs beat token privileges until an
    # explicit takeown). Fall back to an empty file so the install
    # keeps going. The empty file is only unused on a fresh install
    # anyway (no .env.enc to decrypt).
    $VaultAgeKey = Join-Path (Get-Location) "vault-keys\age.key"
    $copied = $false
    if (Test-Path $VaultAgeKey -PathType Leaf) {
        try {
            Copy-Item -LiteralPath $VaultAgeKey -Destination $AgeKeyHost -Force -ErrorAction Stop
            $copied = $true
        } catch {
            Write-Host "  ⚠ Could not copy vault-keys\age.key into .coderaft-age.key ($($_.Exception.Message.Trim()))." -ForegroundColor Yellow
            Write-Host "    Falling back to an empty placeholder — SOPS re-encrypt from the dashboard will still work" -ForegroundColor Yellow
            Write-Host "    once you copy the age key manually. Fresh installs do not need it." -ForegroundColor Yellow
        }
    }
    if (-not $copied) {
        New-Item -Path $AgeKeyHost -ItemType File -Force | Out-Null
    }
}

# Task #218 (2026-07-31): start coderaft-vault ALONE first — it must be up,
# unsealed, AND seeded with the bootstrap secrets above (or already holding
# them, on a re-run) BEFORE postgres/redis/dashboard-api are created. See
# Invoke-VaultSeedBootstrapSecrets's header comment for the full race and its
# confirmed real-world impact (mirrors install.sh commit for task #218).
docker compose @ComposeEnvArgs up -d coderaft-vault
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  ✗ docker compose up coderaft-vault failed (exit $LASTEXITCODE). Aborting install." -ForegroundColor Red
    Write-Host "    Run 'docker compose logs coderaft-vault' to investigate." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "  Checking vault seal state..."
$vaultOk = Invoke-VaultCheckSealState
if (-not $vaultOk) {
    Write-Host "  ⚠ Vault is sealed — dashboard will show 'vault unavailable' until an" -ForegroundColor Yellow
    Write-Host "    operator completes the ceremony printed above."
}

Write-Host ""
Write-Host "  Seeding bootstrap secrets into Coderaft Vault..."
$seedOk = Invoke-VaultSeedBootstrapSecrets
if (-not $seedOk) {
    Write-Host "  ⚠ Could not seed one or more bootstrap secrets into Coderaft Vault." -ForegroundColor Yellow
    Write-Host "    dashboard-api will mint its own value(s) on first deploy, which"
    Write-Host "    may then MISMATCH what postgres/redis were actually initialized"
    Write-Host "    with. Re-run the installer once the vault is reachable, or seed"
    Write-Host "    manually — see docs/vault.md."
}

# B-OVERRIDE-RACE (install-time variant, found 2026-08-08): a
# docker-compose.override.yml left on disk from a prior install/dev run can
# predate the current dashboard-api's ${HOST_PROJECT_DIR} compose-variable
# convention for bind-mount sources -- older generations wrote the resolved
# (and here, empty-prefixed) host path literally, e.g. falconone-relay's
# signal-server key mount ending up as the bare
# `/certs/falconone-signal-server.key` instead of
# `${HOST_PROJECT_DIR}/certs/falconone-signal-server.key`. Docker Desktop
# then refuses that mount outright ("is not shared from the host and is not
# known to Docker"), and since `docker compose up -d` with no service filter
# computes its WHOLE plan from the override file as it sits on disk before
# any container starts, the single call aborts before dashboard-api -- the
# only thing that regenerates this file correctly on boot (server.js
# bootstrap(), logs "override.yml refreshed for products:") -- ever gets a
# chance to fix it. Same root cause update.ps1's B-OVERRIDE-RACE
# reconciliation pass already documents for the --remove-orphans case; here
# it manifests as a hard failure instead of silent orphan removal. Fix:
# bring up dashboard-api alone first (it only depends on services already
# started above), wait for its self-heal log line, THEN bring up everything
# else -- so the full plan is always computed from a freshly-regenerated,
# correct override file.
Write-Host ""
Write-Host "  Starting dashboard-api (regenerates docker-compose.override.yml)..."
docker compose @ComposeEnvArgs up -d dashboard-api
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  ✗ docker compose up dashboard-api failed (exit $LASTEXITCODE). Aborting install." -ForegroundColor Red
    Write-Host "    Run 'docker compose logs dashboard-api' to investigate." -ForegroundColor Yellow
    exit 1
}

$overrideRefreshTimeout = 60
$overrideRefreshPoll = 2
$overrideRefreshElapsed = 0
$overrideRefreshed = $false
while ($overrideRefreshElapsed -lt $overrideRefreshTimeout) {
    $logs = docker compose @ComposeEnvArgs logs dashboard-api 2>&1 | Out-String
    if ($logs -match "override\.yml refreshed for products:") {
        Write-Host "  ✓ docker-compose.override.yml regenerated by dashboard-api." -ForegroundColor Green
        $overrideRefreshed = $true
        break
    }
    Start-Sleep -Seconds $overrideRefreshPoll
    $overrideRefreshElapsed += $overrideRefreshPoll
}
if (-not $overrideRefreshed) {
    Write-Host "  [warn] Timed out waiting for dashboard-api's override.yml self-heal log line." -ForegroundColor Yellow
    Write-Host "  Expected on a brand-new install with no license activated yet -- proceeding."
}

Write-Host ""
Write-Host "  Starting remaining services..."
docker compose @ComposeEnvArgs up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  ✗ docker compose up failed (exit $LASTEXITCODE). Aborting install." -ForegroundColor Red
    Write-Host "    Run 'docker compose logs' to investigate." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "  Setting up HTTPS trust (Caddy internal CA)..."
$null = Install-CaddyRootCA

Write-Host ""
Write-Host "  Waiting for dashboard to be ready..."
Start-Sleep -Seconds 10

# BANKING-GRADE PURGE — DEFERRED (task #149).
# An earlier revision purged .env here, but Docker Compose re-interpolates
# ${VAR} refs on every subsequent `docker compose up` (updates, product
# deploys, scheduled restarts). No .env on disk = empty vars in containers
# = crash-loop. Reintroduce the purge only once dashboard-api regenerates
# .env from .env.enc before every compose action.


# ── Native capture daemon — REMOVED FROM ONELINER (B-CAPTURE-DEFER) ─────────
# 2026-06-09: per Liam, the capture daemon must NOT be installed at the
# oneliner stage — only inside the Setup Wizard, AFTER license activation,
# and only if Ravenscan is in the licensed products (bundle_products
# contains "secaudit"). Installing it upfront prompts UAC for a product
# the user may not even own a license for, violating the unified
# architecture "oneliner = platform + deps only".
#
# The capture daemon install now lives in dashboard-api as a dedicated
# endpoint, called from the Setup Wizard / Settings page when Ravenscan
# is activated. See task #31.
#
# Skip flag retained for documentation; no-op now.
if ($env:SKIP_NATIVE_CAPTURE -eq "1") {
    Write-Host "  ⓘ Capture daemon install skipped (SKIP_NATIVE_CAPTURE=1)"
}

$DashboardUrl = "http://localhost:3000"
if ((Get-Content "$env:WINDIR\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue) -match "coderaft\.local") {
    $DashboardUrl = "https://coderaft.local"
}

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║            Installation complete!                    ║" -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host ("  ║   Dashboard: {0,-39} ║" -f $DashboardUrl) -ForegroundColor Green
Write-Host "  ║                                                      ║" -ForegroundColor Green
Write-Host "  ║   Open the dashboard to activate your license        ║" -ForegroundColor Green
Write-Host "  ║   and deploy your products.                          ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Commands:  .\start.ps1  .\stop.ps1  .\update.ps1  .\rollback.ps1"
Write-Host "  Full install log: $INSTALL_LOG"
Write-Host ""

Start-Process $DashboardUrl
