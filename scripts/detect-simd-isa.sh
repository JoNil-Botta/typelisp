#!/usr/bin/env sh
set -eu

# detect-simd-isa.sh - print the host CPU's runnable SIMD ISAs, one token per
# line (currently `avx2` and/or `avx512f`). A token is printed only when the
# host running this script can actually EXECUTE that ISA (CPUID feature bit AND
# OS XSAVE state enablement), not merely compile for it.
#
# This lets test harnesses gate SIMD *execution* on real capability instead of
# host OS (refs #1147): the fleet's Windows box has AVX-512, while a generic
# `windows-latest` runner may not, so host-OS gating is wrong either way.
#
# Reusable shared helper:
#   ISAS=$(sh scripts/detect-simd-isa.sh)
#   printf '%s\n' "$ISAS" | grep -qx avx512f && run_avx512_checks
#
# Linux reads /proc/cpuinfo (no build). Windows (Git Bash/MSYS/Cygwin) builds
# and runs the TypeLisp cpuid detector (scripts/detect_simd_isa.tl, built on
# stdlib/cpu.tl) with the harness's typelisp ($TYPELISP_BIN, else
# target/release/typelisp.exe) and caches it under $TMPDIR -- no C component
# remains in the repo (refs #1168). Unknown hosts print nothing.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

case "$(uname -s)" in
    Linux*)
        # The kernel only advertises a flag when the CPU+OS can use it.
        if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then echo avx2; fi
        if grep -qw avx512f /proc/cpuinfo 2>/dev/null; then echo avx512f; fi
        ;;
    MINGW* | MSYS* | CYGWIN*)
        # No /proc/cpuinfo here: build and run the TypeLisp cpuid detector.
        if [ -n "${TYPELISP_BIN:-}" ]; then
            COMPILER=$TYPELISP_BIN
        else
            COMPILER="$ROOT/target/release/typelisp.exe"
        fi
        PROBE_SRC="$ROOT/scripts/detect_simd_isa.tl"
        PROBE_EXE="${TMPDIR:-/tmp}/tl-simd-cpuid-probe.exe"
        if [ ! -x "$PROBE_EXE" ] \
            || [ "$PROBE_SRC" -nt "$PROBE_EXE" ] \
            || [ "$ROOT/stdlib/cpu.tl" -nt "$PROBE_EXE" ]; then
            # Build from a temp copy so the compiler's .s/.obj intermediates land
            # beside the copy in TMPDIR rather than polluting the repo tree; the
            # stdlib import still resolves through --stdlib-root.
            PROBE_TMP="${TMPDIR:-/tmp}/tl-simd-detect.tl"
            cp "$PROBE_SRC" "$PROBE_TMP"
            if ! "$COMPILER" build "$PROBE_TMP" -o "$PROBE_EXE" \
                --target windows-x86_64 --stdlib-root "$ROOT/stdlib" >/dev/null 2>&1; then
                echo "detect-simd-isa: failed to build TypeLisp cpuid detector with '$COMPILER'" >&2
                exit 1
            fi
        fi
        "$PROBE_EXE"
        ;;
    *)
        # Unknown host: detect nothing; callers skip SIMD execution gracefully.
        : ;;
esac
