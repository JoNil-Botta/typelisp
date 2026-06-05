# lib-native-link.sh — shared host toolchain discovery + assemble/link helpers.
#
# Extracted from scripts/check-bootstrap-fixpoint.sh so both the bootstrap
# fixpoint gate and the stage0 self-build (scripts/build-stage0.sh, used by
# .github/workflows/bootstrap-stage0.yml) drive the same proven native flow:
#   - Linux: `as` + `ld` (libc dynamic link).
#   - Windows (Git Bash/MSYS/Cygwin): `clang --target=x86_64-pc-windows-msvc -c`
#     to assemble, then MSVC `link.exe` to link, with Windows SDK / MSVC env
#     discovery (overridable via TYPELISP_WINDOWS_CLANG / TYPELISP_WINDOWS_LINK).
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
WINDOWS_SDK_ROOT_POSIX=
WINDOWS_SDK_VERSION_VALUE=
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
        echo "[native-link] windows sdk=$WindowsSdkDir version=$WindowsSDKVersion"
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
        echo "[native-link] windows linker=$TYPELISP_WINDOWS_LINK"
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
    echo "[native-link] windows linker=$TYPELISP_WINDOWS_LINK"
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
    echo "[native-link] link $label with MSVC link.exe"
    MSYS2_ARG_CONV_EXCL='*' "$TYPELISP_WINDOWS_LINK_POSIX" \
        /NOLOGO \
        ${repro_arg:+"$repro_arg"} \
        "$obj_win" \
        "/OUT:$bin_win" \
        /SUBSYSTEM:CONSOLE \
        /DYNAMICBASE:NO \
        "/STACK:$NL_WINDOWS_STACK_RESERVE" \
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

    if [ "$NL_HOST_OS" = windows ]; then
        assemble_and_link_windows "$label" "$asm" "$obj" "$bin"
    else
        echo "[native-link] assemble $label with as"
        as "$asm" -o "$obj"
        echo "[native-link] link $label with ld"
        ld "$obj" -o "$bin" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc
    fi
}
