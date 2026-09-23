#!/usr/bin/env sh
set -eu

# verify-no-libc.sh - guard that the compiler and the programs it builds depend
# on NO C runtime. On Linux that means no dynamic libc (the binary is fully
# static, no DT_NEEDED, no interpreter); on Windows that means no
# vcruntime140 / ucrtbase / api-ms-win-crt-* / msvcrt imports (only the audited
# kernel32 and ntdll system DLLs). A regression here means someone reintroduced a
# libc/CRT dependency (e.g. a new stdlib FFI to a libc symbol, or a backend
# helper that calls the CRT instead of a syscall / Win32 API).
#
# Usage: verify-no-libc.sh
#   TYPELISP_BIN  path to the compiler under test (else the published stage0).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "no-libc verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
[ -x "$COMPILER" ] || {
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
}

WORKDIR="$ROOT/target/no-libc-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

inspect_linux() {
    _bin=$1
    _label=$2
    _deps=$(readelf -d "$_bin" 2>/dev/null | grep -E 'NEEDED' || true)
    _interp=$(readelf -l "$_bin" 2>/dev/null | grep -E 'interpreter' || true)
    if [ -n "$_deps" ] || [ -n "$_interp" ]; then
        echo "FAIL [$_label]: depends on a shared library / dynamic loader (expected freestanding static):" >&2
        [ -n "$_deps" ] && printf '%s\n' "$_deps" | sed 's/^/  /' >&2
        [ -n "$_interp" ] && printf '%s\n' "$_interp" | sed 's/^/  /' >&2
        return 1
    fi
    echo "ok [$_label]: no NEEDED libraries, no interpreter (freestanding)"
}

inspect_windows() {
    _bin=$1
    _label=$2
    # The freestanding runtime admits only kernel32 and the narrow ntdll
    # NtCreateFile boundary. Anything else (a CRT DLL, advapi32, ole32, ...)
    # is a regression.
    _dlls=$(llvm-readobj --coff-imports "$_bin" 2>/dev/null \
        | grep -iE 'Name:.*\.dll' | sed -E 's/.*Name:[[:space:]]*//' | tr -d '\r')
    _bad=$(printf '%s\n' "$_dlls" | grep -ivE '^(kernel32|ntdll)\.dll$' | grep -vE '^$' || true)
    if [ -n "$_bad" ]; then
        echo "FAIL [$_label]: imports a DLL other than kernel32.dll/ntdll.dll:" >&2
        printf '%s\n' "$_bad" | sed 's/^/  /' >&2
        return 1
    fi
    echo "ok [$_label]: audited kernel32.dll/ntdll.dll set only"
}

build_probe() {
    _target=$1
    _out=$2
    "$COMPILER" build "$ROOT/tests/no-libc/probe.tl" -o "$_out" \
        --target "$_target" --stdlib-root "$ROOT/stdlib" >"$WORKDIR/build.out" 2>&1 || {
        echo "FAIL: building the no-libc probe failed:" >&2
        sed 's/^/  /' "$WORKDIR/build.out" >&2
        return 1
    }
}

