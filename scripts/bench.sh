#!/usr/bin/env sh
set -eu
LC_ALL=C
export LC_ALL

# scripts/bench.sh - TypeLisp vs clang paired benchmark harness. refs #1097
#
# Required CI uses --correctness: build every comparison pair and compare exact
# stdout, stderr, and exit status without collecting timings.
#
# Manual timing builds three fixed optimization legs, warms each binary once,
# then rotates their execution order in paired rounds:
#   typelisp --opt-level 2
#   clang_auto   clang -O2
#   clang_scalar clang -O2 -fno-vectorize -fno-slp-vectorize
#
# Timing writes stable metadata.tsv, runs.tsv, and summary.tsv schemas. Linux
# runs use a small TypeLisp wait4/monotonic-clock helper so an ordinary exit
# above 128 is never confused with signal termination.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

RUNS=${BENCH_RUNS:-5}
CPU=${BENCH_CPU:-}
OUTDIR=${BENCH_OUT:-"$ROOT/target/bench-report"}
FILTER=${BENCH_FILTER:-}
CASES=${BENCH_CASES:-}
CORRECTNESS=0
SELF_TEST=0

usage() {
    cat <<'EOF'
usage: scripts/bench.sh [OPTIONS]

Modes:
  --correctness       Build all selected pairs and compare exact output/status.
  --self-test         Run fast report-validator and Linux runner self-tests.

Timing options:
  --runs N            Recorded interleaved rounds (default BENCH_RUNS or 5).
  --cpu N             Pin every Linux warm-up/run to logical CPU N with taskset.
  --output DIR        Report directory (default target/bench-report).
  --cases A,B,...     Exact ordered benchmark case list.
  --filter TEXT       Select discovered case names containing TEXT.
  --help              Show this help.

Environment mirrors: BENCH_RUNS, BENCH_CPU, BENCH_OUT, BENCH_CASES,
BENCH_FILTER, and TYPELISP_BIN.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --correctness)
            CORRECTNESS=1
            shift
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        --runs)
            [ "$#" -ge 2 ] || { echo "--runs requires a value" >&2; exit 2; }
            RUNS=$2
            shift 2
            ;;
        --cpu)
            [ "$#" -ge 2 ] || { echo "--cpu requires a value" >&2; exit 2; }
            CPU=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { echo "--output requires a value" >&2; exit 2; }
            OUTDIR=$2
            shift 2
            ;;
        --cases)
            [ "$#" -ge 2 ] || { echo "--cases requires a value" >&2; exit 2; }
            CASES=$2
            shift 2
            ;;
        --filter)
            [ "$#" -ge 2 ] || { echo "--filter requires a value" >&2; exit 2; }
            FILTER=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "unknown benchmark harness argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$CORRECTNESS" -eq 0 ] && [ "$SELF_TEST" -eq 0 ]; then
    case "$RUNS" in
        *[!0-9]*|"")
            echo "benchmark run count must be an integer of at least 3: $RUNS" >&2
            exit 2
            ;;
    esac
    if [ "$RUNS" -lt 3 ]; then
        echo "benchmark run count must be at least 3: $RUNS" >&2
        exit 2
    fi
    case "$CPU" in
        *[!0-9]*)
            echo "logical CPU must be a non-negative integer: $CPU" >&2
            exit 2
            ;;
    esac
fi
if [ "$SELF_TEST" -eq 0 ] && [ -n "$CASES" ] && [ -n "$FILTER" ]; then
    echo "--cases/BENCH_CASES and --filter/BENCH_FILTER are mutually exclusive" >&2
    exit 2
fi
if [ "$SELF_TEST" -eq 0 ]; then
    case "$CASES$FILTER$OUTDIR" in
        *"	"*|*"
"*)
            echo "benchmark arguments must not contain tabs or newlines" >&2
            exit 2
            ;;
    esac
fi

HOST_OS=linux
EXE=
TARGET_ARGS=
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        EXE=.exe
        TARGET_ARGS="--target windows-x86_64"
        ;;
    *)
        echo "benchmark harness is unsupported on this host" >&2
        exit 1
        ;;
esac

