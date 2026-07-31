#!/usr/bin/env sh
set -eu

# verify-native-link-windows.sh - Windows native link and archive smoke for
# compiler-owned MSVC tool discovery and LLVM fallbacks.

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

resolve_llvm_ar() {
    if command -v llvm-ar >/dev/null 2>&1; then
        command -v llvm-ar
        return 0
    fi
    if command -v llvm-ar.exe >/dev/null 2>&1; then
        command -v llvm-ar.exe
        return 0
    fi

    for candidate_dir in \
        "/c/Program Files/LLVM/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Professional/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/Llvm/x64/bin"; do
        if [ -x "$candidate_dir/llvm-ar.exe" ]; then
            printf '%s\n' "$candidate_dir/llvm-ar.exe"
            return 0
        fi
    done

    if command -v powershell.exe >/dev/null 2>&1; then
        ps_llvm_ar=$(powershell.exe -NoProfile -Command '$cmd = Get-Command llvm-ar.exe -ErrorAction SilentlyContinue; if ($cmd) { $cmd.Source }' |
            tr -d '\r' |
            sed -n '1p')
        if [ -n "$ps_llvm_ar" ]; then
            to_unix_path "$ps_llvm_ar"
            return 0
        fi
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
(extern (unused-direct [value : i64]) : i64
  (:symbol "typelisp_unused_direct"))
(extern unused-data (:symbol "typelisp_unused_data") : i64)
(extern unused-fnptr (:symbol "typelisp_unused_fnptr") : (-> i64 i64))
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

NOASM_BIN="$WORKDIR/tiny-direct-object.exe"
NOASM_BIN_DISPLAY=$NOASM_BIN
if command -v cygpath >/dev/null 2>&1; then
    NOASM_BIN_DISPLAY=$(cygpath -m "$NOASM_BIN")
fi

echo "[windows-native-link] build --direct direct-object without assembler"
set +e
TYPELISP_WINDOWS_DIRECT_OBJECT=1 \
    TYPELISP_WINDOWS_CLANG=__typelisp_unexpected_assembler_fallback__.exe \
    "$COMPILER" build \
    --direct "$SRC" --target windows-x86_64 -o "$NOASM_BIN" \
    --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/build-direct-object.stdout" 2> "$WORKDIR/build-direct-object.stderr"
noasm_build_status=$?
set -e
if [ "$noasm_build_status" -ne 0 ]; then
    sed 's/^/  /' "$WORKDIR/build-direct-object.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/build-direct-object.stderr" >&2 || true
    fail "selfhost build --direct direct-object without assembler failed"
fi
assert_contains "$WORKDIR/build-direct-object.stdout" "Built $NOASM_BIN_DISPLAY"
assert_empty "$WORKDIR/build-direct-object.stderr"
[ -x "$NOASM_BIN" ] || fail "direct-object build did not write executable $NOASM_BIN"

set +e
"$NOASM_BIN" > "$WORKDIR/built-direct-object.stdout" 2> "$WORKDIR/built-direct-object.stderr"
noasm_built_status=$?
set -e
if [ "$noasm_built_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/built-direct-object.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/built-direct-object.stderr" >&2 || true
    fail "direct-object executable expected exit 42, got $noasm_built_status"
fi
assert_empty "$WORKDIR/built-direct-object.stdout"
assert_empty "$WORKDIR/built-direct-object.stderr"

echo "[windows-native-link] run --direct direct-object without assembler"
set +e
TYPELISP_WINDOWS_DIRECT_OBJECT=1 \
    TYPELISP_WINDOWS_CLANG=__typelisp_unexpected_assembler_fallback__.exe \
    "$COMPILER" run \
    --direct "$SRC" --target windows-x86_64 --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/run-direct-object.stdout" 2> "$WORKDIR/run-direct-object.stderr"
noasm_run_status=$?
set -e
if [ "$noasm_run_status" -ne 42 ]; then
    sed 's/^/  /' "$WORKDIR/run-direct-object.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/run-direct-object.stderr" >&2 || true
    fail "selfhost run --direct direct-object without assembler expected exit 42, got $noasm_run_status"
fi
assert_empty "$WORKDIR/run-direct-object.stdout"
assert_empty "$WORKDIR/run-direct-object.stderr"

TEST_SRC="$WORKDIR/tiny-test.tl"
cat > "$TEST_SRC" <<'EOF'
(cfg test (test direct-object-smoke unit))
EOF

echo "[windows-native-link] test direct-object without assembler"
set +e
TYPELISP_WINDOWS_DIRECT_OBJECT=1 \
    TYPELISP_WINDOWS_CLANG=__typelisp_unexpected_assembler_fallback__.exe \
    "$COMPILER" test "$TEST_SRC" --target windows-x86_64 --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/test-direct-object.stdout" 2> "$WORKDIR/test-direct-object.stderr"
noasm_test_status=$?
set -e
if [ "$noasm_test_status" -ne 0 ]; then
    sed 's/^/  /' "$WORKDIR/test-direct-object.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/test-direct-object.stderr" >&2 || true
    fail "selfhost test direct-object without assembler failed"
fi
assert_empty "$WORKDIR/test-direct-object.stdout"
assert_contains "$WORKDIR/test-direct-object.stderr" "TypeLisp tests: 1 passed; 0 failed; 1 total"

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
LLVM_AR_PATH=$(resolve_llvm_ar || true)
if [ -z "$LLVM_AR_PATH" ]; then
    fail "missing deterministic COFF archiver: llvm-ar"
fi
CLANG_RUN_PATH=$(find_clang || true)
if [ -z "$CLANG_RUN_PATH" ]; then
    CLANG_RUN_PATH=$TYPELISP_WINDOWS_CLANG
fi
"$CLANG_RUN_PATH" --target=x86_64-pc-windows-msvc -c \
    "$LINK_LIB_DIR/ffi_add7.s" -o "$LINK_LIB_DIR/ffi_add7.obj"
"$LLVM_AR_PATH" --format=coff rcsD \
    "$LINK_LIB_DIR/ffi_add7.lib" \
    "$LINK_LIB_DIR/ffi_add7.obj" \
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

run_windows_archive_smoke() {
    ARCHIVE_SMOKE_NAME=$1
    ARCHIVER_OVERRIDE=$2
    ARCHIVE_WORKDIR="$ROOT/target/native-archive-windows-$ARCHIVE_SMOKE_NAME"
    ARCHIVE_LIB_PKG="$ARCHIVE_WORKDIR/archive-lib"
    ARCHIVE_APP_PKG="$ARCHIVE_WORKDIR/archive-app"
    ARCHIVE_LIB="$ARCHIVE_LIB_PKG/target/release/archive_lib.lib"
    ARCHIVE_OBJ="$ARCHIVE_LIB_PKG/target/release/archive_lib.obj"
    ARCHIVE_APP="$ARCHIVE_APP_PKG/target/release/archive_app.exe"

    rm -rf "$ARCHIVE_WORKDIR"
    mkdir -p "$ARCHIVE_LIB_PKG/src" "$ARCHIVE_APP_PKG/src"
    cat > "$ARCHIVE_LIB_PKG/typelisp.pkg" <<'EOF'
(package
  (name "archive_lib")
  (version "0.1.0")
  (kind staticlib))
EOF
    cat > "$ARCHIVE_LIB_PKG/src/lib.tl" <<'EOF'
(define (archive-answer) : i64 42)
EOF
    cat > "$ARCHIVE_APP_PKG/typelisp.pkg" <<'EOF'
(package
  (name "archive_app")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (archive_lib "../archive-lib")))
EOF
    cat > "$ARCHIVE_APP_PKG/src/main.tl" <<'EOF'
(import "pkg:archive_lib/src/lib.tl")
(define (main) : i64 (archive-answer))
EOF

    if [ -n "$ARCHIVER_OVERRIDE" ]; then
        TYPELISP_WINDOWS_LIB=$ARCHIVER_OVERRIDE
        export TYPELISP_WINDOWS_LIB
        echo "[windows-native-archive:$ARCHIVE_SMOKE_NAME] archiver override=$TYPELISP_WINDOWS_LIB"
    else
        unset TYPELISP_WINDOWS_LIB
        echo "[windows-native-archive:$ARCHIVE_SMOKE_NAME] archiver=compiler auto-discovery"
    fi

    if ! "$COMPILER" build --manifest-path "$ARCHIVE_LIB_PKG/typelisp.pkg" \
        --target windows-x86_64 --opt-level 0 \
        > "$ARCHIVE_WORKDIR/build-first.stdout" \
        2> "$ARCHIVE_WORKDIR/build-first.stderr"; then
        sed 's/^/  /' "$ARCHIVE_WORKDIR/build-first.stdout" >&2 || true
        sed 's/^/  /' "$ARCHIVE_WORKDIR/build-first.stderr" >&2 || true
        fail "first deterministic archive build failed ($ARCHIVE_SMOKE_NAME)"
    fi
    assert_empty "$ARCHIVE_WORKDIR/build-first.stderr"
    [ -s "$ARCHIVE_LIB" ] || fail "archive build did not write $ARCHIVE_LIB"
    [ -s "$ARCHIVE_OBJ" ] || fail "archive build did not write $ARCHIVE_OBJ"
    cp "$ARCHIVE_LIB" "$ARCHIVE_WORKDIR/archive-first.lib"
    cp "$ARCHIVE_OBJ" "$ARCHIVE_WORKDIR/object-first.obj"

    rm -rf "$ARCHIVE_LIB_PKG/target"
    sleep 2
    if ! "$COMPILER" build --manifest-path "$ARCHIVE_LIB_PKG/typelisp.pkg" \
        --target windows-x86_64 --opt-level 0 \
        > "$ARCHIVE_WORKDIR/build-second.stdout" \
        2> "$ARCHIVE_WORKDIR/build-second.stderr"; then
        sed 's/^/  /' "$ARCHIVE_WORKDIR/build-second.stdout" >&2 || true
        sed 's/^/  /' "$ARCHIVE_WORKDIR/build-second.stderr" >&2 || true
        fail "second deterministic archive build failed ($ARCHIVE_SMOKE_NAME)"
    fi
    assert_empty "$ARCHIVE_WORKDIR/build-second.stderr"
    if ! cmp -s "$ARCHIVE_WORKDIR/object-first.obj" "$ARCHIVE_OBJ"; then
        fail "clean package builds produced different COFF object inputs ($ARCHIVE_SMOKE_NAME)"
    fi
    if ! cmp -s "$ARCHIVE_WORKDIR/archive-first.lib" "$ARCHIVE_LIB"; then
        fail "clean package builds produced nondeterministic .lib archives ($ARCHIVE_SMOKE_NAME)"
    fi

    if ! "$COMPILER" build --manifest-path "$ARCHIVE_APP_PKG/typelisp.pkg" \
        --target windows-x86_64 --opt-level 0 \
        > "$ARCHIVE_WORKDIR/build-consumer.stdout" \
        2> "$ARCHIVE_WORKDIR/build-consumer.stderr"; then
        sed 's/^/  /' "$ARCHIVE_WORKDIR/build-consumer.stdout" >&2 || true
        sed 's/^/  /' "$ARCHIVE_WORKDIR/build-consumer.stderr" >&2 || true
        fail "archive package consumer build failed ($ARCHIVE_SMOKE_NAME)"
    fi
    assert_empty "$ARCHIVE_WORKDIR/build-consumer.stderr"
    [ -x "$ARCHIVE_APP" ] || fail "archive package consumer did not write $ARCHIVE_APP"

    set +e
    "$ARCHIVE_APP" > "$ARCHIVE_WORKDIR/consumer.stdout" 2> "$ARCHIVE_WORKDIR/consumer.stderr"
    archive_consumer_status=$?
    set -e
    if [ "$archive_consumer_status" -ne 42 ]; then
        sed 's/^/  /' "$ARCHIVE_WORKDIR/consumer.stdout" >&2 || true
        sed 's/^/  /' "$ARCHIVE_WORKDIR/consumer.stderr" >&2 || true
        fail "archive package consumer expected exit 42, got $archive_consumer_status"
    fi
    assert_empty "$ARCHIVE_WORKDIR/consumer.stdout"
    assert_empty "$ARCHIVE_WORKDIR/consumer.stderr"
    echo "[windows-native-archive:$ARCHIVE_SMOKE_NAME] deterministic archive smoke passed"
}

run_windows_archive_override_rejection() {
    REJECT_WORKDIR="$ROOT/target/native-archive-windows-override-rejection"
    REJECT_PKG="$REJECT_WORKDIR/archive-lib"
    rm -rf "$REJECT_WORKDIR"
    mkdir -p "$REJECT_PKG/src"
    cat > "$REJECT_PKG/typelisp.pkg" <<'EOF'
(package
  (name "rejected_archive_lib")
  (version "0.1.0")
  (kind staticlib))
EOF
    cat > "$REJECT_PKG/src/lib.tl" <<'EOF'
(define (archive-answer) : i64 42)
EOF

    TYPELISP_WINDOWS_LIB=$COMPILER
    export TYPELISP_WINDOWS_LIB
    set +e
    "$COMPILER" build --manifest-path "$REJECT_PKG/typelisp.pkg" \
        --target windows-x86_64 --opt-level 0 \
        > "$REJECT_WORKDIR/build.stdout" 2> "$REJECT_WORKDIR/build.stderr"
    reject_status=$?
    set -e
    if [ "$reject_status" -eq 0 ]; then
        fail "incompatible TYPELISP_WINDOWS_LIB override unexpectedly succeeded"
    fi
    assert_empty "$REJECT_WORKDIR/build.stdout"
    assert_contains "$REJECT_WORKDIR/build.stderr" \
        "TYPELISP_WINDOWS_LIB must resolve to llvm-ar(.exe) or MSVC lib(.exe)"
    unset TYPELISP_WINDOWS_LIB
    echo "[windows-native-archive:override-rejection] incompatible override rejected"
}

run_windows_link_smoke msvc-auto ""

LLD_LINK_COMMAND=$(resolve_lld_link_command || true)
if [ -z "$LLD_LINK_COMMAND" ]; then
    fail "missing linker fallback: lld-link"
fi
run_windows_link_smoke lld-link "$LLD_LINK_COMMAND"

run_windows_archive_smoke msvc-auto ""
LLVM_AR_OVERRIDE=$(to_windows_path "$LLVM_AR_PATH")
run_windows_archive_smoke llvm-ar "$LLVM_AR_OVERRIDE"
run_windows_archive_override_rejection

echo "windows native link smoke passed"
