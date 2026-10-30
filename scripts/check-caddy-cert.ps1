# CodeRaft Caddy TLS certificate watchdog (Windows / PowerShell) — standalone,
# Scheduled-Task-invoked counterpart to the pre/post-update check already
# shipped inside update.ps1 (2026-08-13). See update.ps1 for the full
# incident writeup (Liam locked out with net::ERR_CERT_DATE_INVALID after
# ~4 weeks of continuous `caddy` container uptime with no update.ps1 run
# in between).
#
# THE GAP THIS CLOSES: the update.ps1 check only runs when a human (or
# some external automation) actually executes update.ps1. A real customer
# install that nobody touches for weeks never runs update.ps1, so it never
# got that protection either — same failure mode Liam hit, just with no
# admin available to unblock it with a manual `docker compose restart
# caddy`. This script is the exact same detection+self-heal logic (copied
# verbatim, not reinvented — see Get-CaddyCertDaysRemaining /
# Test-CaddyCertExpiryAndSelfHeal below, unchanged from update.ps1), wired
# to run once a day via a Windows Scheduled Task, independent of
# update.ps1 ever being invoked.
#
# Installed by install.ps1 on a fresh install, and self-healed by
# update.ps1 on every run (existing installs get the scheduled task added
# retroactively the next time they update — see update.ps1's
# `-RegisterTask` call).
#
# Usage:
#   .\check-caddy-cert.ps1                  # run the check once (also what the Scheduled Task calls)
#   .\check-caddy-cert.ps1 -RegisterTask    # (idempotent) install/refresh the daily Scheduled Task
#   .\check-caddy-cert.ps1 -UninstallTask   # remove the Scheduled Task
#
# Deliberately does NOT set $ErrorActionPreference = "Stop" globally (unlike
# update.ps1): this is a background monitoring script. A transient failure
# in one sub-step (network hiccup on the self-update fetch, Docker briefly
# unavailable) must never abort silently mid-script with no log — every
# step below handles its own failure explicitly via try/catch.

param(
    [switch]$RegisterTask,
    [switch]$UninstallTask,
    [switch]$PeriodicCron   # explicit marker used by the installed Scheduled Task action itself; same as running with no switch at all
)

# ── Resolve INSTALL_DIR ──────────────────────────────────────────────────
# Same layout as update.ps1/install.ps1: this script lives flat at the
# root of the install directory (next to docker-compose.yml, .env,
# update.ps1). Default to $PSScriptRoot (the directory containing THIS
# file) rather than the current directory — a Scheduled Task run has no
# guaranteed CWD. The Scheduled Task registered below also sets an
# explicit -WorkingDirectory as a second layer of safety, but this default
# keeps `.\check-caddy-cert.ps1` correct even when run manually from
# elsewhere.
$INSTALL_DIR = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
try {
    Set-Location -LiteralPath $INSTALL_DIR -ErrorAction Stop
} catch {
    Write-Host "ERROR: install dir '$INSTALL_DIR' not accessible: $($_.Exception.Message)" -ForegroundColor Red
    return   # not 'exit' — this script can be dot-invoked via iex in some contexts
}