COMPILER=
resolve_benchmark_compiler() {
    [ -z "$COMPILER" ] || return 0
    if [ -n "${TYPELISP_BIN:-}" ]; then
        COMPILER=$TYPELISP_BIN
    else
        . "$ROOT/scripts/lib-stage0.sh"
        COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    fi
    case "$COMPILER" in
        /*) ;;
        [A-Za-z]:/*) ;;
        *) COMPILER="$ROOT/$COMPILER" ;;
    esac
    [ -x "$COMPILER" ] || {
        echo "typelisp compiler is not executable: $COMPILER" >&2
        exit 1
    }
}

build_wall_clock_runner() {
    _runner=$1
    resolve_benchmark_compiler
    if ! "$COMPILER" build benchmarks/wall_clock_runner.tl \
        --target linux-x86_64 --opt-level 2 --stdlib-root stdlib \
        -o "$_runner" \
        >"$_runner.build.stdout" 2>"$_runner.build.stderr"; then
        echo "FAIL: TypeLisp wall-clock runner build failed" >&2
        sed 's/^/  /' "$_runner.build.stderr" >&2 || true
        exit 1
    fi
}

# Validate runs.tsv and derive summary.tsv. The validator is deliberately
# strict: a partial run must never look like a complete performance report.
summarize_runs() {
    _input=$1
    _output=$2
    _expected_cases=$3
    _expected_runs=$4
    _temporary="$_output.tmp"
    rm -f "$_temporary"
    printf '%s\n' \
        'benchmark	implementation	sample_count	min_seconds	median_seconds	mean_seconds	stddev_seconds	cv_percent	iqr_seconds	mad_seconds	typelisp_over_implementation' \
        >"$_temporary"
    if ! awk -F '	' -v OFS='	' \
        -v expected_cases="$_expected_cases" -v expected_runs="$_expected_runs" '
        function reject(message) {
            print "invalid benchmark runs: " message > "/dev/stderr"
            failed = 1
            exit 1
        }
        function implementation_index(value) {
            if (value == "typelisp") return 1
            if (value == "clang_auto") return 2
            if (value == "clang_scalar") return 3
            return 0
        }
        function expected_implementation(round, order, impl_index) {
            impl_index = ((round + order - 2) % 3) + 1
            return implementations[impl_index]
        }
        function numeric(value) {
            return value ~ /^[0-9]+([.][0-9]+)?$/
        }
        function integer(value) {
            return value ~ /^-?[0-9]+$/
        }
        function sort_values(values, count,    i, j, value) {
            for (i = 2; i <= count; ++i) {
                value = values[i]
                j = i - 1
                while (j >= 1 && values[j] > value) {
                    values[j + 1] = values[j]
                    --j
                }
                values[j + 1] = value
            }
        }
        function median(values, count) {
            if (count % 2) return values[(count + 1) / 2]
            return (values[count / 2] + values[count / 2 + 1]) / 2
        }
        function ceiling(value, truncated) {
            truncated = int(value)
            return value == truncated ? truncated : truncated + 1
        }
        function emit_summary(benchmark, implementation,    key, count, i,
                              values, deviations, minimum, med, mean, sum,
                              stddev, cv, q1, q3, iqr, mad, ratio) {
            key = benchmark SUBSEP implementation
            count = sample_count[key]
            sum = 0
            for (i = 1; i <= count; ++i) {
                values[i] = samples[key SUBSEP i] + 0
                sum += values[i]
            }
            sort_values(values, count)
            minimum = values[1]
            med = median(values, count)
            mean = sum / count
            sum = 0
            for (i = 1; i <= count; ++i) {
                sum += (values[i] - mean) * (values[i] - mean)
                deviations[i] = values[i] >= med \
                    ? values[i] - med : med - values[i]
            }
            stddev = count > 1 ? sqrt(sum / (count - 1)) : 0
            cv = mean == 0 ? 0 : stddev * 100 / mean
            q1 = values[ceiling(count * 0.25)]
            q3 = values[ceiling(count * 0.75)]
            iqr = q3 - q1
            sort_values(deviations, count)
            mad = median(deviations, count)
            medians[key] = med
            ratio = implementation == "typelisp" \
                ? "-" : sprintf("%.6f", medians[benchmark SUBSEP "typelisp"] / med)
            printf "%s\t%s\t%d\t%.9f\t%.9f\t%.9f\t%.9f\t%.6f\t%.9f\t%.9f\t%s\n",
                benchmark, implementation, count, minimum, med, mean, stddev,
                cv, iqr, mad, ratio
        }
        BEGIN {
            implementations[1] = "typelisp"
            implementations[2] = "clang_auto"
            implementations[3] = "clang_scalar"
            case_count = split(expected_cases, case_order, ",")
            if (expected_cases == "" || case_count == 0) {
                reject("expected case list is empty")
            }
            for (i = 1; i <= case_count; ++i) {
                if (case_order[i] !~ /^[A-Za-z0-9_.-]+$/) {
                    reject("invalid expected benchmark label: " case_order[i])
                }
                if (expected[case_order[i]]++) {
                    reject("duplicate expected benchmark: " case_order[i])
                }
            }
        }
        NR == 1 {
            expected_header = "benchmark\timplementation\tphase\tround\torder\telapsed_seconds\texit_status\tsignal\tlaunch_errno\tstdout_sha256\tstderr_sha256\tparity"
            if ($0 != expected_header) reject("unexpected header")
            next
        }
        {
            if (NF != 12) reject("row " NR " has " NF " fields, expected 12")
            benchmark = $1
            implementation = $2
            phase = $3
            round = $4
            order = $5
            elapsed = $6
            status = $7
            signal_number = $8
            launch_errno = $9
            stdout_hash = $10
            stderr_hash = $11
            parity = $12
            impl_index = implementation_index(implementation)

            if (!(benchmark in expected)) reject("unexpected benchmark label: " benchmark)
            if (!impl_index) reject("unexpected implementation label: " implementation)
            if (!numeric(elapsed) || elapsed + 0 <= 0) reject("invalid elapsed time on row " NR)
            if (status !~ /^[0-9]+$/ || status + 0 > 255 ||
                !integer(signal_number) || !integer(launch_errno)) {
                reject("invalid status field on row " NR)
            }
            if (signal_number + 0 != 0) reject("signal termination on row " NR)
            if (launch_errno + 0 != 0) reject("launch failure on row " NR)
            if (stdout_hash !~ /^[0-9a-f][0-9a-f]*$/ || length(stdout_hash) != 64 ||
                stderr_hash !~ /^[0-9a-f][0-9a-f]*$/ || length(stderr_hash) != 64) {
                reject("invalid output fingerprint on row " NR)
            }
            if (parity != "match") reject("parity failure on row " NR)

            parity_key = benchmark
            if (!(parity_key in canonical_status)) {
                canonical_status[parity_key] = status
                canonical_stdout[parity_key] = stdout_hash
                canonical_stderr[parity_key] = stderr_hash
            } else if (status != canonical_status[parity_key] ||
                       stdout_hash != canonical_stdout[parity_key] ||
                       stderr_hash != canonical_stderr[parity_key]) {
                reject("non-repeatable observable output on row " NR)
            }

            key = benchmark SUBSEP implementation
            if (phase == "warmup") {
                if (round != "0" || order != "0") reject("invalid warm-up coordinates on row " NR)
                if (++warmups[key] != 1) reject("duplicate warm-up on row " NR)
            } else if (phase == "measured") {
                if (round !~ /^[0-9]+$/ || round + 0 < 1 || round + 0 > expected_runs) {
                    reject("invalid measured round on row " NR)
                }
                if (order !~ /^[0-9]+$/ || order + 0 < 1 || order + 0 > 3) {
                    reject("invalid measured order on row " NR)
                }
                if (implementation != expected_implementation(round + 0, order + 0)) {
                    reject("non-interleaved execution order on row " NR)
                }
                occurrence = benchmark SUBSEP round SUBSEP order
                if (++orders[occurrence] != 1) reject("duplicate round/order on row " NR)
                occurrence = key SUBSEP round
                if (++rounds[occurrence] != 1) reject("duplicate implementation/round on row " NR)
                sample_count[key]++
                samples[key SUBSEP sample_count[key]] = elapsed + 0
            } else {
                reject("unexpected phase on row " NR ": " phase)
            }
        }
        END {
            if (failed) exit 1
            if (NR == 0) reject("empty runs file")
            for (case_index = 1; case_index <= case_count; ++case_index) {
                benchmark = case_order[case_index]
                for (implementation_index_value = 1;
                     implementation_index_value <= 3;
                     ++implementation_index_value) {
                    implementation = implementations[implementation_index_value]
                    key = benchmark SUBSEP implementation
                    if (warmups[key] != 1) {
                        reject("missing warm-up: " benchmark "/" implementation)
                    }
                    if (sample_count[key] != expected_runs) {
                        reject("wrong sample count: " benchmark "/" implementation)
                    }
                    for (round = 1; round <= expected_runs; ++round) {
                        if (rounds[key SUBSEP round] != 1) {
                            reject("missing measured round: " benchmark "/" implementation "/" round)
                        }
                    }
                }
                for (round = 1; round <= expected_runs; ++round) {
                    for (order = 1; order <= 3; ++order) {
                        if (orders[benchmark SUBSEP round SUBSEP order] != 1) {
                            reject("missing round/order: " benchmark "/" round "/" order)
                        }
                    }
                }
                emit_summary(benchmark, "typelisp")
                emit_summary(benchmark, "clang_auto")
                emit_summary(benchmark, "clang_scalar")
            }
        }
    ' "$_input" >>"$_temporary"; then
        rm -f "$_temporary"
        return 1
    fi
    mv "$_temporary" "$_output"
}

write_self_test_fixture() {
    _fixture=$1
    _hash_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    _hash_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    printf '%s\n' \
        'benchmark	implementation	phase	round	order	elapsed_seconds	exit_status	signal	launch_errno	stdout_sha256	stderr_sha256	parity' \
        >"$_fixture"
    for _implementation in typelisp clang_auto clang_scalar; do
        printf 'case_a\t%s\twarmup\t0\t0\t0.010000000\t172\t0\t0\t%s\t%s\tmatch\n' \
            "$_implementation" "$_hash_a" "$_hash_b" >>"$_fixture"
    done
    _round=1
    while [ "$_round" -le 3 ]; do
        case "$_round" in
            1) _order='typelisp clang_auto clang_scalar' ;;
            2) _order='clang_auto clang_scalar typelisp' ;;
            3) _order='clang_scalar typelisp clang_auto' ;;
        esac
        _position=1
        for _implementation in $_order; do
            case "$_implementation" in
                typelisp) _elapsed=$_round.000000000 ;;
                clang_auto)
                    case "$_round" in
                        1) _elapsed=0.500000000 ;;
                        2) _elapsed=1.000000000 ;;
                        3) _elapsed=1.500000000 ;;
                    esac
                    ;;
                clang_scalar)
                    case "$_round" in
                        1) _elapsed=0.800000000 ;;
                        2) _elapsed=1.000000000 ;;
                        3) _elapsed=1.200000000 ;;
                    esac
                    ;;
            esac
            printf 'case_a\t%s\tmeasured\t%s\t%s\t%s\t172\t0\t0\t%s\t%s\tmatch\n' \
                "$_implementation" "$_round" "$_position" "$_elapsed" \
                "$_hash_a" "$_hash_b" >>"$_fixture"
            _position=$((_position + 1))
        done
        _round=$((_round + 1))
    done
}

expect_invalid_fixture() {
    _label=$1
    _fixture=$2
    _report=$3
    if summarize_runs "$_fixture" "$_report" case_a 3 >/dev/null 2>&1; then
        echo "self-test FAIL: accepted $_label fixture" >&2
        exit 1
    fi
}

run_self_tests() {
    _self_root=${TMPDIR:-/tmp}/typelisp-bench-self-test.$$
    rm -rf "$_self_root"
    mkdir -p "$_self_root"
    trap 'rm -rf "$_self_root"' EXIT HUP INT TERM
    _valid="$_self_root/valid.tsv"
    _summary="$_self_root/summary.tsv"
    write_self_test_fixture "$_valid"
    summarize_runs "$_valid" "$_summary" case_a 3

    awk -F '	' '
        BEGIN { ok = 0 }
        $1 == "case_a" && $2 == "typelisp" {
            ok += ($3 == 3 && $4 == "1.000000000" && $5 == "2.000000000" &&
                   $6 == "2.000000000" && $7 == "1.000000000" &&
                   $8 == "50.000000" && $9 == "2.000000000" &&
                   $10 == "1.000000000" && $11 == "-")
        }
        $1 == "case_a" && $2 == "clang_auto" {
            ok += ($5 == "1.000000000" && $7 == "0.500000000" &&
                   $11 == "2.000000")
        }
        $1 == "case_a" && $2 == "clang_scalar" {
            ok += ($5 == "1.000000000" && $7 == "0.200000000" &&
                   $8 == "20.000000" && $11 == "2.000000")
        }
        END { exit ok == 3 ? 0 : 1 }
    ' "$_summary" || {
        echo "self-test FAIL: incorrect statistics or ratios" >&2
        exit 1
    }

    awk 'NR != 5' "$_valid" >"$_self_root/missing.tsv"
    expect_invalid_fixture missing-row "$_self_root/missing.tsv" "$_summary"
    awk '1; NR == 5 { print }' "$_valid" >"$_self_root/duplicate.tsv"
    expect_invalid_fixture duplicate-row "$_self_root/duplicate.tsv" "$_summary"
    awk -F '	' -v OFS='	' 'NR == 7 {$10 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"} 1' \
        "$_valid" >"$_self_root/output.tsv"
    expect_invalid_fixture changed-output "$_self_root/output.tsv" "$_summary"
    awk -F '	' -v OFS='	' 'NR == 7 {$7 = 171} 1' \
        "$_valid" >"$_self_root/status.tsv"
    expect_invalid_fixture changed-status "$_self_root/status.tsv" "$_summary"
    awk -F '	' -v OFS='	' 'NR == 5 {$5 = 2} 1' \
        "$_valid" >"$_self_root/order.tsv"
    expect_invalid_fixture noninterleaved-order "$_self_root/order.tsv" "$_summary"
    awk -F '	' -v OFS='	' 'NR == 5 {$1 = "../case_a"} 1' \
        "$_valid" >"$_self_root/label.tsv"
    expect_invalid_fixture corrupt-label "$_self_root/label.tsv" "$_summary"
    awk -F '	' -v OFS='	' 'NR == 5 {$6 = "not-a-time"} 1' \
        "$_valid" >"$_self_root/time.tsv"
    expect_invalid_fixture malformed-time "$_self_root/time.tsv" "$_summary"

    if [ "$HOST_OS" = linux ]; then
        build_wall_clock_runner "$_self_root/runner"
        _line=$("$_self_root/runner" "$_self_root/out" "$_self_root/err" -- \
            /bin/sh -c 'printf output; printf error >&2; exit 172')
        set -- $_line
        [ "$#" -eq 4 ] && [ "$2" -eq 172 ] && [ "$3" -eq 0 ] && [ "$4" -eq 0 ] &&
            [ "$(cat "$_self_root/out")" = output ] &&
            [ "$(cat "$_self_root/err")" = error ] || {
                echo "self-test FAIL: ordinary exit/status capture" >&2
                exit 1
        }
        _line=$("$_self_root/runner" "$_self_root/out" "$_self_root/err" -- \
            /bin/sh -c 'kill -TERM $$')
        set -- $_line
        [ "$#" -eq 4 ] && [ "$2" -eq -1 ] && [ "$3" -eq 15 ] && [ "$4" -eq 0 ] || {
            echo "self-test FAIL: signal capture" >&2
            exit 1
        }
        _line=$("$_self_root/runner" "$_self_root/out" "$_self_root/err" -- \
            /definitely/missing/typelisp-benchmark-command)
        set -- $_line
        [ "$#" -eq 4 ] && [ "$4" -ne 0 ] || {
            echo "self-test FAIL: launch failure capture" >&2
            exit 1
        }
    fi

    echo "benchmark wall-clock harness self-tests passed"
    rm -rf "$_self_root"
    trap - EXIT HUP INT TERM
}

if [ "$SELF_TEST" -eq 1 ]; then
    [ "$CORRECTNESS" -eq 0 ] || {
        echo "--self-test and --correctness are mutually exclusive" >&2
        exit 2
    }
    run_self_tests
    exit 0
fi

# CPU affinity is a timing-only control. Preserve correctness-mode behavior
# when BENCH_CPU happens to be set in a caller environment.
if [ "$CORRECTNESS" -eq 1 ]; then
    CPU=
fi
if [ -n "$CPU" ]; then
    if [ "$HOST_OS" != linux ]; then
        echo "--cpu/BENCH_CPU pinning is supported only on Linux with taskset" >&2
        exit 1
    fi
    command -v taskset >/dev/null 2>&1 || {
        echo "CPU pinning requested but taskset is unavailable" >&2
        exit 1
    }
    if ! taskset -c "$CPU" true >/dev/null 2>&1; then
        echo "logical CPU $CPU is unavailable to this process (taskset failed)" >&2
        exit 1
    fi
fi

resolve_benchmark_compiler

command -v clang >/dev/null 2>&1 || {
    echo "missing clang (C baseline compiler)" >&2
    exit 1
}
if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || { echo "missing assembler: as" >&2; exit 1; }
    command -v ld >/dev/null 2>&1 || { echo "missing linker: ld" >&2; exit 1; }
fi
mkdir -p "$OUTDIR"
OUTDIR=$(CDPATH= cd -- "$OUTDIR" && pwd)
case "$OUTDIR" in
    /|"$ROOT")
        echo "unsafe benchmark output directory: $OUTDIR" >&2
        exit 1
        ;;
esac
WORKDIR="$OUTDIR/build"
LOGDIR="$OUTDIR/logs"
rm -rf "$WORKDIR" "$LOGDIR"
mkdir -p "$WORKDIR" "$LOGDIR"
rm -f "$OUTDIR/metadata.tsv" "$OUTDIR/runs.tsv" "$OUTDIR/summary.tsv" \
    "$OUTDIR/builds.tsv"

CR=$(printf '\r')
AUTO_FLAGS='-O2'
SCALAR_FLAGS='-O2 -fno-vectorize -fno-slp-vectorize'
TL_FLAGS='--opt-level 2'
if [ -n "$TARGET_ARGS" ]; then
    TL_FLAGS="$TL_FLAGS $TARGET_ARGS"
fi

now() { date +%s.%N; }
elapsed() { awk "BEGIN { printf \"%.9f\", $2 - $1 }"; }
fingerprint() { sha256sum "$1" | awk '{ print $1 }'; }
one_line() {
    awk -v cr="$CR" '{
        gsub(cr, "")
        gsub(/\t/, " ")
        if (seen) printf " "
        printf "%s", $0
        seen = 1
    } END { if (seen) print "" }'
}
normalize_output() {
    _source=$1
    _normalized=$2
    if [ "$HOST_OS" = windows ]; then
        # clang-linked Windows stdio emits CRLF while the TypeLisp runtime writes
        # LF directly. Retain the raw logs, but compare the logical text stream.
        sed "s/${CR}\$//" "$_source" >"$_normalized"
    else
        cp "$_source" "$_normalized"
    fi
}

command -v sha256sum >/dev/null 2>&1 || {
    echo "missing sha256sum (required for reproducible benchmark reports)" >&2
    exit 1
}

time_build() {
    _out=$1
    shift
    _start=$(now)
    "$@" >"$_out.build.stdout" 2>"$_out.build.stderr" || {
        echo "FAIL: build command failed: $*" >&2
        sed 's/^/  /' "$_out.build.stderr" >&2 || true
        exit 1
    }
    _end=$(now)
    elapsed "$_start" "$_end"
}

run_build() {
    _out=$1
    shift
    "$@" >"$_out.build.stdout" 2>"$_out.build.stderr" || {
        echo "FAIL: build command failed: $*" >&2
        sed 's/^/  /' "$_out.build.stderr" >&2 || true
        exit 1
    }
}

run_status() {
    _stdout=$1
    _stderr=$2
    shift 2
    set +e
    "$@" >"$_stdout" 2>"$_stderr"
    _status=$?
    set -e
    printf '%s\n' "$_status"
}

benchmark_args_for_dir() {
    _dir=$1
    _metadata="$_dir/optimization.tsv"
    BENCHMARK_ARGS=
    [ -f "$_metadata" ] || return 0

    _line=
    while IFS= read -r _candidate || [ -n "$_candidate" ]; do
        case "$_candidate" in
            *"$CR") _candidate=${_candidate%"$CR"} ;;
        esac
        case "$_candidate" in
            "" | \#*) continue ;;
        esac
        if [ -n "$_line" ]; then
            echo "multiple metadata rows in $_metadata" >&2
            exit 1
        fi
        _line=$_candidate
    done <"$_metadata"
    [ -n "$_line" ] || {
        echo "missing metadata row in $_metadata" >&2
        exit 1
    }
    _fields=$(printf '%s\n' "$_line" | awk -F'|' '{ print NF }')
    [ "$_fields" -eq 2 ] || {
        echo "metadata line must have 2 fields: $_metadata: $_line" >&2
        exit 1
    }
    IFS='|' read -r _category BENCHMARK_ARGS <<EOF
$_line
EOF
}

DISCOVERED="$WORKDIR/discovered.txt"
SELECTED="$WORKDIR/selected.txt"
: >"$DISCOVERED"
for _bench_tl in benchmarks/*/bench.tl; do
    [ -e "$_bench_tl" ] || continue
    _dir=$(dirname "$_bench_tl")
    [ -f "$_dir/baseline.c" ] || continue
    _name=$(basename "$_dir")
    case "$_name" in
        *[!A-Za-z0-9_.-]*)
            echo "unsafe benchmark directory label: $_name" >&2
            exit 1
            ;;
    esac
    printf '%s\n' "$_name" >>"$DISCOVERED"
