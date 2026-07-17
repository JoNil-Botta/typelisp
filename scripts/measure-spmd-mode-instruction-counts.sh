#!/usr/bin/env sh
set -eu

# Deterministic Linux cachegrind counts for the checked scalar/AVX2 SPMD
# benchmark matrix. This is an opt-in measurement and baseline tool; the normal
# correctness gate remains scripts/verify-spmd-simd.sh.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEFAULT_CASES=spmd_map,spmd_zip,spmd_reduce,spmd_short_tail,spmd_mask
DEFAULT_MODES=scalar,avx2
DEFAULT_SUPPORT="$ROOT/perf/spmd-mode-support.tsv"
DEFAULT_BASELINE="$ROOT/perf/spmd-mode-insn-baseline.tsv"

RUNS=${TYPELISP_SPMD_IR_RUNS:-3}
CASES=${TYPELISP_SPMD_IR_CASES:-$DEFAULT_CASES}
MODES=${TYPELISP_SPMD_IR_MODES:-$DEFAULT_MODES}
WORKDIR=${TYPELISP_SPMD_IR_OUT:-target/spmd-mode-instruction-counts}
SUPPORT_TABLE=${TYPELISP_SPMD_IR_SUPPORT:-$DEFAULT_SUPPORT}
BASELINE=${TYPELISP_SPMD_IR_BASELINE:-$DEFAULT_BASELINE}
CHECK_BASELINE=0
UPDATE_BASELINE=0
SELF_TEST=0
COMPILER_ARG=
TAB=$(printf '\t')
CR=$(printf '\r')

usage() {
    cat <<'EOF'
usage: scripts/measure-spmd-mode-instruction-counts.sh [options] [typelisp-bin]

Options:
  --runs N              Repeated cachegrind runs per measured binary (default: 3)
  --cases LIST          Comma-separated SPMD benchmark names
  --modes LIST          Comma-separated modes: scalar,avx2
  --output DIR          Output root
  --support-table FILE  Checked support/diagnostic matrix
  --baseline FILE       Checked count baseline
  --check-baseline      Require selected rows to exactly match the baseline
  --update-baseline     Replace the baseline from a full 5x2 matrix run
  --self-test           Run fast shell/reporting mutation tests only
  -h, --help            Show this help

Environment:
  TYPELISP_BIN                 Compiler when no positional binary is given
  TYPELISP_SPMD_IR_RUNS        Default --runs
  TYPELISP_SPMD_IR_CASES       Default --cases
  TYPELISP_SPMD_IR_MODES       Default --modes
  TYPELISP_SPMD_IR_OUT         Default --output
  TYPELISP_SPMD_IR_SUPPORT     Default --support-table
  TYPELISP_SPMD_IR_BASELINE    Default --baseline

AVX-512 is deliberately excluded from cachegrind. See issue #4933.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --runs)
            [ "$#" -ge 2 ] || { echo "missing value for --runs" >&2; exit 2; }
            RUNS=$2
            shift 2
            ;;
        --cases)
            [ "$#" -ge 2 ] || { echo "missing value for --cases" >&2; exit 2; }
            CASES=$2
            shift 2
            ;;
        --modes)
            [ "$#" -ge 2 ] || { echo "missing value for --modes" >&2; exit 2; }
            MODES=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { echo "missing value for --output" >&2; exit 2; }
            WORKDIR=$2
            shift 2
            ;;
        --support-table)
            [ "$#" -ge 2 ] || { echo "missing value for --support-table" >&2; exit 2; }
            SUPPORT_TABLE=$2
            shift 2
            ;;
        --baseline)
            [ "$#" -ge 2 ] || { echo "missing value for --baseline" >&2; exit 2; }
            BASELINE=$2
            shift 2
            ;;
        --check-baseline)
            CHECK_BASELINE=1
            shift
            ;;
        --update-baseline)
            UPDATE_BASELINE=1
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
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            [ -z "$COMPILER_ARG" ] || {
                echo "only one typelisp binary may be provided" >&2
                exit 2
            }
            COMPILER_ARG=$1
            shift
            ;;
    esac
done

fail() {
    echo "[spmd-mode-ir] $*" >&2
    exit 1
}

