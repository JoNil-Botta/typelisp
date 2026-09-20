#!/usr/bin/env sh
set -eu
# check-compiler-scaling.sh - compiler cost growth along one input dimension.
#
# The instruction-count gate pins the compiler's cost on fixed inputs. It cannot
# see a cost that is fine at today's sizes and quadratic in the size of a
# function, a struct or a module. This gate measures that directly (#7773).
#
# For every row of perf/compiler-scaling-budgets.tsv it generates three
# self-checking programs of sizes S < M < L along one dimension with
# tools/compiler-scaling, proves each program still computes its expected
# result, measures the compiler under Cachegrind on each, and derives two
# numbers in which the compiler's fixed start-up cost cancels:
#
#   marginal  (Ir(L) - Ir(M)) / (L - M)      instructions per added unit
#   growth    marginal / ((Ir(M) - Ir(S)) / (M - S))
#
# growth is 1.0 for a linear cost. With sizes in ratio 1:2:4 it is 2.0 for a
# quadratic one. Both numbers must stay within the row's tolerance of the
# checked values, in either direction: an improvement is accepted by committing
# the refreshed row, exactly like the instruction-count baselines.
#
# Differences of instruction counts make the result independent of the host's
# environment and paths (they move the absolute count by a few hundred
# instructions), so a local refresh reproduces the CI values:
#
#   scripts/check-compiler-scaling.sh --update-budgets <compiler>

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

BUDGETS=perf/compiler-scaling-budgets.tsv
WORKDIR=target/compiler-scaling
UPDATE=0
SELF_TEST=0
COMPILER_ARG=
# Percent of the checked marginal cost, and absolute growth, a row may move.
MARGINAL_TOLERANCE_PCT=10
GROWTH_TOLERANCE_MILLI=100

usage() {
    cat <<'EOF'
usage: scripts/check-compiler-scaling.sh [options] [typelisp-compiler]

Options:
  --budgets FILE     Budget TSV (default: perf/compiler-scaling-budgets.tsv)
  --output DIR       Work directory (default: target/compiler-scaling)
  --update-budgets   Rewrite the measured columns of every budget row
  --self-test        Check the comparison logic against fixtures and exit;
                     needs no compiler, valgrind or Linux host
  -h, --help         Show this help

Environment:
  TYPELISP_BIN       Compiler to measure when no argument is given. The script
                     never downloads a compiler.
EOF
}

fail() {
    echo "[compiler-scaling] $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --budgets)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            BUDGETS=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            WORKDIR=$2
            shift 2
            ;;
        --update-budgets)
            UPDATE=1
            shift
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            exit 2
            ;;
        *)
            [ -z "$COMPILER_ARG" ] || { usage >&2; exit 2; }
            COMPILER_ARG=$1
            shift
            ;;
    esac
done

