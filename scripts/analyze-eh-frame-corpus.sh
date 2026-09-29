#!/usr/bin/env sh
set -eu

# Rebuild the external .eh_frame corpus only when the exact pinned tools are
# available. Pure TypeLisp tests (src/compiler_eh_frame_tests.tl) consume
# checked-in bytes; this oracle proves where those bytes came from, that the
# tests embed exactly them, and that readelf and llvm-dwarfdump read the same
# records the codec decodes.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures/eh-frame"
TESTS="$ROOT/src/compiler_eh_frame_tests.tl"
AS_BIN=${EH_FRAME_AS:-as}
LD_BIN=${EH_FRAME_LD:-ld}
OBJCOPY_BIN=${EH_FRAME_OBJCOPY:-objcopy}
READELF_BIN=${EH_FRAME_READELF:-readelf}
GCC_BIN=${EH_FRAME_GCC:-gcc}
CLANG_BIN=${EH_FRAME_CLANG:-clang}
DWARFDUMP_BIN=${EH_FRAME_DWARFDUMP:-llvm-dwarfdump}

fail() {
    echo "eh-frame oracle: $*" >&2
    exit 1
}

require_version() {
    label=$1
    tool=$2
    expected=$3
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
    first_line=$($tool --version | sed -n '1p')
    case "$first_line" in
        *"$expected"*) ;;
        *) fail "$label must be $expected; found: $first_line" ;;
    esac
}

require_version assembler "$AS_BIN" 'GNU Binutils) 2.47'
require_version linker "$LD_BIN" 'GNU Binutils) 2.47'
require_version objcopy "$OBJCOPY_BIN" 'GNU Binutils) 2.47'
require_version readelf "$READELF_BIN" 'GNU Binutils) 2.47'
require_version gcc "$GCC_BIN" 'GCC) 16.2.1'
require_version clang "$CLANG_BIN" 'clang version 22.1.8'
command -v "$DWARFDUMP_BIN" >/dev/null 2>&1 || fail "required tool is unavailable: $DWARFDUMP_BIN"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-eh-frame.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT HUP INT TERM
# Keep a corrupted tool or input from turning this small oracle into
# unbounded work or output. Values are KiB for -f and seconds for -t.
ulimit -f 4096
ulimit -t 60

# check_bytes NAME FILE SHA256: the dumped section equals the pinned hex, its
# hash, and the hex the tests embed.
check_bytes() {
    name=$1
    file=$2
    hash=$3
    expected=$(tr -d '[:space:]' < "$FIXTURES/$name.expected")
    actual=$(od -An -tx1 -v "$file" | tr -d '[:space:]')
    [ "$actual" = "$expected" ] || fail "$name bytes differ from the pinned corpus"
    [ "$(sha256sum "$file" | awk '{print $1}')" = "$hash" ] || fail "$name hash mismatch"
    grep -F "\"$expected\"" "$TESTS" >/dev/null || fail "$name is not embedded verbatim in $TESTS"
}

"$AS_BIN" --64 -o "$WORK/basic.o" "$FIXTURES/basic.s.in"
"$OBJCOPY_BIN" --dump-section ".eh_frame=$WORK/basic.eh" "$WORK/basic.o"
check_bytes basic.eh_frame "$WORK/basic.eh" \
    25dc439bc8a0ff32f33669591cd9c6a1dc1e3040549356e6ffb06ec8ea06608a

"$LD_BIN" --eh-frame-hdr -e leaf -o "$WORK/basic" "$WORK/basic.o"
"$OBJCOPY_BIN" --dump-section ".eh_frame=$WORK/basic-linked.eh" \
    --dump-section ".eh_frame_hdr=$WORK/basic-linked.hdr" "$WORK/basic"
check_bytes basic-linked.eh_frame "$WORK/basic-linked.eh" \
    50e131b6dae3b683e6fb2ae67fff99151c5ef2297030b01da494a64f61444b20
check_bytes basic-linked.eh_frame_hdr "$WORK/basic-linked.hdr" \
    c8f51834f416331f694a1cac4a5d3bc0384640dde5806ea4ca0a04fa9c57296a
"$READELF_BIN" -SW "$WORK/basic" > "$WORK/sections"
grep -E '\.text +PROGBITS +0000000000401000 ' "$WORK/sections" >/dev/null ||
    fail "linked .text is not at 0x401000"
