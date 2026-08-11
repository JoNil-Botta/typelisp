#!/usr/bin/env sh
set -eu

# verify-docs-workflow-policy.sh - keep Pages publication ordered behind the
# exact compatible Bootstrap Stage0 artifact.
#
# The docs and bootstrap workflows once ran independently on every main push.
# Docs fetched mutable stage0-latest while its successor was still building,
# so a compiler/stdlib surface change deterministically failed publication.
# This cheap policy gate makes the handoff and stale-deployment interlocks part
# of PR CI rather than relying on workflow review alone. Refs #6284.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKFLOW=.github/workflows/docs-pages.yml

fail() {
    echo "docs workflow policy: $*" >&2
    exit 1
}

require_fixed() {
    needle=$1
    label=$2
    grep -F "$needle" "$WORKFLOW" >/dev/null 2>&1 || fail "$label"
}

reject_fixed() {
    needle=$1
    label=$2
    if grep -F "$needle" "$WORKFLOW" >/dev/null 2>&1; then
        fail "$label"
    fi
}

require_count_at_least() {
    needle=$1
    minimum=$2
    label=$3
    count=$(grep -Fc "$needle" "$WORKFLOW" || true)
    [ "$count" -ge "$minimum" ] || fail "$label (found $count, need $minimum)"
}

require_fixed "workflow_run:" "missing workflow_run trigger"
require_fixed "workflows: [Bootstrap Stage0]" "docs must follow Bootstrap Stage0"
require_fixed "types: [completed]" "docs must wait for bootstrap completion"
require_fixed "branches: [main]" "bootstrap handoff must be limited to main"
require_fixed "workflow_dispatch:" "manual docs dispatch was removed"
require_fixed "bootstrap_run_id:" "manual dispatch must name a bootstrap run"
require_fixed "required: true" "manual bootstrap run ID must be required"
reject_fixed "  push:" "docs must not race bootstrap from an independent push trigger"

require_fixed "permissions: {}" "workflow permissions must default to none"
require_fixed "actions: read" "cross-run artifact download needs actions: read"
require_fixed "pages: write" "deploy job needs pages: write"
require_fixed "id-token: write" "deploy job needs id-token: write"
require_fixed "github.event.workflow_run.conclusion == 'success'" \
    "failed or cancelled bootstrap runs must not publish docs"
require_fixed "github.event.workflow_run.event == 'push'" \
    "automatic docs must accept only bootstrap push runs"
require_fixed "github.event.workflow_run.head_repository.full_name == github.repository" \
    "automatic docs must accept only runs from this repository"

require_fixed "ref: \${{ needs.resolve.outputs.source_sha }}" \
    "checkout must use the bootstrap run head SHA"
require_fixed "name: stage0-linux" "docs must consume the Linux stage0 artifact"
require_fixed "github-token: \${{ secrets.GITHUB_TOKEN }}" \
    "cross-run artifact download must authenticate"
require_fixed "run-id: \${{ needs.resolve.outputs.run_id }}" \
    "artifact download must use the resolved bootstrap run"
require_fixed "target/stage0/typelisp" "matching artifact must be the docs compiler"
reject_fixed "scripts/fetch-stage0.sh" \
    "docs must not return to mutable stage0-latest consumption"

# One main check rejects stale work before the expensive build; the second runs
# immediately before deploy because main may move while the site is building or
# while the workflow waits in the Pages concurrency group.
require_count_at_least "/git/ref/heads/main" 2 \
    "current main must be checked before build and deployment"
require_fixed "if: needs.resolve.outputs.current == 'true'" \
    "stale bootstrap runs must not build a Pages artifact"
require_fixed "if: steps.current.outputs.publish == 'true'" \
    "stale docs artifacts must not deploy"

echo "docs workflow policy passed"
