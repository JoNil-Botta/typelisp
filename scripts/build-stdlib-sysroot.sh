#!/usr/bin/env sh
set -eu

# build-stdlib-sysroot.sh - build the prebuilt stdlib sysroot (`stdlib.tli` +
# `libstdlib.a`) from a single checked pass of the embedded stdlib.
#
# usage:
#   scripts/build-stdlib-sysroot.sh <compiler> <out-dir> \
#       [--target <linux-x86_64|windows-x86_64>] [--opt-level <0|1|2>] [--jobs <N>]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
. "$ROOT/scripts/lib-ci-compiler-artifact.sh"
. "$ROOT/scripts/lib-bounded-pool.sh"

usage() {
    cat >&2 <<'EOF'
usage: scripts/build-stdlib-sysroot.sh <compiler> <out-dir> [options]

Builds <out-dir>/lib/<triple>/stdlib.tli and <out-dir>/lib/<triple>/libstdlib.a
from a single typecheck + lower pass over the embedded stdlib.

Options:
  --target <linux-x86_64|windows-x86_64>  Target platform (default: host target)
  --opt-level <0|1|2>                     Optimization level (default: 2)
  --jobs <N>                              Parallel assembly jobs (default: auto)
EOF
}

if [ "$#" -lt 2 ]; then
    usage
    exit 2
fi

COMPILER=$1
OUT_DIR=$2
shift 2

TARGET=$NL_BOOTSTRAP_TARGET
OPT_LEVEL=2
JOBS=${TYPELISP_SYSROOT_JOBS:-}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            TARGET=$2
            shift 2
            ;;
        --opt-level)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            OPT_LEVEL=$2
            shift 2
            ;;
        --jobs)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            JOBS=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "build-stdlib-sysroot: unexpected argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

case "$TARGET" in
    linux-x86_64)
        TRIPLE=x86_64-unknown-linux-gnu
        TARGET_OBJ_EXT=o
        ;;
    windows-x86_64)
        TRIPLE=x86_64-pc-windows-msvc
        TARGET_OBJ_EXT=obj
        ;;
    *)
        echo "build-stdlib-sysroot: unsupported target: $TARGET" >&2
        exit 2
        ;;
esac

case "$OPT_LEVEL" in
    0 | 1 | 2) ;;
    *)
        echo "build-stdlib-sysroot: unsupported opt-level: $OPT_LEVEL" >&2
        exit 2
        ;;
esac

if [ -z "$JOBS" ]; then
    if command -v nproc >/dev/null 2>&1; then
        JOBS=$(nproc)
    else
        JOBS=4
    fi
    if [ "$JOBS" -gt 8 ]; then
        JOBS=8
    fi
fi
case "$JOBS" in
    '' | *[!0-9]* | 0*)
        echo "build-stdlib-sysroot: --jobs must be a positive integer: $JOBS" >&2
        exit 2
        ;;
esac

case "$COMPILER" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
case "$OUT_DIR" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) OUT_DIR="$ROOT/$OUT_DIR" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "build-stdlib-sysroot: compiler is not executable: $COMPILER" >&2
    exit 1
fi

# Configure host toolchain for building the host-runnable builder tool.
configure_toolchain

# Check target assembler + deterministic archiver before doing heavy work.
TARGET_CLANG=
TARGET_AR=
TARGET_AR_KIND=
if [ "$TARGET" = linux-x86_64 ]; then
    command -v as >/dev/null 2>&1 || fail "build-stdlib-sysroot: linux target requires 'as'"
    command -v ar >/dev/null 2>&1 || fail "build-stdlib-sysroot: linux target requires 'ar'"
    TARGET_AR=ar
    TARGET_AR_KIND=gnu