done

: >"$SELECTED"
if [ -n "$CASES" ]; then
    case "$CASES" in
        ,*|*,|*,,*)
            echo "BENCH_CASES/--cases contains an empty case: $CASES" >&2
            exit 2
            ;;
    esac
    printf '%s\n' "$CASES" | tr ',' '\n' >"$WORKDIR/requested.txt"
    _duplicates=$(sort "$WORKDIR/requested.txt" | uniq -d | one_line)
    [ -z "$_duplicates" ] || {
        echo "duplicate benchmark case(s): $_duplicates" >&2
        exit 2
    }
    while IFS= read -r _name; do
        case "$_name" in
            *[!A-Za-z0-9_.-]*|"")
                echo "invalid benchmark case label: $_name" >&2
                exit 2
                ;;
        esac
        grep -Fqx "$_name" "$DISCOVERED" || {
            echo "unknown comparison benchmark case: $_name" >&2
            exit 2
        }
        printf '%s\n' "$_name" >>"$SELECTED"
    done <"$WORKDIR/requested.txt"
else
    while IFS= read -r _name; do
        case "$_name" in
            *"$FILTER"*) printf '%s\n' "$_name" >>"$SELECTED" ;;
        esac
    done <"$DISCOVERED"
fi

FOUND=$(awk 'END { print NR + 0 }' "$SELECTED")
[ "$FOUND" -gt 0 ] || {
    echo "no benchmarks matched (filter='$FILTER', cases='$CASES')" >&2
    exit 1
}
CASE_CSV=$(awk 'BEGIN { separator="" } { printf "%s%s", separator, $0; separator="," } END { print "" }' "$SELECTED")
DISCOVERED_COUNT=$(awk 'END { print NR + 0 }' "$DISCOVERED")
DISCOVERED_CSV=$(awk 'BEGIN { separator="" } { printf "%s%s", separator, $0; separator="," } END { print "" }' "$DISCOVERED")
if [ -n "$CASES" ]; then
    SELECTION_MODE=cases
    SELECTION_REQUEST=$CASES
