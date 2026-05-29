#!/usr/bin/env sh
set -eu

# check-bootstrap-fixpoint.sh - selfhost compiler stage2/stage3 fixpoint gate.
#
# The Rust stage0 compiler builds the TypeLisp selfhost compiler to stage1.
# stage1 then compiles the same selfhost source to stage2.s, stage2 repeats that
# compile to stage3.s, and the selfhost-emitted stage2/stage3 assembly must be
# byte-identical.
#
# Set TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE to persist the stage1 compiler path for
# callers that want to reuse the freshly bootstrapped compiler. Set
# TYPELISP_BOOTSTRAP_STAGE1_ONLY=1 to stop after linking stage1; normal runs
# continue through the stage2/stage3 fixpoint.
#
# refs #47.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "bootstrap fixpoint check is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

BOOTSTRAP_TARGET=linux-x86_64
OBJ_EXT=o
BIN_EXT=
if [ "$HOST_OS" = windows ]; then
    BOOTSTRAP_TARGET=windows-x86_64
    OBJ_EXT=obj
    BIN_EXT=.exe
fi

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [typelisp-binary]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    COMPILER=$1
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Fallback only for local development; CI should pass a fetched stage0
    # compiler through TYPELISP_BIN until #793/#795 remove Rust stage0.
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

