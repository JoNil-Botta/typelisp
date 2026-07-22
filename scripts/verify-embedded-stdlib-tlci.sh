#!/usr/bin/env sh
set -eu

# Prove the checked-in stdlib source set produces a deterministic, source-bound
# host image that the production include-bin and W^X loader path can register.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-embedded-stdlib-tlci.sh" >&2
    exit 2
fi

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) HOST_TARGET=windows ;;
    *) HOST_TARGET=linux ;;
esac

WORKDIR=target/embedded-stdlib-tlci-verify
EMBEDDED_IMAGE=target/embedded-stdlib-tlci/stdlib.tlci
IMAGE_A=$WORKDIR/stdlib-a.tlci
IMAGE_B=$WORKDIR/stdlib-b.tlci
MUTATED_ROOT=$WORKDIR/stdlib-mutated
MUTATED_IMAGE=$WORKDIR/stdlib-mutated.tlci
MUTATED_SURFACE=$WORKDIR/stdlib-mutated-surface.rodata
MANIFEST=target/embedded-stdlib-tlci/modules.txt
mkdir -p "$WORKDIR"

scripts/build-embedded-stdlib-tlci.sh \
    "$COMPILER" "$EMBEDDED_IMAGE" "$HOST_TARGET"
cp "$EMBEDDED_IMAGE" "$IMAGE_A"
scripts/build-embedded-stdlib-tlci.sh \
    "$COMPILER" "$EMBEDDED_IMAGE" "$HOST_TARGET"
cp "$EMBEDDED_IMAGE" "$IMAGE_B"

if ! cmp -s "$IMAGE_A" "$IMAGE_B"; then
    echo "embedded stdlib tlci build is not deterministic" >&2
    exit 1
fi

set +e
"$COMPILER" run tools/embedded-stdlib-tlci/verify.tl \
    --stdlib-root stdlib --stdlib-root src \
    --cfg embedded-stdlib-tlci
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "embedded stdlib tlci loader verifier exited $status, expected 42" >&2
    exit 1
fi

"$COMPILER" inspect "$IMAGE_A" > "$WORKDIR/inspect.txt"
grep -q '^package-name: stdlib$' "$WORKDIR/inspect.txt"
grep -Eq '^  code: .* bytes=[1-9][0-9]*$' "$WORKDIR/inspect.txt"

# A source-only change must alter the image even while the macro identity set
# and generated registration shells remain unchanged.
rm -rf "$MUTATED_ROOT"
mkdir -p "$MUTATED_ROOT"
while IFS= read -r suffix; do
    cp "stdlib/$suffix" "$MUTATED_ROOT/$suffix"
done < "$MANIFEST"
printf '\n;; embedded stdlib tlci source binding probe\n' \
    >> "$MUTATED_ROOT/array.tl"
BUILD_HASH=$(git rev-parse --verify HEAD)
MUTATED_SOURCE_HASH=$(
    while IFS= read -r module_path; do
        source_path="$MUTATED_ROOT/$module_path"
        source_size=$(wc -c < "$source_path" | tr -d ' ')
        printf '%s\000%s\000' "$module_path" "$source_size"
        cat "$source_path"
    done < "$MANIFEST" | git hash-object --stdin
)
"$COMPILER" run tools/embedded-stdlib-tlci/build-surface.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$MUTATED_ROOT" "$MUTATED_SURFACE" "$HOST_TARGET" \
    "$BUILD_HASH" "$MUTATED_SOURCE_HASH"
"$COMPILER" run tools/embedded-stdlib-tlci/build.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$MANIFEST" "$MUTATED_ROOT" "$MUTATED_IMAGE" \
    "$HOST_TARGET" "$BUILD_HASH" "$MUTATED_SURFACE"
if cmp -s "$IMAGE_A" "$MUTATED_IMAGE"; then
    echo "embedded stdlib source mutation did not change the tlci image" >&2
    exit 1
fi

echo "embedded stdlib tlci image is deterministic, source-bound, and loadable"
