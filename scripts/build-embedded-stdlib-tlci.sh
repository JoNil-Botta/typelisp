#!/usr/bin/env sh
set -eu

# Build the host-native stdlib comptime image catalog consumed by include-bin.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-build-provenance.sh"

# The source hash below goes through `git hash-object`, which needs a resolvable
# repository; check up front rather than dying partway through the build.
build_provenance_require_repository "$0"

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
SURFACE="$WORKDIR/prelude-surface-$HOST_TARGET.rodata"
SOURCE_HASH_FILE="$WORKDIR/source-hash.txt"
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
' src/compiler_embedded_stdlib_payload.tl > "$MANIFEST"

if PRODUCER_IDENTITY=$($COMPILER --producer-identity 2>/dev/null); then
    :
else
    # Transition fallback for the previously published stage0, which reports
    # the same deterministic source identity through `--version` but predates
    # the dedicated machine-readable command.
    PRODUCER_VERSION=$($COMPILER --version 2>/dev/null) || {
        echo "cannot read producer identity from compiler: $COMPILER" >&2
        exit 1
    }
    PRODUCER_IDENTITY=$(printf '%s\n' "$PRODUCER_VERSION" | awk 'NR == 1 && $1 == "typelisp" { print $2 }')
fi
if ! printf '%s\n' "$PRODUCER_IDENTITY" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "compiler reported malformed producer identity: $PRODUCER_IDENTITY" >&2
    exit 1
fi
SOURCE_HASH=$(
    while IFS= read -r MODULE_PATH; do
        SOURCE_PATH="$ROOT/stdlib/$MODULE_PATH"
        [ -f "$SOURCE_PATH" ] || {
            echo "embedded stdlib module is missing: $SOURCE_PATH" >&2
            exit 1
        }
        SOURCE_SIZE=$(wc -c < "$SOURCE_PATH" | tr -d ' ')
        printf '%s\000%s\000' "$MODULE_PATH" "$SOURCE_SIZE"
        cat "$SOURCE_PATH"
    done < "$MANIFEST" | git hash-object --stdin
)
printf '%s' "$SOURCE_HASH" > "$SOURCE_HASH_FILE"
"$COMPILER" run tools/embedded-stdlib-tlci/build-surface.tl \
    --stdlib-root stdlib --stdlib-root src \
    --cfg compiler-surface-producer -- \
    stdlib "$SURFACE" "$HOST_TARGET" "$PRODUCER_IDENTITY" "$SOURCE_HASH"
"$COMPILER" run tools/embedded-stdlib-tlci/build.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$MANIFEST" stdlib "$OUTPUT" "$HOST_TARGET" "$PRODUCER_IDENTITY" "$SURFACE"

[ -s "$OUTPUT" ] || {
    echo "embedded stdlib tlci builder emitted no image: $OUTPUT" >&2
    exit 1
}
