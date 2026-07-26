#!/usr/bin/env sh
set -eu

# measure-instruction-counts.sh - local Linux cachegrind instruction counts.
#
# This is a repeatable measurement harness, not a CI gate. It measures the full
# process under valgrind/cachegrind and records the `Ir` event (executed
# instructions) for TypeLisp benchmark binaries, their clang -O2 C baselines,
# and for a compiler self-compile command. TypeLisp benchmark rows reproduce
# across supported WSL/Linux and CI hosts. The full-process self_compile
# absolute count is environment-specific; compare two trees back to back on one
# host and use their delta. C baselines start Cachegrind instrumentation at the
# C `main` boundary through benchmarks/cachegrind-region.c, excluding the
# dynamically linked PIE startup path whose exact count varies across supported
# local/CI loader environments.
#
# The self_compile metric measures an opt2-built stage2 compiling src/main.tl,
# matching check-instruction-counts.sh (the CI gate) and the number it ratchets
# (self_compile/compile_cli_opt1). When no compiler is given explicitly, the
# harness builds that stage2 from the seed (seed -> stage1 -> stage2, opt2) so a
# standalone run measures the same register-allocated compiler CI does rather
# than the older seed. Pass a compiler explicitly (positional arg or
# TYPELISP_BIN) to measure it as-is, or set TYPELISP_IR_SELF_STAGE2=0 to measure
# the raw seed.
#
# The `--c-scalar` mode (env TYPELISP_IR_MEASURE_C_SCALAR=1) additionally
# builds each C baseline with clang vectorization disabled
# (-fno-vectorize -fno-slp-vectorize) and measures it as
# `benchmark/c-scalar/<name>`, a scalar-fair comparison point alongside the
# auto-vectorized clang -O2 baseline. It remains opt-in for ad-hoc measurement;
# check-instruction-counts.sh enables it for the per-PR scalar gate.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

RUNS=${TYPELISP_IR_RUNS:-3}
FILTER=${TYPELISP_IR_FILTER:-}
CASES=${TYPELISP_IR_CASES:-}
WORKDIR=${TYPELISP_IR_OUT:-target/instruction-counts}
OPT_LEVEL=${TYPELISP_IR_OPT_LEVEL:-1}
# Benchmark binaries are built at opt-level 2 so the TypeLisp/C comparison is
# release-vs-release (clang -O2). This is independent of OPT_LEVEL, which only
# selects the self-compile throughput metric's optimizer level.
BENCH_OPT_LEVEL=${TYPELISP_IR_BENCH_OPT_LEVEL:-2}
C_OPT=-O2
C_SCALAR=${TYPELISP_IR_MEASURE_C_SCALAR:-0}
MEASURE_BENCHMARKS=1
MEASURE_SELF_COMPILE=1
SELF_TEST=0
C_REGION_MAIN=typelisp_instruction_count_benchmark_main
C_REGION_WRAPPER="$ROOT/benchmarks/cachegrind-region.c"
C_REGION_SELF_TEST="$ROOT/benchmarks/cachegrind-region-self-test.c"

usage() {
    cat <<'EOF'
usage: scripts/measure-instruction-counts.sh [options] [typelisp-seed]

Options:
  --runs N              Repeated cachegrind runs per case (default: 3)
  --filter TEXT         Run benchmark names containing TEXT
  --cases LIST          Run exact comma-separated benchmark names
  --output DIR          Output root (default: target/instruction-counts)
  --opt-level N         Self-compile opt level 0, 1, or 2 (default: 1)
                        (benchmark binaries always build at opt-level 2)
  --benchmarks-only     Measure benchmark binaries only
  --self-compile-only   Measure compiler self-compile only
  --skip-benchmarks     Do not measure benchmark binaries
  --skip-self-compile   Do not measure compiler self-compile
  --c-scalar            Also build each C baseline with clang vectorization
                        disabled (-fno-vectorize -fno-slp-vectorize) and
                        measure it as benchmark/c-scalar/<name> (opt-in)
  --self-test           Verify that the C measured region excludes startup and
                        is reproducible; does not require a TypeLisp compiler
  -h, --help            Show this help

Environment:
  TYPELISP_BIN          Seed compiler when no argument is given
  TYPELISP_IR_RUNS      Default --runs
  TYPELISP_IR_FILTER    Default --filter
  TYPELISP_IR_CASES     Default --cases
  TYPELISP_IR_OUT       Default --output
  TYPELISP_IR_OPT_LEVEL Default --opt-level (self-compile only)
  TYPELISP_IR_BENCH_OPT_LEVEL
                        Benchmark binary opt level (default: 2)
  TYPELISP_IR_MEASURE_C_SCALAR
                        Default --c-scalar (0 or 1; also measure a scalar,
                        vectorization-disabled C baseline)
EOF
}

