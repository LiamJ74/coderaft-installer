#!/bin/bash
# generate-install-checksums.sh — regenerate install.sh.sha256 / install.ps1.sha256
# (F-037, 2026-07-31).
#
# WHEN TO RUN THIS: every time install.sh or install.ps1 changes, as part of
# the same commit. This is the ONLY supported way to produce or update the
# two .sha256 sidecar files and the EXPECTED_SHA256 / $CoderaftExpectedSha256
# pins embedded near the top of each script — never hand-edit any of those
# four values.
#
# WHAT IT DOES, per script:
#   1. Hashes the script's content with its own EXPECTED_SHA256 /
#      $CoderaftExpectedSha256 declaration line excluded (so embedding the
#      hash doesn't change the hash — the classic chicken-and-egg fix).
#   2. Writes that digest to <script>.sha256 (bare lowercase hex, no
#      filename, no trailing newline games — matches what the runtime
#      self-check in each script expects to fetch/read).
#   3. Rewrites the embedded EXPECTED_SHA256 / $CoderaftExpectedSha256 line
#      in place with the same digest (used by each script as an offline
#      fallback pin when the network fetch of the sidecar file fails).
#   4. Re-hashes the now-patched file and asserts it's IDENTICAL to what was
#      just written — a cheap, mandatory regression guard: the exclusion
#      pattern only works if patching that one line never perturbs the hash
#      of everything else. If this assertion ever fails, something is
#      wrong with the exclusion pattern (or the file has multiple matching
#      lines) — the script aborts loudly rather than shipping a
#      self-inconsistent checksum.
#
# install.sh uses plain `sed | sha256sum` (or shasum/openssl) — bash/text
# tools already treat it byte-for-byte since the file is a normal LF/UTF-8
# text file (verified: no BOM, no CRLF).
#
# install.ps1's runtime self-check (Get-CoderaftSelfHash, defined inside
# install.ps1 itself) hashes via .NET's SHA256 over a CRLF-normalized,
# line-filtered, UTF8-re-encoded string — NOT a raw byte pipe — so this
# script shells out to `pwsh` and runs the *exact same* algorithm, to
# guarantee the generation-time hash and the install-time hash can never
# drift apart. Requires PowerShell (pwsh) to be installed on whatever
# machine regenerates the checksums (macOS: `brew install --cask powershell`
# or `brew install powershell`); it is NOT required at install time — only
# to regenerate these files.
#
# NOT YET LIVE: the public install.coderaft.io endpoint (Cloudflare Worker,
# deploy/worker.js) still proxies the legacy `coderaft-installer` GitHub
# repo, not this monorepo's deploy/install.sh — see
# deploy/docs/installer-integrity-verification.md for the full status.
# Regenerating these files today prepares the monorepo to be a correct
# distribution source once that cutover happens; it has no effect on what
# real customers currently download.
#
# Usage: bash deploy/scripts/generate-install-checksums.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${DEPLOY_DIR}"

echo "── generate-install-checksums.sh ──────────────────────────────────────────"
echo "  Working in: ${DEPLOY_DIR}"
echo ""

_sha256_stdin() {
    if command -v sha256sum &>/dev/null; then
        sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 | awk '{print $1}'
    elif command -v openssl &>/dev/null; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        echo "FATAL: no sha256sum, shasum, or openssl found on this machine." >&2
        exit 1
    fi
}

# ── install.sh ────────────────────────────────────────────────────────────
process_install_sh() {
    local file="install.sh"
    local sidecar="install.sh.sha256"

    if [ ! -f "$file" ]; then
        echo "FATAL: ${file} not found in ${DEPLOY_DIR}" >&2
        exit 1
    fi
    if ! grep -qE '^EXPECTED_SHA256=' "$file"; then
        echo "FATAL: ${file} has no 'EXPECTED_SHA256=' line — has the F-037 self-verify block been removed?" >&2
        exit 1
    fi
    local match_count
    match_count="$(grep -cE '^EXPECTED_SHA256=' "$file")"
    if [ "$match_count" -ne 1 ]; then
        echo "FATAL: ${file} has ${match_count} lines matching '^EXPECTED_SHA256=' (expected exactly 1) — refusing to guess which one to exclude/patch." >&2
        exit 1
    fi

    local digest
    digest="$(sed '/^EXPECTED_SHA256=/d' "$file" | _sha256_stdin)"
    if [ -z "$digest" ]; then
        echo "FATAL: computed an empty digest for ${file}." >&2
        exit 1
    fi

    printf '%s' "$digest" > "$sidecar"
    echo "  ✓ ${sidecar} written: ${digest}"

    # Portable in-place sed (BSD sed on macOS requires -i '', GNU sed accepts
    # -i alone) — the `-i.bak` + explicit rm form works identically on both.
    sed -i.bak -E "s/^EXPECTED_SHA256=.*/EXPECTED_SHA256=\"${digest}\"/" "$file"
    rm -f "${file}.bak"
    echo "  ✓ ${file}: EXPECTED_SHA256 pin updated"

    # Regression guard: re-hash the patched file, must match exactly.
    local verify_digest
    verify_digest="$(sed '/^EXPECTED_SHA256=/d' "$file" | _sha256_stdin)"
    if [ "$verify_digest" != "$digest" ]; then
        echo "FATAL: post-patch re-hash of ${file} does not match (${verify_digest} != ${digest})." >&2
        echo "        The EXPECTED_SHA256 exclusion pattern is not stable — investigate before shipping." >&2
        exit 1
    fi
    echo "  ✓ ${file}: idempotency verified (re-hash matches)"
}

