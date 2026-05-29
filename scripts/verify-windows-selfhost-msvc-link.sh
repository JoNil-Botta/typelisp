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

echo "windows selfhost MSVC link smoke passed"
