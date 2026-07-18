#!/usr/bin/env sh
set -eu

# Enforce generous wall-clock budgets on the four selfhost compile rows that
# check-build-invariance.sh already records. This gate must remain a pure TSV
# consumer: adding compiler invocations here would lengthen CI and make the
# measurements differ from the build-invariance workload.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-ci-timing-budgets.sh <ci-timing.tsv>
       scripts/check-ci-timing-budgets.sh --self-test

Checks the four Linux selfhost compile rows recorded by the build-invariance
gate. Fails closed on missing, duplicate, malformed, or nonzero-exit rows.
EOF
}

check_budget() {
    timing_file=$1
    if [ ! -f "$timing_file" ]; then
        echo "[ci-timing-budget] timing artifact not found: $timing_file" >&2
        return 1
    fi
    if [ ! -s "$timing_file" ]; then
        echo "[ci-timing-budget] timing artifact is empty: $timing_file" >&2
        return 1
    fi

    awk -F '\t' \
        -v required_gate='stage2 opt1/opt2 build-invariance' \
        -v opt2_opt1_cap=25000 \
        -v opt1_opt1_cap=35000 \
        -v opt2_opt2_cap=55000 \
        -v opt1_opt2_cap=90000 \
        -v ratio_limit=2.5 '
        function is_required(key) {
            return key == "opt2-built:selfhost_main_opt1" ||
                key == "opt1-built:selfhost_main_opt1" ||
                key == "opt2-built:selfhost_main_opt2" ||
                key == "opt1-built:selfhost_main_opt2"
        }

        function mark_error(message) {
            errors += 1
            details = details "[ci-timing-budget] ERROR: " message "\n"
        }

        function display(key) {
            if (counts[key] == 0) {
                return "<missing>"
            }
            if (!valid[key]) {
                return "<invalid>"
            }
            return values[key] "ms"
        }

        NR == 1 {
            sub(/\r$/, "")
            if ($0 != "gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost") {
                mark_error("invalid TSV header")
            }
            next
        }

        {
            sub(/\r$/, "", $6)
            key = $2
            if ($1 != required_gate || $3 != "compile" || !is_required(key)) {
                next
            }

            counts[key] += 1
            if (NF != 6) {
                mark_error("row " key " has " NF " fields; expected 6")
                next
            }
            if ($4 !~ /^[0-9]+$/) {
                mark_error("row " key " has invalid elapsed_ms: " $4)
                next
            }
            if ($5 != "0") {
                mark_error("row " key " recorded nonzero exit: " $5)
                next
            }
            if ($6 != "linux") {
                mark_error("row " key " has host " $6 "; expected linux")
                next
            }
            values[key] = $4 + 0
            valid[key] = 1
        }

        END {
            opt2_opt1 = "opt2-built:selfhost_main_opt1"
            opt1_opt1 = "opt1-built:selfhost_main_opt1"
            opt2_opt2 = "opt2-built:selfhost_main_opt2"
            opt1_opt2 = "opt1-built:selfhost_main_opt2"

            required[1] = opt2_opt1
            required[2] = opt1_opt1
            required[3] = opt2_opt2
            required[4] = opt1_opt2
            for (i = 1; i <= 4; i += 1) {
                key = required[i]
                if (counts[key] == 0) {
                    mark_error("missing required row " key)
                } else if (counts[key] != 1) {
                    mark_error("required row " key " occurs " counts[key] " times")
                }
            }

            print "[ci-timing-budget] measured compile rows:"
            print "[ci-timing-budget]   " opt2_opt1 "=" display(opt2_opt1) \
                " cap=" opt2_opt1_cap "ms"
            print "[ci-timing-budget]   " opt1_opt1 "=" display(opt1_opt1) \
                " cap=" opt1_opt1_cap "ms"
            print "[ci-timing-budget]   " opt2_opt2 "=" display(opt2_opt2) \
                " cap=" opt2_opt2_cap "ms"
            print "[ci-timing-budget]   " opt1_opt2 "=" display(opt1_opt2) \
                " cap=" opt1_opt2_cap "ms"

            if (counts[opt2_opt1] == 1 && valid[opt2_opt1] &&
                    values[opt2_opt1] > opt2_opt1_cap) {
                mark_error(opt2_opt1 " exceeds its " opt2_opt1_cap "ms cap")
            }
            if (counts[opt1_opt1] == 1 && valid[opt1_opt1] &&
                    values[opt1_opt1] > opt1_opt1_cap) {
                mark_error(opt1_opt1 " exceeds its " opt1_opt1_cap "ms cap")
            }
            if (counts[opt2_opt2] == 1 && valid[opt2_opt2] &&
                    values[opt2_opt2] > opt2_opt2_cap) {
                mark_error(opt2_opt2 " exceeds its " opt2_opt2_cap "ms cap")
            }
            if (counts[opt1_opt2] == 1 && valid[opt1_opt2] &&
                    values[opt1_opt2] > opt1_opt2_cap) {
                mark_error(opt1_opt2 " exceeds its " opt1_opt2_cap "ms cap")
            }

            if (counts[opt2_opt2] == 1 && valid[opt2_opt2] &&
                    counts[opt1_opt1] == 1 && valid[opt1_opt1]) {
                if (values[opt1_opt1] == 0) {
                    print "[ci-timing-budget]   self-build-ratio=<invalid> cap=" \
                        ratio_limit
                    mark_error(opt1_opt1 " is zero; ratio is undefined")
                } else {
                    ratio = values[opt2_opt2] / values[opt1_opt1]
                    printf "[ci-timing-budget]   self-build-ratio=%.3f cap=%.3f\n", \
                        ratio, ratio_limit
                    if (ratio > ratio_limit) {
                        mark_error(sprintf("self-build ratio %.3f exceeds %.3f",
                            ratio, ratio_limit))
                    }
                }
            } else {
                print "[ci-timing-budget]   self-build-ratio=<unavailable> cap=" \
                    ratio_limit
            }

            if (errors != 0) {
                printf "%s", details > "/dev/stderr"
                print "[ci-timing-budget] Use scripts/benchmark-compile-cli.sh " \
                    "for local phase-level profiling." > "/dev/stderr"
                exit 1
            }

            print "[ci-timing-budget] wall-clock compile budgets passed"
        }
    ' "$timing_file"
}

