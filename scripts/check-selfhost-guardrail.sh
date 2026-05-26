#!/usr/bin/env sh
set -eu

# check-selfhost-guardrail.sh - report Rust-owned changes and require a PR note.
#
# PRs that change Rust-owned files must state the paired TypeLisp path or the
# temporary bootstrap/migration reason in the PR body:
#
#   Selfhost-Guardrail: selfhost/compiler_parse_core.tl
#   Selfhost-Guardrail: temporary stage0 routing change for #795

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

BASE=${SELFHOST_GUARDRAIL_BASE:-}
if [ -z "$BASE" ]; then
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
        BASE=origin/main
    else
        BASE=HEAD~1
    fi
fi

WORKDIR="$ROOT/target/selfhost-guardrail"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

CHANGED="$WORKDIR/changed-files.txt"
RUST_OWNED="$WORKDIR/rust-owned-files.txt"

if git merge-base "$BASE" HEAD >/dev/null 2>&1; then
    git diff --name-only "$BASE"...HEAD > "$CHANGED"
else
    git diff --name-only "$BASE" HEAD > "$CHANGED"
fi
git diff --name-only >> "$CHANGED"
git diff --name-only --cached >> "$CHANGED"
git ls-files --others --exclude-standard >> "$CHANGED"
sort -u "$CHANGED" > "$WORKDIR/changed-files.sorted"
mv "$WORKDIR/changed-files.sorted" "$CHANGED"

grep -E '^(src|tests|tools)/.*\.rs$|^Cargo\.(toml|lock)$' "$CHANGED" \
    > "$RUST_OWNED" || true

if [ ! -s "$RUST_OWNED" ]; then
    echo "selfhost guardrail: no Rust-owned source/test changes detected"
    exit 0
fi

echo "selfhost guardrail: Rust-owned source/test changes detected:"
sed 's/^/  - /' "$RUST_OWNED"

PR_BODY=${SELFHOST_GUARDRAIL_PR_BODY:-}

GUARDRAIL=$(
    printf '%s\n' "$PR_BODY" |
        sed -n 's/^[[:space:]]*[-*]*[[:space:]]*Selfhost-Guardrail:[[:space:]]*//p' |
        sed '/^[[:space:]]*$/d' |
        head -n 1
)

NORMALIZED=$(
    printf '%s' "$GUARDRAIL" |
        tr '[:upper:]' '[:lower:]' |
        tr -d '[:space:]'
)

case "$NORMALIZED" in
    "" | none | n/a | na | todo | tbd)
        echo "selfhost guardrail: missing PR body statement." >&2
        echo "Fill in 'Selfhost-Guardrail:' with a paired selfhost/stdlib path or temporary migration reason." >&2
        exit 1
        ;;
esac

echo "selfhost guardrail: PR statement found: $GUARDRAIL"
