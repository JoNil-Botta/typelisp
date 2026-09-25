#!/usr/bin/env sh
# measure-pass-firing.sh - census of which optimizer pass slots change code, per program.
#
# usage: scripts/measure-pass-firing.sh <compiler> [--jobs N] [--out DIR] [--counts-only]
#            [--max-exact-functions N] [<file.tl>...]
#
# Compiles each program at --opt-level 2 for linux-x86_64 and records, per pass
# slot (the names `--trace-passes` prints and `--dump-ir after-<slot>` accepts)
# and per program, how many functions that slot changed. Default programs:
# benchmarks/*/bench.tl, examples/*.tl, tests/integration/*.tl, tests/inline/*.tl,
# the tools/*/*.tl programs that define main, and src/main.tl.
#
# Method "exact": one `--trace-passes --dump-ir` compile gives every function's
# ordered slot observations, then one `--dump-ir after-<slot>` compile per slot
# gives the IR after each of them; a slot changed a function when that IR
# differs from the IR at the function's previous observation. Method "counts"
# (--counts-only, programs above --max-exact-functions (default 3000), and
# programs whose IR dump fails, e.g. src/main.tl) reads only the trace: a slot
# changed a function when its block or instruction count moved. That is a lower
# bound: pure moves (LICM, sinks) and in-place rewrites go unseen.
# Unobserved steps (const-length rewrite, loop_bce, prune, LGA-1 specialize,
# the late scratch reset, ...) are charged to the next observed slot. The
# runtime module is left out: every program carries the same copy.
#
# Writes DIR/firing.tsv (pass, program, functions_changed, method) and
# DIR/summary.tsv (pass, programs, benchmark_programs, other_programs, scope,
# benchmarks), where scope is none, benchmark-only or general. DIR defaults to
# target/exp/pass-firing; programs that fail to compile are listed in
# DIR/failed.txt.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "${1:-}" = "--job" ]; then # --job <compiler> <out> <counts-only> <max-exact> <file>
    tl=$2 out=$3 counts_only=$4 max_exact=$5 file=$6
    key=$(printf '%s' "$file" | tr '/' '_')
    work="$out/work/$key"
    mkdir -p "$work"
    set -- --opt-level 2 --target linux-x86_64 --stdlib-root stdlib --stdlib-root src
    method=counts
    if [ "$counts_only" = 0 ] &&
        "$tl" compile "$file" -o "$work/round_input.ir" "$@" --dump-ir after-round_input --trace-passes \
            > /dev/null 2> "$work/stderr"; then
        grep '^optimizer-pass|' "$work/stderr" > "$work/trace" || true
        if [ "$(cut -d'|' -f2 "$work/trace" | sort -u | wc -l)" -le "$max_exact" ]; then
            method=exact
            for slot in $(cut -d'|' -f3 "$work/trace" | sort -u | grep -vx round_input); do
                "$tl" compile "$file" -o "$work/$slot.ir" "$@" --dump-ir "after-$slot" \
                    > /dev/null 2>&1 || { method=counts; break; }
            done
        fi
    fi
    if [ "$method" = counts ]; then
        rm -f "$work"/*.ir
        if ! "$tl" compile "$file" -o "$work/out.s" "$@" --trace-passes > /dev/null 2> "$work/stderr"; then
            echo "$file" >> "$out/failed.txt"
            rm -rf "$work"
            exit 0
        fi
        grep '^optimizer-pass|' "$work/stderr" > "$work/trace" || true
    fi
    rm -f "$work/stderr" "$work/out.s"
    while :; do
        if awk -v prog="$file" -v method="$method" '
            function flush() {
                sub(/\n+$/, "", buf) # the last record of a dump has no blank separator
                if (key != "") { if (!(buf in text)) text[buf] = ++ntext; snap[key] = text[buf] }
                key = ""; buf = ""
            }
            FNR == 1 { flush(); file++ }
            file == 1 {
                split($0, f, "|")
                if (index(f[2], "stdlib/runtime.tl::") == 1) next
                n++; fn[n] = f[2]; slot[n] = f[3]; shape[n] = f[4] "|" f[5]
                occ[n] = ++seen[f[2] SUBSEP f[3]]
                next
            }
            /^after [^ ]+ @/ { flush(); key = $2 SUBSEP substr($0, length($2) + 9) SUBSEP (++dumped[$2 SUBSEP substr($0, length($2) + 9)]); next }
            { buf = buf $0 "\n" }
            END {
                flush()
                for (i = 1; i <= n; i++) {
                    k = slot[i] SUBSEP fn[i] SUBSEP occ[i]
                    if (method == "exact" && !(k in snap)) exit 3
                    cur = method == "exact" ? snap[k] : shape[i]
                    if ((fn[i] in prev) && prev[fn[i]] != cur) changed[slot[i] SUBSEP fn[i]] = 1
                    prev[fn[i]] = cur; slots[slot[i]] = 1
                }
                for (k in changed) { split(k, a, SUBSEP); count[a[1]]++ }
                for (s in slots) printf "%s\t%s\t%d\t%s\n", s, prog, count[s], method
            }' "$work/trace" $(ls "$work"/*.ir 2>/dev/null) > "$work/firing.tsv"; then
            break
        fi
        [ "$method" = exact ] || { echo "$file" >> "$out/failed.txt"; break; }
        method=counts # the dumps do not line up with the trace
        rm -f "$work"/*.ir
    done
    mv "$work/firing.tsv" "$out/work/$key.tsv" 2>/dev/null || true
    rm -rf "$work"
    exit 0
fi

[ "$#" -ge 1 ] || { sed -n '4,28p' "$0" >&2; exit 2; }
TL=$1
shift
case "$TL" in /*) ;; *) TL="$ROOT/$TL" ;; esac
[ -x "$TL" ] || { echo "not executable: $TL" >&2; exit 2; }
JOBS=8 OUT="$ROOT/target/exp/pass-firing" COUNTS_ONLY=0 MAX_EXACT=3000 FILES=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --jobs) JOBS=$2; shift ;;
        --out) OUT=$2; shift ;;
        --counts-only) COUNTS_ONLY=1 ;;
        --max-exact-functions) MAX_EXACT=$2; shift ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) FILES="$FILES $1" ;;
    esac
    shift
done
if [ -z "$FILES" ]; then
    FILES="src/main.tl $(ls benchmarks/*/bench.tl examples/*.tl tests/integration/*.tl tests/inline/*.tl)"
    FILES="$FILES $(grep -l '^(define (main' tools/*/*.tl)"