elif [ -n "$FILTER" ]; then
    SELECTION_MODE=filter
    SELECTION_REQUEST=$FILTER
else
    SELECTION_MODE=all
    SELECTION_REQUEST=-
fi

if [ "$CORRECTNESS" -eq 1 ]; then
    echo "TypeLisp benchmark harness (host=$HOST_OS, mode=correctness, no timing)"
    echo "compiler: $COMPILER"
    echo
    while IFS= read -r name; do
        dir="benchmarks/$name"
        benchmark_args_for_dir "$dir"
        bench_args=$BENCHMARK_ARGS
        tl_bin="$WORKDIR/$name.typelisp$EXE"
        c_bin="$WORKDIR/$name.clang_auto$EXE"
        run_build "$WORKDIR/$name.typelisp" \
            "$COMPILER" build "$dir/bench.tl" -o "$tl_bin" $TARGET_ARGS
        # shellcheck disable=SC2086
        run_build "$WORKDIR/$name.clang_auto" \
            clang $AUTO_FLAGS "$dir/baseline.c" -o "$c_bin"

        # shellcheck disable=SC2086
        tl_status=$(run_status "$LOGDIR/$name.typelisp.stdout" \
            "$LOGDIR/$name.typelisp.stderr" "$tl_bin" $bench_args)
        # shellcheck disable=SC2086
        c_status=$(run_status "$LOGDIR/$name.clang_auto.stdout" \
            "$LOGDIR/$name.clang_auto.stderr" "$c_bin" $bench_args)
        normalize_output "$LOGDIR/$name.typelisp.stdout" \
            "$WORKDIR/$name.typelisp.stdout.normalized"
        normalize_output "$LOGDIR/$name.typelisp.stderr" \
            "$WORKDIR/$name.typelisp.stderr.normalized"
        normalize_output "$LOGDIR/$name.clang_auto.stdout" \
            "$WORKDIR/$name.clang_auto.stdout.normalized"
        normalize_output "$LOGDIR/$name.clang_auto.stderr" \
            "$WORKDIR/$name.clang_auto.stderr.normalized"
        if [ "$tl_status" != "$c_status" ] ||
           ! cmp -s "$WORKDIR/$name.typelisp.stdout.normalized" \
               "$WORKDIR/$name.clang_auto.stdout.normalized" ||
           ! cmp -s "$WORKDIR/$name.typelisp.stderr.normalized" \
               "$WORKDIR/$name.clang_auto.stderr.normalized"; then
            echo "FAIL: $name observable output differs (typelisp status $tl_status, clang status $c_status)" >&2
            exit 1
        fi
        printf 'correctness OK: %s -- exact stdout/stderr and exit %s agree\n' \
            "$name" "$tl_status"
    done <"$SELECTED"
    echo "benchmark correctness completed: $FOUND benchmark(s)"
    exit 0