SEED_ARG=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --runs)
            [ "$#" -ge 2 ] || {
                echo "missing value for --runs" >&2
                exit 2
            }
            RUNS=$2
            shift 2
            ;;
        --filter)
            [ "$#" -ge 2 ] || {
                echo "missing value for --filter" >&2
                exit 2
            }
            FILTER=$2
            shift 2
            ;;
        --cases)
            [ "$#" -ge 2 ] || {
                echo "missing value for --cases" >&2
                exit 2
            }
            CASES=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || {
                echo "missing value for --output" >&2
                exit 2
            }
            WORKDIR=$2
            shift 2
            ;;
        --opt-level)
            [ "$#" -ge 2 ] || {
                echo "missing value for --opt-level" >&2
                exit 2
            }
            OPT_LEVEL=$2
            shift 2
            ;;
        --benchmarks-only)
            MEASURE_BENCHMARKS=1
            MEASURE_SELF_COMPILE=0
            shift
            ;;
        --self-compile-only)
            MEASURE_BENCHMARKS=0
            MEASURE_SELF_COMPILE=1
            shift
            ;;
        --skip-benchmarks)
            MEASURE_BENCHMARKS=0
            shift
            ;;
        --skip-self-compile)
            MEASURE_SELF_COMPILE=0
            shift
            ;;
        --c-scalar)
            C_SCALAR=1
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
            if [ -n "$SEED_ARG" ]; then
                echo "only one typelisp seed may be provided" >&2
                exit 2
            fi
            SEED_ARG=$1
            shift
            ;;
    esac
done

case "$RUNS" in
    "" | *[!0-9]* | 0)
        echo "--runs must be a positive integer: $RUNS" >&2
        exit 2
        ;;
esac

case "$OPT_LEVEL" in
    0 | 1 | 2) ;;
    *)
        echo "--opt-level must be 0, 1, or 2: $OPT_LEVEL" >&2
        exit 2
        ;;
esac

case "$CASES" in
    *[!A-Za-z0-9_.,-]*)
        echo "--cases may only contain comma-separated benchmark names: $CASES" >&2
        exit 2
        ;;
esac

case "$C_SCALAR" in
    0 | 1) ;;
    *)
        echo "TYPELISP_IR_MEASURE_C_SCALAR must be 0 or 1: $C_SCALAR" >&2
        exit 2
        ;;
esac

if [ "$SELF_TEST" -eq 0 ] && [ "$MEASURE_BENCHMARKS" -eq 0 ] && [ "$MEASURE_SELF_COMPILE" -eq 0 ]; then
    echo "nothing to measure: both benchmark and self-compile modes are disabled" >&2
    exit 2
fi

fail() {
    echo "[ir-count] $*" >&2
    exit 1
}

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "instruction-count harness is Linux-only (requires valgrind/cachegrind)"
        exit 0
        ;;
esac

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

for tool in valgrind awk tr sed basename dirname; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing tool: $tool" >&2
        exit 1
    }
done
VALGRIND=$(command -v valgrind)
if [ "$MEASURE_BENCHMARKS" -eq 1 ] || [ "$SELF_TEST" -eq 1 ]; then
    command -v clang >/dev/null 2>&1 || fail "missing tool: clang (C baseline compiler)"
fi

if [ "$MEASURE_BENCHMARKS" -eq 1 ] || [ "$SELF_TEST" -eq 1 ]; then
    [ -f "$C_REGION_WRAPPER" ] || fail "missing C measured-region wrapper: $C_REGION_WRAPPER"
fi

