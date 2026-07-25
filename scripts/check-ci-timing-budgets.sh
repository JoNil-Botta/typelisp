#!/usr/bin/env sh
set -eu

# Enforce generous wall-clock budgets on the repository lint gate, the stage2
# CLI host-action smoke gate, and the four selfhost compile rows that
# check-build-invariance.sh already records. This gate must remain a pure TSV
# consumer: adding compiler invocations here would lengthen CI and make the
# measurements differ from the measured workloads.
#
# #5660 asked whether this script should cover the host-action smoke gate once
# its raised cost was accepted. The decision is yes, and this is the executable
# form of that acceptance: a comment cannot stop the timing trend analyzer from
# re-flagging a cost we have already investigated, and a cap can, because a gate
# with an explicit budget is denylisted from the analyzer (see
# scripts/analyze-ci-timing-trends.sh). The two mechanisms are meant to be
# exclusive -- an expectation lives in exactly one of them.
#
# The 26000ms cap comes from three Linux CI artifacts: 12730, 12750, 14170ms.
# It is just under 2x the ~13.1s accepted median, so a doubling fails, and 1.8x
# the highest observed sample, so ordinary variance does not.
#
# What a cap does not do, stated plainly because the caps below look more
# protective than they are: it catches a doubling, not the step change that
# started #5660. That was +6.1s on a ~7s gate, and a repeat of it lands near
# 20s, under this cap. Catching that class would need a cap below 20s, and the
# spread above cannot support one without flaking. Doubling is what is
# enforceable here; a step change is a matter for review of the gate's case
# list, which is why the note at scripts/check-stage1-wrapper.sh asks for the
# cap to move in the same commit that adds a case of that weight.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-ci-timing-budgets.sh <ci-timing.tsv>
       scripts/check-ci-timing-budgets.sh --self-test

Checks the Linux source-lint gate, the stage2 CLI host-action smoke gate, and
the four selfhost compile rows recorded by the build-invariance gate. Fails
closed on missing, duplicate, malformed, or nonzero-exit rows.
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
        -v lint_cap=60000 \
        -v host_action_cap=26000 \
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
            if ($2 == "all" && $3 == "gate") {
                if ($1 == "TypeLisp source lint") {
                    key = "lint-gate"
                } else if ($1 == "stage2 CLI host-action smoke") {
                    key = "host-action-smoke"
                } else {
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
                next
            }

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

            lint = "lint-gate"
            if (counts[lint] == 0) {
                mark_error("missing required row " lint)
            } else if (counts[lint] != 1) {
                mark_error("required row " lint " occurs " counts[lint] " times")
            }

            host_action = "host-action-smoke"
            if (counts[host_action] == 0) {
                mark_error("missing required row " host_action)
            } else if (counts[host_action] != 1) {
                mark_error("required row " host_action " occurs " \
                    counts[host_action] " times")
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
            print "[ci-timing-budget] measured gates:"
            print "[ci-timing-budget]   " lint "=" display(lint) \
                " cap=" lint_cap "ms"
            print "[ci-timing-budget]   " host_action "=" display(host_action) \
                " cap=" host_action_cap "ms"

            if (counts[lint] == 1 && valid[lint] && values[lint] > lint_cap) {
                mark_error(lint " exceeds its " lint_cap "ms cap")
            }

            if (counts[host_action] == 1 && valid[host_action] &&
                    values[host_action] > host_action_cap) {
                mark_error(host_action " exceeds its " host_action_cap "ms cap")
            }

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
    lint_ms=${6-30000}
    host_action_ms=${7-13000}
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
        if [ -n "$lint_ms" ]; then
            printf 'TypeLisp source lint\tall\tgate\t%s\t0\tlinux\n' "$lint_ms"
        fi
        if [ -n "$host_action_ms" ]; then
            printf 'stage2 CLI host-action smoke\tall\tgate\t%s\t0\tlinux\n' \
                "$host_action_ms"
        fi
    } > "$fixture"
}

append_lint_row() {
    fixture=$1
    elapsed_ms=$2
    exit_status=$3
    host=$4
    printf 'TypeLisp source lint\tall\tgate\t%s\t%s\t%s\n' \
        "$elapsed_ms" "$exit_status" "$host" >> "$fixture"
}

