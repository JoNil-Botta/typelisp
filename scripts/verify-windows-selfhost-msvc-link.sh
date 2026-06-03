#!/usr/bin/env sh
set -eu

# verify-windows-selfhost-msvc-link.sh - Windows no-Rust selfhost build/run
# smoke for the MSVC link.exe path (#860).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    Linux*) HOST_OS=linux ;;
    *)
        echo "windows selfhost MSVC link smoke is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

if [ "$HOST_OS" != windows ]; then
    echo "windows selfhost MSVC link smoke is Windows-only"
    exit 0
fi

COMPILER=${TYPELISP_BIN:-}
if [ -z "$COMPILER" ]; then
    echo "windows selfhost MSVC link smoke requires TYPELISP_BIN" >&2
    exit 1
fi
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/windows-selfhost-msvc-link"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

WINDOWS_SDK_ROOT_POSIX=
WINDOWS_SDK_VERSION_VALUE=

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

find_windows_sdk_root() {
    for candidate_dir in \
        "/c/Program Files (x86)/Windows Kits/10" \
        "/c/Program Files/Windows Kits/10"; do
        if [ -d "$candidate_dir/Include" ] && [ -d "$candidate_dir/Lib" ]; then
            printf '%s\n' "$candidate_dir"
            return 0
        fi
    done

    return 1
}

find_windows_sdk_version() {
    sdk_root=$1
    latest=
    for include_dir in "$sdk_root"/Include/10.*; do
        if [ -d "$include_dir/ucrt" ] &&
            [ -d "$include_dir/um" ] &&
            [ -d "$include_dir/shared" ]; then
            version=$(basename "$include_dir")
            if [ -z "$latest" ] || [ "$version" \> "$latest" ]; then
                latest=$version
            fi
        fi
    done
    if [ -n "$latest" ]; then
        printf '%s\n' "$latest"
        return 0
    fi

    return 1
}

configure_windows_sdk_env() {
    sdk_root=$(find_windows_sdk_root || true)
    if [ -n "$sdk_root" ]; then
        WINDOWS_SDK_ROOT_POSIX=$sdk_root
    fi

    if [ -n "$WINDOWS_SDK_ROOT_POSIX" ]; then
        sdk_version=$(find_windows_sdk_version "$WINDOWS_SDK_ROOT_POSIX" || true)
        if [ -n "$sdk_version" ]; then
            WINDOWS_SDK_VERSION_VALUE=$sdk_version
        fi
    fi

    if [ -z "${WindowsSdkDir:-}" ] && [ -n "$WINDOWS_SDK_ROOT_POSIX" ]; then
        WindowsSdkDir=$(short_windows_path "$WINDOWS_SDK_ROOT_POSIX")
        export WindowsSdkDir
    fi
    if [ -z "${WindowsSDKVersion:-}" ] && [ -n "$WINDOWS_SDK_VERSION_VALUE" ]; then
        WindowsSDKVersion=$WINDOWS_SDK_VERSION_VALUE
        export WindowsSDKVersion
    fi

    if [ -n "${WindowsSdkDir:-}" ] && [ -n "${WindowsSDKVersion:-}" ]; then
        echo "[windows-selfhost-msvc] sdk=$WindowsSdkDir version=$WindowsSDKVersion"
    fi
}

find_link() {
    latest=
    for candidate in \
        "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/MSVC"/*/bin/Hostx64/x64/link.exe \
        "/c/Program Files/Microsoft Visual Studio/2022/Professional/VC/Tools/MSVC"/*/bin/Hostx64/x64/link.exe \
        "/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC"/*/bin/Hostx64/x64/link.exe \
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC"/*/bin/Hostx64/x64/link.exe; do
        if [ -x "$candidate" ]; then
            latest=$candidate
        fi
    done

    if [ -n "$latest" ]; then
        printf '%s\n' "$latest"
        return 0
    fi

    if command -v link.exe >/dev/null 2>&1; then
        path_link=$(command -v link.exe)
        case "$path_link" in
            */Git/usr/bin/link.exe) ;;
            *)
                printf '%s\n' "$path_link"
                return 0
                ;;
        esac
    fi

    return 1
}

find_lib() {
    latest=
    for candidate in \
        "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/MSVC"/*/bin/Hostx64/x64/lib.exe \
        "/c/Program Files/Microsoft Visual Studio/2022/Professional/VC/Tools/MSVC"/*/bin/Hostx64/x64/lib.exe \
        "/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC"/*/bin/Hostx64/x64/lib.exe \
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC"/*/bin/Hostx64/x64/lib.exe; do
        if [ -x "$candidate" ]; then
            latest=$candidate
        fi
    done

    if [ -n "$latest" ]; then
        printf '%s\n' "$latest"
        return 0
    fi

    if command -v lib.exe >/dev/null 2>&1; then
        command -v lib.exe
        return 0
    fi

    return 1
}