fi

if [ "$HOST_OS" = linux ]; then
    RUNNER="$WORKDIR/wall-clock-runner"
    build_wall_clock_runner "$RUNNER"
    TIMER='clock_gettime(CLOCK_MONOTONIC)'
else
    RUNNER=
    TIMER='shell date wall clock (Windows signal field unavailable)'
fi

printf '%s\n' \
    'benchmark	implementation	phase	round	order	elapsed_seconds	exit_status	signal	launch_errno	stdout_sha256	stderr_sha256	parity' \
    >"$OUTDIR/runs.tsv"
printf '%s\n' \
    'benchmark	implementation	compile_seconds	executable_bytes	assembly_bytes	assembly_lines' \
    >"$OUTDIR/builds.tsv"

metadata_row() {
    printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | one_line)" >>"$OUTDIR/metadata.tsv"
}

printf 'key\tvalue\n' >"$OUTDIR/metadata.tsv"
CLANG_PATH=$(command -v clang)
if GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null); then
    GIT_COMMAND=$(command -v git)
elif command -v git.exe >/dev/null 2>&1 &&
     GIT_COMMIT=$(git.exe rev-parse HEAD 2>/dev/null); then
    # WSL can enter a Windows-created linked worktree whose .git file contains
    # a Windows path. Use Git for Windows through WSL interop in that case.
    GIT_COMMAND=$(command -v git.exe)
