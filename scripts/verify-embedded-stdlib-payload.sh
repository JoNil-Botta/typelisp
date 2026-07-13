#!/usr/bin/env sh
set -eu

# Regenerate/diff the compressed payload and prove every module decodes exactly.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-embedded-stdlib-payload.sh" >&2
    exit 2
fi

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

WORKDIR=target/embedded-stdlib-payload-verify
GENERATED="$WORKDIR/compiler_embedded_stdlib_payload.tl"
MANIFEST=tools/embedded-stdlib-payload/modules.txt
NORMALIZED_MANIFEST="$WORKDIR/modules.txt"
mkdir -p "$WORKDIR"
tr -d '\r' < "$MANIFEST" > "$NORMALIZED_MANIFEST"

if [ ! -s "$NORMALIZED_MANIFEST" ]; then
    echo "embedded stdlib payload manifest is empty" >&2
    exit 1
fi
if grep -n -v '^[A-Za-z0-9_][A-Za-z0-9_]*\.tl$' "$NORMALIZED_MANIFEST" \
    > "$WORKDIR/invalid-manifest-lines.txt"; then
    echo "embedded stdlib payload manifest has invalid module suffixes" >&2
    sed 's/^/  /' "$WORKDIR/invalid-manifest-lines.txt" >&2
    exit 1
fi
sort "$NORMALIZED_MANIFEST" | uniq -d > "$WORKDIR/duplicate-manifest-lines.txt"
if [ -s "$WORKDIR/duplicate-manifest-lines.txt" ]; then
    echo "embedded stdlib payload manifest has duplicate modules" >&2
    sed 's/^/  /' "$WORKDIR/duplicate-manifest-lines.txt" >&2
    exit 1
fi
while IFS= read -r suffix; do
    if [ ! -f "stdlib/$suffix" ]; then
        echo "embedded stdlib payload source is missing: stdlib/$suffix" >&2
        exit 1
    fi
done < "$NORMALIZED_MANIFEST"

TYPELISP_BIN=$COMPILER scripts/generate-embedded-stdlib-payload.sh "$GENERATED"
if ! cmp -s src/compiler_embedded_stdlib_payload.tl "$GENERATED"; then
    echo "generated embedded stdlib payload is stale" >&2
    diff -u src/compiler_embedded_stdlib_payload.tl "$GENERATED" >&2 || true
    exit 1
fi

"$COMPILER" check src/compiler_embedded_stdlib_payload.tl \
    --stdlib-root stdlib --stdlib-root src
set +e
"$COMPILER" run tools/embedded-stdlib-payload/verify.tl \
    --stdlib-root stdlib --stdlib-root src
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "embedded stdlib exact-source verifier exited $status, expected 42" >&2
    exit 1
fi

echo "embedded stdlib payload is deterministic and exact"
