# lib-native-link.sh — shared host toolchain discovery + assemble/link helpers.
#
# Shared so both the bootstrap fixpoint gate
# (scripts/check-bootstrap-fixpoint.sh) and the stage0 self-build
# (scripts/build-stage0.sh, used by .github/workflows/bootstrap-stage0.yml)
# drive the same proven native flow:
#   - Linux: `as` + `ld` (libc dynamic link).
#   - Windows (Git Bash/MSYS/Cygwin): `clang --target=x86_64-pc-windows-msvc -c`
#     to assemble, then a Windows COFF linker (`lld-link` by default,
#     overridable via TYPELISP_WINDOWS_CLANG / TYPELISP_WINDOWS_LINK).
#
# Source it (not exec): `. "$ROOT/scripts/lib-native-link.sh"`. POSIX sh only.
# Callers must set ROOT (repo root) before sourcing. After sourcing, call
# `native_link_detect_host` (sets NL_HOST_OS / NL_OBJ_EXT / NL_BIN_EXT /
# NL_BOOTSTRAP_TARGET) and `configure_toolchain` once, then `assemble_and_link`,
# or `link_native_object` for a serialized object.
#
# Stack reserve: a 256 MiB PE entry-stack setting, kept for compatibility with
# existing link paths. The freestanding Windows entry uses it only for bounded
# argv/fiber bootstrap; `main` runs on a runtime-owned 1 GiB fiber stack, so
# compiler-sized recursion does not depend on this linker value. Override with
# TYPELISP_WINDOWS_STACK_RESERVE (bytes).

HEARTBEAT_SECONDS=${TYPELISP_BOOTSTRAP_HEARTBEAT_SECONDS:-30}
NL_WINDOWS_STACK_RESERVE=${TYPELISP_WINDOWS_STACK_RESERVE:-268435456}
TYPELISP_WINDOWS_LINK_POSIX=
TYPELISP_WINDOWS_CLANG_POSIX=

. "$ROOT/scripts/lib-linux-entry.sh"

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

. "$ROOT/scripts/lib-gate.sh"

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
        if short_path=$(cygpath -d "$1" 2>/dev/null); then
            if [ -n "$short_path" ]; then
                command printf '%s\n' "$short_path" || return $?
                return 0
            fi
        fi
    fi
    to_windows_path "$1"
}

configure_windows_linker() {
    if [ -n "${TYPELISP_WINDOWS_LINK:-}" ]; then
        TYPELISP_WINDOWS_LINK_POSIX=$(to_unix_path "$TYPELISP_WINDOWS_LINK") || return $?
        echo "[native-link] windows linker=$TYPELISP_WINDOWS_LINK" || return $?
        return 0
    fi

    if command -v lld-link >/dev/null 2>&1; then
        TYPELISP_WINDOWS_LINK_POSIX=$(command -v lld-link) || return $?
    elif command -v lld-link.exe >/dev/null 2>&1; then
        TYPELISP_WINDOWS_LINK_POSIX=$(command -v lld-link.exe) || return $?
    else
        fail "missing linker: lld-link (or set TYPELISP_WINDOWS_LINK)"
    fi

    echo "[native-link] windows linker=$TYPELISP_WINDOWS_LINK_POSIX"
}

find_clang() {
    if command -v clang.exe >/dev/null 2>&1; then
        command -v clang.exe || return $?
        return 0
    fi
    if command -v clang >/dev/null 2>&1; then
        command -v clang || return $?
        return 0
    fi

    for candidate_dir in \
        "/c/Program Files/LLVM/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Professional/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin" \
        "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/Llvm/x64/bin"; do
        if test -x "$candidate_dir/clang.exe"; then
            printf '%s\n' "$candidate_dir/clang.exe" || return $?
            return 0
        fi
    done

    if command -v powershell.exe >/dev/null 2>&1; then
        ps_clang=$(command powershell.exe -NoProfile -Command '$cmd = Get-Command clang.exe -ErrorAction SilentlyContinue; if ($cmd) { $cmd.Source }') || return $?
        # A here-document supplies input without a producer whose failure
        # could be hidden by the normalization command's pipeline status.
        ps_clang=$(tr -d '\r' <<EOF
$ps_clang
EOF
        ) || return $?
        IFS= read -r ps_clang <<EOF || return $?
$ps_clang
EOF
        if [ -n "$ps_clang" ]; then
            to_unix_path "$ps_clang" || return $?
            return 0
        fi
    fi

    return 1
}