else
    echo "cannot resolve the benchmark source git commit" >&2
    exit 1
fi
if ! GIT_STATUS=$("$GIT_COMMAND" status --porcelain); then
    echo "cannot inspect benchmark source git worktree state" >&2
    exit 1
fi
GIT_DIRTY=$(printf '%s\n' "$GIT_STATUS" | one_line)
GIT_VERSION=$("$GIT_COMMAND" --version | one_line)
COMPILER_VERSION=$("$COMPILER" --version 2>&1 | one_line)
CLANG_VERSION=$(clang --version 2>&1 | sed -n '1p' | one_line)
UNAME_VALUE=$(uname -a | one_line)
if [ "$HOST_OS" = linux ]; then
    if [ -r /proc/cpuinfo ]; then
        CPU_MODEL=$(awk -F: '/^model name[[:space:]]*:/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }' /proc/cpuinfo)
    else
        CPU_MODEL=$(uname -p)
    fi
    AS_PATH=$(command -v as)
    AS_VERSION=$(as --version 2>&1 | sed -n '1p' | one_line)
    LD_PATH=$(command -v ld)
    LD_VERSION=$(ld --version 2>&1 | sed -n '1p' | one_line)
else
    CPU_MODEL=${PROCESSOR_IDENTIFIER:-unknown}
    AS_PATH=not-used-on-windows
    AS_VERSION=not-used-on-windows
    LD_PATH=not-used-on-windows
    LD_VERSION=not-used-on-windows