# SELF_STAGE2 (default on) builds an opt2 stage2 from the seed so a standalone
# run measures the same register-allocated self-hosted compiler as the CI
# instruction-count gate (check-instruction-counts.sh passes its bootstrap
# stage2 in explicitly). An explicit compiler -- a positional seed (CI passes
# its prebuilt stage2 here) or TYPELISP_BIN -- is measured as given. Set
# TYPELISP_IR_SELF_STAGE2=0 to measure the raw seed instead (faster, but does
# not reflect the metric CI ratchets).
SELF_STAGE2=${TYPELISP_IR_SELF_STAGE2:-1}
BUILD_STAGE2_FROM_SEED=0
if [ "$SELF_TEST" -eq 1 ]; then
    [ -z "$SEED_ARG" ] || fail "--self-test does not accept a TypeLisp compiler"
    COMPILER=/bin/true
elif [ -n "$SEED_ARG" ]; then
    COMPILER=$SEED_ARG
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    if [ "$SELF_STAGE2" = 1 ]; then
        BUILD_STAGE2_FROM_SEED=1
    fi
fi

[ -x "$COMPILER" ] || {
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
}

if [ "$SELF_TEST" -eq 0 ] &&
    [ "$MEASURE_SELF_COMPILE" -eq 1 ] &&
    [ "${GITHUB_ACTIONS:-}" != true ]; then
    echo "[ir-count] note: local self_compile absolute counts are environment-specific" >&2
    echo "[ir-count] measure base and branch back to back on this host and compare their delta" >&2
    echo "[ir-count] the checked absolute baseline is owned by Linux CI; see perf/README.md" >&2
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/bin" "$WORKDIR/logs"

if [ "$BUILD_STAGE2_FROM_SEED" -eq 1 ]; then
    echo "[ir-count] building opt2 stage2 from seed to match the CI self-compile metric" >&2
    echo "[ir-count]   (set TYPELISP_IR_SELF_STAGE2=0 to measure the raw seed instead)" >&2
    build_selfhost_stage2 "$ROOT" "$COMPILER" "$WORKDIR/stage2-compiler" || exit 1
    COMPILER=$(selfhost_stage2_path "$WORKDIR/stage2-compiler")
    [ -x "$COMPILER" ] || {
        echo "stage2 compiler not executable after build: $COMPILER" >&2
        exit 1
    }
fi
RUNS_TSV="$WORKDIR/runs.tsv"
SUMMARY_TSV="$WORKDIR/summary.tsv"
RATIOS_TSV="$WORKDIR/ratios.tsv"
printf 'kind\tname\trun\tir_count\texit_status\n' > "$RUNS_TSV"
printf 'kind\tname\tir_count\tmin_ir\tmax_ir\truns\tstable\n' > "$SUMMARY_TSV"
CR=$(printf '\r')

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
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
            fail "multiple metadata rows in $_metadata"
        fi
        _line=$_candidate
    done < "$_metadata"

    [ -n "$_line" ] || fail "missing metadata row in $_metadata"
    _fields=$(printf '%s\n' "$_line" | awk -F'|' '{ print NF }')
    [ "$_fields" -eq 2 ] || fail "metadata line must have 2 fields: $_metadata: $_line"

    IFS='|' read -r _category BENCHMARK_ARGS <<EOF
$_line
EOF
}

