#!/usr/bin/env sh
set -eu

# Rebuild the compact external GNU SFrame v3 corpus only when the exact pinned
# binutils release is available.  Pure TypeLisp tests consume checked-in bytes;
# this gate independently proves where those bytes came from.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures/sframe-v3"
AS_BIN=${SFRAME_AS:-as}
OBJCOPY_BIN=${SFRAME_OBJCOPY:-objcopy}
READELF_BIN=${SFRAME_READELF:-readelf}
LD_BIN=${SFRAME_LD:-ld}
EXPECTED_VERSION='2.47'

require_tool() {
    tool=$1
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "sframe-v3 oracle: required tool is unavailable: $tool" >&2
        exit 1
    fi
}

require_version() {
    label=$1
    tool=$2
    first_line=$($tool --version | sed -n '1p')
    case "$first_line" in
        *"GNU Binutils"*" $EXPECTED_VERSION"*) ;;
        *)
            echo "sframe-v3 oracle: $label must be GNU binutils $EXPECTED_VERSION" >&2
            echo "sframe-v3 oracle: found: $first_line" >&2
            exit 1
            ;;
    esac
}

for tool in "$AS_BIN" "$OBJCOPY_BIN" "$READELF_BIN" "$LD_BIN"; do
    require_tool "$tool"
done
require_version assembler "$AS_BIN"
require_version objcopy "$OBJCOPY_BIN"
require_version readelf "$READELF_BIN"
require_version linker "$LD_BIN"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-sframe-v3.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT HUP INT TERM

# Keep a corrupted tool or input from turning this tiny oracle into unbounded
# work or output.  Values are KiB for -f and seconds for -t.
ulimit -f 1024
ulimit -t 30

"$AS_BIN" --64 -o "$WORK/basic.o" \
    "$FIXTURES/binutils-2.47-amd64-le-v1-basic.s.in"
"$OBJCOPY_BIN" --dump-section ".sframe=$WORK/basic.sframe" "$WORK/basic.o"

expected_hex=$(tr -d '[:space:]' \
    < "$FIXTURES/binutils-2.47-amd64-le-v1-basic.expected")
actual_hex=$(od -An -tx1 -v "$WORK/basic.sframe" | tr -d '[:space:]')
if [ "$actual_hex" != "$expected_hex" ]; then
    echo "sframe-v3 oracle: relocatable .sframe bytes differ from the pinned corpus" >&2
    exit 1
fi
actual_hash=$(sha256sum "$WORK/basic.sframe" | awk '{print $1}')
if [ "$actual_hash" != cee03053d626fd2eeb378ce7a8c0fda1532ac2df389456697d231d91cc33a9b6 ]; then
    echo "sframe-v3 oracle: relocatable .sframe hash mismatch" >&2
    exit 1
fi

"$READELF_BIN" --sframe "$WORK/basic.o" > "$WORK/object.readelf"
grep -F 'Version: SFRAME_VERSION_3' "$WORK/object.readelf" >/dev/null
grep -F 'Flags: SFRAME_F_FDE_FUNC_START_PCREL' "$WORK/object.readelf" >/dev/null
grep -F 'Num FDEs: 2' "$WORK/object.readelf" >/dev/null
grep -F 'Num FREs: 5' "$WORK/object.readelf" >/dev/null
grep -F 'func idx [1]: pc = 0x2, size = 7 bytes' "$WORK/object.readelf" >/dev/null

"$LD_BIN" -o "$WORK/basic" "$WORK/basic.o" 2> "$WORK/link.stderr"
"$OBJCOPY_BIN" --dump-section ".sframe=$WORK/basic-linked.sframe" "$WORK/basic"
expected_linked_hex=$(tr -d '[:space:]' \
    < "$FIXTURES/binutils-2.47-amd64-le-v1-basic-linked.expected")
actual_linked_hex=$(od -An -tx1 -v "$WORK/basic-linked.sframe" | tr -d '[:space:]')
if [ "$actual_linked_hex" != "$expected_linked_hex" ]; then
    echo "sframe-v3 oracle: linked .sframe bytes differ from the pinned corpus" >&2
    exit 1
fi
linked_hash=$(sha256sum "$WORK/basic-linked.sframe" | awk '{print $1}')
if [ "$linked_hash" != 67c5f5fa9c08b3f08e631d652a12412ba039d0376ac485e153356d43cea38bae ]; then
    echo "sframe-v3 oracle: linked .sframe hash mismatch" >&2
    exit 1
fi

"$READELF_BIN" --sframe "$WORK/basic" > "$WORK/linked.readelf"
grep -F 'SFRAME_F_FDE_SORTED' "$WORK/linked.readelf" >/dev/null
grep -F 'SFRAME_F_FDE_FUNC_START_PCREL' "$WORK/linked.readelf" >/dev/null
grep -F 'func idx [0]: pc = 0x401000, size = 2 bytes' "$WORK/linked.readelf" >/dev/null
grep -F 'func idx [1]: pc = 0x401002, size = 7 bytes' "$WORK/linked.readelf" >/dev/null

echo "sframe-v3 oracle: GNU binutils $EXPECTED_VERSION corpus verified"
