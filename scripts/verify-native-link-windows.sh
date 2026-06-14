#!/usr/bin/env sh
set -eu

# verify-native-link-windows.sh - Windows native link
# smoke for compiler-owned MSVC link.exe discovery and lld-link fallback.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    Linux*) HOST_OS=linux ;;
    *)
        echo "windows native link smoke is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

if [ "$HOST_OS" != windows ]; then
    echo "windows native link smoke is Windows-only"
    exit 0
fi

COMPILER=${TYPELISP_BIN:-}
if [ -z "$COMPILER" ]; then
    echo "windows native link smoke requires TYPELISP_BIN" >&2
    exit 1
fi
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

fail() {
    echo "$*" >&2
    exit 1
}

to_unix_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1"
    else
        printf '%s\n' "$1"
    fi
}

to_windows_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s\n' "$1"
    fi
}

short_windows_path() {
    if command -v cygpath >/dev/null 2>&1; then
        short_path=$(cygpath -d "$1" 2>/dev/null || true)
        if [ -n "$short_path" ]; then
            printf '%s\n' "$short_path"
            return 0
        fi
    fi
    to_windows_path "$1"
}

resolve_windows_archiver() {
    if [ -n "${TYPELISP_WINDOWS_LIB:-}" ]; then
        to_unix_path "$TYPELISP_WINDOWS_LIB"
        return 0
    fi
    if command -v llvm-lib >/dev/null 2>&1; then
        command -v llvm-lib
        return 0
    fi
    if command -v llvm-lib.exe >/dev/null 2>&1; then
        command -v llvm-lib.exe
        return 0
    fi
    if command -v lib.exe >/dev/null 2>&1; then
        command -v lib.exe
        return 0
    fi

    return 1
}

resolve_lld_link_command() {
    if command -v lld-link >/dev/null 2>&1; then
        printf '%s\n' "lld-link"
        return 0
    fi
    if command -v lld-link.exe >/dev/null 2>&1; then
        printf '%s\n' "lld-link.exe"
        return 0
    fi

    return 1
}

find_clang() {
    if command -v clang.exe >/dev/null 2>&1; then
        command -v clang.exe
        return 0
    fi
    if command -v clang >/dev/null 2>&1; then
        command -v clang
        return 0
    fi

    for candidate_dir in \
        "/c/Program Files/LLVM/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Professional/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/Llvm/x64/bin"; do
        if [ -x "$candidate_dir/clang.exe" ]; then
            printf '%s\n' "$candidate_dir/clang.exe"
            return 0
        fi
    done

    if command -v powershell.exe >/dev/null 2>&1; then
        ps_clang=$(powershell.exe -NoProfile -Command '$cmd = Get-Command clang.exe -ErrorAction SilentlyContinue; if ($cmd) { $cmd.Source }' |
            tr -d '\r' |
            sed -n '1p')
        if [ -n "$ps_clang" ]; then
            to_unix_path "$ps_clang"
            return 0
        fi
    fi

    return 1
}

assert_empty() {
    file=$1
    [ ! -s "$file" ] || {
        echo "expected empty file: $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    }
}

assert_contains() {
    file=$1
    needle=$2
    if ! grep -qF "$needle" "$file"; then
        echo "expected '$needle' in $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    fi
}

if [ -z "${TYPELISP_WINDOWS_CLANG:-}" ]; then
    CLANG_PATH=$(find_clang || true)
    if [ -z "$CLANG_PATH" ]; then
        fail "missing assembler: clang"
    fi
    TYPELISP_WINDOWS_CLANG=$(short_windows_path "$CLANG_PATH")
fi
case "$TYPELISP_WINDOWS_CLANG" in
    *" "*) fail "assembler path contains spaces after short-path conversion: $TYPELISP_WINDOWS_CLANG" ;;
esac
export TYPELISP_WINDOWS_CLANG
echo "[windows-native-link] assembler=$TYPELISP_WINDOWS_CLANG"

