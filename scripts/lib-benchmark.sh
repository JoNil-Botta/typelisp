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

# benchmark_manifest_dir ROOT
#   Print the directory of per-benchmark manifests (`perf/benchmarks`).
benchmark_manifest_dir() {
    printf '%s/perf/benchmarks\n' "$1"
}

# benchmark_manifest_read DIR SUITE [CASES_CSV] [OUT_C_ROWS]
#   Validate every per-benchmark manifest `<case>.tsv` under DIR:
#     - `suites<TAB>csv` from {benchmark, optimization-opt2, instruction-main,
#       instruction-heavy, realistic-kernel}, non-empty, no duplicates
#     - optional `benchmark/c-scalar/<case><TAB><ir>` (required iff the case
#       belongs to instruction-main or instruction-heavy)
#     - optional `benchmark/c/<case><TAB><ir>`
#     - no `benchmark/typelisp/*` or `self_compile/*` rows (TypeLisp Ir is
#       owned by CI's `insn-exec-reference` artifact, never checked in)
#     - instruction-main and instruction-heavy are disjoint
#     - instruction-heavy is disjoint from benchmark
#     - realistic-kernel is a subset of instruction-main
#   When SUITE is non-empty, prints SUITE's cases as a deterministic LC_ALL=C
#   CSV. When OUT_C_ROWS is non-empty, writes the C baseline TSV (`name\tir_count`)
#   for CASES_CSV (requiring every selected case to have a manifest and a
#   benchmark/c-scalar/<case> row).
benchmark_manifest_read() {
    _bmr_dir=$1
    _bmr_suite=${2:-}
    _bmr_cases=${3:-}
    _bmr_out=${4:-}

    [ -d "$_bmr_dir" ] || {
        echo "missing benchmark manifest directory: $_bmr_dir" >&2
        return 1
    }

    set --
    for _bmr_file in $(LC_ALL=C; for _bmr_f in "$_bmr_dir"/*.tsv; do [ -f "$_bmr_f" ] && printf '%s\n' "$_bmr_f"; done | LC_ALL=C sort); do
        set -- "$@" "$_bmr_file"
    done
    [ "$#" -gt 0 ] || {
        echo "no benchmark manifests found in $_bmr_dir" >&2
        return 1
    }

    LC_ALL=C awk -F '\t' \
        -v wanted="$_bmr_suite" \
        -v cases_csv="$_bmr_cases" \
        -v out_c_rows="$_bmr_out" '
        function problem(file, message) {
            print file ": " message > "/dev/stderr"
            failed = 1
        }
        function base_case(path,    s) {
            s = path
            sub(/^.*\//, "", s)
            sub(/\.tsv$/, "", s)
            return s
        }
        function finish_file(    s) {
            if (cur_file == "") return
            if (!has_suites) {
                problem(cur_file, "missing suites row")
            }
            if (cur_suite["instruction-main"] && cur_suite["instruction-heavy"]) {
                problem(cur_file, "case belongs to both instruction-main and instruction-heavy: " cur_case)
            }
            if (cur_suite["instruction-heavy"] && cur_suite["benchmark"]) {
                problem(cur_file, "instruction-heavy case also belongs to benchmark: " cur_case)
            }
            if (cur_suite["realistic-kernel"] && !cur_suite["instruction-main"]) {
                problem(cur_file, "realistic kernel missing from instruction-main: " cur_case)
            }
            if ((cur_suite["instruction-main"] || cur_suite["instruction-heavy"]) && !has_c_scalar) {
                problem(cur_file, "instruction-gated case lacks benchmark/c-scalar/" cur_case)
            }
            if (!(cur_suite["instruction-main"] || cur_suite["instruction-heavy"]) && (has_c_scalar || has_c_auto)) {
                problem(cur_file, "non-instruction case carries C instruction counts: " cur_case)
            }
            for (s in cur_suite) delete cur_suite[s]
        }
        FNR == 1 {
            finish_file()
            cur_file = FILENAME
            cur_case = base_case(FILENAME)
            has_suites = 0
            has_c_scalar = 0
            has_c_auto = 0
            if (cur_case !~ /^[A-Za-z0-9_.-]+$/) {
                problem(cur_file, "invalid case name: " cur_case)
            }
            if (seen_case[cur_case]++) {
                problem(cur_file, "duplicate case manifest: " cur_case)
            }
            case_order[++case_count] = cur_case
        }
        {
            sub(/\r$/, "")
            if ($0 == "") next
            if (NF != 2) {
                problem(cur_file, "row " FNR " must have exactly two tab-separated fields")
                next
            }
            if ($1 == "suites") {
                if (has_suites) {
                    problem(cur_file, "duplicate suites row")
                    next
                }
                has_suites = 1
                n = split($2, sarr, ",")
                if (n == 0 || $2 == "") {
                    problem(cur_file, "empty suites list")
                    next
                }
                for (i = 1; i <= n; i++) {
                    s = sarr[i]
                    if (s != "benchmark" &&
                        s != "optimization-opt2" &&
                        s != "instruction-main" &&
                        s != "instruction-heavy" &&
                        s != "realistic-kernel") {
                        problem(cur_file, "unknown suite: " s)
                        continue
                    }
                    if (cur_suite[s]++) {
                        problem(cur_file, "duplicate suite " s)
                        continue
                    }
                    membership[s SUBSEP cur_case] = 1
                    if (s == wanted) {
                        selected[++selected_count] = cur_case
                    }
                }
                next
            }
            if ($1 ~ /^benchmark\/typelisp\//) {
                problem(cur_file, "checked-in TypeLisp row is forbidden (" $1 "); TypeLisp Ir is owned by CI insn-exec-reference")
                next
            }
            if ($1 ~ /^self_compile\//) {
                problem(cur_file, "self_compile row is forbidden (" $1 "); see scripts/self-compile.sh")
                next
            }
            if ($1 == "benchmark/c-scalar/" cur_case) {
                if (has_c_scalar) {
                    problem(cur_file, "duplicate row: " $1)
                    next
                }
                if ($2 !~ /^[1-9][0-9]*$/) {
                    problem(cur_file, "non-positive Ir count for " $1 ": " $2)
                    next
                }
                has_c_scalar = 1
                c_scalar[cur_case] = $2
                next
            }
            if ($1 == "benchmark/c/" cur_case) {
                if (has_c_auto) {
                    problem(cur_file, "duplicate row: " $1)
                    next
                }
                if ($2 !~ /^[1-9][0-9]*$/) {
                    problem(cur_file, "non-positive Ir count for " $1 ": " $2)
                    next
                }
                has_c_auto = 1
                c_auto[cur_case] = $2
                next
            }
            problem(cur_file, "unexpected or mismatched key on row " FNR ": " $1)
        }
        END {
            finish_file()
            if (wanted != "") {
                if (wanted != "benchmark" &&
                    wanted != "optimization-opt2" &&
                    wanted != "instruction-main" &&
                    wanted != "instruction-heavy" &&
                    wanted != "realistic-kernel") {
                    problem("benchmark_ci_case_csv", "unknown requested suite: " wanted)
                } else if (!failed && selected_count == 0) {
                    problem("benchmark_ci_case_csv", "no cases for suite: " wanted)
                }
            }
            if (out_c_rows != "") {
                if (cases_csv == "") {
                    problem("benchmark_manifest_c_rows", "empty case list")
                } else {
                    nc = split(cases_csv, carr, ",")
                    for (i = 1; i <= nc; i++) {
                        cname = carr[i]
                        if (cname == "") continue
                        if (!(cname in seen_case)) {
                            problem("benchmark_manifest_c_rows", "missing manifest for case: " cname)
                        } else if (!(cname in c_scalar)) {
                            problem("benchmark_manifest_c_rows", "case lacks benchmark/c-scalar row: " cname)
                        }
                    }
                }
            }
            if (failed) exit 1
            if (out_c_rows != "") {
                printf "name\tir_count\n" > out_c_rows
                nc = split(cases_csv, carr, ",")
                for (i = 1; i <= nc; i++) {
                    cname = carr[i]
                    if (cname == "" || emitted[cname]++) continue
                    if (cname in c_auto) {
                        printf "benchmark/c/%s\t%s\n", cname, c_auto[cname] > out_c_rows
                    }
                    printf "benchmark/c-scalar/%s\t%s\n", cname, c_scalar[cname] > out_c_rows
                }
                close(out_c_rows)
            }
            if (wanted != "") {
                for (i = 1; i <= selected_count; i++) {
                    printf "%s%s", i == 1 ? "" : ",", selected[i]
                }
                print ""
            }
        }
    ' "$@"
}

# benchmark_ci_case_csv ROOT SUITE
#   Print SUITE's cases from per-benchmark manifests under perf/benchmarks/*.tsv
#   as a deterministic LC_ALL=C CSV.
benchmark_ci_case_csv() {
    benchmark_manifest_read "$(benchmark_manifest_dir "$1")" "$2" "" ""
}

# benchmark_manifest_c_rows DIR CASES_CSV OUT_FILE
#   Validate manifests in DIR and write C baseline rows (`benchmark/c-scalar/*`
#   plus optional `benchmark/c/*`) for CASES_CSV to OUT_FILE.
benchmark_manifest_c_rows() {
    benchmark_manifest_read "$1" "" "$2" "$3"
}

# benchmark_manifest_update_c DIR CASE C_SCALAR_IR [C_IR]
#   Rewrite only the C Ir rows in DIR/CASE.tsv, preserving `suites`. Never
#   writes benchmark/typelisp or self_compile rows.
benchmark_manifest_update_c() {
    _bmuc_dir=$1
    _bmuc_case=$2
    _bmuc_scalar=$3
    _bmuc_auto=${4:-}
    _bmuc_file="$_bmuc_dir/$_bmuc_case.tsv"
    [ -f "$_bmuc_file" ] || {
        echo "missing benchmark manifest: $_bmuc_file" >&2
        return 1
    }
    _bmuc_suites=$(awk -F '\t' '$1 == "suites" { print $2; exit }' "$_bmuc_file")
    [ -n "$_bmuc_suites" ] || {
        echo "missing suites row in $_bmuc_file" >&2
        return 1
    }
    _bmuc_has_auto=0
    if awk -F '\t' -v key="benchmark/c/$_bmuc_case" '$1 == key { found = 1 } END { exit found ? 0 : 1 }' "$_bmuc_file"; then
        _bmuc_has_auto=1
    fi
    {
        printf 'suites\t%s\n' "$_bmuc_suites"
        if [ "$_bmuc_has_auto" -eq 1 ]; then
            [ -n "$_bmuc_auto" ] || {
                echo "missing benchmark/c/$_bmuc_case count for auto-C gated manifest $_bmuc_file" >&2
                return 1
            }
            printf 'benchmark/c/%s\t%s\n' "$_bmuc_case" "$_bmuc_auto"
        fi
        printf 'benchmark/c-scalar/%s\t%s\n' "$_bmuc_case" "$_bmuc_scalar"
    } > "$_bmuc_file.tmp"
    mv "$_bmuc_file.tmp" "$_bmuc_file"
}