show_logs() {
    stdout=$1
    stderr=$2
    if [ -s "$stdout" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
    fi
    if [ -s "$stderr" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
    fi
}

cachegrind_ir() {
    awk '
        /^events:/ {
            ir_col = 0
            for (i = 2; i <= NF; i++) {
                if ($i == "Ir") {
                    ir_col = i - 1
                }
            }
        }
        /^summary:/ && ir_col > 0 {
            value = $(ir_col + 1)
            gsub(/,/, "", value)
            print value
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$1"
}

run_cachegrind() {
    kind=$1
    name=$2
    run=$3
    instr_at_start=$4
    shift 4

    safe=$(safe_name "$kind-$name-$run")
    cgout="$WORKDIR/logs/$safe.cachegrind.out"
    stdout="$WORKDIR/logs/$safe.stdout"
    stderr="$WORKDIR/logs/$safe.stderr"

    set +e
    env -i LC_ALL=C "$VALGRIND" \
        --quiet --tool=cachegrind --instr-at-start="$instr_at_start" \
        --cachegrind-out-file="$cgout" \
        "$@" >"$stdout" 2>"$stderr"
    status=$?
    set -e

    [ -s "$cgout" ] || {
        show_logs "$stdout" "$stderr"
        fail "cachegrind did not write output for $kind/$name run $run"
    }

    ir=$(cachegrind_ir "$cgout") || {
        show_logs "$stdout" "$stderr"
        fail "could not parse Ir from $cgout"
    }
    case "$ir" in
        "" | *[!0-9]*)
            fail "parsed non-numeric Ir for $kind/$name run $run: $ir"
            ;;
    esac

    printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$name" "$run" "$ir" "$status" >> "$RUNS_TSV"
    LAST_IR=$ir
    LAST_STATUS=$status
}

measure_repeated() {
    kind=$1
    name=$2
    require_zero=$3
    instr_at_start=$4
    shift 4

    first=
    min=
    max=
    first_status=
    status_stable=1
    run=1
    while [ "$run" -le "$RUNS" ]; do
        echo "[ir-count] $kind/$name run $run"
        run_cachegrind "$kind" "$name" "$run" "$instr_at_start" "$@"
        if [ "$require_zero" -eq 1 ] && [ "$LAST_STATUS" -ne 0 ]; then
            safe=$(safe_name "$kind-$name-$run")
            show_logs "$WORKDIR/logs/$safe.stdout" "$WORKDIR/logs/$safe.stderr"
            fail "$kind/$name run $run exited $LAST_STATUS"
        fi
        if [ -z "$first" ]; then
            first=$LAST_IR
            min=$LAST_IR
            max=$LAST_IR
            first_status=$LAST_STATUS
        else
            if [ "$LAST_IR" -lt "$min" ]; then min=$LAST_IR; fi
            if [ "$LAST_IR" -gt "$max" ]; then max=$LAST_IR; fi
            if [ "$LAST_STATUS" != "$first_status" ]; then status_stable=0; fi
        fi
        run=$((run + 1))
    done

    stable=0
    if [ "$min" = "$max" ]; then
        stable=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$name" "$first" "$min" "$max" "$RUNS" "$stable" >> "$SUMMARY_TSV"
    if [ "$stable" -ne 1 ]; then
        fail "$kind/$name Ir was not stable across $RUNS runs: min=$min max=$max"
    fi
    if [ "$status_stable" -ne 1 ]; then
        fail "$kind/$name exit status was not stable across $RUNS runs"
    fi
    LAST_SUMMARY_STATUS=$first_status
}

build_c_region_self_test() {
    startup_iterations=$1
    name=$2
    bin="$WORKDIR/bin/c-region-$name"
    stdout="$WORKDIR/logs/c-region-$name.build.stdout"
    stderr="$WORKDIR/logs/c-region-$name.build.stderr"

    if ! clang "$C_OPT" \
        "-DTYPELISP_IR_STARTUP_ITERATIONS=$startup_iterations" \
        "-Dmain=$C_REGION_MAIN" \
        "$C_REGION_SELF_TEST" "$C_REGION_WRAPPER" \
        -o "$bin" >"$stdout" 2>"$stderr"; then
        show_logs "$stdout" "$stderr"
        fail "unsupported C measured-region toolchain: clang must find valgrind/cachegrind.h"
    fi
    [ -x "$bin" ] || fail "C measured-region self-test did not write executable: $bin"
    C_REGION_SELF_TEST_BIN=$bin
}

run_c_region_self_test() {
    [ -f "$C_REGION_SELF_TEST" ] || fail "missing C measured-region self-test: $C_REGION_SELF_TEST"

    build_c_region_self_test 1 short-startup
    short_bin=$C_REGION_SELF_TEST_BIN
    build_c_region_self_test 100000 long-startup
    long_bin=$C_REGION_SELF_TEST_BIN

    run_cachegrind "self-test/c-region" short-startup 1 no "$short_bin"
    short_ir=$LAST_IR
    run_cachegrind "self-test/c-region" long-startup 1 no "$long_bin"
    long_ir=$LAST_IR
    run_cachegrind "self-test/c-region" long-startup-repeat 1 no "$long_bin"
    repeat_ir=$LAST_IR

    [ "$short_ir" -gt 0 ] || {
        fail "unsupported Cachegrind measured-region environment: start instrumentation request recorded zero instructions"
    }
    [ "$short_ir" = "$long_ir" ] || {
        fail "C measured region includes startup work: short=$short_ir long=$long_ir"
    }
    [ "$long_ir" = "$repeat_ir" ] || {
        fail "C measured region is not reproducible: first=$long_ir repeat=$repeat_ir"
    }
    echo "[ir-count] C measured-region self-test passed: Ir=$short_ir"
}

build_typelisp_benchmark() {
    bench_tl=$1
    name=$2
    bin="$WORKDIR/bin/$name.typelisp"
    safe=$(safe_name "benchmark-typelisp-$name")
    stdout="$WORKDIR/logs/$safe.build.stdout"
    stderr="$WORKDIR/logs/$safe.build.stderr"

    echo "[ir-count] build benchmark/typelisp $name (opt-level $BENCH_OPT_LEVEL)"
    if ! "$COMPILER" build "$bench_tl" -o "$bin" \
        --target "$NL_BOOTSTRAP_TARGET" \
        --opt-level "$BENCH_OPT_LEVEL" \
        --stdlib-root stdlib \
        --stdlib-root src \
        >"$stdout" 2>"$stderr"; then
        show_logs "$stdout" "$stderr"
        fail "failed to build benchmark $name"
    fi
    [ -x "$bin" ] || fail "benchmark build did not write executable: $bin"
    # shellcheck disable=SC2086
    measure_repeated "benchmark/typelisp" "$name" 0 yes "$bin" $bench_args
    TL_STATUS=$LAST_SUMMARY_STATUS
}

build_c_benchmark() {
    baseline_c=$1
    name=$2
    bin="$WORKDIR/bin/$name.c"
    safe=$(safe_name "benchmark-c-$name")
    stdout="$WORKDIR/logs/$safe.build.stdout"
    stderr="$WORKDIR/logs/$safe.build.stderr"

    echo "[ir-count] build benchmark/c $name"
    if ! clang "$C_OPT" \
        "-Dmain=$C_REGION_MAIN" \
        "$baseline_c" "$C_REGION_WRAPPER" \
        -o "$bin" >"$stdout" 2>"$stderr"; then
        show_logs "$stdout" "$stderr"
        fail "failed to build C benchmark $name (the measured-region wrapper requires valgrind/cachegrind.h)"
    fi
    [ -x "$bin" ] || fail "C benchmark build did not write executable: $bin"
    # shellcheck disable=SC2086
    measure_repeated "benchmark/c" "$name" 0 no "$bin" $bench_args
    C_STATUS=$LAST_SUMMARY_STATUS
}

build_c_scalar_benchmark() {
    baseline_c=$1
    name=$2
    bin="$WORKDIR/bin/$name.c-scalar"
    safe=$(safe_name "benchmark-c-scalar-$name")
    stdout="$WORKDIR/logs/$safe.build.stdout"
    stderr="$WORKDIR/logs/$safe.build.stderr"

    echo "[ir-count] build benchmark/c-scalar $name"
    if ! clang "$C_OPT" -fno-vectorize -fno-slp-vectorize \
        "-Dmain=$C_REGION_MAIN" \
        "$baseline_c" "$C_REGION_WRAPPER" \
        -o "$bin" >"$stdout" 2>"$stderr"; then
        show_logs "$stdout" "$stderr"
        fail "failed to build scalar C benchmark $name (the measured-region wrapper requires valgrind/cachegrind.h)"
    fi
    [ -x "$bin" ] || fail "scalar C benchmark build did not write executable: $bin"
    # shellcheck disable=SC2086
    measure_repeated "benchmark/c-scalar" "$name" 0 no "$bin" $bench_args
    C_SCALAR_STATUS=$LAST_SUMMARY_STATUS
}

build_benchmark_pair() {
    bench_tl=$1
    name=$2
    dir=$(dirname "$bench_tl")
    baseline_c="$dir/baseline.c"

    [ -f "$baseline_c" ] || fail "selected benchmark $name has bench.tl but no baseline.c"
    benchmark_args_for_dir "$dir"
    bench_args=$BENCHMARK_ARGS

    build_typelisp_benchmark "$bench_tl" "$name"
    build_c_benchmark "$baseline_c" "$name"
    [ "$TL_STATUS" = "$C_STATUS" ] || {
        fail "benchmark $name observable output differs (typelisp exit $TL_STATUS, C exit $C_STATUS)"
    }
    if [ "$C_SCALAR" -eq 1 ]; then
        build_c_scalar_benchmark "$baseline_c" "$name"
        [ "$C_SCALAR_STATUS" = "$C_STATUS" ] || {
            fail "benchmark $name scalar C baseline output differs (c-scalar exit $C_SCALAR_STATUS, C exit $C_STATUS)"
        }
    fi
}

benchmark_selected() {
    name=$1
    if [ -n "$CASES" ]; then
        case ",$CASES," in
            *,"$name",*) ;;
            *) return 1 ;;
        esac
    fi
    if [ -n "$FILTER" ]; then
        case "$name" in
            *"$FILTER"*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

measure_benchmarks() {
    matched=0
    explicit_selection=0
    if [ -n "$CASES" ] || [ -n "$FILTER" ]; then
        explicit_selection=1
    fi
    for bench_tl in benchmarks/*/bench.tl; do
        [ -e "$bench_tl" ] || continue
        dir=$(dirname "$bench_tl")
        name=$(basename "$(dirname "$bench_tl")")
        benchmark_selected "$name" || continue
        if [ ! -f "$dir/baseline.c" ]; then
            if [ "$explicit_selection" -eq 1 ]; then
                fail "selected benchmark $name has bench.tl but no baseline.c"
            fi
            echo "[ir-count] skip benchmark $name without baseline.c"
            continue
        fi
        matched=$((matched + 1))
        build_benchmark_pair "$bench_tl" "$name"
    done
    [ "$matched" -gt 0 ] || fail "no benchmark cases matched filter='$FILTER' cases='$CASES'"
}

generate_benchmark_ratios() {
    summary=$1
    output=$2
    require_scalar=$3
    awk -F '\t' -v require_scalar="$require_scalar" '
        function problem(message) {
            print "[ir-count] " message > "/dev/stderr"
            failed = 1
        }
        NR == 1 {
            if ($0 != "kind\tname\tir_count\tmin_ir\tmax_ir\truns\tstable") {
                problem("invalid summary header for ratio report")
            }
            next
        }
        $1 == "benchmark/typelisp" ||
        $1 == "benchmark/c" ||
        $1 == "benchmark/c-scalar" {
            implementation = $1
            sub(/^benchmark\//, "", implementation)
            key = implementation SUBSEP $2
            if (seen[key]++) {
                problem("duplicate summary row for " $1 "/" $2)
                next
            }
            if ($3 !~ /^[0-9]+$/ || ($3 + 0) <= 0 || $7 != 1) {
                problem("invalid or unstable summary row for " $1 "/" $2)
                next
            }
            count[key] = $3
            if (implementation == "typelisp") {
                benchmark_order[++benchmark_count] = $2
                typelisp_seen[$2] = 1
            } else {
                comparison_seen[$2] = 1
            }
        }
        END {
            print "benchmark", "typelisp_ir", "clang_auto_ir", \
                "clang_scalar_ir", "typelisp_over_clang_auto_x", \
                "typelisp_over_clang_scalar_x"
            for (i = 1; i <= benchmark_count; i++) {
                benchmark = benchmark_order[i]
                tl = count["typelisp" SUBSEP benchmark]
                auto = count["c" SUBSEP benchmark]
                scalar = count["c-scalar" SUBSEP benchmark]
                valid = 1
                if (auto == "") {
                    problem("missing auto-vectorized clang row for " benchmark)
                    valid = 0
                }
                if (require_scalar == 1 && scalar == "") {
                    problem("missing scalar-fair clang row for " benchmark)
                    valid = 0
                }
                if (valid) {
                    if (scalar == "") {
                        print benchmark, tl, auto, "-", \
                            sprintf("%.6f", (tl + 0.0) / auto), "-"
                    } else {
                        print benchmark, tl, auto, scalar, \
                            sprintf("%.6f", (tl + 0.0) / auto), \
                            sprintf("%.6f", (tl + 0.0) / scalar)
                    }
                }
            }
            for (benchmark in comparison_seen) {
                if (!(benchmark in typelisp_seen)) {
                    problem("comparison row has no TypeLisp row for " benchmark)
                }
            }
            exit failed ? 1 : 0
        }
    ' OFS="$(printf '\t')" "$summary" > "$output"
}

run_ratio_self_test() {
    ratio_summary="$WORKDIR/ratio-self-test-summary.tsv"
    ratio_output="$WORKDIR/ratio-self-test.tsv"
    ratio_missing="$WORKDIR/ratio-self-test-missing.tsv"
    printf 'kind\tname\tir_count\tmin_ir\tmax_ir\truns\tstable\n' > "$ratio_summary"
    printf 'benchmark/typelisp\tdemo\t100\t100\t100\t2\t1\n' >> "$ratio_summary"
    printf 'benchmark/c\tdemo\t25\t25\t25\t2\t1\n' >> "$ratio_summary"
    printf 'benchmark/c-scalar\tdemo\t50\t50\t50\t2\t1\n' >> "$ratio_summary"
    printf 'self_compile\tcompile_cli_opt1\t999\t999\t999\t1\t1\n' >> "$ratio_summary"

    generate_benchmark_ratios "$ratio_summary" "$ratio_output" 1 ||
        fail "ratio self-test could not generate paired report"
    awk -F '\t' '
        $1 == "demo" && $2 == 100 && $3 == 25 && $4 == 50 &&
        $5 == "4.000000" && $6 == "2.000000" { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$ratio_output" || fail "ratio self-test paired values"

    grep -v '^benchmark/c-scalar' "$ratio_summary" > "$ratio_missing"
    if generate_benchmark_ratios "$ratio_missing" "$ratio_output" 1 2>/dev/null; then
        fail "ratio self-test accepted a missing scalar-fair row"
    fi
    generate_benchmark_ratios "$ratio_missing" "$ratio_output" 0 ||
        fail "ratio self-test rejected optional scalar-fair row"
    awk -F '\t' '
        $1 == "demo" && $2 == 100 && $3 == 25 && $4 == "-" &&
        $5 == "4.000000" && $6 == "-" { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$ratio_output" || fail "ratio self-test optional values"
    echo "[ir-count] benchmark ratio self-test passed"
}

measure_self_compile() {
    asm="$WORKDIR/bin/self-compile.opt$OPT_LEVEL.s"
    measure_repeated self_compile "compile_cli_opt$OPT_LEVEL" 1 yes \
        "$COMPILER" compile src/main.tl -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root src \
        --opt-level "$OPT_LEVEL"
    [ -s "$asm" ] || fail "self-compile did not write assembly: $asm"
}

if [ "$SELF_TEST" -eq 1 ]; then
    run_c_region_self_test
    run_ratio_self_test
    exit 0
fi

echo "[ir-count] compiler: $COMPILER"
if [ "$MEASURE_BENCHMARKS" -eq 1 ]; then
    echo "[ir-count] C benchmark compiler: clang $C_OPT"
    echo "[ir-count] C benchmark region: Cachegrind starts at C main"
    if [ "$C_SCALAR" -eq 1 ]; then
        echo "[ir-count] scalar C baseline: clang $C_OPT -fno-vectorize -fno-slp-vectorize"
    fi
fi
echo "[ir-count] output: $WORKDIR"
echo "[ir-count] runs per case: $RUNS"
if [ -n "$CASES" ]; then
    echo "[ir-count] exact benchmark cases: $CASES"
fi

if [ "$MEASURE_BENCHMARKS" -eq 1 ]; then
    measure_benchmarks
    generate_benchmark_ratios "$SUMMARY_TSV" "$RATIOS_TSV" "$C_SCALAR" ||
        fail "could not generate benchmark ratio report"
fi

if [ "$MEASURE_SELF_COMPILE" -eq 1 ]; then
    measure_self_compile
fi

echo "[ir-count] runs: $RUNS_TSV"
echo "[ir-count] summary: $SUMMARY_TSV"
cat "$SUMMARY_TSV"
if [ "$MEASURE_BENCHMARKS" -eq 1 ]; then
    echo "[ir-count] ratios: $RATIOS_TSV"
    cat "$RATIOS_TSV"
fi
