#!/usr/bin/env sh

# Positive case membership for the Linux benchmark-related CI suites.

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