# ── Detail log file (2026-08-13) ─────────────────────────────────────────
# Same convention as update.ps1/install.ps1's Write-DetailLog:
# logs\certcheck-<timestamp>.log, one file per run, pruned to the last 30
# (~1 month of daily runs — more than update.ps1's own 10, since this runs
# far more often and unattended, with nobody watching a console).
$LOG_DIR = Join-Path $INSTALL_DIR "logs"
try { New-Item -ItemType Directory -Force -Path $LOG_DIR -ErrorAction Stop | Out-Null } catch { $LOG_DIR = $env:TEMP }
$CERTCHECK_LOG = Join-Path $LOG_DIR ("certcheck-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
try {
    [System.IO.File]::WriteAllText($CERTCHECK_LOG, "[$(Get-Date -Format o)] check-caddy-cert.ps1 started`n", [System.Text.UTF8Encoding]::new($false))
} catch { }
function Write-CertCheckLog {
    param([Parameter(ValueFromPipeline = $true)][string]$Message)
    process {
        Write-Host $Message
        try { Add-Content -LiteralPath $script:CERTCHECK_LOG -Value "[$(Get-Date -Format o)] $Message" -Encoding utf8 -ErrorAction SilentlyContinue } catch { }
    }
}
try {
    Get-ChildItem -LiteralPath $LOG_DIR -Filter "certcheck-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

# ── Scheduled Task (un)registration ───────────────────────────────────────
$TaskName = "CaddyCertWatchdog"
$TaskPath = "\CodeRaft\"

function Register-CaddyCertWatchdogTask {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -PeriodicCron" `
            -WorkingDirectory $INSTALL_DIR

        $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if ($existing) {
            # Idempotent self-heal: never register a second task under the
            # same name (Get-ScheduledTask check above is what prevents the
            # duplication install.ps1/update.ps1 re-runs would otherwise
            # cause) — only refresh the action, in case the install path
            # changed (rare, e.g. a re-install elsewhere).
            try {
                Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -ErrorAction Stop | Out-Null
                Write-CertCheckLog "  Caddy cert watchdog scheduled task already present (action refreshed)."
            } catch {
                Write-CertCheckLog "  Caddy cert watchdog scheduled task already present."
            }
            return
        }

        $trigger = New-ScheduledTaskTrigger -Daily -At "09:00"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

        # LogonType Interactive (bound to the account that ran install.ps1),
        # NOT SYSTEM/ServiceAccount like the unrelated WolfGuard standalone
        # agent scheduled task (products/entraguard/.../agent.ps1) — that
        # one only collects local OS posture and never touches Docker.
        # THIS task must run `docker compose restart caddy`, and Docker
        # Desktop's engine pipe is scoped to the interactive user's own
        # session; a SYSTEM-run task frequently cannot reach it at all.
        # Known trade-off (documented in deploy/docs/local-https.md):
        # this only fires while that user is logged in — acceptable here
        # because Docker Desktop itself doesn't run without that same
        # interactive session either, so it is not a materially smaller
        # window than what the underlying dependency already imposes.
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest

        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal `
            -Description "CodeRaft: checks the Caddy TLS certificate daily and preemptively restarts the caddy service if it is within 14 days of expiring (or already expired). Runs independently of update.ps1 so installs that go weeks without an update stay protected. Uninstall: .\check-caddy-cert.ps1 -UninstallTask (or Unregister-ScheduledTask -TaskName '$TaskName' -TaskPath '$TaskPath' -Confirm:`$false)." `
            -Force -ErrorAction Stop | Out-Null
        Write-CertCheckLog "  Caddy cert watchdog scheduled task registered (daily at 09:00, user: $currentUser)."
    } catch {
        Write-CertCheckLog "  [warn] Could not register the Caddy cert watchdog scheduled task: $($_.Exception.Message)"
        Write-CertCheckLog "         Add it manually later, or re-run: powershell -File `"$ScriptPath`" -RegisterTask"
    }
}

function Unregister-CaddyCertWatchdogTask {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop
        Write-CertCheckLog "  Caddy cert watchdog scheduled task removed."
    } catch {
        Write-CertCheckLog "  [info] No scheduled task found to remove (or removal failed): $($_.Exception.Message)"
    }
}

if ($UninstallTask) {
    Unregister-CaddyCertWatchdogTask
    return
}
if ($RegisterTask) {
    $selfPath = $MyInvocation.MyCommand.Path
    if (-not $selfPath) { $selfPath = $PSCommandPath }
    if (-not $selfPath) { $selfPath = Join-Path $INSTALL_DIR "check-caddy-cert.ps1" }
    Register-CaddyCertWatchdogTask -ScriptPath $selfPath
    return
}

# ── Below: the actual periodic run (e.g. from the Scheduled Task) ───────

# ── Concurrency guard #1: is a real update.ps1 currently running? ───────
# The periodic check must never race update.ps1's own `docker compose
# pull` + `up -d --force-recreate` — restarting caddy mid-recreate could
# produce confusing transient errors. Detected by process inspection
# rather than a new shared lock file that update.ps1 would need to be
# taught to hold (higher risk: that file is large, delicate, and already
# shipped/tested — this check works without touching a single line of
# it). Get-Process does not expose command-line arguments; Win32_Process
# via CIM does.
try {
    $updateRunning = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
        Where-Object { $_.CommandLine -and ($_.CommandLine -match 'update\.ps1') -and ($_.ProcessId -ne $PID) }
    if ($updateRunning) {
        Write-CertCheckLog "update.ps1 appears to be running right now — skipping this cycle to avoid racing a live update. Will retry on the next scheduled run."
        return
    }
} catch {
    # Win32_Process query failed (locked-down WMI, restricted GPO) — proceed;
    # the lock-directory guard below still protects against overlapping
    # check-caddy-cert.ps1 runs, which is the higher-probability collision.
}

# ── Self-update (2026-08-13) ──────────────────────────────────────────────
# Same convention update.ps1/rollback.ps1 already use for themselves: this
# script self-refreshes from the installer repo before running, with a
# re-exec guard against infinite loops. Particularly important HERE:
# unlike update.ps1 (re-fetched every time a human runs an update), this
# script's whole point is to keep running unattended for weeks/months via
# the Scheduled Task with nobody re-triggering install.ps1/update.ps1 in
# between — so it needs its OWN refresh path to ever receive a bugfix.
#
# Deliberately placed BEFORE the lock-directory guard below (not nested
# inside it, unlike a first draft of this script): the re-exec below
# spawns check-caddy-cert.ps1 as a CHILD process and blocks waiting for
# it. If the lock were already held by this (parent) process at that
# point, the child would immediately see that same lock, conclude
# "another run is active", and return without ever performing the actual
# cert check — so the whole self-update path would silently skip every
# cycle where a refresh happens. Self-update first, lock second, avoids
# that: the freshly re-exec'd child starts clean and acquires the lock
# itself.
$IsReexecChild = [bool]$env:CODERAFT_CERTCHECK_REEXEC
if ($IsReexecChild) {
    Remove-Item Env:\CODERAFT_CERTCHECK_REEXEC -ErrorAction SilentlyContinue
}
if (-not $IsReexecChild) {
    try {
        $url = "https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/check-caddy-cert.ps1"
        $latest = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($latest.StatusCode -eq 200 -and $latest.Content.Length -gt 50) {
            $selfPath = $MyInvocation.MyCommand.Path
            if (-not $selfPath) { $selfPath = $PSCommandPath }
            if (-not $selfPath) { $selfPath = Join-Path $INSTALL_DIR "check-caddy-cert.ps1" }
            $current = ""
            try { $current = [System.IO.File]::ReadAllText($selfPath) } catch { }
            if ($current -ne $latest.Content) {
                [System.IO.File]::WriteAllText($selfPath, $latest.Content, [System.Text.Encoding]::UTF8)
                Write-CertCheckLog "check-caddy-cert.ps1 refreshed — re-running the updated version."
                # Detect the current PowerShell binary the same way update.ps1 does
                # (PS 5.1 'powershell.exe' vs PS7 'pwsh.exe' compat).
                $PSBin = (Get-Process -Id $PID).Path
                if (-not $PSBin -or -not (Test-Path $PSBin)) {
                    if (Get-Command pwsh -ErrorAction SilentlyContinue)       { $PSBin = "pwsh" }
                    elseif (Get-Command powershell -ErrorAction SilentlyContinue) { $PSBin = "powershell" }
                    else { $PSBin = "powershell" }
                }
                $env:CODERAFT_CERTCHECK_REEXEC = "1"
                & $PSBin -NoProfile -ExecutionPolicy Bypass -File $selfPath -PeriodicCron
                Remove-Item Env:\CODERAFT_CERTCHECK_REEXEC -ErrorAction SilentlyContinue
                return
            }
        }
    } catch {
        # Offline or upstream down — keep the local copy, continue below.
    }
}

# ── Concurrency guard #2: another check-caddy-cert.ps1 run already active? ─
# Belt-and-suspenders against a double Scheduled Task trigger / an
# overlapping manual run. New-Item -ItemType Directory with -ErrorAction
# Stop is atomic (single CreateDirectory syscall) so this is a safe
# test-and-set even against a genuinely concurrent second invocation.
# Stale-lock reclaim after 5 minutes covers a run that crashed before
# cleanup (the entire check+restart+reread cycle normally completes in a
# few seconds).
$LockDir = Join-Path $INSTALL_DIR ".coderaft-certcheck.lock"
function Enter-CertCheckLock {
    try {
        New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
        return $true
    } catch {
        if (Test-Path -LiteralPath $LockDir) {
            $age = (Get-Date) - (Get-Item -LiteralPath $LockDir).LastWriteTime
            if ($age.TotalSeconds -gt 300) {
                Write-CertCheckLog "[warn] Stale lock ($LockDir, age $([Math]::Round($age.TotalSeconds))s) — reclaiming."
                try {
                    Remove-Item -LiteralPath $LockDir -Force -Recurse -ErrorAction SilentlyContinue
                    New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
                    return $true
                } catch { return $false }
            }
        }
        return $false
    }
}
if (-not (Enter-CertCheckLock)) {
    Write-CertCheckLog "Another check-caddy-cert.ps1 run holds the lock — skipping this cycle."
    return
}

try {
    # ── docker compose file/env selection ─────────────────────────────────
    # Verbatim copy of update.ps1's own $ComposeArgs construction (same
    # file selection logic, same variable name) — needed so `docker compose
    # restart caddy` below targets the exact same compose project
    # update.ps1 would.
    $ComposeEnvArgs = @("--env-file", ".\install-config.env", "--env-file", ".\.env")
    $ComposeArgs = @("compose")
    if (Test-Path ".\docker-compose.override.yml") {
        $ComposeArgs += @("-f", ".\docker-compose.yml", "-f", ".\docker-compose.override.yml")
    }
    $vaultInMainTop = $false
    if (Test-Path ".\docker-compose.yml") {
        $vaultInMainTop = (Select-String -Path ".\docker-compose.yml" -Pattern '^\s*coderaft-vault:\s*$' -Quiet -ErrorAction SilentlyContinue)
    }
    if (-not $vaultInMainTop -and (Test-Path ".\docker-compose.vault.yml")) {
        if ($ComposeArgs -notcontains ".\docker-compose.yml") {
            $ComposeArgs += @("-f", ".\docker-compose.yml")
        }
        $ComposeArgs += @("-f", ".\docker-compose.vault.yml")
    }
    $ComposeArgs += $ComposeEnvArgs

    # ── PROACTIVE Caddy TLS certificate expiry detection ──────────────────
    # Copied VERBATIM from update.ps1 (2026-08-13 commit) — same function
    # names, same logic, same 14-day warning window. Do not fork the
    # detection algorithm here; if it needs to change, change it in
    # update.ps1 and mirror the change here (same duplication convention
    # update.ps1/update.sh already use relative to each other).
    function Get-CaddyCertDaysRemaining {
        param(
            [string]$TargetHost = "127.0.0.1",
            [int]$Port = 443,
            [string]$SniName = "coderaft.local"
        )
        $tcp = $null
        $sslStream = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $connectTask = $tcp.ConnectAsync($TargetHost, $Port)
            if (-not $connectTask.Wait(5000)) { return $null }
            $validationCallback = {
                param($sender, $certificate, $chain, $sslPolicyErrors)
                return $true
            }
            $sslStream = New-Object System.Net.Security.SslStream(
                $tcp.GetStream(), $false,
                [System.Net.Security.RemoteCertificateValidationCallback]$validationCallback
            )
            $sslStream.AuthenticateAsClient($SniName)
            $cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)
            return [Math]::Ceiling(($cert2.NotAfter - (Get-Date)).TotalDays)
        } catch {
            return $null   # unreachable / handshake failed — caller treats as "unknown", non-fatal
        } finally {
            if ($sslStream) { $sslStream.Dispose() }
            if ($tcp) { $tcp.Close() }
        }
    }

    function Test-CaddyCertExpiryAndSelfHeal {
        param([string]$Phase = "periodic")
        $CaddyCertWarnDays = 14
        $hostnameForCheck = "coderaft.local"
        $envPathForCert = Join-Path $INSTALL_DIR ".env"
        if (Test-Path $envPathForCert) {
            $envTextCert = [System.IO.File]::ReadAllText($envPathForCert, [System.Text.UTF8Encoding]::new($false))
            if ($envTextCert -match '(?m)^\s*CODERAFT_HOSTNAME\s*=(.+)$') {
                $candidate = $Matches[1].Trim().Trim('"').Trim("'")
                if ($candidate) { $hostnameForCheck = $candidate }
            }
        }
        Write-CertCheckLog "Checking Caddy TLS certificate expiry ($Phase, host=$hostnameForCheck)..."
        $days = Get-CaddyCertDaysRemaining -SniName $hostnameForCheck
        if ($null -eq $days) {
            Write-CertCheckLog "[warn] Could not check Caddy certificate (not reachable on 127.0.0.1:443, or platform not deployed yet) — skipping."
            return
        }
        if ($days -le $CaddyCertWarnDays) {
            if ($days -lt 0) {
                Write-CertCheckLog "[warn] Certificat Caddy EXPIRÉ depuis $([Math]::Abs($days)) jour(s) — redémarrage préventif du service caddy."
            } else {
                Write-CertCheckLog "[warn] Certificat Caddy expirant dans $days jour(s) — redémarrage préventif du service caddy."
            }
            & docker @ComposeArgs restart caddy 2>$null | Out-Null
            Start-Sleep -Seconds 3
            $daysAfter = Get-CaddyCertDaysRemaining -SniName $hostnameForCheck
            if ($null -ne $daysAfter -and $daysAfter -gt $days) {
                Write-CertCheckLog "Caddy redémarré — certificat désormais valide $daysAfter jour(s)."
            } else {
                Write-CertCheckLog "[warn] Redémarrage effectué mais l'expiration ne semble pas avoir progressé (valeur relue: $daysAfter). Vérifier: docker compose logs caddy"
            }
        } else {
            Write-CertCheckLog "Certificat Caddy valide encore $days jour(s)."
        }
    }

    try { Test-CaddyCertExpiryAndSelfHeal -Phase "periodic (scheduled task)" } catch {
        Write-CertCheckLog "[warn] Caddy cert expiry check failed unexpectedly: $($_.Exception.Message)"
    }
    Write-CertCheckLog "check-caddy-cert.ps1 run complete. Log: $CERTCHECK_LOG"
} finally {
    Remove-Item -LiteralPath $LockDir -Force -Recurse -ErrorAction SilentlyContinue
}