HEARTBEAT_SECONDS=${TYPELISP_BOOTSTRAP_HEARTBEAT_SECONDS:-30}
WINDOWS_SDK_ROOT_POSIX=
WINDOWS_SDK_VERSION_VALUE=
TYPELISP_WINDOWS_LINK_POSIX=
TYPELISP_WINDOWS_CLANG_POSIX=

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
        echo "[bootstrap] windows sdk=$WindowsSdkDir version=$WindowsSDKVersion"
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
            /usr/bin/link.exe | /bin/link.exe | */Git/usr/bin/link.exe | */Git/bin/link.exe) ;;
            *)
                printf '%s\n' "$path_link"
                return 0
                ;;
        esac
    fi

    return 1
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
    case "$link_path" in
        */VC/Tools/MSVC/*/bin/Hostx64/x64/link.exe) ;;
        *) return 0 ;;
    esac

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

configure_windows_link_env() {
    if [ -n "${TYPELISP_WINDOWS_LINK:-}" ]; then
        link_path=$(to_unix_path "$TYPELISP_WINDOWS_LINK")
        TYPELISP_WINDOWS_LINK_POSIX=$link_path
        export TYPELISP_WINDOWS_LINK_POSIX
        configure_msvc_inherited_env "$link_path"
        echo "[bootstrap] windows linker=$TYPELISP_WINDOWS_LINK"
        return 0
    fi

    link_path=$(find_link || true)
    if [ -z "$link_path" ]; then
        fail "missing linker: link.exe"
    fi

    TYPELISP_WINDOWS_LINK_POSIX=$link_path
    TYPELISP_WINDOWS_LINK=$(short_windows_path "$link_path")
    case "$TYPELISP_WINDOWS_LINK" in
        *" "*) fail "linker path contains spaces after short-path conversion: $TYPELISP_WINDOWS_LINK" ;;
    esac
    export TYPELISP_WINDOWS_LINK
    export TYPELISP_WINDOWS_LINK_POSIX
    configure_msvc_inherited_env "$link_path"
    echo "[bootstrap] windows linker=$TYPELISP_WINDOWS_LINK"
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

configure_windows_clang_env() {
    if [ -n "${TYPELISP_WINDOWS_CLANG:-}" ]; then
        TYPELISP_WINDOWS_CLANG_POSIX=$(to_unix_path "$TYPELISP_WINDOWS_CLANG")
        export TYPELISP_WINDOWS_CLANG_POSIX
        return 0
    fi

    clang_path=$(find_clang || true)
    if [ -z "$clang_path" ]; then
        fail "missing assembler: clang"
    fi

    TYPELISP_WINDOWS_CLANG_POSIX=$clang_path
    TYPELISP_WINDOWS_CLANG=$(short_windows_path "$clang_path")
    case "$TYPELISP_WINDOWS_CLANG" in
        *" "*) fail "assembler path contains spaces after short-path conversion: $TYPELISP_WINDOWS_CLANG" ;;
    esac
    export TYPELISP_WINDOWS_CLANG
    export TYPELISP_WINDOWS_CLANG_POSIX
    echo "[bootstrap] windows assembler=$TYPELISP_WINDOWS_CLANG"
}

configure_toolchain() {
    if [ "$HOST_OS" = linux ]; then
        command -v as >/dev/null 2>&1 || fail "bootstrap fixpoint check requires 'as'"
        command -v ld >/dev/null 2>&1 || fail "bootstrap fixpoint check requires 'ld'"
    else
        configure_windows_clang_env
        configure_windows_sdk_env
        configure_windows_link_env
    fi
}

run_with_heartbeat() {
    heartbeat_label=$1
    shift

    "$@" &
    heartbeat_cmd_pid=$!
    (
        while kill -0 "$heartbeat_cmd_pid" 2>/dev/null; do
            sleep "$HEARTBEAT_SECONDS"
            if kill -0 "$heartbeat_cmd_pid" 2>/dev/null; then
                echo "[bootstrap] ${heartbeat_label} still running"
            fi
        done
    ) &
    heartbeat_pid=$!

    heartbeat_status=0
    wait "$heartbeat_cmd_pid" || heartbeat_status=$?
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
    return "$heartbeat_status"
}

assemble_and_link_windows() {
    label=$1
    asm=$2
    obj=$3
    bin=$4

    echo "[bootstrap] assemble $label with clang"
    "$TYPELISP_WINDOWS_CLANG_POSIX" --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj"

    obj_win=$(to_windows_path "$obj")
    bin_win=$(to_windows_path "$bin")
    echo "[bootstrap] link $label with MSVC link.exe"
    MSYS2_ARG_CONV_EXCL='*' "$TYPELISP_WINDOWS_LINK_POSIX" \
        /NOLOGO \
        "$obj_win" \
        "/OUT:$bin_win" \
        /SUBSYSTEM:CONSOLE \
        /DYNAMICBASE:NO \
        /STACK:16777216 \
        msvcrt.lib \
        legacy_stdio_definitions.lib \
        kernel32.lib \
        advapi32.lib \
        ole32.lib \
        oleaut32.lib
}

assemble_and_link() {
    label=$1
    asm=$2
    obj=$3
    bin=$4

    if [ "$HOST_OS" = windows ]; then
        assemble_and_link_windows "$label" "$asm" "$obj" "$bin"
    else
        echo "[bootstrap] assemble $label with as"
        as "$asm" -o "$obj"
        echo "[bootstrap] link $label with ld"
        ld "$obj" -o "$bin"
    fi
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

run_stage1_cli_expect_failure() {
    label=$1
    shift
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    set +e
    "$@" > "$stdout" 2> "$stderr"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "stage1 CLI command unexpectedly succeeded: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

run_stage1_cli_capture() {
    label=$1
    shift
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    if ! "$@" > "$stdout" 2> "$stderr"; then
        echo "stage1 CLI command failed: $label" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
}

WORKDIR="$ROOT/target/bootstrap-fixpoint"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
configure_toolchain

STAGE1_ASM="$WORKDIR/stage1.s"
STAGE1_OBJ="$WORKDIR/stage1.$OBJ_EXT"
STAGE1_BIN="$WORKDIR/stage1$BIN_EXT"
STAGE2_ASM="$WORKDIR/stage2.s"
STAGE2_OBJ="$WORKDIR/stage2.$OBJ_EXT"
STAGE2_BIN="$WORKDIR/stage2$BIN_EXT"
STAGE3_ASM="$WORKDIR/stage3.s"
STAGE1_CLI_SRC="$WORKDIR/stage1_cli_smoke.tl"
STAGE1_CLI_ASM="$WORKDIR/stage1_cli_smoke.s"
STAGE1_CLI_DIRECT_ASM="$WORKDIR/stage1_cli_direct.s"
STAGE1_CLI_IR="$WORKDIR/stage1_cli_smoke.ir"

cat > "$STAGE1_CLI_SRC" <<'EOF'
(define (main) : i64 42)
EOF

write_stage1_path() {
    if [ -n "${TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE:-}" ]; then
        STAGE1_PATH_DIR=$(dirname -- "$TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE")
        mkdir -p "$STAGE1_PATH_DIR"
        printf '%s\n' "$STAGE1_BIN" > "$TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE"
        echo "[bootstrap] stage1 compiler: $STAGE1_BIN"
    fi
}

check_stage1_compile_cli() {
    echo "[bootstrap] stage1 compile CLI smoke"
    run_stage1_cli_capture \
        stage1-compile-command \
        "$STAGE1_BIN" compile "$STAGE1_CLI_SRC" \
        --target "$BOOTSTRAP_TARGET" \
        --backend-mode scalar \
        --opt-level 0 \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/selfhost"
    [ -s "$STAGE1_CLI_ASM" ] || {
        echo "stage1 compile command did not write default assembly: $STAGE1_CLI_ASM" >&2
        exit 1
    }
    assert_contains "$STAGE1_CLI_ASM" "main:"

    run_stage1_cli_capture \
        stage1-compile-direct \
        "$STAGE1_BIN" "$STAGE1_CLI_SRC" -o "$STAGE1_CLI_DIRECT_ASM" --target "$BOOTSTRAP_TARGET"
    [ -s "$STAGE1_CLI_DIRECT_ASM" ] || {
        echo "stage1 direct bootstrap form did not write assembly: $STAGE1_CLI_DIRECT_ASM" >&2
        exit 1
    }
    assert_contains "$STAGE1_CLI_DIRECT_ASM" "main:"

    run_stage1_cli_capture \
        stage1-compile-emit-ir \
        "$STAGE1_BIN" compile "$STAGE1_CLI_SRC" --emit-ir --target "$BOOTSTRAP_TARGET" --stdlib-root "$ROOT/stdlib"
    [ -s "$STAGE1_CLI_IR" ] || {
        echo "stage1 compile --emit-ir did not write default IR: $STAGE1_CLI_IR" >&2
        exit 1
    }
    assert_contains "$STAGE1_CLI_IR" "typelisp-ir-summary v1"

    run_stage1_cli_capture stage1-help "$STAGE1_BIN" help
    assert_contains "$WORKDIR/stage1-help.stderr" "typelisp compile <file.tl>"

    run_stage1_cli_expect_failure stage1-missing-command "$STAGE1_BIN"
    assert_contains "$WORKDIR/stage1-missing-command.stderr" "typelisp: expected command"
    assert_contains "$WORKDIR/stage1-missing-command.stderr" "Usage:"

    run_stage1_cli_expect_failure stage1-missing-source "$STAGE1_BIN" compile
    assert_contains "$WORKDIR/stage1-missing-source.stderr" "compile: expected source path"

    run_stage1_cli_expect_failure stage1-unknown-command "$STAGE1_BIN" check "$STAGE1_CLI_SRC"
    assert_contains "$WORKDIR/stage1-unknown-command.stderr" "Unknown command: check"
    assert_contains "$WORKDIR/stage1-unknown-command.stderr" "Usage:"
}

echo "[bootstrap] stage0 -> stage1.s"
run_with_heartbeat "stage0 -> stage1.s" "$COMPILER" compile selfhost/compile.tl -o "$STAGE1_ASM" --target "$BOOTSTRAP_TARGET"

assemble_and_link "stage1" "$STAGE1_ASM" "$STAGE1_OBJ" "$STAGE1_BIN"

check_stage1_compile_cli

if [ "${TYPELISP_BOOTSTRAP_STAGE1_ONLY:-}" = 1 ]; then
    write_stage1_path
    echo "bootstrap stage1 build passed"
    exit 0
fi

echo "[bootstrap] stage1 -> stage2.s"
run_with_heartbeat "stage1 -> stage2.s" "$STAGE1_BIN" selfhost/compile.tl -o "$STAGE2_ASM" --target "$BOOTSTRAP_TARGET"

assemble_and_link "stage2" "$STAGE2_ASM" "$STAGE2_OBJ" "$STAGE2_BIN"

echo "[bootstrap] stage2 -> stage3.s"
run_with_heartbeat "stage2 -> stage3.s" "$STAGE2_BIN" selfhost/compile.tl -o "$STAGE3_ASM" --target "$BOOTSTRAP_TARGET"

echo "[bootstrap] compare stage2.s and stage3.s"
if ! cmp -s "$STAGE2_ASM" "$STAGE3_ASM"; then
    echo "bootstrap fixpoint mismatch: stage2.s and stage3.s differ" >&2
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$STAGE2_ASM" "$STAGE3_ASM" >&2 || true
    fi
    wc -l "$STAGE2_ASM" "$STAGE3_ASM" >&2 || true
    if command -v diff >/dev/null 2>&1; then
        diff -u "$STAGE2_ASM" "$STAGE3_ASM" | sed -n '1,200p' >&2 || true
    else
        cmp -l "$STAGE2_ASM" "$STAGE3_ASM" | sed -n '1,80p' >&2 || true
    fi
    exit 1
fi

wc -l "$STAGE2_ASM" "$STAGE3_ASM"
write_stage1_path
echo "bootstrap fixpoint check passed"
