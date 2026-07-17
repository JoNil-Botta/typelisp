#!/usr/bin/env sh
set -eu

# Build the host-native stdlib comptime image catalog consumed by include-bin.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <typelisp-compiler> <output.tlci> <linux|windows>" >&2
    exit 2
fi

COMPILER=$1
OUTPUT=$2
HOST_TARGET=$3
case "$HOST_TARGET" in
    linux | windows) ;;
    *)
        echo "invalid embedded stdlib tlci host target: $HOST_TARGET" >&2
        exit 2
        ;;
esac

case "$COMPILER" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
case "$OUTPUT" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) OUTPUT="$ROOT/$OUTPUT" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "embedded stdlib tlci compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/embedded-stdlib-tlci"
MANIFEST="$WORKDIR/modules.txt"
mkdir -p "$WORKDIR" "$(dirname -- "$OUTPUT")"

awk '
function emit_input() {
    path = declaration
    sub(/^[^"]*"\.\.\/stdlib\//, "", path)
    sub(/".*$/, "", path)
    print path
    declaration = ""
    collecting = 0
}
/^\(include-str-lzss([ \t]|$)/ {
    declaration = $0
    collecting = 1
    if ($0 ~ /\)[ \t]*$/) emit_input()
    next
}
collecting {
    declaration = declaration " " $0
    if ($0 ~ /\)[ \t]*$/) emit_input()
}
' src/compiler_embedded_stdlib_payload_[a-f].tl > "$MANIFEST"

BUILD_HASH=$(git rev-parse --verify HEAD)
"$COMPILER" run tools/embedded-stdlib-tlci/build.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$MANIFEST" stdlib "$OUTPUT" "$HOST_TARGET" "$BUILD_HASH"

[ -s "$OUTPUT" ] || {
    echo "embedded stdlib tlci builder emitted no image: $OUTPUT" >&2
    exit 1
}
