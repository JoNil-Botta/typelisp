#!/usr/bin/env sh
set -eu

# check-rust-test-coverage-map.sh - require Rust test additions to update the
# Rust -> TypeLisp replacement inventory.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

BASE=${RUST_TEST_COVERAGE_BASE:-}
if [ -z "$BASE" ]; then
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
        BASE=origin/main
    else
        BASE=HEAD~1
    fi
fi

WORKDIR="$ROOT/target/rust-test-coverage-map"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

CHANGED="$WORKDIR/changed-files.txt"
RUST_FILES="$WORKDIR/rust-files.txt"
ADDED_TESTS="$WORKDIR/added-rust-tests.txt"
: > "$ADDED_TESTS"

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

grep -E '^(src|tests)/.*\.rs$' "$CHANGED" > "$RUST_FILES" || true

if [ ! -s "$RUST_FILES" ]; then
    echo "rust test coverage map: no Rust source/test files changed"
    exit 0
fi

while IFS= read -r file; do
    if git merge-base "$BASE" HEAD >/dev/null 2>&1; then
        git diff --unified=0 "$BASE"...HEAD -- "$file"
    else
        git diff --unified=0 "$BASE" HEAD -- "$file"
    fi
    git diff --unified=0 -- "$file"
    git diff --cached --unified=0 -- "$file"
done < "$RUST_FILES" |
    grep -E '^\+[[:space:]]*#\[[^]]*test' > "$ADDED_TESTS" || true

if [ ! -s "$ADDED_TESTS" ]; then
    echo "rust test coverage map: no new Rust #[test] items detected"
    exit 0
fi

if grep -qx 'selfhost/RUST_TEST_COVERAGE.md' "$CHANGED"; then
    echo "rust test coverage map: Rust test additions paired with coverage map update"
    exit 0
fi

echo "rust test coverage map: new Rust #[test] items require selfhost/RUST_TEST_COVERAGE.md updates" >&2
echo "Added test markers:" >&2
sed 's/^/  /' "$ADDED_TESTS" >&2
exit 1
