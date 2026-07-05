#!/usr/bin/env sh
set -eu

# measure-static-asm-counts.sh - local STATIC assembly instruction counts.
#
# This is a local measurement tool, not a CI gate. For each comparison
# benchmark (benchmarks/<name>/ with both bench.tl and baseline.c) it emits the
# TypeLisp assembly and the clang -O2 C assembly, then counts the STATIC
# instructions in each (mnemonics in the emitted text, not executed dynamic
# instructions -- contrast scripts/measure-instruction-counts.sh, which is the
# Linux-only dynamic cachegrind harness). Static counts track emitted code-size
# progress and, unlike the dynamic harness, run cross-platform: Linux and Git
# Bash on Windows both work because the TypeLisp side only emits linux-x86_64
# assembly text (no assembling or linking) and the C side falls back to the host
# default clang target when the linux target lacks libc headers.
#
# The TypeLisp count is split into three buckets by the current column-0 label:
#   program  - labels starting `_tl_bench` or exactly `main`
#   stdlib   - labels starting `_tl_stdlib`
#   runtime  - every other label (arena/memcpy/abort shims, _tl_start, ...)
# The reported tl_over_c ratio compares tl_program against the C total, since the
# runtime/stdlib prologue is fixed overhead shared by every TypeLisp program.
#
# Env:
#   TYPELISP_BIN                   compiler path (else the published stage0 is
#                                  fetched via scripts/lib-stage0.sh)
#   TYPELISP_STATIC_ASM_OUT        output dir (default target/static-asm-counts)
#   BENCH_FILTER                   only run benchmarks whose name contains this
#                                  substring
#   TYPELISP_STATIC_ASM_OPT_LEVEL  TypeLisp opt level (default 2)

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

OUT=${TYPELISP_STATIC_ASM_OUT:-target/static-asm-counts}
FILTER=${BENCH_FILTER:-}
OPT_LEVEL=${TYPELISP_STATIC_ASM_OPT_LEVEL:-2}

fail() {
    echo "[static-asm] $*" >&2
    exit 1
}

case "$OPT_LEVEL" in
    0 | 1 | 2) ;;
    *) fail "TYPELISP_STATIC_ASM_OPT_LEVEL must be 0, 1, or 2: $OPT_LEVEL" ;;
esac

for tool in clang awk grep; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Local-development fallback: fetch the published self-hosted stage0
    # (the same resolver bench.sh / measure-instruction-counts.sh use).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
[ -x "$COMPILER" ] || fail "typelisp compiler is not executable: $COMPILER"

rm -rf "$OUT"
mkdir -p "$OUT"
TSV="$OUT/static-asm-counts.tsv"
printf 'name\ttl_total\ttl_program\ttl_stdlib\ttl_runtime\tc_total\ttl_over_c\n' > "$TSV"

# count_tl FILE -> "tl_total tl_program tl_stdlib tl_runtime"
# A column-0 label (`^[A-Za-z_][A-Za-z0-9_.]*:`) selects the current bucket; it
# is not itself an instruction. `.L*` local labels start with '.', so they neither
# switch buckets nor count. Instructions are indented lines whose first non-space
# char is a lowercase mnemonic; leading '.' (directives) and '#' (comments) are
# excluded because the class is [a-z].
count_tl() {
    awk '
        BEGIN { bucket = "runtime" }
        { sub(/\r$/, "") }
        /^[A-Za-z_][A-Za-z0-9_.]*:/ {
            lbl = $0
            sub(/:.*/, "", lbl)
            if (lbl ~ /^_tl_bench/ || lbl == "main") {
                bucket = "program"
            } else if (lbl ~ /^_tl_stdlib/) {
                bucket = "stdlib"
            } else {
                bucket = "runtime"
            }
            next
        }
        /^[[:space:]]+[a-z]/ {
            total += 1
            counts[bucket] += 1
            next
        }
        END {
            printf "%d %d %d %d\n", \
                total + 0, counts["program"] + 0, counts["stdlib"] + 0, counts["runtime"] + 0
        }
    ' "$1"
}

# count_c FILE -> total static instructions (same instruction shape as count_tl;
# clang directives start with '.' and comments with '#', both excluded).
count_c() {
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]+[a-z]/ { n += 1 }
        END { print n + 0 }
    ' "$1"
}

