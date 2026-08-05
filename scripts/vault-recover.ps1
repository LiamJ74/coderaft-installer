# vault-recover.ps1 — unseal ceremony helper: prompts an operator for a
# threshold of Shamir shares and submits them to the running vault's
# POST /v1/unseal.
#
# AUDIT-SECU-2026-08-04 (Vault H1): this used to reconstruct
# vault-keys\age.key from a 24-word BIP39 mnemonic via a `-mnemonic-to-key`
# vault CLI sub-command that was never actually implemented (it always fell
# through to a "not available" error). That whole model is gone: there is
# no more on-disk master key file, no more recovery phrase. The vault
# generates its own master key once (POST /v1/init) and splits it into real
# Shamir shares; "recovery" of a sealed vault is simply re-running the
# unseal ceremony with a threshold of those ORIGINAL shares. If fewer than
# the threshold can be gathered, the vault's data is permanently
# unrecoverable — there is no back door.
#
# Usage:
#   .\vault-recover.ps1

param(
    [string] $InstallDir = $env:INSTALL_DIR
)

if (-not $InstallDir) { $InstallDir = (Get-Location).Path }

Write-Host ""
Write-Host "  +==================================================================+" -ForegroundColor Cyan
Write-Host "  |              coderaft-vault — Unseal Ceremony                    |" -ForegroundColor Cyan
Write-Host "  +==================================================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This submits Shamir shares to POST /v1/unseal on the running vault."
Write-Host "  You need a THRESHOLD number of shares from THIS vault's own"
Write-Host "  POST /v1/init response (default: 3 of 5) — shares from a different"
Write-Host "  vault will not work, and there is no way to reconstruct a share."
Write-Host ""

$shares = New-Object System.Collections.Generic.List[string]
Write-Host "  Enter each share (base64), one per line. Press Enter on an empty"
Write-Host "  line when you have entered enough (you'll be told if you need more):"
while ($true) {
    $secureShare = Read-Host -AsSecureString ("  Share {0}" -f ($shares.Count + 1))
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureShare)
    try { $shareText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $shareText) { break }
    $shares.Add($shareText)
}

if ($shares.Count -eq 0) {
    Write-Host "  [!] No shares entered. Aborting." -ForegroundColor Red
    exit 1
}

# Detect compose project name (determines Docker network for sidecar)
$inspectFormat = '{{ index .Config.Labels "com.docker.compose.project" }}'
$inspectStdout = Join-Path $env:TEMP "coderaft-vr-inspect-out-$(Get-Random).log"
$inspectStderr = Join-Path $env:TEMP "coderaft-vr-inspect-err-$(Get-Random).log"
Start-Process -FilePath "docker" -ArgumentList @(
    "inspect", "coderaft-coderaft-vault-1", "--format", $inspectFormat
) -NoNewWindow -Wait `
    -RedirectStandardOutput $inspectStdout `
    -RedirectStandardError $inspectStderr `
    -ErrorAction SilentlyContinue | Out-Null
$vaultProject = ((Get-Content $inspectStdout -ErrorAction SilentlyContinue) -join "").Trim()
Remove-Item -Path $inspectStdout, $inspectStderr -ErrorAction SilentlyContinue
if (-not $vaultProject) { $vaultProject = "coderaft" }
$vaultNetwork = "${vaultProject}_coderaft-vault-net"
$absTlsDir = (Resolve-Path -LiteralPath (Join-Path $InstallDir "vault-tls")).Path

function Invoke-VaultCurlRecover {
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
        $bodyFile = Join-Path $env:TEMP "coderaft-vr-body-$(Get-Random).json"
        [System.IO.File]::WriteAllText($bodyFile, $JsonBody, [System.Text.UTF8Encoding]::new($false))
        $dockerArgs += @("-H", "Content-Type: application/json", "--data-binary", "@-")
    }
    $curlStdout = Join-Path $env:TEMP "coderaft-vr-curl-out-$(Get-Random).log"
    $curlStderr = Join-Path $env:TEMP "coderaft-vr-curl-err-$(Get-Random).log"
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
    if (Test-Path $curlStdout) { $body = ((Get-Content $curlStdout -ErrorAction SilentlyContinue) -join "") }
    Remove-Item -Path $curlStdout, $curlStderr -ErrorAction SilentlyContinue
    if ($bodyFile) { Remove-Item -Path $bodyFile -ErrorAction SilentlyContinue }
    return $body
}

$unsealBody = @{ shares = @($shares) } | ConvertTo-Json -Compress
Write-Host "  Submitting $($shares.Count) share(s) to POST /v1/unseal..."
$unsealResp = Invoke-VaultCurlRecover -Method "POST" -Path "/v1/unseal" -JsonBody $unsealBody
Write-Host "  Response: $unsealResp"

if ($unsealResp -match '"ok"\s*:\s*true') {
    Write-Host "  ✓ Vault unsealed" -ForegroundColor Green
} elseif ($unsealResp -match '"progress"') {
    Write-Host "  [!] Not enough shares yet — re-run this script and enter the remaining share(s)." -ForegroundColor Yellow
    Write-Host "    Shares already submitted are NOT remembered between separate runs of this"
    Write-Host "    script if the vault process restarts in between; submit them all in one run."
    exit 1
} else {
    Write-Host "  [!] Unseal failed — see response above (wrong shares, or vault not yet" -ForegroundColor Red
    Write-Host "    initialized — run POST /v1/init first if this is a brand new vault)." -ForegroundColor Red
    exit 1
}

$finalHealth = Invoke-VaultCurlRecover -Method "GET" -Path "/v1/health"
if ($finalHealth -match '"sealed"\s*:\s*false') {
    Write-Host "  ✓ coderaft-vault is healthy and unsealed" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Recovery complete."
} else {
    Write-Host ""
    Write-Host "  [!] Unseal reported success but health check does not confirm sealed:false." -ForegroundColor Yellow
    Write-Host "    Health: $finalHealth" -ForegroundColor Yellow
    exit 1
}