inspect_winsock_capability() {
    _asm="$WORKDIR/winsock-capability.s"
    _obj="$WORKDIR/winsock-capability.obj"
    _exe="$WORKDIR/winsock-capability.exe"
    _source="$ROOT/tests/integration/winsock_capability.tl"
    _direct="$WORKDIR/winsock-capability.direct.obj"
    # Batch row paths are read from the file by the compiler, so MSYS cannot
    # translate POSIX absolute paths inside it. Keep them relative to ROOT.
    _source_row=tests/integration/winsock_capability.tl
    _direct_row=target/no-libc-verify/winsock-capability.direct.obj
    _asm_row=target/no-libc-verify/winsock-capability.s
    printf '%s|%s|%s\n' "$_source_row" "$_direct_row" "$_asm_row" \
        >"$WORKDIR/winsock-batch.list"
    "$COMPILER" compile --batch "$WORKDIR/winsock-batch.list" \
        --windows-coff-plan "$WORKDIR/winsock-batch.plan" \
        --target windows-x86_64 --opt-level 2 --stdlib-root "$ROOT/stdlib" \
        >"$WORKDIR/winsock-compile.out" 2>&1 || {
        echo "FAIL: compiling the Winsock capability fixture failed:" >&2
        sed 's/^/  /' "$WORKDIR/winsock-compile.out" >&2
        return 1
    }
    printf '%s|assembly|%s|unsupported-object-semantics\n' \
        "$_source_row" "$_asm_row" >"$WORKDIR/winsock-batch.expected"
    if ! cmp "$WORKDIR/winsock-batch.expected" "$WORKDIR/winsock-batch.plan" \
        >/dev/null || [ -e "$_direct" ]; then
        echo "FAIL [winsock object]: expected checked assembly fallback" >&2
        cat "$WORKDIR/winsock-batch.plan" >&2
        return 1
    fi
    clang --target=x86_64-pc-windows-msvc -c "$_asm" -o "$_obj" || return 1
    llvm-readobj --symbols "$_obj" >"$WORKDIR/winsock-objects.txt" || return 1

    # The assembly fallback's COFF object must refer only to kernel32 loader
    # entries. String literals containing export names are allowed; unresolved
    # object symbols with those names would request static Winsock linkage.
    for _symbol in LoadLibraryExW GetModuleFileNameW GetSystemDirectoryW \
        CompareStringOrdinal GetProcAddress FreeLibrary GetLastError; do
        if ! grep -F "Name: $_symbol" "$WORKDIR/winsock-objects.txt" >/dev/null; then
            echo "FAIL [winsock object]: missing kernel32 loader symbol $_symbol" >&2
            return 1
        fi
    done
    if grep -iE 'Name: (WSAStartup|WSACleanup|WSAGetLastError|WSASocketW|closesocket|ioctlsocket|bind|listen|accept|connect|getsockname|getpeername|recv|send|recvfrom|sendto|shutdown|getsockopt|setsockopt|select|WSADuplicateSocketW)$' \
        "$WORKDIR/winsock-objects.txt" >/dev/null; then
        echo "FAIL [winsock object]: direct Winsock symbol" >&2
        return 1
    fi

    "$COMPILER" build "$_source" -o "$_exe" \
        --target windows-x86_64 --opt-level 2 --stdlib-root "$ROOT/stdlib" \
        >"$WORKDIR/winsock-build.out" 2>&1 || {
        echo "FAIL: building the Winsock capability PE failed:" >&2
        sed 's/^/  /' "$WORKDIR/winsock-build.out" >&2
        return 1
    }
    inspect_windows "$_exe" "winsock PE" || return 1
    llvm-readobj --coff-imports "$_exe" >"$WORKDIR/winsock-imports.txt" || return 1
    for _symbol in LoadLibraryExW GetModuleFileNameW GetSystemDirectoryW \
        CompareStringOrdinal GetProcAddress FreeLibrary GetLastError; do
        if ! grep -F "Symbol: $_symbol" "$WORKDIR/winsock-imports.txt" >/dev/null; then
            echo "FAIL [winsock PE]: missing kernel32 loader import $_symbol" >&2
            return 1
        fi
    done
    if grep -iE 'ws2_32\.lib|[-]lws2_32|/defaultlib:ws2_32' \
        "$ROOT/stdlib/net_windows_winsock.tl" "$ROOT/typelisp.pkg" >/dev/null; then
        echo "FAIL [winsock source/package]: requests static Winsock linkage" >&2
        return 1
    fi
    echo "ok [winsock capability]: COFF and PE use kernel32 loader imports without static Winsock linkage"
}

