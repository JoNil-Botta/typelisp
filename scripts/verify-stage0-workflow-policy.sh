#!/usr/bin/env sh
set -eu

# Keep the mutable stage0 publication on the staged-draft protocol. Reverting
# to a composite `gh release create stage0-latest` reintroduces both the long
# delete/upload 404 window and the late draft transition from #6367.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKFLOW=.github/workflows/bootstrap-stage0.yml
PUBLISHER=scripts/publish-stage0-latest.sh
WINDOWS_FETCHER=scripts/fetch-stage0.ps1

fail() {
    echo "stage0 workflow policy: $*" >&2
    exit 1
}

require_fixed() {
    needle=$1
    file=$2
    label=$3
    grep -F -- "$needle" "$file" >/dev/null 2>&1 || fail "$label"
}

reject_fixed() {
    needle=$1
    file=$2
    label=$3
    if grep -F -- "$needle" "$file" >/dev/null 2>&1; then
        fail "$label"
    fi
}

require_count() {
    needle=$1
    file=$2
    expected=$3
    label=$4
    count=$(grep -F -c -- "$needle" "$file" || true)
    [ "$count" -eq "$expected" ] || fail "$label (found $count, expected $expected)"
}

require_fixed "scripts/publish-stage0-latest.sh" "$WORKFLOW" \
    "bootstrap must use the staged publication helper"
require_fixed 'stage0-candidate-${{ github.run_id }}-${{ github.run_attempt }}' \
    "$WORKFLOW" "candidate tag must be unique across workflow attempts"
require_fixed "scripts/verify-stage0-release.sh" "$WORKFLOW" \
    "promoted release must still pass the public verifier"
require_fixed 'if [ "$publish_status" -eq 3 ]; then' "$WORKFLOW" \
    "stale candidates must skip final-SHA verification without failing the run"
reject_fixed "gh release create stage0-latest" "$WORKFLOW" \
    "workflow must not recreate and implicitly publish the stable tag"
reject_fixed "gh release delete stage0-latest" "$WORKFLOW" \
    "workflow must not open a release-wide gap before candidate upload"

require_fixed 'gh api --method POST "repos/$REPO/releases"' "$PUBLISHER" \
    "candidate must be created through the explicit REST protocol"
require_fixed "-F draft=true" "$PUBLISHER" \
    "candidate must stay private throughout asset upload"
require_fixed "-F draft=false" "$PUBLISHER" \
    "promotion must explicitly publish the prepared draft"
require_fixed 'gh api --paginate "repos/$REPO/releases?per_page=100"' "$PUBLISHER" \
    "stable release discovery must not age out of the first API page"
require_count 'latest_main=$(current_main_sha)' "$PUBLISHER" 3 \
    "main must be checked before staging, before cutover, and after promotion"
require_fixed "CUTOVER_STARTED=1" "$PUBLISHER" \
    "candidate cleanup must stop once stable cutover begins"
require_fixed "validate_candidate_assets" "$PUBLISHER" \
    "candidate asset completeness must be validated before cutover"

require_fixed "TYPELISP_STAGE0_FETCH_ATTEMPTS" "$WINDOWS_FETCHER" \
    "PowerShell consumers need the bounded cutover retry budget"
require_fixed 'for ($Attempt = 1; $Attempt -le $FetchAttempts; $Attempt++)' \
    "$WINDOWS_FETCHER" "PowerShell consumers must retry the whole asset/checksum generation"
require_fixed "Start-Sleep -Seconds \$FetchRetryDelay" "$WINDOWS_FETCHER" \
    "PowerShell cutover retries must use the configured delay"

echo "stage0 workflow publication policy passed"