csv_contains() {
    case ",$1," in
        *,"$2",*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_selection() {
    _label=$1
    _selected=$2
    _allowed=$3
    case "$_selected" in
        "" | ,* | *, | *,,* | *[!A-Za-z0-9_,-]*)
            fail "invalid $_label list: $_selected"
            ;;
    esac
    _old_ifs=$IFS
    IFS=,
    set -- $_selected
    IFS=$_old_ifs
    _seen=,
    for _item do
        csv_contains "$_allowed" "$_item" || fail "unknown $_label: $_item"
        case "$_seen" in
            *,"$_item",*) fail "duplicate $_label: $_item" ;;
        esac
        _seen="$_seen$_item,"
    done
}

c_flags_for_mode() {
    case "$1" in
        scalar) C_FLAGS="-O2 -fno-vectorize -fno-slp-vectorize" ;;
        avx2) C_FLAGS="-O2 -mavx2 -mno-avx512f" ;;
        *) fail "no clang flags for mode: $1" ;;
    esac
}

support_lookup() {
    _benchmark=$1
    _mode=$2
    _row=$(awk -F '\t' -v benchmark="$_benchmark" -v mode="$_mode" '
        NR == 1 { next }
        $1 == benchmark && $2 == mode {
            count++
            print $3 "\t" $4
        }
        END { if (count != 1) exit 1 }
    ' "$SUPPORT_TABLE") || fail "support table needs exactly one row for $_benchmark/$_mode"
    IFS="$TAB" read -r SUPPORT_STATUS SUPPORT_DIAGNOSTIC <<EOF
$_row
EOF
}

validate_support_table() {
    [ -f "$SUPPORT_TABLE" ] || fail "missing support table: $SUPPORT_TABLE"
    awk -F '\t' -v cases="$DEFAULT_CASES" -v modes="$DEFAULT_MODES" '
        function contains(csv, value) {
            return index("," csv ",", "," value ",") != 0
        }
        NR == 1 {
            if ($0 != "benchmark\tmode\tstatus\texpected_diagnostic") {
                print "invalid support-table header" > "/dev/stderr"
                failed = 1
            }
            next
        }
        {
            if (NF != 4) {
                print "support row must have 4 fields at line " NR > "/dev/stderr"
                failed = 1
                next
            }
            key = $1 SUBSEP $2
            if (seen[key]++) {
                print "duplicate support row: " $1 "/" $2 > "/dev/stderr"
                failed = 1
            }
            if (!contains(cases, $1) || !contains(modes, $2)) {
                print "unexpected support row: " $1 "/" $2 > "/dev/stderr"
                failed = 1
            }
            if ($3 == "supported") {
                if ($4 != "-") {
                    print "supported row must use diagnostic -: " $1 "/" $2 > "/dev/stderr"
                    failed = 1
                }
            } else if ($3 == "unsupported") {
                if ($4 !~ /^lower: /) {
                    print "unsupported row needs exact lower diagnostic: " $1 "/" $2 > "/dev/stderr"
                    failed = 1
                }
            } else {
                print "invalid support status: " $3 > "/dev/stderr"
                failed = 1
            }
            rows++
        }
        END {
            if (rows != 10) {
                print "support table must contain 10 rows, found " rows > "/dev/stderr"
                failed = 1
            }
            exit failed ? 1 : 0
        }
    ' "$SUPPORT_TABLE" || fail "invalid support table: $SUPPORT_TABLE"

    _old_ifs=$IFS
    IFS=,
    for _benchmark in $DEFAULT_CASES; do
        for _mode in $DEFAULT_MODES; do
            support_lookup "$_benchmark" "$_mode"
        done
    done
    IFS=$_old_ifs
}

write_selected_support() {
    _output=$1
    printf 'benchmark\tmode\tstatus\texpected_diagnostic\n' > "$_output"
    _old_ifs=$IFS
    IFS=,
    for _benchmark in $CASES; do
        for _mode in $MODES; do
            support_lookup "$_benchmark" "$_mode"
            printf '%s\t%s\t%s\t%s\n' \
                "$_benchmark" "$_mode" "$SUPPORT_STATUS" "$SUPPORT_DIAGNOSTIC" \
                >> "$_output"
        done
    done
    IFS=$_old_ifs
}

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

show_logs() {
    _stdout=$1
    _stderr=$2
    if [ -s "$_stdout" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$_stdout" >&2 || true
    fi
    if [ -s "$_stderr" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$_stderr" >&2 || true
    fi
}

cachegrind_ir() {
    awk '
        /^events:/ {
            ir_col = 0
            for (i = 2; i <= NF; i++) {
                if ($i == "Ir") ir_col = i - 1
            }
        }
        /^summary:/ && ir_col > 0 {
            value = $(ir_col + 1)
            gsub(/,/, "", value)
            print value
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$1"
}

run_cachegrind() {
    _benchmark=$1
    _mode=$2
    _implementation=$3
    _run=$4
    _binary=$5
    _safe=$(safe_name "$_benchmark-$_mode-$_implementation-$_run")
    _cgout="$WORKDIR/logs/$_safe.cachegrind.out"
    _stdout="$WORKDIR/logs/$_safe.stdout"
    _stderr="$WORKDIR/logs/$_safe.stderr"

    set +e
    env -i PATH="$PATH" LC_ALL=C "$VALGRIND" \
        --quiet --tool=cachegrind --cachegrind-out-file="$_cgout" \
        "$_binary" >"$_stdout" 2>"$_stderr"
    _status=$?
    set -e

    [ -s "$_cgout" ] || {
        show_logs "$_stdout" "$_stderr"
        fail "cachegrind did not write output for $_benchmark/$_mode/$_implementation run $_run"
    }
    _ir=$(cachegrind_ir "$_cgout") || {
        show_logs "$_stdout" "$_stderr"
        fail "could not parse Ir for $_benchmark/$_mode/$_implementation run $_run"
    }
    case "$_ir" in
        "" | *[!0-9]*) fail "non-numeric Ir for $_benchmark/$_mode/$_implementation: $_ir" ;;
    esac
    printf '%s\t%s\t%s\t%s\tmeasured\t%s\t%s\n' \
        "$_benchmark" "$_mode" "$_implementation" "$_run" "$_ir" "$_status" \
        >> "$RUNS_TSV"
}

measure_binary() {
    _benchmark=$1
    _mode=$2
    _implementation=$3
    _binary=$4
    _run=1
    while [ "$_run" -le "$RUNS" ]; do
        echo "[spmd-mode-ir] $_benchmark/$_mode/$_implementation run $_run"
        run_cachegrind "$_benchmark" "$_mode" "$_implementation" "$_run" "$_binary"
        _run=$((_run + 1))
    done
}

build_typelisp_supported() {
    _benchmark=$1
    _mode=$2
    _source="benchmarks/$_benchmark/bench.tl"
    _binary="$WORKDIR/bin/$_benchmark.$_mode.typelisp"
    _safe=$(safe_name "$_benchmark-$_mode-typelisp-build")
    _stdout="$WORKDIR/logs/$_safe.stdout"
    _stderr="$WORKDIR/logs/$_safe.stderr"
    echo "[spmd-mode-ir] build $_benchmark/$_mode/typelisp"
    if ! "$COMPILER" build "$_source" -o "$_binary" \
        --target linux-x86_64 \
        --opt-level 2 \
        --backend-mode "$_mode" \
        --stdlib-root stdlib \
        --stdlib-root src \
        >"$_stdout" 2>"$_stderr"; then
        show_logs "$_stdout" "$_stderr"
        fail "failed to build supported TypeLisp row $_benchmark/$_mode"
    fi
    [ -x "$_binary" ] || fail "TypeLisp build did not write executable: $_binary"
    measure_binary "$_benchmark" "$_mode" typelisp "$_binary"
}

verify_typelisp_unsupported() {
    _benchmark=$1
    _mode=$2
    _expected=$3
    _source="benchmarks/$_benchmark/bench.tl"
    _binary="$WORKDIR/bin/$_benchmark.$_mode.unsupported.typelisp"
    _safe=$(safe_name "$_benchmark-$_mode-typelisp-unsupported")
    _stdout="$WORKDIR/logs/$_safe.stdout"
    _stderr="$WORKDIR/logs/$_safe.stderr"
    echo "[spmd-mode-ir] verify unsupported $_benchmark/$_mode/typelisp"
    set +e
    "$COMPILER" build "$_source" -o "$_binary" \
        --target linux-x86_64 \
        --opt-level 2 \
        --backend-mode "$_mode" \
        --stdlib-root stdlib \
        --stdlib-root src \
        >"$_stdout" 2>"$_stderr"
    _status=$?
    set -e
    [ "$_status" -ne 0 ] || fail "unsupported row unexpectedly compiled: $_benchmark/$_mode"
    _actual=$(sed -n 's/^.*: lower: /lower: /p' "$_stderr")
    [ "$_actual" = "$_expected" ] || {
        show_logs "$_stdout" "$_stderr"
        fail "unsupported diagnostic mismatch for $_benchmark/$_mode: expected '$_expected', got '$_actual'"
    }
    printf '%s\t%s\ttypelisp\t0\tunsupported\t-\t-\n' \
        "$_benchmark" "$_mode" >> "$RUNS_TSV"
}

build_c_baseline() {
    _benchmark=$1
    _mode=$2
    _source="benchmarks/$_benchmark/baseline.c"
    _binary="$WORKDIR/bin/$_benchmark.$_mode.clang"
    _safe=$(safe_name "$_benchmark-$_mode-clang-build")
    _stdout="$WORKDIR/logs/$_safe.stdout"
    _stderr="$WORKDIR/logs/$_safe.stderr"
    c_flags_for_mode "$_mode"
    echo "[spmd-mode-ir] build $_benchmark/$_mode/clang ($C_FLAGS)"
    # C_FLAGS is a checked, script-owned flag string rather than user input.
    # shellcheck disable=SC2086
    if ! clang $C_FLAGS "$_source" -o "$_binary" >"$_stdout" 2>"$_stderr"; then
        show_logs "$_stdout" "$_stderr"
        fail "failed to build clang row $_benchmark/$_mode"
    fi
    [ -x "$_binary" ] || fail "clang build did not write executable: $_binary"
    measure_binary "$_benchmark" "$_mode" clang "$_binary"
}

summarize_runs() {
    _expected=$1
    _runs=$2
    _summary=$3
    awk -F '\t' -v expected_runs="$RUNS" '
        function problem(message) {
            print "[spmd-mode-ir] " message > "/dev/stderr"
            failed = 1
        }
        function emit(benchmark, mode, implementation, expected_status,
                      key, count, min, max, exit_status, i, status) {
            key = benchmark SUBSEP mode SUBSEP implementation
            expected_key[key] = 1
            count = row_count[key] + 0
            if (expected_status == "unsupported") {
                if (count != 1 || !(key SUBSEP 0 in run_seen) ||
                    run_status[key SUBSEP 0] != "unsupported" ||
                    run_ir[key SUBSEP 0] != "-" || run_exit[key SUBSEP 0] != "-") {
                    problem("invalid unsupported raw row for " benchmark "/" mode "/" implementation)
                    return
                }
                print benchmark, mode, implementation, "unsupported", "-", "-", "-", 0, "-", "-"
                return
            }
            if (count != expected_runs) {
                problem("missing raw runs for " benchmark "/" mode "/" implementation ": expected " expected_runs ", got " count)
                return
            }
            for (i = 1; i <= expected_runs; i++) {
                if (!(key SUBSEP i in run_seen)) {
                    problem("missing raw run " i " for " benchmark "/" mode "/" implementation)
                    return
                }
                status = run_status[key SUBSEP i]
                if (status != "measured" || run_ir[key SUBSEP i] !~ /^[0-9]+$/ ||
                    run_exit[key SUBSEP i] !~ /^[0-9]+$/) {
                    problem("invalid measured raw row for " benchmark "/" mode "/" implementation " run " i)
                    return
                }
                if (i == 1) {
                    min = run_ir[key SUBSEP i] + 0
                    max = min
                    exit_status = run_exit[key SUBSEP i]
                } else {
                    if ((run_ir[key SUBSEP i] + 0) < min) min = run_ir[key SUBSEP i] + 0
                    if ((run_ir[key SUBSEP i] + 0) > max) max = run_ir[key SUBSEP i] + 0
                    if (run_exit[key SUBSEP i] != exit_status) {
                        problem("unstable exit status for " benchmark "/" mode "/" implementation)
                        return
                    }
                }
            }
            if (min != max) {
                problem("unstable Ir for " benchmark "/" mode "/" implementation ": min=" min " max=" max)
                return
            }
            print benchmark, mode, implementation, "supported", min, min, max, expected_runs, 1, exit_status
        }
        NR == FNR {
            if (FNR == 1) next
            if (NF != 7) {
                problem("raw run row must have 7 fields at line " FNR)
                next
            }
            key = $1 SUBSEP $2 SUBSEP $3
            run_key = key SUBSEP $4
            if (run_seen[run_key]++) {
                problem("duplicate raw run: " $1 "/" $2 "/" $3 "/" $4)
                next
            }
            raw_key[key] = 1
            row_count[key]++
            run_status[run_key] = $5
            run_ir[run_key] = $6
            run_exit[run_key] = $7
            next
        }
        FNR == 1 {
            print "benchmark", "mode", "implementation", "status", "ir_count", "min_ir", "max_ir", "runs", "stable", "exit_status"
            next
        }
        {
            emit($1, $2, "typelisp", $3)
            emit($1, $2, "clang", "supported")
        }
        END {
            for (key in raw_key) {
                if (!(key in expected_key)) problem("unexpected raw measurement row")
            }
            exit failed ? 1 : 0
        }
    ' OFS="$TAB" "$_runs" "$_expected" > "$_summary"
}

generate_ratios() {
    _summary=$1
    _expected=$2
    _ratios=$3
    awk -F '\t' '
        function problem(message) {
            print "[spmd-mode-ir] " message > "/dev/stderr"
            failed = 1
        }
        NR == FNR {
            if (FNR == 1) next
            key = $1 SUBSEP $2 SUBSEP $3
            status[key] = $4
            count[key] = $5
            exit_status[key] = $10
            next
        }
        FNR == 1 {
            print "benchmark", "mode", "typelisp_ir", "clang_ir", "ratio_x", "status"
            next
        }
        {
            tl = $1 SUBSEP $2 SUBSEP "typelisp"
            c = $1 SUBSEP $2 SUBSEP "clang"
            if ($3 == "unsupported") {
                if (status[tl] != "unsupported" || status[c] != "supported") {
                    problem("summary status mismatch for unsupported pair " $1 "/" $2)
                }
                print $1, $2, "-", count[c], "-", "unsupported"
            } else {
                if (status[tl] != "supported" || status[c] != "supported") {
                    problem("summary status mismatch for supported pair " $1 "/" $2)
                    next
                }
                if (exit_status[tl] != exit_status[c]) {
                    problem("exit-status mismatch for " $1 "/" $2 ": typelisp=" exit_status[tl] " clang=" exit_status[c])
                }
                if ((count[c] + 0) <= 0) {
                    problem("zero clang count for " $1 "/" $2)
                    next
                }
                print $1, $2, count[tl], count[c], sprintf("%.6f", (count[tl] + 0.0) / count[c]), "supported"
            }
        }
        END { exit failed ? 1 : 0 }
    ' OFS="$TAB" "$_summary" "$_expected" > "$_ratios"
}

generate_geomeans() {
    _ratios=$1
    _geomeans=$2
    awk -F '\t' -v modes="$MODES" '
        NR == 1 { next }
        $6 == "supported" {
            log_sum[$2] += log($5 + 0.0)
            pairs[$2]++
        }
        END {
            print "mode", "pairs", "geomean_ratio_x"
            count = split(modes, ordered, ",")
            for (i = 1; i <= count; i++) {
                mode = ordered[i]
                if (pairs[mode] > 0) {
                    print mode, pairs[mode], sprintf("%.6f", exp(log_sum[mode] / pairs[mode]))
                } else {
                    print mode, 0, "-"
                }
            }
        }
    ' OFS="$TAB" "$_ratios" > "$_geomeans"
}

write_current_baseline() {
    _summary=$1
    _current=$2
    awk -F '\t' '
        BEGIN { OFS = "\t"; print "benchmark", "mode", "implementation", "status", "ir_count" }
        NR == 1 { next }
        { print $1, $2, $3, $4, $5 }
    ' "$_summary" > "$_current"
}

compare_baseline() {
    _baseline=$1
    _current=$2
    _require_full=$3
    awk -F '\t' -v require_full="$_require_full" '
        function problem(message) {
            print "[spmd-mode-ir] " message > "/dev/stderr"
            failed = 1
        }
        NR == FNR {
            if (FNR == 1) {
                if ($0 != "benchmark\tmode\timplementation\tstatus\tir_count") problem("invalid baseline header")
                next
            }
            key = $1 SUBSEP $2 SUBSEP $3
            if (key in base_status) problem("duplicate baseline row")
            base_status[key] = $4
            base_count[key] = $5
            base_rows++
            next
        }
        FNR == 1 {
            print "benchmark/mode/implementation | baseline | current | status"
            next
        }
        {
            key = $1 SUBSEP $2 SUBSEP $3
            current_key[key] = 1
            label = $1 "/" $2 "/" $3
            if (!(key in base_status)) {
                print label " | <missing> | " $4 ":" $5 " | missing-baseline"
                failed = 1
            } else if (base_status[key] != $4 || base_count[key] != $5) {
                print label " | " base_status[key] ":" base_count[key] " | " $4 ":" $5 " | MISMATCH"
                failed = 1
            } else {
                print label " | " base_status[key] ":" base_count[key] " | " $4 ":" $5 " | ok"
            }
            current_rows++
        }
        END {
            if (require_full == 1) {
                for (key in base_status) {
                    if (!(key in current_key)) problem("full run omitted a baseline row")
                }
                if (base_rows != current_rows) problem("full baseline row count differs")
            }
            exit failed ? 1 : 0
        }
    ' "$_baseline" "$_current"
}

run_self_test() {
    validate_selection modes scalar scalar,avx2
    csv_contains scalar scalar || fail "self-test mode selection omitted scalar"
    if csv_contains scalar avx2; then fail "self-test mode selection included avx2"; fi
    c_flags_for_mode scalar
    [ "$C_FLAGS" = "-O2 -fno-vectorize -fno-slp-vectorize" ] || fail "self-test scalar C flags"
    c_flags_for_mode avx2
    [ "$C_FLAGS" = "-O2 -mavx2 -mno-avx512f" ] || fail "self-test AVX2 C flags"

    validate_support_table
    support_lookup spmd_mask avx2
    [ "$SUPPORT_STATUS" = supported ] || fail "self-test supported spmd_mask row"
    [ "$SUPPORT_DIAGNOSTIC" = "-" ] || fail "self-test supported spmd_mask diagnostic"

    _dir="$ROOT/target/spmd-mode-instruction-count-self-test"
    rm -rf "$_dir"
    mkdir -p "$_dir"
    _expected="$_dir/expected.tsv"
    _runs="$_dir/runs.tsv"
    _summary="$_dir/summary.tsv"
    _ratios="$_dir/ratios.tsv"
    _geomeans="$_dir/geomeans.tsv"
    printf 'benchmark\tmode\tstatus\texpected_diagnostic\n' > "$_expected"
    printf 'spmd_map\tscalar\tsupported\t-\n' >> "$_expected"
    printf 'spmd_zip\tavx2\tsupported\t-\n' >> "$_expected"
    printf 'spmd_mask\tavx2\tunsupported\tlower: expected\n' >> "$_expected"
    printf 'benchmark\tmode\timplementation\trun\tstatus\tir_count\texit_status\n' > "$_runs"
    printf 'spmd_map\tscalar\ttypelisp\t1\tmeasured\t100\t7\n' >> "$_runs"
    printf 'spmd_map\tscalar\ttypelisp\t2\tmeasured\t100\t7\n' >> "$_runs"
    printf 'spmd_map\tscalar\tclang\t1\tmeasured\t50\t7\n' >> "$_runs"
    printf 'spmd_map\tscalar\tclang\t2\tmeasured\t50\t7\n' >> "$_runs"
    printf 'spmd_zip\tavx2\ttypelisp\t1\tmeasured\t400\t9\n' >> "$_runs"
    printf 'spmd_zip\tavx2\ttypelisp\t2\tmeasured\t400\t9\n' >> "$_runs"
    printf 'spmd_zip\tavx2\tclang\t1\tmeasured\t100\t9\n' >> "$_runs"
    printf 'spmd_zip\tavx2\tclang\t2\tmeasured\t100\t9\n' >> "$_runs"
    printf 'spmd_mask\tavx2\ttypelisp\t0\tunsupported\t-\t-\n' >> "$_runs"
    printf 'spmd_mask\tavx2\tclang\t1\tmeasured\t80\t11\n' >> "$_runs"
    printf 'spmd_mask\tavx2\tclang\t2\tmeasured\t80\t11\n' >> "$_runs"

    _saved_runs=$RUNS
    RUNS=2
    summarize_runs "$_expected" "$_runs" "$_summary" || fail "self-test stable summary"
    generate_ratios "$_summary" "$_expected" "$_ratios" || fail "self-test ratio generation"
    MODES=scalar,avx2
    generate_geomeans "$_ratios" "$_geomeans"
    grep -F "spmd_map${TAB}scalar${TAB}100${TAB}50${TAB}2.000000${TAB}supported" "$_ratios" >/dev/null || \
        fail "self-test scalar ratio"
    grep -F "spmd_zip${TAB}avx2${TAB}400${TAB}100${TAB}4.000000${TAB}supported" "$_ratios" >/dev/null || \
        fail "self-test AVX2 ratio"
    grep -F "spmd_mask${TAB}avx2${TAB}-${TAB}80${TAB}-${TAB}unsupported" "$_ratios" >/dev/null || \
        fail "self-test unsupported ratio row"
    grep -F "scalar${TAB}1${TAB}2.000000" "$_geomeans" >/dev/null || fail "self-test scalar geomean"
    grep -F "avx2${TAB}1${TAB}4.000000" "$_geomeans" >/dev/null || fail "self-test AVX2 geomean"

    cp "$_runs" "$_dir/unstable.tsv"
    sed 's/spmd_zip\tavx2\ttypelisp\t2\tmeasured\t400\t9/spmd_zip\tavx2\ttypelisp\t2\tmeasured\t401\t9/' \
        "$_dir/unstable.tsv" > "$_dir/unstable-mutated.tsv"
    if summarize_runs "$_expected" "$_dir/unstable-mutated.tsv" "$_dir/unstable-summary.tsv" 2>/dev/null; then
        fail "self-test did not reject unstable Ir"
    fi
    grep -v "spmd_map${TAB}scalar${TAB}clang${TAB}2" "$_runs" > "$_dir/missing.tsv"
    if summarize_runs "$_expected" "$_dir/missing.tsv" "$_dir/missing-summary.tsv" 2>/dev/null; then
        fail "self-test did not reject missing run"
    fi
    RUNS=$_saved_runs
    echo "SPMD mode instruction-count harness self-tests passed"
}

case "$RUNS" in
    "" | *[!0-9]* | 0) echo "--runs must be a positive integer: $RUNS" >&2; exit 2 ;;
esac
validate_selection cases "$CASES" "$DEFAULT_CASES"
validate_selection modes "$MODES" "$DEFAULT_MODES"
[ "$CHECK_BASELINE" -eq 0 ] || [ "$UPDATE_BASELINE" -eq 0 ] || {
    echo "--check-baseline and --update-baseline are mutually exclusive" >&2
    exit 2
}

if [ "$SELF_TEST" -eq 1 ]; then
    run_self_test
    exit 0
fi

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "SPMD mode instruction counts are Linux-only (requires valgrind/cachegrind)"
        exit 0
        ;;
esac

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain
[ "$NL_BOOTSTRAP_TARGET" = linux-x86_64 ] || fail "Linux target configuration required"

for _tool in valgrind clang awk sed tr grep; do
    command -v "$_tool" >/dev/null 2>&1 || fail "missing tool: $_tool"
done
VALGRIND=$(command -v valgrind)

if [ -n "$COMPILER_ARG" ]; then
    COMPILER=$COMPILER_ARG
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
case "$COMPILER" in
    /*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || fail "typelisp compiler is not executable: $COMPILER"

validate_support_table
if [ "$UPDATE_BASELINE" -eq 1 ] && \
   { [ "$CASES" != "$DEFAULT_CASES" ] || [ "$MODES" != "$DEFAULT_MODES" ]; }; then
    fail "--update-baseline requires the full default case and mode matrix"
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/bin" "$WORKDIR/logs"
RUNS_TSV="$WORKDIR/runs.tsv"
SUMMARY_TSV="$WORKDIR/summary.tsv"
RATIOS_TSV="$WORKDIR/ratios.tsv"
GEOMEANS_TSV="$WORKDIR/geomeans.tsv"
METADATA_TSV="$WORKDIR/metadata.tsv"
SELECTED_SUPPORT_TSV="$WORKDIR/support.tsv"
CURRENT_BASELINE_TSV="$WORKDIR/current-baseline.tsv"
printf 'benchmark\tmode\timplementation\trun\tstatus\tir_count\texit_status\n' > "$RUNS_TSV"
write_selected_support "$SELECTED_SUPPORT_TSV"

_typelisp_version=$("$COMPILER" --version 2>&1 | sed -n '1p' | tr "$TAB$CR" '  ')
_clang_version=$(clang --version | sed -n '1p' | tr "$TAB$CR" '  ')
_valgrind_version=$("$VALGRIND" --version | sed -n '1p' | tr "$TAB$CR" '  ')
printf 'key\tvalue\n' > "$METADATA_TSV"
printf 'schema_version\t1\n' >> "$METADATA_TSV"
printf 'typelisp_compiler\t%s\n' "$COMPILER" >> "$METADATA_TSV"
printf 'typelisp_version\t%s\n' "$_typelisp_version" >> "$METADATA_TSV"
printf 'typelisp_flags\t--target linux-x86_64 --opt-level 2 --backend-mode <mode>\n' >> "$METADATA_TSV"
printf 'clang_version\t%s\n' "$_clang_version" >> "$METADATA_TSV"
c_flags_for_mode scalar
printf 'clang_scalar_flags\t%s\n' "$C_FLAGS" >> "$METADATA_TSV"
c_flags_for_mode avx2
printf 'clang_avx2_flags\t%s\n' "$C_FLAGS" >> "$METADATA_TSV"
printf 'valgrind_version\t%s\n' "$_valgrind_version" >> "$METADATA_TSV"
printf 'avx512_methodology\thttps://github.com/JoNil-Botta/typelisp/issues/4933\n' >> "$METADATA_TSV"

while IFS="$TAB" read -r _benchmark _mode _status _diagnostic || [ -n "$_benchmark" ]; do
    [ "$_benchmark" != benchmark ] || continue
    if [ "$_status" = supported ]; then
        build_typelisp_supported "$_benchmark" "$_mode"
    else
        verify_typelisp_unsupported "$_benchmark" "$_mode" "$_diagnostic"
    fi
    build_c_baseline "$_benchmark" "$_mode"
done < "$SELECTED_SUPPORT_TSV"

summarize_runs "$SELECTED_SUPPORT_TSV" "$RUNS_TSV" "$SUMMARY_TSV" || \
    fail "raw measurements are missing or unstable"
generate_ratios "$SUMMARY_TSV" "$SELECTED_SUPPORT_TSV" "$RATIOS_TSV" || \
    fail "could not generate parity-checked ratios"
generate_geomeans "$RATIOS_TSV" "$GEOMEANS_TSV"
write_current_baseline "$SUMMARY_TSV" "$CURRENT_BASELINE_TSV"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    mkdir -p "$(dirname -- "$BASELINE")"
    cp "$CURRENT_BASELINE_TSV" "$BASELINE"
    echo "[spmd-mode-ir] baseline updated: $BASELINE"
elif [ "$CHECK_BASELINE" -eq 1 ]; then
    [ -f "$BASELINE" ] || fail "missing baseline: $BASELINE"
    _full=0
    if [ "$CASES" = "$DEFAULT_CASES" ] && [ "$MODES" = "$DEFAULT_MODES" ]; then _full=1; fi
    compare_baseline "$BASELINE" "$CURRENT_BASELINE_TSV" "$_full" || \
        fail "SPMD mode instruction counts differ from $BASELINE"
fi

echo "[spmd-mode-ir] metadata: $METADATA_TSV"
echo "[spmd-mode-ir] raw runs: $RUNS_TSV"
echo "[spmd-mode-ir] summary: $SUMMARY_TSV"
cat "$SUMMARY_TSV"
echo "[spmd-mode-ir] ratios: $RATIOS_TSV"
cat "$RATIOS_TSV"
echo "[spmd-mode-ir] geomeans: $GEOMEANS_TSV"
cat "$GEOMEANS_TSV"