inspect_winsock_shadow() {
    command -v lld-link >/dev/null 2>&1 || {
        echo "FAIL [winsock shadow]: lld-link is required" >&2
        return 1
    }
    cat >"$WORKDIR/winsock-shadow.c" <<'SHADOW_C'
/* A freestanding application-directory shadow used only by this gate. */
__declspec(dllexport) int WSAStartup(unsigned short version, void *data) {
    (void)version;
    (void)data;
    return 10093;
}
__declspec(dllexport) int typelisp_shadow_marker(void) {
    return 7549;
}
SHADOW_C
    clang --target=x86_64-pc-windows-msvc -c \
        "$WORKDIR/winsock-shadow.c" \
        -o "$WORKDIR/winsock-shadow.obj" || return 1
    (
        cd "$WORKDIR"
        MSYS2_ARG_CONV_EXCL='*' lld-link /NOLOGO /DLL /NOENTRY /NODEFAULTLIB \
            winsock-shadow.obj /OUT:Ws2_32.dll
    ) || return 1
    "$COMPILER" build "$ROOT/tests/integration/winsock_shadow_identity.tl" \
        -o "$WORKDIR/winsock-shadow.exe" --target windows-x86_64 \
        --opt-level 2 --stdlib-root "$ROOT/stdlib" \
        >"$WORKDIR/winsock-shadow-build.out" 2>&1 || {
        echo "FAIL: building the preloaded Winsock shadow fixture failed:" >&2
        sed 's/^/  /' "$WORKDIR/winsock-shadow-build.out" >&2
        return 1
    }
    _shadow_status=0
    (cd "$WORKDIR" && ./winsock-shadow.exe) || _shadow_status=$?
    case "$_shadow_status" in
        42) echo "ok [winsock shadow]: non-System32 preloaded module rejected" ;;
        43) echo "ok [winsock shadow]: published module verified as System32" ;;
        *)
            echo "FAIL [winsock shadow]: identity fixture exited $_shadow_status" >&2
            return 1
            ;;
    esac
}

measure_winsock_capability() {
    _exe="$WORKDIR/winsock-capability-measure.exe"
    "$COMPILER" build "$ROOT/tests/integration/winsock_capability_measure.tl" \
        -o "$_exe" --target windows-x86_64 --opt-level 2 \
        --stdlib-root "$ROOT/stdlib" >"$WORKDIR/winsock-measure-build.out" 2>&1 || {
        echo "FAIL: building the Winsock capability measurement failed:" >&2
        sed 's/^/  /' "$WORKDIR/winsock-measure-build.out" >&2
        return 1
    }
    inspect_windows "$_exe" "winsock measurement PE" || return 1
    _measure_status=0
    "$_exe" >"$WORKDIR/winsock-measure.out" 2>&1 || _measure_status=$?
    if [ "$_measure_status" -ne 42 ]; then
        echo "FAIL [winsock measurement]: exited $_measure_status" >&2
        sed 's/^/  /' "$WORKDIR/winsock-measure.out" >&2
        return 1
    fi
    sed 's/^/[winsock measurement] /' "$WORKDIR/winsock-measure.out"
}

rc=0
if [ "$HOST_OS" = linux ]; then
    inspect_linux "$COMPILER" "compiler" || rc=1
    PROBE="$WORKDIR/probe"
    build_probe linux-x86_64 "$PROBE" || rc=1
    [ "$rc" -eq 0 ] && { inspect_linux "$PROBE" "probe" || rc=1; }
    [ "$rc" -eq 0 ] && { "$PROBE" >/dev/null 2>&1 || true; }
else
    command -v llvm-readobj >/dev/null 2>&1 || {
        echo "no-libc verification requires llvm-readobj on Windows" >&2
        exit 1
    }
    inspect_windows "$COMPILER" "compiler" || rc=1
    PROBE="$WORKDIR/probe.exe"
    build_probe windows-x86_64 "$PROBE" || rc=1
    [ "$rc" -eq 0 ] && { inspect_windows "$PROBE" "probe" || rc=1; }
    [ "$rc" -eq 0 ] && { inspect_winsock_capability || rc=1; }
    [ "$rc" -eq 0 ] && { inspect_winsock_shadow || rc=1; }
    [ "$rc" -eq 0 ] && { measure_winsock_capability || rc=1; }
fi

if [ "$rc" -ne 0 ]; then
    echo "no-libc guard FAILED" >&2
    exit 1
fi
echo "no-libc guard passed"
