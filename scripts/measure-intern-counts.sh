#!/usr/bin/env sh
# measure-intern-counts.sh - deterministic per-compile interning counters.
#
# Builds a --cfg compile-profile compiler from the CURRENT source with a seed
# compiler, links it, runs it compiling src/main.tl, and prints the
# `compile-profile|intern.*` counter rows (hash_words / intern_calls /
# slice_calls / generated_allocations / lookup_calls). These counts are deterministic for a given
# (compiler, input), so they isolate redundant-interning changes from wall-clock
# noise. Not a CI gate -- a local iteration metric.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
. "$ROOT/scripts/lib-stage0.sh"

SEED=${TYPELISP_BIN:-$(stage0_compiler_path "$ROOT")}
[ -x "$SEED" ] || { echo "seed not executable: $SEED" >&2; exit 1; }

OUT=${TYPELISP_INTERN_OUT:-target/intern-counts}
OPT=${TYPELISP_INTERN_OPT:-1}
rm -rf "$OUT"
mkdir -p "$OUT"
configure_toolchain

ASM="$OUT/profile.s"
OBJ="$OUT/profile.$NL_OBJ_EXT"
BIN="$OUT/profile$NL_BIN_EXT"

echo "[intern-counts] building --cfg compile-profile compiler (opt$OPT) with seed"
# shellcheck disable=SC2046
"$SEED" compile src/main.tl -o "$ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level "$OPT" \
    --cfg compile-profile
assemble_and_link "intern-profile" "$ASM" "$OBJ" "$BIN"

echo "[intern-counts] running profile compiler on src/main.tl"
# shellcheck disable=SC2046
"$BIN" compile src/main.tl -o "$OUT/out.s" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level "$OPT" \
    2>"$OUT/profile.stderr" >/dev/null

echo "[intern-counts] intern counters:"
grep '^compile-profile|intern\.' "$OUT/profile.stderr" \
    | awk -F'|' '{ printf "  %-14s %s\n", $2, $3 }'

echo "[intern-counts] per-phase interning deltas:"
grep '^compile-profile-detail|intern.phase' "$OUT/profile.stderr" \
    | awk -F'|' '
        {
            metric = "direct"
            if ($2 == "intern.phase.slice") metric = "slice"
            if ($2 == "intern.phase.generated") metric = "generated"
            if ($2 == "intern.phase.pool") metric = "pool-growth"
            if ($2 == "intern.phase.lookup") metric = "lookup"
            printf "  %-14s %-12s %s\n", $3, metric, $4
        }'

COMPILER_SOURCE_BYTES=$(
    find src stdlib -type f -name '*.tl' \
        -exec sh -c 'for file do wc -c < "$file"; done' sh {} + \
        | awk '{ total += $1 } END { print total + 0 }'
)

grep '^compile-profile|intern\.' "$OUT/profile.stderr" \
    | awk -F'|' -v compiler_source_bytes="$COMPILER_SOURCE_BYTES" '
        { value[$2] = $3 }
        END {
            symbols = value["intern.source_symbols"]
            symbol_bytes = value["intern.source_symbol_bytes"]
            source_bytes = value["intern.source_bytes"]
            direct = value["intern.intern_calls"]
            if (symbols > 0) {
                printf "[intern-counts] source estimate:\n"
                printf "  average symbol length       %.2f bytes\n", symbol_bytes / symbols
                printf "  average source bytes/symbol %.2f bytes\n", source_bytes / symbols
                printf "  compiler source bytes       %d\n", compiler_source_bytes
                printf "  byte/length symbol estimate %.0f\n", compiler_source_bytes / (symbol_bytes / symbols)
                printf "  measured source symbols     %d\n", symbols
                printf "  direct interns/source symbol %.2f\n", direct / symbols
                printf "  parse-time target            %d source-symbol slices, 0 direct interns\n", symbols
            }
        }'