fi
if [ -n "$CPU" ]; then
    PINNING="taskset -c $CPU"
    LOGICAL_CPU=$CPU
else
    PINNING=disabled
    LOGICAL_CPU=-
fi
metadata_row schema_version 1
metadata_row git_commit "$GIT_COMMIT"
metadata_row git_worktree_dirty "${GIT_DIRTY:-clean}"
metadata_row git_path "$GIT_COMMAND"
metadata_row git_version "$GIT_VERSION"
metadata_row compiler_path "$COMPILER"
metadata_row compiler_version "$COMPILER_VERSION"
metadata_row compiler_sha256 "$(fingerprint "$COMPILER")"
metadata_row harness_sha256 "$(fingerprint "$ROOT/scripts/bench.sh")"
metadata_row timing_runner_source_sha256 "$(fingerprint "$ROOT/benchmarks/wall_clock_runner.tl")"
if [ -n "$RUNNER" ]; then
    metadata_row timing_runner_binary_sha256 "$(fingerprint "$RUNNER")"
else
    metadata_row timing_runner_binary_sha256 not-built-on-windows
fi
metadata_row clang_path "$CLANG_PATH"
metadata_row clang_version "$CLANG_VERSION"
metadata_row clang_sha256 "$(fingerprint "$CLANG_PATH")"
metadata_row as_path "$AS_PATH"
metadata_row as_version "$AS_VERSION"
metadata_row ld_path "$LD_PATH"
metadata_row ld_version "$LD_VERSION"
metadata_row host_os "$HOST_OS"
metadata_row host_uname "$UNAME_VALUE"
metadata_row cpu_model "$CPU_MODEL"
metadata_row kernel "$(uname -r)"
metadata_row typelisp_flags "$TL_FLAGS"
metadata_row clang_auto_flags "$AUTO_FLAGS"
metadata_row clang_scalar_flags "$SCALAR_FLAGS"
metadata_row recorded_rounds "$RUNS"
metadata_row warmups_per_binary 1
metadata_row logical_cpu "$LOGICAL_CPU"
metadata_row cpu_pinning "$PINNING"
metadata_row timer "$TIMER"
metadata_row interleave_order 'cyclic rotation: typelisp,clang_auto,clang_scalar'
metadata_row warmup_order 'typelisp,clang_auto,clang_scalar'
if [ "$HOST_OS" = windows ]; then
    metadata_row output_parity 'raw logs retained; CRLF normalized to LF for fingerprints'
else
    metadata_row output_parity 'raw byte-exact stdout and stderr'
fi
metadata_row benchmark_count "$FOUND"
metadata_row benchmark_cases "$CASE_CSV"
metadata_row selection_mode "$SELECTION_MODE"
metadata_row selection_request "$SELECTION_REQUEST"
metadata_row discovered_benchmark_count "$DISCOVERED_COUNT"
metadata_row discovered_benchmark_cases "$DISCOVERED_CSV"
metadata_row report_generated_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

measure_and_record() {
    _name=$1
    _implementation=$2
    _phase=$3
    _round=$4
    _order=$5
    shift 5
    _base="$LOGDIR/$_name.$_implementation.$_phase.$_round"
    _stdout="$_base.stdout"
    _stderr="$_base.stderr"
    if [ "$HOST_OS" = linux ]; then
        set +e
        if [ -n "$CPU" ]; then
            _measurement=$(taskset -c "$CPU" "$RUNNER" "$_stdout" "$_stderr" -- "$@")
            _runner_status=$?
        else
            _measurement=$("$RUNNER" "$_stdout" "$_stderr" -- "$@")
            _runner_status=$?
        fi
        set -e
        [ "$_runner_status" -eq 0 ] || {
            echo "FAIL: timing runner failed for $_name/$_implementation" >&2
            exit 1
        }
        set -- $_measurement
        [ "$#" -eq 4 ] || {
            echo "FAIL: malformed timing result for $_name/$_implementation: $_measurement" >&2
            exit 1
        }
        _elapsed=$1
        _status=$2
        _signal=$3
        _launch_errno=$4
    else
        _start=$(now)
        _status=$(run_status "$_stdout" "$_stderr" "$@")
        _end=$(now)
        _elapsed=$(elapsed "$_start" "$_end")
        _signal=0
        _launch_errno=0
    fi

    _normalized_stdout="$_base.stdout.normalized"
    _normalized_stderr="$_base.stderr.normalized"
    normalize_output "$_stdout" "$_normalized_stdout"
    normalize_output "$_stderr" "$_normalized_stderr"
    _stdout_hash=$(fingerprint "$_normalized_stdout")
    _stderr_hash=$(fingerprint "$_normalized_stderr")
    _parity=match
    if [ -f "$WORKDIR/$_name.canonical.status" ]; then
        _canonical_status=$(cat "$WORKDIR/$_name.canonical.status")
        if [ "$_status" != "$_canonical_status" ] ||
           ! cmp -s "$_normalized_stdout" "$WORKDIR/$_name.canonical.stdout" ||
           ! cmp -s "$_normalized_stderr" "$WORKDIR/$_name.canonical.stderr"; then
            _parity=mismatch
        fi
    else
        cp "$_normalized_stdout" "$WORKDIR/$_name.canonical.stdout"
        cp "$_normalized_stderr" "$WORKDIR/$_name.canonical.stderr"
        printf '%s\n' "$_status" >"$WORKDIR/$_name.canonical.status"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_name" "$_implementation" "$_phase" "$_round" "$_order" \
        "$_elapsed" "$_status" "$_signal" "$_launch_errno" \
        "$_stdout_hash" "$_stderr_hash" "$_parity" >>"$OUTDIR/runs.tsv"

    if [ "$_launch_errno" -ne 0 ]; then
        echo "FAIL: $_name/$_implementation could not launch (errno $_launch_errno)" >&2
        exit 1
    fi
    if [ "$_signal" -ne 0 ]; then
        echo "FAIL: $_name/$_implementation terminated by signal $_signal" >&2
        exit 1
    fi
    if [ "$_parity" != match ]; then
        echo "FAIL: $_name/$_implementation $_phase round $_round changed stdout, stderr, or exit status" >&2
        exit 1
    fi
}