# Budget rows: dimension phase small medium large marginal_ir growth_milli owner
#   phase         check | opt0 | opt1 | opt2
#   marginal_ir   checked instructions per added unit between medium and large
#   growth_milli  checked growth x 1000
#   owner         `-`, or the issue that owns a row whose growth is not linear
validate_budgets() {
    awk -F '\t' '
        function bad(message) {
            print "[compiler-scaling] " FILENAME ":" FNR ": " message > "/dev/stderr"
            failed = 1
        }
        /^#/ || /^[[:space:]]*$/ { next }
        {
            if (NF != 8) { bad("expected 8 tab-separated fields, found " NF); next }
            if ($1 !~ /^[a-z][a-z0-9-]*$/) bad("invalid dimension: " $1)
            if ($2 !~ /^(check|opt0|opt1|opt2)$/) bad("invalid phase: " $2)
            for (i = 3; i <= 7; i++)
                if ($i !~ /^[1-9][0-9]*$/) bad("field " i " is not a positive integer: " $i)
            if (!($3 + 0 < $4 + 0 && $4 + 0 < $5 + 0)) bad("sizes must increase: " $3 " " $4 " " $5)
            if ($8 != "-" && $8 !~ /^#[1-9][0-9]*$/) bad("owner must be - or #<issue>: " $8)
            if (seen[$1 SUBSEP $2]++) bad("duplicate row: " $1 " " $2)
            rows++
        }
        END {
            if (!failed && rows == 0) {
                print "[compiler-scaling] " FILENAME ": no budget rows" > "/dev/stderr"
                failed = 1
            }
            exit failed ? 1 : 0
        }
    ' "$1"
}

# compare BUDGETS MEASUREMENTS
#   MEASUREMENTS rows: dimension phase ir_small ir_medium ir_large
# Prints one report line per budget row and fails on any row that is missing,
# unmeasurable, regressed or improved beyond tolerance, and on any measurement
# that has no budget row.
compare() {
    awk -F '\t' \
        -v marginal_pct="$MARGINAL_TOLERANCE_PCT" \
        -v growth_tol="$GROWTH_TOLERANCE_MILLI" '
        FNR == NR {
            if ($0 ~ /^#/ || $0 ~ /^[[:space:]]*$/) next
            key = $1 SUBSEP $2
            order[++count] = key
            small[key] = $3; medium[key] = $4; large[key] = $5
            want_marginal[key] = $6; want_growth[key] = $7; owner[key] = $8
            next
        }
        {
            key = $1 SUBSEP $2
            if (!(key in want_marginal)) {
                print $1 " " $2 " | measured without a budget row"
                failed = 1
                next
            }
            if (key in have) {
                print $1 " " $2 " | measured twice"
                failed = 1
                next
            }
            have[key] = 1
            ir_s[key] = $3; ir_m[key] = $4; ir_l[key] = $5
        }
        END {
            print "row | marginal Ir/unit (checked) | growth (checked) | owner | status"
            for (i = 1; i <= count; i++) {
                key = order[i]
                split(key, part, SUBSEP)
                name = part[1] " " part[2]
                if (!(key in have)) {
                    print name " | <missing> | <missing> | " owner[key] " | missing-measurement"
                    failed = 1
                    continue
                }
                low = (ir_m[key] - ir_s[key]) / (medium[key] - small[key])
                high = (ir_l[key] - ir_m[key]) / (large[key] - medium[key])
                if (low <= 0 || high <= 0) {
                    print name " | n/a | n/a | " owner[key] " | non-increasing-cost"
                    failed = 1
                    continue
                }
                marginal = int(high + 0.5)
                growth = int(high * 1000 / low + 0.5)
                status = "ok"
                slack = want_marginal[key] * marginal_pct / 100
                if (marginal > want_marginal[key] + slack || growth > want_growth[key] + growth_tol) {
                    status = "REGRESSION"
                    failed = 1
                } else if (marginal < want_marginal[key] - slack || growth < want_growth[key] - growth_tol) {
                    status = "IMPROVEMENT (refresh the row)"
                    failed = 1
                }
                printf "%s | %d (%d) | %.3f (%.3f) | %s | %s\n", name, marginal, \
                    want_marginal[key], growth / 1000, want_growth[key] / 1000, owner[key], status
            }
            exit failed ? 1 : 0
        }
    ' "$1" "$2"
}

# refresh BUDGETS MEASUREMENTS: rewrite the two measured columns in place,
# keeping comments, order, sizes and owners.
refresh() {
    awk -F '\t' -v OFS='\t' '
        FNR == NR {
            key = $1 SUBSEP $2
            ir_s[key] = $3; ir_m[key] = $4; ir_l[key] = $5
            have[key] = 1
            next
        }
        /^#/ || /^[[:space:]]*$/ { print; next }
        {
            key = $1 SUBSEP $2
            if (!(key in have)) {
                print "[compiler-scaling] no measurement for " $1 " " $2 > "/dev/stderr"
                failed = 1
                print
                next
            }
            low = (ir_m[key] - ir_s[key]) / ($4 - $3)
            high = (ir_l[key] - ir_m[key]) / ($5 - $4)
            if (low <= 0 || high <= 0) {
                print "[compiler-scaling] non-increasing cost for " $1 " " $2 > "/dev/stderr"
                failed = 1
                print
                next
            }
            $6 = int(high + 0.5)
            $7 = int(high * 1000 / low + 0.5)
            print
        }
        END { exit failed ? 1 : 0 }
    ' "$2" "$1"
}

self_test() {
    _st=$(mktemp -d "${TMPDIR:-/tmp}/compiler-scaling-self-test.XXXXXX")
    trap 'rm -rf "$_st"' EXIT HUP INT TERM
    _st_status=0
    expect() {
        _label=$1
        _want=$2
        shift 2
        _got=0
        "$@" > "$_st/out" 2> "$_st/err" || _got=$?
        if [ "$_got" -ne "$_want" ]; then
            echo "self-test $_label: expected exit $_want, got $_got" >&2
            sed 's/^/    /' "$_st/out" "$_st/err" >&2
            _st_status=1
        fi
    }
    expect_text() {
        _label=$1
        _text=$2
        if ! grep -F -- "$_text" "$_st/out" "$_st/err" > /dev/null; then
            echo "self-test $_label: output does not contain: $_text" >&2
            _st_status=1
        fi
    }
    # Linear: 100 Ir per unit at both steps. Quadratic-ish: 100 then 200.
    printf 'decls\tcheck\t100\t200\t400\t100\t1000\t-\n' > "$_st/budgets"
    printf 'cfg\topt1\t100\t200\t400\t200\t2000\t#1\n' >> "$_st/budgets"
    printf 'decls\tcheck\t50000\t60000\t80000\n' > "$_st/ok"
    printf 'cfg\topt1\t50000\t60000\t100000\n' >> "$_st/ok"

    expect budgets-valid 0 validate_budgets "$_st/budgets"
    expect ok 0 compare "$_st/budgets" "$_st/ok"
    expect_text ok "decls check | 100 (100) | 1.000 (1.000) | - | ok"
    expect_text ok "cfg opt1 | 200 (200) | 2.000 (2.000) | #1 | ok"

    # Within tolerance: +9% marginal and +0.09 growth.
    printf 'decls\tcheck\t50000\t60000\t81800\n' > "$_st/m"
    printf 'cfg\topt1\t50000\t60000\t100000\n' >> "$_st/m"
    expect within-tolerance 0 compare "$_st/budgets" "$_st/m"

    # A linear row that turns quadratic.
    printf 'decls\tcheck\t50000\t60000\t100000\n' > "$_st/m"
    printf 'cfg\topt1\t50000\t60000\t100000\n' >> "$_st/m"
    expect regression 1 compare "$_st/budgets" "$_st/m"
    expect_text regression "decls check | 200 (100) | 2.000 (1.000) | - | REGRESSION"

    # Same growth, 20% more per unit everywhere.
    printf 'decls\tcheck\t50000\t62000\t86000\n' > "$_st/m"
    printf 'cfg\topt1\t50000\t60000\t100000\n' >> "$_st/m"
    expect marginal-regression 1 compare "$_st/budgets" "$_st/m"
    expect_text marginal-regression "decls check | 120 (100) | 1.000 (1.000) | - | REGRESSION"

    # The owned quadratic row becomes linear: accepted only by refreshing it.
    printf 'decls\tcheck\t50000\t60000\t80000\n' > "$_st/m"
    printf 'cfg\topt1\t50000\t60000\t80000\n' >> "$_st/m"
    expect improvement 1 compare "$_st/budgets" "$_st/m"
    expect_text improvement "cfg opt1 | 100 (200) | 1.000 (2.000) | #1 | IMPROVEMENT"

    printf 'decls\tcheck\t50000\t60000\t80000\n' > "$_st/m"
    expect missing-measurement 1 compare "$_st/budgets" "$_st/m"
    expect_text missing-measurement "cfg opt1 | <missing>"

    cat "$_st/ok" > "$_st/m"
    printf 'fields\tcheck\t1\t2\t3\n' >> "$_st/m"
    expect unbudgeted-measurement 1 compare "$_st/budgets" "$_st/m"
    expect_text unbudgeted-measurement "fields check | measured without a budget row"

    cat "$_st/ok" "$_st/ok" > "$_st/m"
    expect duplicate-measurement 1 compare "$_st/budgets" "$_st/m"

    # A larger input that costs no more than a smaller one is not a result.
    printf 'decls\tcheck\t50000\t50000\t80000\n' > "$_st/m"
    printf 'cfg\topt1\t50000\t60000\t100000\n' >> "$_st/m"
    expect non-increasing 1 compare "$_st/budgets" "$_st/m"
    expect_text non-increasing "non-increasing-cost"

    : > "$_st/empty"
    expect budgets-empty 1 validate_budgets "$_st/empty"
    for _bad in \
        'decls	check	100	200	400	100	1000' \
        'Decls	check	100	200	400	100	1000	-' \
        'decls	opt3	100	200	400	100	1000	-' \
        'decls	check	200	200	400	100	1000	-' \
        'decls	check	100	200	400	0	1000	-' \
        'decls	check	100	200	400	100	1000	7773' \
        'decls	check	100	200	400	100	1.5	-'; do
        printf '%s\n' "$_bad" > "$_st/bad"
        expect "budgets-invalid" 1 validate_budgets "$_st/bad"
    done
    cat "$_st/budgets" "$_st/budgets" > "$_st/bad"
    expect budgets-duplicate 1 validate_budgets "$_st/bad"

    # Refresh rewrites only the measured columns.
    printf '# kept comment\n' > "$_st/b2"
    printf 'decls\tcheck\t100\t200\t400\t1\t1\t-\n' >> "$_st/b2"
    printf 'cfg\topt1\t100\t200\t400\t1\t1\t#1\n' >> "$_st/b2"
    refresh "$_st/b2" "$_st/ok" > "$_st/b3" 2> "$_st/err" || _st_status=1
    if ! diff - "$_st/b3" > "$_st/out" <<'EOF'
# kept comment
decls	check	100	200	400	100	1000	-
cfg	opt1	100	200	400	200	2000	#1
EOF
    then
        echo "self-test refresh: unexpected refreshed budgets" >&2
        sed 's/^/    /' "$_st/out" >&2
        _st_status=1
    fi
    printf 'decls\tcheck\t50000\t60000\t80000\n' > "$_st/m"
    expect refresh-missing 1 refresh "$_st/b2" "$_st/m"

    [ "$_st_status" -eq 0 ] || exit 1
    echo "compiler-scaling self-test passed"
}

if [ "$SELF_TEST" -eq 1 ]; then
    [ -z "$COMPILER_ARG" ] || fail "--self-test does not accept a compiler"
    self_test
    exit 0
fi

COMPILER=${COMPILER_ARG:-${TYPELISP_BIN:-}}
[ -n "$COMPILER" ] || fail "no compiler: pass one or set TYPELISP_BIN"
case "$COMPILER" in
    /*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || fail "compiler is not executable: $COMPILER"
[ "$(uname -s)" = Linux ] || fail "Cachegrind measurements need a Linux host"
command -v valgrind > /dev/null 2>&1 ||
    fail "valgrind is required; install it rather than skipping this gate"
[ -f "$BUDGETS" ] || fail "missing budgets: $BUDGETS"
validate_budgets "$BUDGETS" || fail "invalid budgets: $BUDGETS"

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/src" "$WORKDIR/out"
GENERATOR="$WORKDIR/compiler-scaling"
echo "[compiler-scaling] compiler: $("$COMPILER" --version)"
echo "[compiler-scaling] build generator"
"$COMPILER" build tools/compiler-scaling/main.tl -o "$GENERATOR" --stdlib-root stdlib \
    > "$WORKDIR/generator.log" 2>&1 || {
    cat "$WORKDIR/generator.log" >&2
    fail "generator build failed"
}

# Generate each distinct program once and prove it still computes its expected
# result before any of it counts as a measurement.
awk -F '\t' '!/^#/ && NF == 8 { for (i = 3; i <= 5; i++) print $1 "\t" $i }' "$BUDGETS" |
    sort -u > "$WORKDIR/programs.tsv"
: > "$WORKDIR/sources.tsv"
while IFS='	' read -r dimension size; do
    source="$WORKDIR/src/${dimension}_$size.tl"
    "$GENERATOR" "$dimension" "$size" > "$source" ||
        fail "generator rejected $dimension $size"
    status=0
    "$COMPILER" build "$source" -o "$WORKDIR/out/${dimension}_$size" --opt-level 1 \
        > "$WORKDIR/out/${dimension}_$size.build.log" 2>&1 || {
        cat "$WORKDIR/out/${dimension}_$size.build.log" >&2
        fail "$dimension $size does not build"
    }
    "$WORKDIR/out/${dimension}_$size" > /dev/null 2>&1 || status=$?
    [ "$status" -eq 42 ] ||
        fail "$dimension $size computed a wrong result (exit $status, expected 42)"
    printf '%s\t%s\t%s\n' "$dimension" "$size" \
        "$(sha256sum "$source" | cut -d ' ' -f 1)" >> "$WORKDIR/sources.tsv"
done < "$WORKDIR/programs.tsv"

instructions() {
    _log=$1
    shift
    valgrind --tool=cachegrind --cache-sim=no --vex-guest-chase=no \
        --cachegrind-out-file=/dev/null "$@" > /dev/null 2> "$_log" || {
        cat "$_log" >&2
        return 1
    }
    sed -n 's/.*I *refs: *\([0-9,]*\).*/\1/p' "$_log" | tr -d ,
}

: > "$WORKDIR/measurements.tsv"
while IFS='	' read -r dimension phase small medium large _marginal _growth _owner; do
    case "$dimension" in "" | \#*) continue ;; esac
    line="$dimension	$phase"
    for size in "$small" "$medium" "$large"; do
        source="$WORKDIR/src/${dimension}_$size.tl"
        log="$WORKDIR/out/${dimension}_${size}_$phase.cachegrind.log"
        if [ "$phase" = check ]; then
            count=$(instructions "$log" "$COMPILER" check "$source") ||
                fail "$dimension $phase $size: check failed"
        else
            count=$(instructions "$log" "$COMPILER" compile "$source" \
                --opt-level "${phase#opt}" -o "$WORKDIR/out/measure.s") ||
                fail "$dimension $phase $size: compile failed"
        fi
        case "$count" in
            "" | *[!0-9]*) fail "$dimension $phase $size: no instruction count" ;;
        esac
        line="$line	$count"
    done
    echo "[compiler-scaling] $line"
    printf '%s\n' "$line" >> "$WORKDIR/measurements.tsv"
done < "$BUDGETS"

if [ "$UPDATE" -eq 1 ]; then
    refresh "$BUDGETS" "$WORKDIR/measurements.tsv" > "$WORKDIR/budgets.new" ||
        fail "budgets were not refreshed"
    cp "$WORKDIR/budgets.new" "$BUDGETS"
    echo "[compiler-scaling] refreshed $BUDGETS"
fi

status=0
compare "$BUDGETS" "$WORKDIR/measurements.tsv" > "$WORKDIR/report.txt" || status=$?
cat "$WORKDIR/report.txt"
[ "$status" -eq 0 ] || fail "compiler scaling is outside its checked budgets"
echo "compiler scaling check passed"
