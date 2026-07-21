#!/usr/bin/env sh
set -eu

# Keep cross-module generated-family calls provider-qualified. The allowlist
# contains only current-module calls and the focused compatibility coverage
# that #5266 will remove with the imported self-name fallback.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

EXPECTED=scripts/qualified-module-macro-import-allowlist.txt
WORKDIR=target/qualified-module-macro-imports
RAW="$WORKDIR/actual-with-lines.txt"
ACTUAL="$WORKDIR/actual.txt"
EXPECTED_SORTED="$WORKDIR/expected.txt"
mkdir -p "$WORKDIR"

# Split regex punctuation from the family names so this verifier does not
# report its own implementation.
open='\(import \('
families='vector|result|hashmap|option|set|slice'
tail='([[:space:]]|\))'

set +e
git grep -n -E "$open($families)$tail" -- . \
    ':!scripts/qualified-module-macro-import-allowlist.txt' > "$RAW"
status=$?
set -e
if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    echo "qualified module-macro import audit could not scan tracked files" >&2
    exit "$status"
fi

sed -E 's/^([^:]+):[0-9]+:/\1:/' "$RAW" | LC_ALL=C sort > "$ACTUAL"
grep -v '^#' "$EXPECTED" | grep -v '^$' | LC_ALL=C sort > "$EXPECTED_SORTED"

if ! diff -u "$EXPECTED_SORTED" "$ACTUAL"; then
    echo "bare imported generated-family call found outside the audited allowlist" >&2
    exit 1
fi

echo "qualified module-macro import audit passed"