append_host_action_row() {
    fixture=$1
    elapsed_ms=$2
    exit_status=$3
    host=$4
    printf 'stage2 CLI host-action smoke\tall\tgate\t%s\t%s\t%s\n' \
        "$elapsed_ms" "$exit_status" "$host" >> "$fixture"
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

    write_fixture "$workdir/lint-absolute.tsv" 12800 18700 30300 50500 60001
    expect_fixture lint-absolute-breach fail \
        "$workdir/lint-absolute.tsv" "$workdir/lint-absolute.out"
    grep -F 'lint-gate exceeds its 60000ms cap' \
        "$workdir/lint-absolute.out" >/dev/null

    write_fixture "$workdir/lint-missing.tsv" 12800 18700 30300 50500 ''
    expect_fixture lint-missing fail \
        "$workdir/lint-missing.tsv" "$workdir/lint-missing.out"
    grep -F 'lint-gate=<missing> cap=60000ms' \
        "$workdir/lint-missing.out" >/dev/null

    write_fixture "$workdir/lint-duplicate.tsv" 12800 18700 30300 50500
    append_lint_row "$workdir/lint-duplicate.tsv" 30000 0 linux
    expect_fixture lint-duplicate fail \
        "$workdir/lint-duplicate.tsv" "$workdir/lint-duplicate.out"
    grep -F 'required row lint-gate occurs 2 times' \
        "$workdir/lint-duplicate.out" >/dev/null

    write_fixture "$workdir/lint-malformed.tsv" 12800 18700 30300 50500 ''
    append_lint_row "$workdir/lint-malformed.tsv" not-a-time 0 linux
    expect_fixture lint-malformed fail \
        "$workdir/lint-malformed.tsv" "$workdir/lint-malformed.out"
    grep -F 'row lint-gate has invalid elapsed_ms: not-a-time' \
        "$workdir/lint-malformed.out" >/dev/null

    write_fixture "$workdir/lint-nonzero.tsv" 12800 18700 30300 50500 ''
    append_lint_row "$workdir/lint-nonzero.tsv" 30000 7 linux
    expect_fixture lint-nonzero fail \
        "$workdir/lint-nonzero.tsv" "$workdir/lint-nonzero.out"
    grep -F 'row lint-gate recorded nonzero exit: 7' \
        "$workdir/lint-nonzero.out" >/dev/null

    write_fixture "$workdir/lint-wrong-host.tsv" 12800 18700 30300 50500 ''
    append_lint_row "$workdir/lint-wrong-host.tsv" 30000 0 windows
    expect_fixture lint-wrong-host fail \
        "$workdir/lint-wrong-host.tsv" "$workdir/lint-wrong-host.out"
    grep -F 'row lint-gate has host windows; expected linux' \
        "$workdir/lint-wrong-host.out" >/dev/null

    # The accepted cost measures 12-14s on Linux CI. Prove the cap tolerates
    # that spread, fires at a doubling, and fails closed the same way the lint
    # gate does -- the row is the executable record of #5660's accepted cost, so
    # a silently missing row would restore exactly the gap #5778 was filed for.
    write_fixture "$workdir/host-action-high.tsv" 12800 18700 30300 50500 30000 14000
    expect_fixture host-action-observed-high pass \
        "$workdir/host-action-high.tsv" "$workdir/host-action-high.out"
    grep -F 'host-action-smoke=14000ms cap=26000ms' \
        "$workdir/host-action-high.out" >/dev/null

    write_fixture "$workdir/host-action-double.tsv" 12800 18700 30300 50500 30000 26200
    expect_fixture host-action-doubled fail \
        "$workdir/host-action-double.tsv" "$workdir/host-action-double.out"
    grep -F 'host-action-smoke exceeds its 26000ms cap' \
        "$workdir/host-action-double.out" >/dev/null

    write_fixture "$workdir/host-action-missing.tsv" 12800 18700 30300 50500 30000 ''
    expect_fixture host-action-missing fail \
        "$workdir/host-action-missing.tsv" "$workdir/host-action-missing.out"
    grep -F 'host-action-smoke=<missing> cap=26000ms' \
        "$workdir/host-action-missing.out" >/dev/null

    write_fixture "$workdir/host-action-duplicate.tsv" 12800 18700 30300 50500
    append_host_action_row "$workdir/host-action-duplicate.tsv" 13000 0 linux
    expect_fixture host-action-duplicate fail \
        "$workdir/host-action-duplicate.tsv" \
        "$workdir/host-action-duplicate.out"
    grep -F 'required row host-action-smoke occurs 2 times' \
        "$workdir/host-action-duplicate.out" >/dev/null

    write_fixture "$workdir/host-action-malformed.tsv" 12800 18700 30300 50500 30000 ''
    append_host_action_row "$workdir/host-action-malformed.tsv" not-a-time 0 linux
    expect_fixture host-action-malformed fail \
        "$workdir/host-action-malformed.tsv" \
        "$workdir/host-action-malformed.out"
    grep -F 'row host-action-smoke has invalid elapsed_ms: not-a-time' \
        "$workdir/host-action-malformed.out" >/dev/null

    write_fixture "$workdir/host-action-nonzero.tsv" 12800 18700 30300 50500 30000 ''
    append_host_action_row "$workdir/host-action-nonzero.tsv" 13000 7 linux
    expect_fixture host-action-nonzero fail \
        "$workdir/host-action-nonzero.tsv" "$workdir/host-action-nonzero.out"
    grep -F 'row host-action-smoke recorded nonzero exit: 7' \
        "$workdir/host-action-nonzero.out" >/dev/null

    # The gate is Linux-only (it needs as + ld), so a windows row is a wiring
    # bug rather than a slow run.
    write_fixture "$workdir/host-action-wrong-host.tsv" 12800 18700 30300 50500 30000 ''
    append_host_action_row "$workdir/host-action-wrong-host.tsv" 13000 0 windows
    expect_fixture host-action-wrong-host fail \
        "$workdir/host-action-wrong-host.tsv" \
        "$workdir/host-action-wrong-host.out"
    grep -F 'row host-action-smoke has host windows; expected linux' \
        "$workdir/host-action-wrong-host.out" >/dev/null

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
