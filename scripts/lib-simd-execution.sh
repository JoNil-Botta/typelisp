#!/usr/bin/env sh

# Execution capability is separate from native CPUID/OS capability. Only the
# existing AVX-512 test programs may use SDE; compiler builds and benchmarks do
# not pass through this helper. -spr supplies the backend's F/BW/DQ/VL surface.
simd_execution_init() {
    SIMDEX_NATIVE_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh") || return 1
    SIMDEX_NATIVE_ISAS=$(printf '%s\n' "$SIMDEX_NATIVE_ISAS" | tr -d '\r')
    SIMDEX_SDE_BIN=${TYPELISP_SDE_BIN:-}
    SIMDEX_POLICY=${TYPELISP_AVX512_EXECUTION:-auto}
    case "$SIMDEX_POLICY" in
        auto | sde) ;;
        *) echo "invalid TYPELISP_AVX512_EXECUTION: $SIMDEX_POLICY" >&2; return 1 ;;
    esac
    if [ -n "$SIMDEX_SDE_BIN" ]; then
        [ -x "$SIMDEX_SDE_BIN" ] &&
            "$SIMDEX_SDE_BIN" -version 2>&1 |
                grep -Eq 'Version: +10[.]13[.]1 external' || {
            echo "expected checksum-verified Intel SDE 10.13.1: $SIMDEX_SDE_BIN" >&2
            return 1
        }
    fi
    SIMDEX_NATIVE=0
    SIMDEX_EMULATED=0
    SIMDEX_SKIPPED=0
    if ! simd_execution_mode avx512; then
        case "${CI:-false}:$SIMDEX_POLICY" in
            true:* | 1:* | *:sde)
                echo "AVX-512 execution is required: native support or pinned Intel SDE 10.13.1 must be available" >&2
                return 1
                ;;
        esac
    fi
}

simd_execution_mode() {
    SIMDEX_MODE=native
    case "$1" in - | scalar) return 0 ;; esac
    if [ "$1:$SIMDEX_POLICY" != avx512:sde ] &&
        printf '%s\n' "$SIMDEX_NATIVE_ISAS" | grep -Fx "$1" >/dev/null; then
        return 0
    fi
    if [ "$1" = avx512 ] && [ -n "$SIMDEX_SDE_BIN" ]; then
        SIMDEX_MODE=sde
        return 0
    fi
    SIMDEX_MODE=unavailable
    return 1
}

# Record outside the program's captured streams. Each caller records once per
# actual execution (or local skip), never for an availability query.
simd_execution_record() {
    simd_execution_mode "$2" || :
    [ "$2" = avx512 ] || return 0
    case "$SIMDEX_MODE" in
        native) SIMDEX_NATIVE=$((SIMDEX_NATIVE + 1)) ;;
        sde) SIMDEX_EMULATED=$((SIMDEX_EMULATED + 1)) ;;
        unavailable) SIMDEX_SKIPPED=$((SIMDEX_SKIPPED + 1)) ;;
    esac
    echo "[simd-execution] $1 isa=$2 execution=$SIMDEX_MODE${SIMDEX_SDE_BIN:+ sde-version=10.13.1}"
}

simd_execution_summary() {
    echo "[simd-execution] $1 avx512 executed=$((SIMDEX_NATIVE + SIMDEX_EMULATED)) native=$SIMDEX_NATIVE emulated=$SIMDEX_EMULATED skipped=$SIMDEX_SKIPPED"
}

simd_execute() {
    simd_execution_mode "$1" || {
        echo "cannot execute ISA $1" >&2
        return 1
    }
    shift
    if [ "$SIMDEX_MODE" = sde ]; then
        "$SIMDEX_SDE_BIN" -spr -- "$@"
    else
        "$@"
    fi
}