fi
rm -rf "$OUT"
mkdir -p "$OUT/work"
OUT=$(cd "$OUT" && pwd)
for f in $FILES; do
    printf '%s\n' "--job $TL $OUT $COUNTS_ONLY $MAX_EXACT $f"
done | xargs -P "$JOBS" -L 1 "$0"

printf 'pass\tprogram\tfunctions_changed\tmethod\n' > "$OUT/firing.tsv"
cat "$OUT"/work/*.tsv | sort >> "$OUT/firing.tsv"
awk -F'\t' '
    NR == 1 { next }
    $3 == 0 { slots[$1] = 1; next }
    {
        slots[$1] = 1; programs[$1]++
        if ($2 ~ /^benchmarks\/[^\/]+\/bench\.tl$/) {
            split($2, p, "/"); bench[$1]++; names[$1] = names[$1] (bench[$1] > 1 ? "," : "") p[2]
        }
    }
    END {
        for (s in slots) {
            other = programs[s] - bench[s]
            scope = programs[s] == 0 ? "none" : other == 0 ? "benchmark-only" : "general"
            printf "%s\t%d\t%d\t%d\t%s\t%s\n", s, programs[s], bench[s], other, scope, names[s]
        }
    }' "$OUT/firing.tsv" | sort > "$OUT/summary.body"
{ printf 'pass\tprograms\tbenchmark_programs\tother_programs\tscope\tbenchmarks\n'; cat "$OUT/summary.body"; } > "$OUT/summary.tsv"
rm -f "$OUT/summary.body"
rm -rf "$OUT/work"
echo "[pass-firing] $(($(wc -l < "$OUT/summary.tsv") - 1)) slots over $(echo $FILES | wc -w) programs; see $OUT/summary.tsv"
[ ! -s "$OUT/failed.txt" ] || echo "[pass-firing] $(wc -l < "$OUT/failed.txt") programs failed to compile: $OUT/failed.txt"
