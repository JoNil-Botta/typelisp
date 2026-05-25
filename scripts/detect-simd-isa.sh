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
# Linux reads /proc/cpuinfo (no build). Windows (Git Bash/MSYS/Cygwin) builds a
# tiny cpuid probe with the toolchain the harness already requires (clang;
# override with $CC) and caches it under $TMPDIR. Unknown hosts print nothing.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

case "$(uname -s)" in
    Linux*)
        # The kernel only advertises a flag when the CPU+OS can use it.
        if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then echo avx2; fi
        if grep -qw avx512f /proc/cpuinfo 2>/dev/null; then echo avx512f; fi
        ;;
    MINGW* | MSYS* | CYGWIN*)
        PROBE_SRC="$ROOT/scripts/simd_cpuid_probe.c"
        PROBE_EXE="${TMPDIR:-/tmp}/tl-simd-cpuid-probe.exe"
        CC=${CC:-clang}
        if [ ! -x "$PROBE_EXE" ] || [ "$PROBE_SRC" -nt "$PROBE_EXE" ]; then
            if ! "$CC" -O1 "$PROBE_SRC" -o "$PROBE_EXE" >/dev/null 2>&1; then
                echo "detect-simd-isa: failed to build cpuid probe with '$CC'" >&2
                exit 1
            fi
        fi
        "$PROBE_EXE"
        ;;
    *)
        # Unknown host: detect nothing; callers skip SIMD execution gracefully.
        : ;;
esac