# ── install.ps1 ───────────────────────────────────────────────────────────
process_install_ps1() {
    local file="install.ps1"
    local sidecar="install.ps1.sha256"

    if [ ! -f "$file" ]; then
        echo "FATAL: ${file} not found in ${DEPLOY_DIR}" >&2
        exit 1
    fi
    if ! grep -qE '^\$CoderaftExpectedSha256[[:space:]]*=' "$file"; then
        echo "FATAL: ${file} has no '\$CoderaftExpectedSha256 =' line — has the F-037 self-verify block been removed?" >&2
        exit 1
    fi
    if ! command -v pwsh &>/dev/null; then
        echo "FATAL: pwsh (PowerShell 7+) is required to hash ${file} using the exact" >&2
        echo "        same algorithm install.ps1 uses on itself at install time (byte" >&2
        echo "        read + CRLF normalize + line filter + UTF8 SHA256 — NOT a raw byte" >&2
        echo "        pipe, so a bash-side reimplementation would risk silently drifting" >&2
        echo "        from the real runtime check)." >&2
        echo "        Install it: brew install --cask powershell   (or: brew install powershell)" >&2
        exit 1
    fi

    # This mirrors Get-CoderaftSelfHash / the exclusion regex embedded in
    # install.ps1 line-for-line. If you change either the hashing
    # normalization or the exclusion pattern in install.ps1, update this
    # block in the same commit — the idempotency check below will catch a
    # drift (patched file re-hashes differently) but NOT a case where both
    # sides drifted together in the same wrong direction, so keep them
    # reviewed side by side.
    #
    # Written to a real temp FILE (not inlined into a `pwsh -Command "$(...)"`
    # string) deliberately: macOS's system /bin/bash (3.2, GPLv2-era —
    # pre-installed, no way around it) mis-parses a heredoc containing an
    # odd number of backtick characters when that heredoc is nested inside a
    # `$(...)` command substitution — and PowerShell's `n`/`r`n escapes
    # below each contribute one backtick, so an odd count is unavoidable.
    # A plain heredoc redirected straight to a file sidesteps the bug
    # entirely; `pwsh -File` then reads it normally.
    # `-t coderaft-install-ps1-hash-XXXXXX` (not a bare prefix): BSD mktemp
    # (macOS) accepts a template with no X's and still randomizes it, but
    # GNU mktemp (Linux — GitHub Actions runners) requires at least some
    # X's in the template and errors "too few X's" otherwise. The XXXXXX
    # suffix works identically on both.
    local pwsh_tmp
    pwsh_tmp="$(mktemp -t coderaft-install-ps1-hash-XXXXXX).ps1"
    trap 'rm -f "$pwsh_tmp"' RETURN
    cat > "$pwsh_tmp" <<'PWSH'
param([string]$Path, [string]$SidecarPath)
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
$digest = ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLower()
if ($SidecarPath) {
    [System.IO.File]::WriteAllText($SidecarPath, $digest)
}
Write-Output $digest
PWSH

    local digest
    digest="$(pwsh -NoProfile -File "$pwsh_tmp" -Path "$(pwd)/${file}" -SidecarPath "$(pwd)/${sidecar}")"
    digest="$(echo -n "$digest" | tr -d '[:space:]')"
    if [ -z "$digest" ]; then
        echo "FATAL: pwsh produced an empty digest for ${file}." >&2
        exit 1
    fi
    echo "  ✓ ${sidecar} written: ${digest}"

    sed -i.bak -E "s/^\\\$CoderaftExpectedSha256[[:space:]]*=.*/\$CoderaftExpectedSha256 = \"${digest}\"/" "$file"
    rm -f "${file}.bak"
    echo "  ✓ ${file}: \$CoderaftExpectedSha256 pin updated"

    # Regression guard: re-hash the patched file via the same pwsh routine.
    local verify_digest
    verify_digest="$(pwsh -NoProfile -File "$pwsh_tmp" -Path "$(pwd)/${file}")"
    verify_digest="$(echo -n "$verify_digest" | tr -d '[:space:]')"
    if [ "$verify_digest" != "$digest" ]; then
        echo "FATAL: post-patch re-hash of ${file} does not match (${verify_digest} != ${digest})." >&2
        echo "        The \$CoderaftExpectedSha256 exclusion pattern is not stable — investigate before shipping." >&2
        exit 1
    fi
    echo "  ✓ ${file}: idempotency verified (re-hash matches)"

    rm -f "$pwsh_tmp"
    trap - RETURN
}

process_install_sh
echo ""
process_install_ps1
echo ""
echo "── Done. Review the diff (install.sh, install.ps1, install.sh.sha256,"
echo "   install.ps1.sha256) and commit all four files together. ────────────────"
