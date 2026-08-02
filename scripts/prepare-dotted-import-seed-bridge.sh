#!/usr/bin/env sh
set -eu

# Materialize the published seed compiler's own source revision when the seed
# predates the dotted-import cutover, then apply only the capacity and
# qualified-reference fixes needed for it to compile the cutover revision. Any
# pre-cutover producer is accepted: the bridge patch context is stable across
# the pre-cutover window, so a moving stage0-latest works just like the
# original pinned producer 38fab957b3d7600f8cad0726955c94aedb8052be. The
# resulting compiler remains a bootstrap implementation detail; current
# sources do not regain support for string-path imports.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <seed-compiler> <output-source-root>" >&2
    exit 2
fi

SEED=$1
OUTPUT=$2

case "$OUTPUT" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) OUTPUT="$ROOT/$OUTPUT" ;;
esac
case "$OUTPUT" in
    "$ROOT"/target/*) ;;
    *)
        echo "dotted-import seed bridge output must stay below $ROOT/target" >&2
        exit 2
        ;;
esac

if [ -e "$OUTPUT" ]; then
    echo "dotted-import seed bridge output already exists: $OUTPUT" >&2
    exit 1
fi

SEED_ID=$("$SEED" --producer-identity 2>/dev/null || true)
if ! printf '%s' "$SEED_ID" | grep -qE '^[0-9a-f]{40}$'; then
    echo "unsupported dotted-import seed bridge producer: $SEED_ID" >&2
    exit 1
fi

if ! git -C "$ROOT" cat-file -e "$SEED_ID^{commit}" 2>/dev/null; then
    echo "[bootstrap] fetching published seed source $SEED_ID" >&2
    git -C "$ROOT" fetch --no-tags --depth=1 origin "$SEED_ID"
fi

# Only a pre-cutover seed needs the bridge: its producer's sources lack the
# nominal-owner classifier fix (which landed together with the generated-name
# capacity bump). A producer that already carries the fix compiles current
# sources natively, and the bridge patch would not apply to it.
if git -C "$ROOT" grep -q "tc-context-with-nominal-owner-module-id" \
    "$SEED_ID" -- src/compiler_lower.tl 2>/dev/null; then
    echo "dotted-import seed bridge is unnecessary for post-cutover producer: $SEED_ID" >&2
    exit 1
fi

mkdir -p "$OUTPUT"
git -C "$ROOT" archive "$SEED_ID" | tar -x -C "$OUTPUT"

# Bump the generated-name map capacity first. Its unified-diff context (the
# surrounding array type spellings) drifted across the pre-cutover window, so
# anchor only on the define line, which is stable.
sed -i '/^(define intern-generated-map-capacity : i64$/{n;s/^  32768)$/  131072)/}' \
    "$OUTPUT/src/compiler_intern.tl"
capacity_value=$(sed -n '/^(define intern-generated-map-capacity : i64$/{n;p}' \
    "$OUTPUT/src/compiler_intern.tl")
if [ "$capacity_value" != "  131072)" ]; then
    echo "dotted-import seed bridge failed to bump intern-generated-map-capacity for $SEED_ID" >&2
    exit 1
fi

patch -s -d "$OUTPUT" -p1 < "$ROOT/bootstrap/dotted-import-seed-bridge.patch"
printf '%s\n' "$SEED_ID" > "$OUTPUT/.seed-producer-identity"