configure_windows_clang_env() {
    if [ -n "${TYPELISP_WINDOWS_CLANG:-}" ]; then
        TYPELISP_WINDOWS_CLANG_POSIX=$(to_unix_path "$TYPELISP_WINDOWS_CLANG") || return $?
        export TYPELISP_WINDOWS_CLANG_POSIX
        return 0
    fi

    clang_path=$(find_clang) || {
        _clang_status=$?
        printf '%s%s\n' "${GATE_FAIL_PREFIX-}" 'missing assembler: clang' >&2
        return "$_clang_status"
    }
    if [ -z "$clang_path" ]; then
        fail "missing assembler: clang"
    fi

    TYPELISP_WINDOWS_CLANG_POSIX=$clang_path
    TYPELISP_WINDOWS_CLANG=$(short_windows_path "$clang_path") || return $?
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
        configure_windows_clang_env || return $?
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

native_link_find_stdlib_archive() {
    _nl_asm=$1
    if [ "${TYPELISP_SYSROOT:-}" = "none" ]; then
        return 0
    fi
    if [ -n "${TYPELISP_NATIVE_LINK_STDLIB_ARCHIVE:-}" ] && [ -f "$TYPELISP_NATIVE_LINK_STDLIB_ARCHIVE" ]; then
        printf '%s\n' "$TYPELISP_NATIVE_LINK_STDLIB_ARCHIVE"
        return 0
    fi
    if [ ! -f "$_nl_asm" ]; then
        return 0
    fi
    if grep -q '^tl_oom_abort:$' "$_nl_asm" 2>/dev/null; then
        return 0
    fi
    if ! grep -qE '(^|[[:space:]])(tl_oom_abort|tl_region_abort|tl_oob_abort|tl_oob_abort_at|tl_c_fn_null_abort|tl_panic_at|_tl_stdlib_|_tl___tl_mod_init_|tl_alloc$|tl_exit$)' "$_nl_asm" 2>/dev/null; then
        return 0
    fi
    if [ "$NL_HOST_OS" = windows ]; then
        _nl_triple="x86_64-pc-windows-msvc"
    else
        _nl_triple="x86_64-unknown-linux-gnu"
    fi
    _nl_rel="lib/$_nl_triple/libstdlib.a"
    for _nl_root in \
        "${TYPELISP_SYSROOT:-}" \
        "${COMPILER:+$(dirname -- "$COMPILER")}" \
        "${COMPILER:+$(dirname -- "$(dirname -- "$COMPILER")")}" \
        "${STAGE3_BIN:+$(dirname -- "$STAGE3_BIN")}" \
        "${STAGE2_BIN:+$(dirname -- "$STAGE2_BIN")}" \
        "${BIN:+$(dirname -- "$BIN")}"; do
        if [ -n "$_nl_root" ] && [ -f "$_nl_root/$_nl_rel" ]; then
            printf '%s\n' "$_nl_root/$_nl_rel"
            return 0
        fi
    done
    return 0
}

link_native_object() {
    label=$1
    obj=$2
    bin=$3
    _entry=${4:-_tl_start}
    _stdlib_archive=${5:-}
    if [ "$NL_HOST_OS" = windows ]; then
        obj_win=$(to_windows_path "$obj") || return $?
        bin_win=$(to_windows_path "$bin") || return $?
        stdlib_archive_win=
        opt_ref_arg=
        if [ -n "$_stdlib_archive" ]; then
            stdlib_archive_win=$(to_windows_path "$_stdlib_archive") || return $?
            opt_ref_arg=/OPT:REF
        fi
        repro_arg=
        if [ "${TYPELISP_WINDOWS_LINK_REPRO:-}" = 1 ]; then
            repro_arg=/Brepro
        fi
        # TYPELISP_WINDOWS_LINK_TIMESTAMP=N writes N as the COFF TimeDateStamp
        # instead of the link time (lld-link /timestamp), with no other change.
        stamp_arg=
        case "${TYPELISP_WINDOWS_LINK_TIMESTAMP:-}" in
            "") ;;
            *[!0-9]*)
                echo "[native-link] TYPELISP_WINDOWS_LINK_TIMESTAMP must be a decimal integer" >&2
                return 2
                ;;
            *) stamp_arg=/timestamp:$TYPELISP_WINDOWS_LINK_TIMESTAMP ;;
        esac
        echo "[native-link] link $label with Windows COFF linker (freestanding: no CRT)" || return $?
        # Freestanding Win32: the backend emits its own entry (_tl_start) plus
        # kernel32-backed shims for the CRT-ABI symbols the runtime/stdlib use plus
        # the audited ntdll rooted-filesystem boundary, so the binary links against
        # no C runtime (no vcruntime140/ucrt/msvcrt).
        # /NODEFAULTLIB keeps link.exe from pulling a default CRT for the entry.
        MSYS2_ARG_CONV_EXCL='*' "$TYPELISP_WINDOWS_LINK_POSIX" \
            /NOLOGO \
            ${repro_arg:+"$repro_arg"} \
            ${opt_ref_arg:+"$opt_ref_arg"} \
            ${stamp_arg:+"$stamp_arg"} \
            "$obj_win" \
            ${stdlib_archive_win:+"$stdlib_archive_win"} \
            "/OUT:$bin_win" \
            /SUBSYSTEM:CONSOLE \
            /ENTRY:_tl_start \
            /NODEFAULTLIB \
            /DYNAMICBASE:NO \
            "/STACK:$NL_WINDOWS_STACK_RESERVE" \
            kernel32.lib \
            ntdll.lib
    else
        echo "[native-link] link $label with ld (freestanding: no libc, no loader)" || return $?
        # Runtime syscalls and libc-ABI shims are emitted in the object; this
        # link requires neither a C library nor a dynamic loader.
        if [ -n "$_stdlib_archive" ]; then
            ld -static -e "$_entry" --gc-sections "$obj" --start-group "$_stdlib_archive" --end-group -o "$bin"
        else
            ld -static -e "$_entry" "$obj" -o "$bin"
        fi
    fi
}

assemble_and_link_windows() {
    label=$1
    asm=$2
    obj=$3
    bin=$4
    _stdlib_archive=${5:-}

    # ci_timing_run disables errexit; each prerequisite must forward its own
    # failure before a stale object or a later successful step can hide it.
    echo "[native-link] assemble $label with clang" || return $?
    "$TYPELISP_WINDOWS_CLANG_POSIX" --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj" || return $?

    link_native_object "$label" "$obj" "$bin" "_tl_start" "$_stdlib_archive"
}

assemble_and_link() {
    label=$1
    asm=$2
    obj=$3
    bin=$4
    _stdlib_archive=$(native_link_find_stdlib_archive "$asm")

    if [ "$NL_HOST_OS" = windows ]; then
        assemble_and_link_windows "$label" "$asm" "$obj" "$bin" "$_stdlib_archive"
    else
        echo "[native-link] assemble $label with as" || return $?
        as "$asm" -o "$obj" || return $?
        _entry=$(linux_entry_symbol_for_asm "$asm") || return $?
        link_native_object "$label" "$obj" "$bin" "$_entry" "$_stdlib_archive"
    fi
}