write_fixture() {
    fixture=$1
    opt2_opt1=$2
    opt1_opt1=$3
    opt2_opt2=$4
    opt1_opt2=${5:-}
    {
        printf 'gate\tcase_or_chunk\tphase\telapsed_ms\texit\thost\n'
        printf 'stage2 opt1/opt2 build-invariance\topt2-built:selfhost_main_opt1\tcompile\t%s\t0\tlinux\n' \
            "$opt2_opt1"
        printf 'stage2 opt1/opt2 build-invariance\topt1-built:selfhost_main_opt1\tcompile\t%s\t0\tlinux\n' \
            "$opt1_opt1"
        printf 'stage2 opt1/opt2 build-invariance\topt2-built:selfhost_main_opt2\tcompile\t%s\t0\tlinux\n' \
            "$opt2_opt2"
        if [ -n "$opt1_opt2" ]; then
            printf 'stage2 opt1/opt2 build-invariance\topt1-built:selfhost_main_opt2\tcompile\t%s\t0\tlinux\n' \
                "$opt1_opt2"
        fi
    } > "$fixture"
}

expect_fixture() {
    label=$1
    expectation=$2
    fixture=$3
    output=$4
    status=0
    check_budget "$fixture" > "$output" 2>&1 || status=$?
    case "$expectation:$status" in
        pass:0) ;;
        fail:0)
            echo "[ci-timing-budget] self-test $label unexpectedly passed" >&2
            cat "$output" >&2
            return 1
            ;;
        fail:*) ;;
        pass:*)
            echo "[ci-timing-budget] self-test $label unexpectedly failed" >&2
            cat "$output" >&2
            return 1
            ;;
    esac
}

self_test() {
    workdir="$ROOT/target/ci-timing-budget-self-test"
    rm -rf "$workdir"
    mkdir -p "$workdir"

    write_fixture "$workdir/pass.tsv" 12800 18700 30300 50500
    expect_fixture pass pass "$workdir/pass.tsv" "$workdir/pass.out"

    write_fixture "$workdir/ratio.tsv" 12000 18000 48000 50000
    expect_fixture ratio-breach fail "$workdir/ratio.tsv" "$workdir/ratio.out"
    grep -F 'self-build ratio 2.667 exceeds 2.500' \
        "$workdir/ratio.out" >/dev/null

    write_fixture "$workdir/absolute.tsv" 25001 18700 30300 50500
    expect_fixture absolute-breach fail \
        "$workdir/absolute.tsv" "$workdir/absolute.out"
    grep -F 'exceeds its 25000ms cap' "$workdir/absolute.out" >/dev/null

    write_fixture "$workdir/missing.tsv" 12800 18700 30300
    expect_fixture missing-row fail \
        "$workdir/missing.tsv" "$workdir/missing.out"
    grep -F 'opt1-built:selfhost_main_opt2=<missing> cap=90000ms' \
        "$workdir/missing.out" >/dev/null
    grep -F 'scripts/benchmark-compile-cli.sh' "$workdir/missing.out" >/dev/null

    echo "CI timing budget self-tests passed"
}

if [ "${1:-}" = "--self-test" ]; then
    if [ "$#" -ne 1 ]; then
        usage
        exit 2
    fi
    self_test
    exit 0
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

check_budget "$1"