# ratio TL_PROGRAM C_TOTAL -> tl_program / c_total to 2 decimals, or "-".
ratio() {
    awk -v p="$1" -v c="$2" 'BEGIN {
        if (c + 0 == 0) { print "-" } else { printf "%.2f\n", (p + 0) / (c + 0) }
    }'
}

sum_tl_total=0
sum_tl_program=0
sum_tl_stdlib=0
sum_tl_runtime=0
sum_c_total=0
found=0

echo "[static-asm] compiler: $COMPILER"
echo "[static-asm] output: $OUT"
echo "[static-asm] typelisp opt-level: $OPT_LEVEL"

for bench_tl in benchmarks/*/bench.tl; do
    [ -e "$bench_tl" ] || continue
    dir=$(dirname "$bench_tl")
    name=$(basename "$dir")
    baseline_c="$dir/baseline.c"
    [ -f "$baseline_c" ] || continue
    case "$name" in
        *"$FILTER"*) ;;
        *) continue ;;
    esac
    found=$((found + 1))

    tl_s="$OUT/$name.tl.s"
    c_s="$OUT/$name.c.s"

    echo "[static-asm] emit typelisp assembly: $name"
    if ! "$COMPILER" compile "$bench_tl" -o "$tl_s" \
        --target linux-x86_64 \
        --opt-level "$OPT_LEVEL" \
        --stdlib-root stdlib \
        --stdlib-root src \
        >"$OUT/$name.tl.log" 2>&1; then
        sed 's/^/  /' "$OUT/$name.tl.log" >&2 || true
        fail "failed to emit TypeLisp assembly for $name"
    fi
    [ -s "$tl_s" ] || fail "TypeLisp assembly is empty: $tl_s"

    # shellcheck disable=SC2046
    set -- $(count_tl "$tl_s")
    tl_total=$1
    tl_program=$2
    tl_stdlib=$3
    tl_runtime=$4

    # The linux target needs Linux libc headers, absent on Windows hosts; retry
    # with the host default target, then give up and report c columns as '-'.
    c_total="-"
    echo "[static-asm] emit C assembly (clang -S -O2 --target=x86_64-linux-gnu): $name"
    if clang -S -O2 --target=x86_64-linux-gnu "$baseline_c" -o "$c_s" \
        >"$OUT/$name.c.log" 2>&1; then
        c_total=$(count_c "$c_s")
    else
        echo "[static-asm] linux-target clang failed for $name; retry host default target"
        if clang -S -O2 "$baseline_c" -o "$c_s" >"$OUT/$name.c.host.log" 2>&1; then
            c_total=$(count_c "$c_s")
        else
            echo "[static-asm] clang could not emit C assembly for $name; c columns reported as '-'"
        fi
    fi

    tl_over_c=$(ratio "$tl_program" "$c_total")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$tl_total" "$tl_program" "$tl_stdlib" "$tl_runtime" "$c_total" "$tl_over_c" >> "$TSV"

    sum_tl_total=$((sum_tl_total + tl_total))
    sum_tl_program=$((sum_tl_program + tl_program))
    sum_tl_stdlib=$((sum_tl_stdlib + tl_stdlib))
    sum_tl_runtime=$((sum_tl_runtime + tl_runtime))
    if [ "$c_total" != "-" ]; then
        sum_c_total=$((sum_c_total + c_total))
    fi
done

[ "$found" -gt 0 ] || fail "no comparison benchmarks matched (filter='$FILTER')"

sum_ratio=$(ratio "$sum_tl_program" "$sum_c_total")

# Print the table (aligned, header row included from the TSV) plus a totals row.
ROW_FMT='%-40s %9s %11s %10s %11s %8s %10s\n'
TAB=$(printf '\t')
CR=$(printf '\r')
echo
while IFS="$TAB" read -r n a b c d e f; do
    case "$n" in
        *"$CR") n=${n%"$CR"} ;;
    esac
    # shellcheck disable=SC2059
    printf "$ROW_FMT" "$n" "$a" "$b" "$c" "$d" "$e" "$f"
done < "$TSV"
# shellcheck disable=SC2059
printf "$ROW_FMT" TOTAL "$sum_tl_total" "$sum_tl_program" "$sum_tl_stdlib" \
    "$sum_tl_runtime" "$sum_c_total" "$sum_ratio"

echo
echo "[static-asm] tsv: $TSV"
echo "[static-asm] measured $found benchmark(s)"
