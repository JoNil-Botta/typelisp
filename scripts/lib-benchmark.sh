#!/usr/bin/env sh

# lib-benchmark.sh - support shared by the benchmark harnesses: bench.sh,
# run-optimization-benchmarks.sh, measure-instruction-counts.sh,
# measure-spmd-mode-instruction-counts.sh and check-instruction-counts.sh.
# The helpers report through lib-gate.sh's `fail`; source that first.
# POSIX sh only.

# bench_compiler [PATH]
#   Set COMPILER to PATH, else TYPELISP_BIN, else the published stage0; resolve
#   it against ROOT and require it to be executable.
bench_compiler() {
    if [ -n "${1:-}" ]; then
        COMPILER=$1
    else
        gate_compiler
    fi
    gate_compiler_absolute
    gate_require_compiler
}

# bench_metadata FILE
#   Read the one `category|args` row of a benchmark's optimization.tsv into
#   BENCH_CATEGORY and BENCH_ARGS, skipping blank and `#` lines and trailing
#   CRs. A missing FILE leaves both empty.
bench_metadata() {
    BENCH_CATEGORY=
    BENCH_ARGS=
    [ -f "$1" ] || return 0
    _bm_cr=$(printf '\r')
    _bm_line=
    while IFS= read -r _bm_row || [ -n "$_bm_row" ]; do
        _bm_row=${_bm_row%"$_bm_cr"}
        case "$_bm_row" in
            "" | \#*) continue ;;
        esac
        [ -z "$_bm_line" ] || fail "multiple metadata rows in $1"
        _bm_line=$_bm_row
    done < "$1"
    [ -n "$_bm_line" ] || fail "missing metadata row in $1"
    [ "$(printf '%s\n' "$_bm_line" | awk -F'|' '{ print NF }')" -eq 2 ] ||
        fail "metadata line must have 2 fields: $1: $_bm_line"
    BENCH_CATEGORY=${_bm_line%%|*}
    BENCH_ARGS=${_bm_line#*|}
}

# bench_safe_name TEXT
#   Print TEXT with every character outside [A-Za-z0-9_.-] replaced by `_`.
bench_safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

# bench_show_logs STDOUT STDERR
#   Print the non-empty logs, indented, to stderr.
bench_show_logs() {
    if [ -s "$1" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$1" >&2 || true
    fi
    if [ -s "$2" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$2" >&2 || true
    fi
}

# bench_build BIN STDOUT STDERR MESSAGE COMMAND...
#   Run the build COMMAND with its logs in STDOUT and STDERR. A failed build
#   shows the logs and fails with MESSAGE; BIN must then be executable.
bench_build() {
    _bb_bin=$1
    _bb_out=$2
    _bb_err=$3
    _bb_msg=$4
    shift 4
    if ! "$@" >"$_bb_out" 2>"$_bb_err"; then
        bench_show_logs "$_bb_out" "$_bb_err"
        fail "$_bb_msg"
    fi
    [ -x "$_bb_bin" ] || fail "$_bb_msg: no executable at $_bb_bin"
}

# bench_cachegrind LABEL CGOUT STDOUT STDERR COMMAND...
#   Run COMMAND, a Cachegrind invocation writing CGOUT, with its logs in STDOUT
#   and STDERR. Set BENCH_STATUS to its exit status and BENCH_IR to the Ir
#   total in CGOUT; missing or unparsable output fails.
bench_cachegrind() {
    _bc_label=$1
    _bc_cgout=$2
    _bc_out=$3
    _bc_err=$4
    shift 4
    set +e
    "$@" >"$_bc_out" 2>"$_bc_err"
    BENCH_STATUS=$?
    set -e
    [ -s "$_bc_cgout" ] || {
        bench_show_logs "$_bc_out" "$_bc_err"
        fail "cachegrind did not write output for $_bc_label"
    }
    BENCH_IR=$(awk '
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
    ' "$_bc_cgout") || {
        bench_show_logs "$_bc_out" "$_bc_err"
        fail "could not parse Ir for $_bc_label from $_bc_cgout"
    }
    case "$BENCH_IR" in
        "" | *[!0-9]*) fail "non-numeric Ir for $_bc_label: $BENCH_IR" ;;
    esac
}

# benchmark_ci_case_csv ROOT SUITE
#   Print SUITE's cases from perf/benchmark-ci-cases.tsv, the positive case
#   membership of the Linux benchmark-related CI suites, as a CSV.
benchmark_ci_case_csv() {
    _bccc_root=$1
    _bccc_suite=$2
    _bccc_file="$_bccc_root/perf/benchmark-ci-cases.tsv"

    [ -f "$_bccc_file" ] || {
        echo "missing benchmark CI case manifest: $_bccc_file" >&2
        return 1
    }

    awk -F '\t' -v file="$_bccc_file" -v wanted="$_bccc_suite" '
        function problem(message) {
            print file ": " message > "/dev/stderr"
            failed = 1
        }
        NR == 1 {
            if (NF != 2 || $1 != "suite" || $2 != "case") {
                problem("invalid header; expected suite<TAB>case")
            }
            next
        }
        NF != 2 {
            problem("row " NR " must have exactly two fields")
            next
        }
        $1 != "benchmark" &&
        $1 != "optimization-opt2" &&
        $1 != "instruction-main" &&
        $1 != "instruction-heavy" {
            problem("row " NR " has unknown suite: " $1)
            next
        }
        $2 !~ /^[A-Za-z0-9_.-]+$/ {
            problem("row " NR " has invalid case name: " $2)
            next
        }
        seen[$1 SUBSEP $2]++ {
            problem("duplicate case in suite " $1 ": " $2)
            next
        }
        {
            membership[$1 SUBSEP $2] = 1
            if ($1 == "instruction-main") {
                main_instruction[$2] = 1
            } else if ($1 == "instruction-heavy") {
                heavy_instruction[$2] = 1
            }
        }
        $1 == wanted {
            selected[++count] = $2
        }
        END {
            if (NR < 2) {
                problem("manifest has no cases")
            }
            if (wanted != "benchmark" &&
                wanted != "optimization-opt2" &&
                wanted != "instruction-main" &&
                wanted != "instruction-heavy") {
                problem("unknown requested suite: " wanted)
            }
            for (case_name in main_instruction) {
                if (membership["benchmark" SUBSEP case_name]) {
                    problem("instruction-main case also belongs to benchmark: " case_name)
                }
                if (membership["optimization-opt2" SUBSEP case_name]) {
                    problem("instruction-main case also belongs to optimization-opt2: " case_name)
                }
            }
            for (case_name in heavy_instruction) {
                if (membership["benchmark" SUBSEP case_name]) {
                    problem("instruction-heavy case also belongs to benchmark: " case_name)
                }
            }
            if (!failed && count == 0) {
                problem("no cases for suite: " wanted)
            }
            if (failed) {
                exit 1
            }
            for (i = 1; i <= count; i++) {
                printf "%s%s", i == 1 ? "" : ",", selected[i]
            }
            print ""
        }
    ' "$_bccc_file"
}
