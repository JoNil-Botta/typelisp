#!/usr/bin/env sh
set -eu

# verify-no-libc.sh - guard that the compiler and the programs it builds depend
# on NO C runtime. On Linux that means no dynamic libc (the binary is fully
# static, no DT_NEEDED, no interpreter); on Windows that means no
# vcruntime140 / ucrtbase / api-ms-win-crt-* / msvcrt imports (only Win32
# system DLLs such as kernel32). A regression here means someone reintroduced a
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
    # The freestanding runtime depends on exactly one DLL: kernel32. Anything
    # else (a CRT DLL, advapi32, ole32, ...) is a regression.
    _dlls=$(llvm-readobj --coff-imports "$_bin" 2>/dev/null \
        | grep -iE 'Name:.*\.dll' | sed -E 's/.*Name:[[:space:]]*//' | tr -d '\r')
    _bad=$(printf '%s\n' "$_dlls" | grep -ivE '^kernel32\.dll$' | grep -vE '^$' || true)
    if [ -n "$_bad" ]; then
        echo "FAIL [$_label]: imports a DLL other than kernel32.dll:" >&2
        printf '%s\n' "$_bad" | sed 's/^/  /' >&2
        return 1
    fi
    echo "ok [$_label]: kernel32.dll only"
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
fi

if [ "$rc" -ne 0 ]; then
    echo "no-libc guard FAILED" >&2
    exit 1
fi
echo "no-libc guard passed"
