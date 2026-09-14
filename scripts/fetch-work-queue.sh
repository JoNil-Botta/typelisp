#!/usr/bin/env sh
set -eu

# Fetching is separate from scheduling: stdout contains both complete, unfiltered
# open queues. Never remove claimed PRs or filter issue labels in this wrapper.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -gt 1 ]; then
    echo 'usage: scripts/fetch-work-queue.sh [OWNER/REPO]' >&2
    exit 2
fi
REPO=${1:-JoNil-Botta/typelisp}
for dependency in gh jq; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "fetch-work-queue: $dependency is required" >&2
        exit 2
    }
done
mkdir -p "$ROOT/target/exp/fetch-work-queue"
WORKDIR=$(mktemp -d "$ROOT/target/exp/fetch-work-queue/request.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

fetch_lane() {
    lane=$1
    limit=$2
    fields=$3
    attempt=0
    while [ "$attempt" -lt 4 ]; do
        attempt=$((attempt + 1))
        if ! gh "$lane" list --repo "$REPO" --state open --limit "$limit" \
            --json "$fields" > "$WORKDIR/$lane.json"; then
            echo "fetch-work-queue: $lane fetch failed; no snapshot emitted; check gh authentication/API availability and retry" >&2
            exit 1
        fi
        # -s rejects multiple JSON documents as well as empty output. Checking
        # unique IDs prevents a malformed/repeated page from certifying coverage.
        if ! jq -se --arg lane "$lane" '
            def labels_ok:
                type == "array" and all(.[]; type == "object" and (.name | type == "string"));
            length == 1 and (.[0] |
                type == "array" and
                all(.[];
                    type == "object" and
                    (.number | type == "number" and . > 0 and . == floor) and
                    (.title | type == "string") and
                    (.labels | labels_ok) and
                    (if $lane == "pr" then
                        (.body | type == "string") and
                        (.headRefName | type == "string") and
                        (.baseRefName | type == "string") and
                        (.isDraft | type == "boolean") and
                        (.statusCheckRollup | . == null or type == "array")
                     else true end)) and
                (length == (map(.number) | unique | length)))
        ' "$WORKDIR/$lane.json" >/dev/null; then
            echo "fetch-work-queue: invalid $lane response (expected one array of unique open records with requested fields); no snapshot emitted" >&2
            exit 1
        fi
        # Native Windows jq may write CRLF under Git Bash.
        count=$(jq 'length' "$WORKDIR/$lane.json" | tr -d '\r')
        if [ "$count" -lt "$limit" ]; then
            return
        fi
        if [ "$count" -gt "$limit" ]; then
            echo "fetch-work-queue: $lane response exceeds requested limit $limit; no snapshot emitted" >&2
            exit 1
        fi
        echo "fetch-work-queue: $lane reached limit $limit; retrying with a larger complete-list request" >&2
        limit=$((limit * 2))
    done
    echo "fetch-work-queue: $lane still reached the limit after four requests; no snapshot emitted; use complete gh api pagination or raise the request bound in this wrapper" >&2
    exit 1
}

fetch_lane pr 1000 number,title,body,headRefName,baseRefName,isDraft,labels,statusCheckRollup
fetch_lane issue 10000 number,title,labels
jq -n --slurpfile prs "$WORKDIR/pr.json" --slurpfile issues "$WORKDIR/issue.json" \
    '{prs:$prs[0],issues:$issues[0]}'
