#!/usr/bin/env sh
set -eu

# Regenerate the checked-in exact-source compressed stdlib payload.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$#" in
    0) OUTPUT=src/compiler_embedded_stdlib_payload.tl ;;
    1) OUTPUT=$1 ;;
    *)
        echo "usage: scripts/generate-embedded-stdlib-payload.sh [output.tl]" >&2
        exit 2
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

"$COMPILER" run tools/embedded-stdlib-payload/generate.tl \
    --stdlib-root stdlib --stdlib-root src -- "$OUTPUT"
"$COMPILER" fmt "$OUTPUT" --stdlib-root stdlib
