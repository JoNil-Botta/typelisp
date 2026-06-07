# lib-native-link.sh — shared host toolchain discovery + assemble/link helpers.
#
# Extracted from scripts/check-bootstrap-fixpoint.sh so both the bootstrap
# fixpoint gate and the stage0 self-build (scripts/build-stage0.sh, used by
# .github/workflows/bootstrap-stage0.yml) drive the same proven native flow:
#   - Linux: `as` + `ld` (libc dynamic link).
#   - Windows (Git Bash/MSYS/Cygwin): `clang --target=x86_64-pc-windows-msvc -c`
#     to assemble, then a Windows COFF linker (`lld-link` by default,
#     overridable via TYPELISP_WINDOWS_CLANG / TYPELISP_WINDOWS_LINK).
#
# Source it (not exec): `. "$ROOT/scripts/lib-native-link.sh"`. POSIX sh only.
# Callers must set ROOT (repo root) before sourcing. After sourcing, call
# `native_link_detect_host` (sets NL_HOST_OS / NL_OBJ_EXT / NL_BIN_EXT /
# NL_BOOTSTRAP_TARGET) and `configure_toolchain` once, then `assemble_and_link`.
#
# Stack reserve: the self-hosted backend recurses over the AST/IR, so a
# self-hosted-built compiler needs a generous stack to compile the large cli.tl
# self-build on Windows (a 16MB reserve STATUS_STACK_OVERFLOWs; 64MB is enough,
# we reserve 256MB for headroom). The reserve is virtual address space, not
# committed RAM. Override with TYPELISP_WINDOWS_STACK_RESERVE (bytes).

HEARTBEAT_SECONDS=${TYPELISP_BOOTSTRAP_HEARTBEAT_SECONDS:-30}
NL_WINDOWS_STACK_RESERVE=${TYPELISP_WINDOWS_STACK_RESERVE:-268435456}
TYPELISP_WINDOWS_LINK_POSIX=
TYPELISP_WINDOWS_CLANG_POSIX=

NL_HOST_OS=linux
NL_BOOTSTRAP_TARGET=linux-x86_64
NL_OBJ_EXT=o
NL_BIN_EXT=

native_link_detect_host() {
    case "$(uname -s)" in
        Linux*) NL_HOST_OS=linux ;;
        MINGW* | MSYS* | CYGWIN*) NL_HOST_OS=windows ;;
        *)
            echo "native link is unsupported on this host: $(uname -s)" >&2
            exit 1
            ;;
    esac
    if [ "$NL_HOST_OS" = windows ]; then
        NL_BOOTSTRAP_TARGET=windows-x86_64
        NL_OBJ_EXT=obj
        NL_BIN_EXT=.exe
    else
        NL_BOOTSTRAP_TARGET=linux-x86_64
        NL_OBJ_EXT=o
        NL_BIN_EXT=
    fi
    # Back-compat aliases for callers that read the old names.
    HOST_OS=$NL_HOST_OS
    BOOTSTRAP_TARGET=$NL_BOOTSTRAP_TARGET
    OBJ_EXT=$NL_OBJ_EXT
    BIN_EXT=$NL_BIN_EXT
}

native_target_cfg_args() {
    if [ "$NL_HOST_OS" = windows ]; then
        printf '%s\n' --cfg windows --cfg target-windows --cfg os-windows
    else
        printf '%s\n' --cfg linux --cfg unix --cfg target-linux --cfg os-linux
    fi
}

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

configure_windows_linker() {
    if [ -n "${TYPELISP_WINDOWS_LINK:-}" ]; then
        TYPELISP_WINDOWS_LINK_POSIX=$(to_unix_path "$TYPELISP_WINDOWS_LINK")
        echo "[native-link] windows linker=$TYPELISP_WINDOWS_LINK"
        return 0
    fi

    if command -v lld-link >/dev/null 2>&1; then
        TYPELISP_WINDOWS_LINK_POSIX=$(command -v lld-link)
    elif command -v lld-link.exe >/dev/null 2>&1; then
        TYPELISP_WINDOWS_LINK_POSIX=$(command -v lld-link.exe)
    else
        fail "missing linker: lld-link (or set TYPELISP_WINDOWS_LINK)"
    fi

    echo "[native-link] windows linker=$TYPELISP_WINDOWS_LINK_POSIX"
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
    echo "[native-link] windows assembler=$TYPELISP_WINDOWS_CLANG"
}

configure_toolchain() {
    if [ "$NL_HOST_OS" = linux ]; then
        command -v as >/dev/null 2>&1 || fail "native link requires 'as'"
        command -v ld >/dev/null 2>&1 || fail "native link requires 'ld'"
    else
        configure_windows_clang_env
        configure_windows_linker
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
                echo "[native-link] ${heartbeat_label} still running"
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

run_with_heartbeat_capture() {
    heartbeat_label=$1
    heartbeat_stdout=$2
    heartbeat_stderr=$3
    shift 3

    "$@" > "$heartbeat_stdout" 2> "$heartbeat_stderr" &
    heartbeat_cmd_pid=$!
    (
        while kill -0 "$heartbeat_cmd_pid" 2>/dev/null; do
            sleep "$HEARTBEAT_SECONDS"
            if kill -0 "$heartbeat_cmd_pid" 2>/dev/null; then
                echo "[native-link] ${heartbeat_label} still running"
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

    echo "[native-link] assemble $label with clang"
    "$TYPELISP_WINDOWS_CLANG_POSIX" --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj"

    obj_win=$(to_windows_path "$obj")
    bin_win=$(to_windows_path "$bin")
    repro_arg=
    if [ "${TYPELISP_WINDOWS_LINK_REPRO:-}" = 1 ]; then
        repro_arg=/Brepro
    fi
    echo "[native-link] link $label with Windows COFF linker (freestanding: no CRT)"
    # Freestanding Win32: the backend emits its own entry (_tl_start) plus
    # kernel32-backed shims for the CRT-ABI symbols the runtime/stdlib use, so
    # the binary links against no C runtime (no vcruntime140/ucrt/msvcrt).
    # /NODEFAULTLIB keeps link.exe from pulling a default CRT for the entry.
    MSYS2_ARG_CONV_EXCL='*' "$TYPELISP_WINDOWS_LINK_POSIX" \
        /NOLOGO \
        ${repro_arg:+"$repro_arg"} \
        "$obj_win" \
        "/OUT:$bin_win" \
        /SUBSYSTEM:CONSOLE \
        /ENTRY:_tl_start \
        /NODEFAULTLIB \
        /DYNAMICBASE:NO \
        "/STACK:$NL_WINDOWS_STACK_RESERVE" \
        kernel32.lib
}

assemble_and_link() {
    label=$1
    asm=$2
    obj=$3
    bin=$4

    if [ "$NL_HOST_OS" = windows ]; then
        assemble_and_link_windows "$label" "$asm" "$obj" "$bin"
    else
        echo "[native-link] assemble $label with as"
        as "$asm" -o "$obj"
        echo "[native-link] link $label with ld (freestanding: no libc, no loader)"
        # The runtime is pure syscalls and the backend emits its own libc-ABI
        # shims (write/read/open/getenv/...), so the compiler links static with
        # no `-lc` and no dynamic loader -- the produced binary depends on no
        # shared library. See compiler-backend-runtime-linux-libc-shim-functions.
        ld -static "$obj" -o "$bin"
    fi
}