configure_windows_link_env() {
    if [ -n "${TYPELISP_WINDOWS_LINK:-}" ]; then
        return 0
    fi

    link_path=$(find_link || true)
    if [ -z "$link_path" ]; then
        return 0
    fi

    TYPELISP_WINDOWS_LINK=$(short_windows_path "$link_path")
    case "$TYPELISP_WINDOWS_LINK" in
        *" "*) fail "linker path contains spaces after short-path conversion: $TYPELISP_WINDOWS_LINK" ;;
    esac
    export TYPELISP_WINDOWS_LINK
    echo "[windows-selfhost-msvc] linker=$TYPELISP_WINDOWS_LINK"
    configure_msvc_inherited_env "$link_path"
}

prepend_env_list() {
    name=$1
    value=$2
    current=$(eval "printf '%s' \"\${$name:-}\"")
    if [ -n "$current" ]; then
        eval "$name=\"\$value;\$current\""
    else
        eval "$name=\"\$value\""
    fi
    export "$name"
}

configure_msvc_inherited_env() {
    link_path=$1
    if [ -z "$WINDOWS_SDK_ROOT_POSIX" ] || [ -z "$WINDOWS_SDK_VERSION_VALUE" ]; then
        return 0
    fi

    link_dir=$(dirname "$link_path")
    toolset_root=$(CDPATH= cd -- "$link_dir/../../.." && pwd)
    sdk_root=$WINDOWS_SDK_ROOT_POSIX
    sdk_version=$WINDOWS_SDK_VERSION_VALUE

    prepend_env_list "LIB" "$(short_windows_path "$sdk_root/Lib/$sdk_version/um/x64")"
    prepend_env_list "LIB" "$(short_windows_path "$sdk_root/Lib/$sdk_version/ucrt/x64")"
    prepend_env_list "LIB" "$(short_windows_path "$toolset_root/lib/x64")"
    prepend_env_list "INCLUDE" "$(short_windows_path "$sdk_root/Include/$sdk_version/shared")"
    prepend_env_list "INCLUDE" "$(short_windows_path "$sdk_root/Include/$sdk_version/um")"
    prepend_env_list "INCLUDE" "$(short_windows_path "$sdk_root/Include/$sdk_version/ucrt")"
    prepend_env_list "INCLUDE" "$(short_windows_path "$toolset_root/include")"
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

compiler_advertises_link_inputs() {
    "$COMPILER" --help 2>&1 | grep -q -- "--link-lib"
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
echo "[windows-selfhost-msvc] assembler=$TYPELISP_WINDOWS_CLANG"
configure_windows_sdk_env
configure_windows_link_env

echo "[windows-selfhost-msvc] build --direct"
if ! "$COMPILER" run "$ROOT/selfhost/build.tl" --stdlib-root "$ROOT/stdlib" -- \
    --direct "$SRC" --target windows-x86_64 -o "$BIN" --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/build.stdout" 2> "$WORKDIR/build.stderr"; then
    sed 's/^/  /' "$WORKDIR/build.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/build.stderr" >&2 || true
    fail "selfhost build --direct failed"
fi
assert_contains "$WORKDIR/build.stdout" "Generated: $BIN_DISPLAY"
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

echo "[windows-selfhost-msvc] run --direct"
set +e
"$COMPILER" run "$ROOT/selfhost/run.tl" --stdlib-root "$ROOT/stdlib" -- \
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
EOF
cat > "$WORKDIR/link-main.tl" <<'EOF'
(extern ffi_add7 : (-> i64 i64))
(define (main) : i64 (ffi_add7 35))
EOF
LINK_SRC="$WORKDIR/link-main.tl"
LINK_BIN="$WORKDIR/link-main.exe"
LINK_BIN_DISPLAY=$LINK_BIN
if command -v cygpath >/dev/null 2>&1; then
    LINK_BIN_DISPLAY=$(cygpath -m "$LINK_BIN")
fi

echo "[windows-selfhost-msvc] create named link library"
LIB_PATH=$(find_lib || true)
if [ -z "$LIB_PATH" ]; then
    fail "missing archiver: lib.exe"
fi
CLANG_RUN_PATH=$(find_clang || true)
if [ -z "$CLANG_RUN_PATH" ]; then
    CLANG_RUN_PATH=$TYPELISP_WINDOWS_CLANG
fi
"$CLANG_RUN_PATH" --target=x86_64-pc-windows-msvc -c \
    "$LINK_LIB_DIR/ffi_add7.s" -o "$LINK_LIB_DIR/ffi_add7.obj"
MSYS2_ARG_CONV_EXCL='*' "$LIB_PATH" /NOLOGO \
    "/OUT:$(to_windows_path "$LINK_LIB_DIR/ffi_add7.lib")" \
    "$(to_windows_path "$LINK_LIB_DIR/ffi_add7.obj")" \
    > "$WORKDIR/link-lib.stdout" 2> "$WORKDIR/link-lib.stderr"
assert_empty "$WORKDIR/link-lib.stderr"

LINK_SEARCH=$(to_windows_path "$LINK_LIB_DIR")
LINK_SEARCH_METADATA=$(printf '%s' "$LINK_SEARCH" | sed 's/\\/\\\\/g; s/"/\\"/g')

echo "[windows-selfhost-msvc] build --direct --link-lib"
if ! "$COMPILER" run "$ROOT/selfhost/build.tl" --stdlib-root "$ROOT/stdlib" -- \
    --direct "$LINK_SRC" --target windows-x86_64 -o "$LINK_BIN" \
    --stdlib-root "$ROOT/stdlib" --link-search "$LINK_SEARCH" --link-lib ffi_add7 \
    > "$WORKDIR/build-link.stdout" 2> "$WORKDIR/build-link.stderr"; then
    sed 's/^/  /' "$WORKDIR/build-link.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/build-link.stderr" >&2 || true
    fail "selfhost build --direct --link-lib failed"
fi
assert_contains "$WORKDIR/build-link.stdout" "Generated: $LINK_BIN_DISPLAY"
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

echo "[windows-selfhost-msvc] run --direct --link-lib"
set +e
"$COMPILER" run "$ROOT/selfhost/run.tl" --stdlib-root "$ROOT/stdlib" -- \
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

LINK_METADATA_SRC="$WORKDIR/link-metadata-main.tl"
LINK_METADATA_MODULE="$WORKDIR/link-metadata-module.tl"
cat > "$LINK_METADATA_MODULE" <<EOF
(extern ffi_add7 (:link-search "$LINK_SEARCH_METADATA") (:link-lib "ffi_add7") : (-> i64 i64))
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

echo "[windows-selfhost-msvc] build --direct extern link metadata"
if ! "$COMPILER" run "$ROOT/selfhost/build.tl" --stdlib-root "$ROOT/stdlib" -- \
    --direct "$LINK_METADATA_SRC" --target windows-x86_64 -o "$LINK_METADATA_BIN" \
    --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/build-link-metadata.stdout" 2> "$WORKDIR/build-link-metadata.stderr"; then
    sed 's/^/  /' "$WORKDIR/build-link-metadata.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/build-link-metadata.stderr" >&2 || true
    fail "selfhost build --direct extern link metadata failed"
fi
assert_contains "$WORKDIR/build-link-metadata.stdout" "Generated: $LINK_METADATA_BIN_DISPLAY"
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

echo "[windows-selfhost-msvc] run --direct extern link metadata"
set +e
"$COMPILER" run "$ROOT/selfhost/run.tl" --stdlib-root "$ROOT/stdlib" -- \
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

if compiler_advertises_link_inputs; then
    echo "[windows-selfhost-msvc] public build --link-lib"
    if ! "$COMPILER" build "$LINK_SRC" --target windows-x86_64 -o "$PUBLIC_LINK_BIN" \
        --stdlib-root "$ROOT/stdlib" --link-search "$LINK_SEARCH" --link-lib ffi_add7 \
        > "$WORKDIR/public-build-link.stdout" 2> "$WORKDIR/public-build-link.stderr"; then
        sed 's/^/  /' "$WORKDIR/public-build-link.stdout" >&2 || true
        sed 's/^/  /' "$WORKDIR/public-build-link.stderr" >&2 || true
        fail "public build --link-lib failed"
    fi
    assert_contains "$WORKDIR/public-build-link.stdout" "Generated: $PUBLIC_LINK_BIN_DISPLAY"
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

    echo "[windows-selfhost-msvc] public run --link-lib"
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

    echo "[windows-selfhost-msvc] public build extern link metadata"
    if ! "$COMPILER" build "$LINK_METADATA_SRC" --target windows-x86_64 \
        -o "$PUBLIC_LINK_METADATA_BIN" --stdlib-root "$ROOT/stdlib" \
        > "$WORKDIR/public-build-link-metadata.stdout" 2> "$WORKDIR/public-build-link-metadata.stderr"; then
        sed 's/^/  /' "$WORKDIR/public-build-link-metadata.stdout" >&2 || true
        sed 's/^/  /' "$WORKDIR/public-build-link-metadata.stderr" >&2 || true
        fail "public build extern link metadata failed"
    fi
    assert_contains "$WORKDIR/public-build-link-metadata.stdout" "Generated: $PUBLIC_LINK_METADATA_BIN_DISPLAY"
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

    echo "[windows-selfhost-msvc] public run extern link metadata"
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
else
    echo "[windows-selfhost-msvc] skipping public build/run --link-lib until the compiler advertises --link-lib"
fi

echo "windows selfhost MSVC link smoke passed"