run_windows_link_smoke() {
    SMOKE_NAME=$1
    FORCED_LINK=$2

    if [ -n "$FORCED_LINK" ]; then
        TYPELISP_WINDOWS_LINK=$FORCED_LINK
        export TYPELISP_WINDOWS_LINK
        echo "[windows-native-link:$SMOKE_NAME] linker override=$TYPELISP_WINDOWS_LINK"
    else
        unset TYPELISP_WINDOWS_LINK LIB INCLUDE WindowsSdkDir WindowsSDKVersion VCToolsInstallDir VCToolsVersion
        echo "[windows-native-link:$SMOKE_NAME] linker=compiler auto-discovery"
    fi

    WORKDIR="$ROOT/target/native-link-windows-$SMOKE_NAME"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    SRC="$WORKDIR/tiny.tl"
    BIN="$WORKDIR/tiny.exe"
    BIN_DISPLAY=$BIN
    if command -v cygpath >/dev/null 2>&1; then
        BIN_DISPLAY=$(cygpath -m "$BIN")
    fi

    cat > "$SRC" <<'EOF'
(define (main) : i64
  42)
EOF
echo "[windows-native-link] build --direct"
if ! "$COMPILER" build \
    --direct "$SRC" --target windows-x86_64 -o "$BIN" --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/build.stdout" 2> "$WORKDIR/build.stderr"; then
    sed 's/^/  /' "$WORKDIR/build.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/build.stderr" >&2 || true
    fail "selfhost build --direct failed"
fi
assert_contains "$WORKDIR/build.stdout" "Built $BIN_DISPLAY"
assert_empty "$WORKDIR/build.stderr"
[ -x "$BIN" ] || fail "selfhost build did not write executable $BIN"

set +e
"$BIN" > "$WORKDIR/built.stdout" 2> "$WORKDIR/built.stderr"
built_status=$?
set -e
if [ "$built_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/built.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/built.stderr" >&2 || true
    fail "built executable expected exit 42, got $built_status"
fi
assert_empty "$WORKDIR/built.stdout"
assert_empty "$WORKDIR/built.stderr"

echo "[windows-native-link] run --direct"
set +e
"$COMPILER" run \
    --direct "$SRC" --target windows-x86_64 --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/run.stdout" 2> "$WORKDIR/run.stderr"
run_status=$?
set -e
if [ "$run_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/run.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/run.stderr" >&2 || true
    fail "selfhost run --direct expected exit 42, got $run_status"
fi
assert_empty "$WORKDIR/run.stdout"
assert_empty "$WORKDIR/run.stderr"

LINK_LIB_DIR="$WORKDIR/native-lib"
mkdir -p "$LINK_LIB_DIR"
cat > "$LINK_LIB_DIR/ffi_add7.s" <<'EOF'
    .text
    .globl ffi_add7
ffi_add7:
    movq %rcx, %rax
    addq $7, %rax
    retq

    .data
    .globl ffi_base_value
ffi_base_value:
    .quad 30

    .globl ffi_add7_ptr
ffi_add7_ptr:
    .quad ffi_add7
EOF
cat > "$WORKDIR/link-main.tl" <<'EOF'
(extern (ffi_add7 [x : i64]) : i64)
(define (main) : i64 (ffi_add7 35))
EOF
LINK_SRC="$WORKDIR/link-main.tl"
LINK_BIN="$WORKDIR/link-main.exe"
LINK_BIN_DISPLAY=$LINK_BIN
if command -v cygpath >/dev/null 2>&1; then
    LINK_BIN_DISPLAY=$(cygpath -m "$LINK_BIN")
fi

echo "[windows-native-link] create named link library"
ARCHIVER_PATH=$(resolve_windows_archiver || true)
if [ -z "$ARCHIVER_PATH" ]; then
    fail "missing archiver: llvm-lib (or configured lib.exe/TYPELISP_WINDOWS_LIB)"
fi
CLANG_RUN_PATH=$(find_clang || true)
if [ -z "$CLANG_RUN_PATH" ]; then
    CLANG_RUN_PATH=$TYPELISP_WINDOWS_CLANG
fi
"$CLANG_RUN_PATH" --target=x86_64-pc-windows-msvc -c \
    "$LINK_LIB_DIR/ffi_add7.s" -o "$LINK_LIB_DIR/ffi_add7.obj"
MSYS2_ARG_CONV_EXCL='*' "$ARCHIVER_PATH" /NOLOGO \
    "/OUT:$(to_windows_path "$LINK_LIB_DIR/ffi_add7.lib")" \
    "$(to_windows_path "$LINK_LIB_DIR/ffi_add7.obj")" \
    > "$WORKDIR/link-lib.stdout" 2> "$WORKDIR/link-lib.stderr"
assert_empty "$WORKDIR/link-lib.stderr"

LINK_SEARCH=$(to_windows_path "$LINK_LIB_DIR")
LINK_SEARCH_METADATA=$(printf '%s' "$LINK_SEARCH" | sed 's/\\/\\\\/g; s/"/\\"/g')

echo "[windows-native-link] build --direct --link-lib"
if ! "$COMPILER" build \
    --direct "$LINK_SRC" --target windows-x86_64 -o "$LINK_BIN" \
    --stdlib-root "$ROOT/stdlib" --link-search "$LINK_SEARCH" --link-lib ffi_add7 \
    > "$WORKDIR/build-link.stdout" 2> "$WORKDIR/build-link.stderr"; then
    sed 's/^/  /' "$WORKDIR/build-link.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/build-link.stderr" >&2 || true
    fail "selfhost build --direct --link-lib failed"
fi
assert_contains "$WORKDIR/build-link.stdout" "Built $LINK_BIN_DISPLAY"
assert_empty "$WORKDIR/build-link.stderr"
[ -x "$LINK_BIN" ] || fail "selfhost link-input build did not write executable $LINK_BIN"

set +e
"$LINK_BIN" > "$WORKDIR/built-link.stdout" 2> "$WORKDIR/built-link.stderr"
built_link_status=$?
set -e
if [ "$built_link_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/built-link.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/built-link.stderr" >&2 || true
    fail "linked executable expected exit 42, got $built_link_status"
fi
assert_empty "$WORKDIR/built-link.stdout"
assert_empty "$WORKDIR/built-link.stderr"

echo "[windows-native-link] run --direct --link-lib"
set +e
"$COMPILER" run \
    --direct "$LINK_SRC" --target windows-x86_64 --stdlib-root "$ROOT/stdlib" \
    --link-search "$LINK_SEARCH" --link-lib ffi_add7 \
    > "$WORKDIR/run-link.stdout" 2> "$WORKDIR/run-link.stderr"
run_link_status=$?
set -e
if [ "$run_link_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/run-link.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/run-link.stderr" >&2 || true
    fail "selfhost run --direct --link-lib expected exit 42, got $run_link_status"
fi
assert_empty "$WORKDIR/run-link.stdout"
assert_empty "$WORKDIR/run-link.stderr"

LINK_FNPTR_SRC="$WORKDIR/link-fnptr-main.tl"
cat > "$LINK_FNPTR_SRC" <<'EOF'
(extern base (:symbol "ffi_base_value") : i64)
(extern ffi_add7_ptr (:symbol "ffi_add7_ptr") : (-> i64 i64))
(define (main) : i64 (+ base (ffi_add7_ptr 5)))
EOF
LINK_FNPTR_BIN="$WORKDIR/link-fnptr-main.exe"
LINK_FNPTR_BIN_DISPLAY=$LINK_FNPTR_BIN
if command -v cygpath >/dev/null 2>&1; then
    LINK_FNPTR_BIN_DISPLAY=$(cygpath -m "$LINK_FNPTR_BIN")
fi

echo "[windows-native-link] build --direct extern function pointer"
if ! "$COMPILER" build \
    --direct "$LINK_FNPTR_SRC" --target windows-x86_64 -o "$LINK_FNPTR_BIN" \
    --stdlib-root "$ROOT/stdlib" --link-search "$LINK_SEARCH" --link-lib ffi_add7 \
    > "$WORKDIR/build-link-fnptr.stdout" 2> "$WORKDIR/build-link-fnptr.stderr"; then
    sed 's/^/  /' "$WORKDIR/build-link-fnptr.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/build-link-fnptr.stderr" >&2 || true
    fail "selfhost build --direct extern function pointer failed"
fi
assert_contains "$WORKDIR/build-link-fnptr.stdout" "Built $LINK_FNPTR_BIN_DISPLAY"
assert_empty "$WORKDIR/build-link-fnptr.stderr"
[ -x "$LINK_FNPTR_BIN" ] || fail "selfhost extern function-pointer build did not write executable $LINK_FNPTR_BIN"

set +e
"$LINK_FNPTR_BIN" > "$WORKDIR/built-link-fnptr.stdout" 2> "$WORKDIR/built-link-fnptr.stderr"
built_link_fnptr_status=$?
set -e
if [ "$built_link_fnptr_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/built-link-fnptr.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/built-link-fnptr.stderr" >&2 || true
    fail "extern function-pointer executable expected exit 42, got $built_link_fnptr_status"
fi
assert_empty "$WORKDIR/built-link-fnptr.stdout"
assert_empty "$WORKDIR/built-link-fnptr.stderr"

echo "[windows-native-link] run --direct extern function pointer"
set +e
"$COMPILER" run \
    --direct "$LINK_FNPTR_SRC" --target windows-x86_64 --stdlib-root "$ROOT/stdlib" \
    --link-search "$LINK_SEARCH" --link-lib ffi_add7 \
    > "$WORKDIR/run-link-fnptr.stdout" 2> "$WORKDIR/run-link-fnptr.stderr"
run_link_fnptr_status=$?
set -e
if [ "$run_link_fnptr_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/run-link-fnptr.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/run-link-fnptr.stderr" >&2 || true
    fail "selfhost run --direct extern function pointer expected exit 42, got $run_link_fnptr_status"
fi
assert_empty "$WORKDIR/run-link-fnptr.stdout"
assert_empty "$WORKDIR/run-link-fnptr.stderr"

LINK_METADATA_SRC="$WORKDIR/link-metadata-main.tl"
LINK_METADATA_MODULE="$WORKDIR/link-metadata-module.tl"
cat > "$LINK_METADATA_MODULE" <<EOF
(extern (ffi_add7 [x : i64]) : i64 (:link-search "$LINK_SEARCH_METADATA") (:link-lib "ffi_add7"))
EOF
cat > "$LINK_METADATA_SRC" <<'EOF'
(import "link-metadata-module.tl")
(define (main) : i64 (ffi_add7 35))
EOF
LINK_METADATA_BIN="$WORKDIR/link-metadata-main.exe"
LINK_METADATA_BIN_DISPLAY=$LINK_METADATA_BIN
if command -v cygpath >/dev/null 2>&1; then
    LINK_METADATA_BIN_DISPLAY=$(cygpath -m "$LINK_METADATA_BIN")
fi

echo "[windows-native-link] build --direct extern link metadata"
if ! "$COMPILER" build \
    --direct "$LINK_METADATA_SRC" --target windows-x86_64 -o "$LINK_METADATA_BIN" \
    --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/build-link-metadata.stdout" 2> "$WORKDIR/build-link-metadata.stderr"; then
    sed 's/^/  /' "$WORKDIR/build-link-metadata.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/build-link-metadata.stderr" >&2 || true
    fail "selfhost build --direct extern link metadata failed"
fi
assert_contains "$WORKDIR/build-link-metadata.stdout" "Built $LINK_METADATA_BIN_DISPLAY"
assert_empty "$WORKDIR/build-link-metadata.stderr"
[ -x "$LINK_METADATA_BIN" ] || fail "selfhost metadata link-input build did not write executable $LINK_METADATA_BIN"

set +e
"$LINK_METADATA_BIN" > "$WORKDIR/built-link-metadata.stdout" 2> "$WORKDIR/built-link-metadata.stderr"
built_link_metadata_status=$?
set -e
if [ "$built_link_metadata_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/built-link-metadata.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/built-link-metadata.stderr" >&2 || true
    fail "metadata linked executable expected exit 42, got $built_link_metadata_status"
fi
assert_empty "$WORKDIR/built-link-metadata.stdout"
assert_empty "$WORKDIR/built-link-metadata.stderr"

echo "[windows-native-link] run --direct extern link metadata"
set +e
"$COMPILER" run \
    --direct "$LINK_METADATA_SRC" --target windows-x86_64 --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/run-link-metadata.stdout" 2> "$WORKDIR/run-link-metadata.stderr"
run_link_metadata_status=$?
set -e
if [ "$run_link_metadata_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/run-link-metadata.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/run-link-metadata.stderr" >&2 || true
    fail "selfhost run --direct extern link metadata expected exit 42, got $run_link_metadata_status"
fi
assert_empty "$WORKDIR/run-link-metadata.stdout"
assert_empty "$WORKDIR/run-link-metadata.stderr"

PUBLIC_LINK_BIN="$WORKDIR/public-link-main.exe"
PUBLIC_LINK_BIN_DISPLAY=$PUBLIC_LINK_BIN
if command -v cygpath >/dev/null 2>&1; then
    PUBLIC_LINK_BIN_DISPLAY=$(cygpath -m "$PUBLIC_LINK_BIN")
fi

echo "[windows-native-link] public build --link-lib"
if ! "$COMPILER" build "$LINK_SRC" --target windows-x86_64 -o "$PUBLIC_LINK_BIN" \
    --stdlib-root "$ROOT/stdlib" --link-search "$LINK_SEARCH" --link-lib ffi_add7 \
    > "$WORKDIR/public-build-link.stdout" 2> "$WORKDIR/public-build-link.stderr"; then
    sed 's/^/  /' "$WORKDIR/public-build-link.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/public-build-link.stderr" >&2 || true
    fail "public build --link-lib failed"
fi
assert_contains "$WORKDIR/public-build-link.stdout" "Built $PUBLIC_LINK_BIN_DISPLAY"
assert_empty "$WORKDIR/public-build-link.stderr"

set +e
"$PUBLIC_LINK_BIN" > "$WORKDIR/public-built-link.stdout" 2> "$WORKDIR/public-built-link.stderr"
public_built_link_status=$?
set -e
if [ "$public_built_link_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/public-built-link.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/public-built-link.stderr" >&2 || true
    fail "public linked executable expected exit 42, got $public_built_link_status"
fi
assert_empty "$WORKDIR/public-built-link.stdout"
assert_empty "$WORKDIR/public-built-link.stderr"

echo "[windows-native-link] public run --link-lib"
set +e
"$COMPILER" run "$LINK_SRC" --target windows-x86_64 --stdlib-root "$ROOT/stdlib" \
    --link-search "$LINK_SEARCH" --link-lib ffi_add7 \
    > "$WORKDIR/public-run-link.stdout" 2> "$WORKDIR/public-run-link.stderr"
public_run_link_status=$?
set -e
if [ "$public_run_link_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/public-run-link.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/public-run-link.stderr" >&2 || true
    fail "public run --link-lib expected exit 42, got $public_run_link_status"
fi
assert_empty "$WORKDIR/public-run-link.stdout"
assert_empty "$WORKDIR/public-run-link.stderr"

PUBLIC_LINK_METADATA_BIN="$WORKDIR/public-link-metadata-main.exe"
PUBLIC_LINK_METADATA_BIN_DISPLAY=$PUBLIC_LINK_METADATA_BIN
if command -v cygpath >/dev/null 2>&1; then
    PUBLIC_LINK_METADATA_BIN_DISPLAY=$(cygpath -m "$PUBLIC_LINK_METADATA_BIN")
fi

echo "[windows-native-link] public build extern link metadata"
if ! "$COMPILER" build "$LINK_METADATA_SRC" --target windows-x86_64 \
    -o "$PUBLIC_LINK_METADATA_BIN" --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/public-build-link-metadata.stdout" 2> "$WORKDIR/public-build-link-metadata.stderr"; then
    sed 's/^/  /' "$WORKDIR/public-build-link-metadata.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/public-build-link-metadata.stderr" >&2 || true
    fail "public build extern link metadata failed"
fi
assert_contains "$WORKDIR/public-build-link-metadata.stdout" "Built $PUBLIC_LINK_METADATA_BIN_DISPLAY"
assert_empty "$WORKDIR/public-build-link-metadata.stderr"

set +e
"$PUBLIC_LINK_METADATA_BIN" > "$WORKDIR/public-built-link-metadata.stdout" 2> "$WORKDIR/public-built-link-metadata.stderr"
public_built_link_metadata_status=$?
set -e
if [ "$public_built_link_metadata_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/public-built-link-metadata.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/public-built-link-metadata.stderr" >&2 || true
    fail "public metadata linked executable expected exit 42, got $public_built_link_metadata_status"
fi
assert_empty "$WORKDIR/public-built-link-metadata.stdout"
assert_empty "$WORKDIR/public-built-link-metadata.stderr"

echo "[windows-native-link] public run extern link metadata"
set +e
"$COMPILER" run "$LINK_METADATA_SRC" --target windows-x86_64 --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/public-run-link-metadata.stdout" 2> "$WORKDIR/public-run-link-metadata.stderr"
public_run_link_metadata_status=$?
set -e
if [ "$public_run_link_metadata_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/public-run-link-metadata.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/public-run-link-metadata.stderr" >&2 || true
    fail "public run extern link metadata expected exit 42, got $public_run_link_metadata_status"
fi
assert_empty "$WORKDIR/public-run-link-metadata.stdout"
assert_empty "$WORKDIR/public-run-link-metadata.stderr"

echo "[windows-native-link:$SMOKE_NAME] smoke passed"
}

run_windows_link_smoke msvc-auto ""

LLD_LINK_COMMAND=$(resolve_lld_link_command || true)
if [ -z "$LLD_LINK_COMMAND" ]; then
    fail "missing linker fallback: lld-link"
fi
run_windows_link_smoke lld-link "$LLD_LINK_COMMAND"

echo "windows native link smoke passed"