echo "TypeLisp benchmark harness (host=$HOST_OS, mode=timing, interleaved rounds=$RUNS)"
echo "compiler: $COMPILER"
echo "pinning: $PINNING"
echo "report: $OUTDIR"
echo

while IFS= read -r name; do
    dir="benchmarks/$name"
    benchmark_args_for_dir "$dir"
    bench_args=$BENCHMARK_ARGS
    tl_bin="$WORKDIR/$name.typelisp$EXE"
    tl_asm="$WORKDIR/$name.typelisp.s"
    auto_bin="$WORKDIR/$name.clang_auto$EXE"
    scalar_bin="$WORKDIR/$name.clang_scalar$EXE"

    tl_compile=$(time_build "$WORKDIR/$name.typelisp.asm" \
        "$COMPILER" compile "$dir/bench.tl" --opt-level 2 -o "$tl_asm" $TARGET_ARGS)
    time_build "$WORKDIR/$name.typelisp" \
        "$COMPILER" build "$dir/bench.tl" --opt-level 2 -o "$tl_bin" $TARGET_ARGS >/dev/null
    # shellcheck disable=SC2086
    auto_compile=$(time_build "$WORKDIR/$name.clang_auto" \
        clang $AUTO_FLAGS "$dir/baseline.c" -o "$auto_bin")
    # shellcheck disable=SC2086
    scalar_compile=$(time_build "$WORKDIR/$name.clang_scalar" \
        clang $SCALAR_FLAGS "$dir/baseline.c" -o "$scalar_bin")

    printf '%s\ttypelisp\t%s\t%s\t%s\t%s\n' "$name" "$tl_compile" \
        "$(wc -c <"$tl_bin" | tr -d ' ')" "$(wc -c <"$tl_asm" | tr -d ' ')" \
        "$(wc -l <"$tl_asm" | tr -d ' ')" >>"$OUTDIR/builds.tsv"
    printf '%s\tclang_auto\t%s\t%s\t-\t-\n' "$name" "$auto_compile" \
        "$(wc -c <"$auto_bin" | tr -d ' ')" >>"$OUTDIR/builds.tsv"
    printf '%s\tclang_scalar\t%s\t%s\t-\t-\n' "$name" "$scalar_compile" \
        "$(wc -c <"$scalar_bin" | tr -d ' ')" >>"$OUTDIR/builds.tsv"

    # One unrecorded-position warm-up per binary; these rows still retain and
    # validate the complete observable result.
    # shellcheck disable=SC2086
    measure_and_record "$name" typelisp warmup 0 0 "$tl_bin" $bench_args
    # shellcheck disable=SC2086
    measure_and_record "$name" clang_auto warmup 0 0 "$auto_bin" $bench_args
    # shellcheck disable=SC2086
    measure_and_record "$name" clang_scalar warmup 0 0 "$scalar_bin" $bench_args

    round=1
    while [ "$round" -le "$RUNS" ]; do
        case $((round % 3)) in
            1) order='typelisp clang_auto clang_scalar' ;;
            2) order='clang_auto clang_scalar typelisp' ;;
            0) order='clang_scalar typelisp clang_auto' ;;
        esac
        position=1
        for implementation in $order; do
            case "$implementation" in
                typelisp) binary=$tl_bin ;;
                clang_auto) binary=$auto_bin ;;
                clang_scalar) binary=$scalar_bin ;;
            esac
            # shellcheck disable=SC2086
            measure_and_record "$name" "$implementation" measured "$round" \
                "$position" "$binary" $bench_args
            position=$((position + 1))
        done
        round=$((round + 1))
    done
    echo "timing captured: $name"
done <"$SELECTED"

summarize_runs "$OUTDIR/runs.tsv" "$OUTDIR/summary.tsv" "$CASE_CSV" "$RUNS"

echo
printf '%-24s %-14s %7s %12s %12s %9s %9s %10s\n' \
    benchmark implementation samples median_s mean_s cv_pct mad_s tl_ratio
awk -F '	' 'NR > 1 {
    printf "%-24s %-14s %7s %12s %12s %9s %9s %10s\n",
        $1, $2, $3, $5, $6, $8, $10, $11
}' "$OUTDIR/summary.tsv"
echo
echo "benchmark harness completed: $FOUND benchmark(s), $RUNS interleaved round(s)"
echo "machine-readable report: $OUTDIR/{metadata,runs,summary}.tsv"