else
    if [ -n "${TYPELISP_WINDOWS_CLANG_POSIX:-}" ]; then
        TARGET_CLANG=$TYPELISP_WINDOWS_CLANG_POSIX
    elif [ -n "${TYPELISP_WINDOWS_CLANG:-}" ]; then
        TARGET_CLANG=$(to_unix_path "$TYPELISP_WINDOWS_CLANG")
    else
        TARGET_CLANG=$(find_clang) || fail "build-stdlib-sysroot: windows target requires 'clang'"
    fi
    TARGET_CLANG_RESOLVED=$TARGET_CLANG
    case "$TARGET_CLANG_RESOLVED" in
        */*) ;;
        *)
            TARGET_CLANG_RESOLVED=$(command -v "$TARGET_CLANG_RESOLVED" 2>/dev/null || printf '%s' "$TARGET_CLANG_RESOLVED")
            ;;
    esac
    TARGET_CLANG_DIR=$(dirname -- "$TARGET_CLANG_RESOLVED")
    if [ -x "$TARGET_CLANG_DIR/llvm-ar.exe" ]; then
        TARGET_AR="$TARGET_CLANG_DIR/llvm-ar.exe"
        TARGET_AR_KIND=llvm-coff
    elif [ -x "$TARGET_CLANG_DIR/llvm-ar" ]; then
        TARGET_AR="$TARGET_CLANG_DIR/llvm-ar"
        TARGET_AR_KIND=llvm-coff
    elif command -v llvm-ar >/dev/null 2>&1; then
        TARGET_AR=$(command -v llvm-ar)
        TARGET_AR_KIND=llvm-coff
    elif command -v llvm-ar.exe >/dev/null 2>&1; then
        TARGET_AR=$(command -v llvm-ar.exe)
        TARGET_AR_KIND=llvm-coff
    elif command -v lib.exe >/dev/null 2>&1; then
        TARGET_AR=$(command -v lib.exe)
        TARGET_AR_KIND=msvc-lib
    else
        fail "build-stdlib-sysroot: windows target requires 'llvm-ar' or 'lib.exe'"
    fi
fi

# Query target compiler's producer identity so stdlib.tli matches it exactly.
if PRODUCER_IDENTITY=$("$COMPILER" --producer-identity 2>/dev/null); then
    PRODUCER_IDENTITY=$(printf '%s' "$PRODUCER_IDENTITY" | tr -d '\r\n')
else
    PRODUCER_IDENTITY=unknown
fi
if [ -z "$PRODUCER_IDENTITY" ]; then
    echo "build-stdlib-sysroot: compiler reported empty producer identity: $COMPILER" >&2
    exit 1
fi

# Include embedded-stdlib-tlci in the host builder tool when building for the
# host target and the canonical embedded TLCI image is present.
TLCI_CFG_ARGS=
TLCI_HASH=none
if [ "$TARGET" = "$NL_BOOTSTRAP_TARGET" ] &&
    [ "${TYPELISP_SYSROOT_NO_TLCI:-0}" != 1 ] &&
    [ -s "$ROOT/target/embedded-stdlib-tlci/stdlib.tlci" ] &&
    [ -s "$ROOT/target/embedded-stdlib-tlci/stdlib.tlci.tlch" ] &&
    [ -s "$ROOT/target/embedded-stdlib-tlci/source-hash.txt" ]; then
    TLCI_CFG_ARGS="--cfg embedded-stdlib-tlci"
    TLCI_HASH=$(ci_compiler_artifact_sha256_stdin < "$ROOT/target/embedded-stdlib-tlci/stdlib.tlci")
fi

# Cache the compiled host builder tool under target/build-stdlib-sysroot/tools.
TOOL_SOURCE="tools/build-stdlib-sysroot/main.tl"
TOOL_SOURCE_HASHES=$(
    find -L "$ROOT/tools/build-stdlib-sysroot" "$ROOT/stdlib" "$ROOT/src" \
        -type f -exec sha256sum -- {} +
)
TOOL_SOURCE_HASH=$(printf '%s\n' "$TOOL_SOURCE_HASHES" | LC_ALL=C sort | ci_compiler_artifact_sha256_stdin)
COMPILER_HASH=$(ci_compiler_artifact_sha256_stdin < "$COMPILER")
TOOL_KEY=$(printf '%s\n' "$COMPILER_HASH" "$TOOL_SOURCE_HASH" "$NL_HOST_OS" "$TLCI_HASH" "tool-opt-1" |
    ci_compiler_artifact_sha256_stdin)
TOOL_CACHE="$ROOT/target/build-stdlib-sysroot/tools/$TOOL_KEY"
BUILDER_BIN="$TOOL_CACHE/build-stdlib-sysroot$NL_BIN_EXT"

if [ ! -x "$BUILDER_BIN" ]; then
    mkdir -p "$TOOL_CACHE/lock"
    bounded_pool_lock "$TOOL_CACHE/lock"
    TOOL_TEMP=
    cleanup_tool_build() {
        [ -z "$TOOL_TEMP" ] || rm -rf -- "$TOOL_TEMP"
        bounded_pool_unlock "$TOOL_CACHE/lock"
    }
    trap cleanup_tool_build EXIT
    trap 'exit 1' HUP INT TERM
    if [ ! -x "$BUILDER_BIN" ]; then
        TOOL_TEMP=$(mktemp -d "$TOOL_CACHE/.build.XXXXXX")
        echo "[build-stdlib-sysroot] compiling builder tool ($NL_BOOTSTRAP_TARGET)"
        TYPELISP_SYSROOT=none "$COMPILER" compile "$TOOL_SOURCE" \
            -o "$TOOL_TEMP/builder.s" \
            --target "$NL_BOOTSTRAP_TARGET" \
            $(native_target_cfg_args) \
            --stdlib-root stdlib --stdlib-root src \
            --opt-level 1 \
            $TLCI_CFG_ARGS
        assemble_and_link "build-stdlib-sysroot" \
            "$TOOL_TEMP/builder.s" \
            "$TOOL_TEMP/builder.$NL_OBJ_EXT" \
            "$TOOL_TEMP/builder$NL_BIN_EXT"
        mv -- "$TOOL_TEMP/builder$NL_BIN_EXT" "$BUILDER_BIN"
    fi
    cleanup_tool_build
    trap - EXIT HUP INT TERM
fi

mkdir -p "$ROOT/target/build-stdlib-sysroot"
WORKDIR=$(mktemp -d "$ROOT/target/build-stdlib-sysroot/run.XXXXXX")
trap 'rm -rf -- "$WORKDIR"' EXIT HUP INT TERM

ASM_DIR="$WORKDIR/asm"
OBJ_DIR="$WORKDIR/obj"
MANIFEST="$WORKDIR/manifest.txt"
TLI_TMP="$WORKDIR/stdlib.tli"
LIB_TMP="$WORKDIR/libstdlib.a"
mkdir -p "$ASM_DIR" "$OBJ_DIR"

echo "[build-stdlib-sysroot] lowering and emitting per-module assembly ($TARGET, opt-level $OPT_LEVEL, producer=$PRODUCER_IDENTITY)"
"$BUILDER_BIN" "$TLI_TMP" "$ASM_DIR" "$MANIFEST" "$TARGET" "$OPT_LEVEL" "$PRODUCER_IDENTITY"

[ -s "$TLI_TMP" ] || fail "build-stdlib-sysroot: builder emitted no stdlib.tli"
[ -s "$MANIFEST" ] || fail "build-stdlib-sysroot: builder emitted empty module manifest"

echo "[build-stdlib-sysroot] assembling modules (jobs=$JOBS)"
ASM_QUEUE="$WORKDIR/asm-pool.queue"
ASM_POOL="$WORKDIR/asm-pool"
: > "$ASM_QUEUE"
while IFS= read -r asm_name; do
    [ -n "$asm_name" ] || continue
    printf '%s|1\n' "$asm_name" >> "$ASM_QUEUE"
done < "$MANIFEST"

bounded_pool_run_job() {
    _asm_file=$1
    _obj_file="${_asm_file%.s}.$TARGET_OBJ_EXT"
    if [ "$TARGET" = linux-x86_64 ]; then
        # Module assembly carries no .note.GNU-stack; mark every object
        # non-executable-stack so linking libstdlib.a stays warning-free.
        as --noexecstack "$ASM_DIR/$_asm_file" -o "$OBJ_DIR/$_obj_file"
    else
        "$TARGET_CLANG" --target=x86_64-pc-windows-msvc -c "$ASM_DIR/$_asm_file" -o "$OBJ_DIR/$_obj_file"
    fi
}

BOUNDED_POOL_LABEL=sysroot-asm
bounded_pool_init "$ASM_POOL" "$JOBS" "$ASM_QUEUE" || exit 1
bounded_pool_start "$ASM_POOL" "$JOBS"
bounded_pool_join "$ASM_POOL" || exit 1

echo "[build-stdlib-sysroot] archiving deterministic libstdlib.a ($TARGET_AR_KIND)"
rm -f "$LIB_TMP"
OBJ_LIST_FILE="$WORKDIR/objects.txt"
: > "$OBJ_LIST_FILE"
while IFS= read -r asm_name; do
    [ -n "$asm_name" ] || continue
    obj_name="${asm_name%.s}.$TARGET_OBJ_EXT"
    [ -s "$OBJ_DIR/$obj_name" ] || fail "build-stdlib-sysroot: missing assembled object $obj_name"
    printf '%s\n' "$obj_name" >> "$OBJ_LIST_FILE"
done < "$MANIFEST"

(
    cd "$OBJ_DIR"
    set --
    while IFS= read -r obj_name; do
        [ -n "$obj_name" ] || continue
        set -- "$@" "$obj_name"
    done < "$OBJ_LIST_FILE"
    case "$TARGET_AR_KIND" in
        gnu)
            "$TARGET_AR" rcsD "$LIB_TMP" "$@"
            ;;
        llvm-coff)
            "$TARGET_AR" --format=coff rcsD "$LIB_TMP" "$@"
            ;;
        msvc-lib)
            lib_tmp_win=$(to_windows_path "$LIB_TMP")
            MSYS2_ARG_CONV_EXCL='*' "$TARGET_AR" /NOLOGO /Brepro "/OUT:$lib_tmp_win" "$@"
            ;;
    esac
)

[ -s "$LIB_TMP" ] || fail "build-stdlib-sysroot: archiver emitted empty libstdlib.a"
chmod 0644 "$TLI_TMP" "$LIB_TMP" 2>/dev/null || true

if [ "$TARGET" = linux-x86_64 ] && command -v nm >/dev/null 2>&1; then
    DOTL_UNDEF=$(nm -u "$LIB_TMP" 2>/dev/null | grep -E '(^|[[:space:]])\.L_' || true)
    if [ -n "$DOTL_UNDEF" ]; then
        printf '%s\n' "$DOTL_UNDEF" | head -n 20 >&2
        fail "build-stdlib-sysroot: archive contains undefined assembler-local .L_* symbols"
    fi
elif [ "$TARGET" = windows-x86_64 ] && command -v llvm-nm >/dev/null 2>&1; then
    DOTL_UNDEF=$(llvm-nm -u "$LIB_TMP" 2>/dev/null | grep -E '(^|[[:space:]])\.L_' || true)
    if [ -n "$DOTL_UNDEF" ]; then
        printf '%s\n' "$DOTL_UNDEF" | head -n 20 >&2
        fail "build-stdlib-sysroot: Win64 archive contains undefined assembler-local .L_* symbols"
    fi
fi

DEST_DIR="$OUT_DIR/lib/$TRIPLE"
mkdir -p "$DEST_DIR"
mv -f "$TLI_TMP" "$DEST_DIR/stdlib.tli"
mv -f "$LIB_TMP" "$DEST_DIR/libstdlib.a"

echo "[build-stdlib-sysroot] verifying sysroot via inspect ($TARGET)"
"$COMPILER" inspect sysroot --sysroot "$OUT_DIR" --target "$TARGET" > "$WORKDIR/inspect.txt"
MOD_COUNT=$(awk '$1 == "modules:" { print $2 }' "$WORKDIR/inspect.txt" | tr -d '\r')
echo "[build-stdlib-sysroot] installed $DEST_DIR/stdlib.tli and $DEST_DIR/libstdlib.a (modules=$MOD_COUNT)"