grep -E '\.eh_frame_hdr +PROGBITS +0000000000402000 ' "$WORK/sections" >/dev/null ||
    fail "linked .eh_frame_hdr is not at 0x402000"
grep -E '\.eh_frame +PROGBITS +0000000000402020 ' "$WORK/sections" >/dev/null ||
    fail "linked .eh_frame is not at 0x402020"

"$GCC_BIN" -O2 -c -o "$WORK/gcc.o" -x c "$FIXTURES/probe.c.in"
"$OBJCOPY_BIN" --dump-section ".eh_frame=$WORK/gcc.eh" "$WORK/gcc.o"
check_bytes gcc-O2.eh_frame "$WORK/gcc.eh" \
    9d1fd2c0f8dffb35cd2e02c1818268c0bf13f4d680785f14860c8a7a1cf1cbb1

"$CLANG_BIN" -O2 -c -o "$WORK/clang.o" -x c "$FIXTURES/probe.c.in"
"$OBJCOPY_BIN" --dump-section ".eh_frame=$WORK/clang.eh" "$WORK/clang.o"
check_bytes clang-O2.eh_frame "$WORK/clang.eh" \
    31a80ee70b618a4fc7beed1466e4ed80e8b4776639d4509a322a9158e06923ca

# The external readers see the records, relocation fields and ranges the
# tests assert on.
"$READELF_BIN" --debug-dump=frames "$WORK/basic.o" > "$WORK/basic.frames"
grep -F 'Augmentation:          "zR"' "$WORK/basic.frames" >/dev/null || fail "basic CIE is not zR"
grep -F 'Augmentation data:     1b' "$WORK/basic.frames" >/dev/null || fail "basic CIE is not pcrel|sdata4"
grep -F '00000018 0000000000000010 0000001c FDE cie=00000000 pc=0000000000000000..0000000000000004' \
    "$WORK/basic.frames" >/dev/null || fail "basic first FDE"
grep -F '0000002c 0000000000000028 00000030 FDE cie=00000000 pc=0000000000000004..000000000000001f' \
    "$WORK/basic.frames" >/dev/null || fail "basic second FDE"
grep -F 'DW_CFA_remember_state' "$WORK/basic.frames" >/dev/null || fail "basic remembered state"
"$READELF_BIN" --debug-dump=frames "$WORK/basic" > "$WORK/linked.frames"
grep -F 'pc=0000000000401000..0000000000401004' "$WORK/linked.frames" >/dev/null || fail "linked first FDE"
grep -F 'pc=0000000000401004..000000000040101f' "$WORK/linked.frames" >/dev/null || fail "linked second FDE"
"$READELF_BIN" -rW "$WORK/gcc.o" > "$WORK/gcc.relocs"
for offset in 0x20 0x34 0x64; do
    grep -E "^$(printf '%016x' "$offset") +[0-9a-f]+ +R_X86_64_PC32 " "$WORK/gcc.relocs" >/dev/null ||
        fail "gcc .eh_frame relocation at $offset"
done
"$READELF_BIN" -rW "$WORK/clang.o" > "$WORK/clang.relocs"
for offset in 0x20 0x34 0x6c; do
    grep -E "^$(printf '%016x' "$offset") +[0-9a-f]+ +R_X86_64_PC32 " "$WORK/clang.relocs" >/dev/null ||
        fail "clang .eh_frame relocation at $offset"
done
"$DWARFDUMP_BIN" --eh-frame "$WORK/gcc.o" > "$WORK/gcc.dwarfdump"
grep -F 'FDE cie=00000000 pc=00000010...00000087' "$WORK/gcc.dwarfdump" >/dev/null || fail "gcc walk FDE"
grep -F 'FDE cie=00000000 pc=00000090...00000120' "$WORK/gcc.dwarfdump" >/dev/null || fail "gcc framed FDE"
"$DWARFDUMP_BIN" --eh-frame "$WORK/clang.o" > "$WORK/clang.dwarfdump"
grep -F 'FDE cie=00000000 pc=00000010...00000057' "$WORK/clang.dwarfdump" >/dev/null || fail "clang walk FDE"
grep -F 'FDE cie=00000000 pc=00000060...000000ea' "$WORK/clang.dwarfdump" >/dev/null || fail "clang framed FDE"

echo "eh-frame oracle: pinned GNU binutils 2.47, GCC 16.2.1 and Clang 22.1.8 corpus verified"
