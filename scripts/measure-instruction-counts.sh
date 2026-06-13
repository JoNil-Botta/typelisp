#!/usr/bin/env sh
set -eu

# measure-instruction-counts.sh - local Linux cachegrind instruction counts.
#
# This is a deterministic measurement harness, not a CI gate. It measures the
# full process under valgrind/cachegrind and records the `Ir` event (executed
# instructions) for TypeLisp benchmark binaries and for a compiler self-compile
# command. Startup is intentionally included; the benchmark loops and the
# self-compile workload are large enough to dominate it. If a future tiny case
# needs startup exclusion, use callgrind region toggling in a separate gate.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

RUNS=${TYPELISP_IR_RUNS:-3}
FILTER=${TYPELISP_IR_FILTER:-}
CASES=${TYPELISP_IR_CASES:-}
WORKDIR=${TYPELISP_IR_OUT:-target/instruction-counts}
OPT_LEVEL=${TYPELISP_IR_OPT_LEVEL:-1}
MEASURE_BENCHMARKS=1
MEASURE_SELF_COMPILE=1

usage() {
    cat <<'EOF'
usage: scripts/measure-instruction-counts.sh [options] [typelisp-seed]

Options:
  --runs N              Repeated cachegrind runs per case (default: 3)
  --filter TEXT         Run benchmark names containing TEXT
  --cases LIST          Run exact comma-separated benchmark names
  --output DIR          Output root (default: target/instruction-counts)
  --opt-level N         Self-compile opt level 0, 1, or 2 (default: 1)
  --benchmarks-only     Measure benchmark binaries only
  --self-compile-only   Measure compiler self-compile only
  --skip-benchmarks     Do not measure benchmark binaries
  --skip-self-compile   Do not measure compiler self-compile
  -h, --help            Show this help

Environment:
  TYPELISP_BIN          Seed compiler when no argument is given
  TYPELISP_IR_RUNS      Default --runs
  TYPELISP_IR_FILTER    Default --filter
  TYPELISP_IR_CASES     Default --cases
  TYPELISP_IR_OUT       Default --output
  TYPELISP_IR_OPT_LEVEL Default --opt-level
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

if [ "$MEASURE_BENCHMARKS" -eq 0 ] && [ "$MEASURE_SELF_COMPILE" -eq 0 ]; then
    echo "nothing to measure: both benchmark and self-compile modes are disabled" >&2
    exit 2
fi

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

if [ -n "$SEED_ARG" ]; then
    COMPILER=$SEED_ARG
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

[ -x "$COMPILER" ] || {
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
}

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/bin" "$WORKDIR/logs"
RUNS_TSV="$WORKDIR/runs.tsv"
SUMMARY_TSV="$WORKDIR/summary.tsv"
printf 'kind\tname\trun\tir_count\texit_status\n' > "$RUNS_TSV"
printf 'kind\tname\tir_count\tmin_ir\tmax_ir\truns\tstable\n' > "$SUMMARY_TSV"

fail() {
    echo "[ir-count] $*" >&2
    exit 1
}

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
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
    shift 3

    safe=$(safe_name "$kind-$name-$run")
    cgout="$WORKDIR/logs/$safe.cachegrind.out"
    stdout="$WORKDIR/logs/$safe.stdout"
    stderr="$WORKDIR/logs/$safe.stderr"

    set +e
    valgrind --quiet --tool=cachegrind --cachegrind-out-file="$cgout" "$@" >"$stdout" 2>"$stderr"
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
    shift 3

    first=
    min=
    max=
    run=1
    while [ "$run" -le "$RUNS" ]; do
        echo "[ir-count] $kind/$name run $run"
        run_cachegrind "$kind" "$name" "$run" "$@"
        if [ "$require_zero" -eq 1 ] && [ "$LAST_STATUS" -ne 0 ]; then
            safe=$(safe_name "$kind-$name-$run")
            show_logs "$WORKDIR/logs/$safe.stdout" "$WORKDIR/logs/$safe.stderr"
            fail "$kind/$name run $run exited $LAST_STATUS"
        fi
        if [ -z "$first" ]; then
            first=$LAST_IR
            min=$LAST_IR
            max=$LAST_IR
        else
            if [ "$LAST_IR" -lt "$min" ]; then min=$LAST_IR; fi
            if [ "$LAST_IR" -gt "$max" ]; then max=$LAST_IR; fi
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
}

build_benchmark() {
    bench_tl=$1
    name=$2
    bin="$WORKDIR/bin/$name"
    stdout="$WORKDIR/logs/benchmark-$name.build.stdout"
    stderr="$WORKDIR/logs/benchmark-$name.build.stderr"

    echo "[ir-count] build benchmark $name"
    if ! "$COMPILER" build "$bench_tl" -o "$bin" \
        --target "$NL_BOOTSTRAP_TARGET" \
        --stdlib-root stdlib \
        --stdlib-root src \
        >"$stdout" 2>"$stderr"; then
        show_logs "$stdout" "$stderr"
        fail "failed to build benchmark $name"
    fi
    [ -x "$bin" ] || fail "benchmark build did not write executable: $bin"
    measure_repeated benchmark "$name" 0 "$bin"
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
    for bench_tl in benchmarks/*/bench.tl; do
        [ -e "$bench_tl" ] || continue
        name=$(basename "$(dirname "$bench_tl")")
        benchmark_selected "$name" || continue
        matched=$((matched + 1))
        build_benchmark "$bench_tl" "$name"
    done
    [ "$matched" -gt 0 ] || fail "no benchmark cases matched filter='$FILTER' cases='$CASES'"
}

measure_self_compile() {
    asm="$WORKDIR/bin/self-compile.opt$OPT_LEVEL.s"
    measure_repeated self_compile "compile_cli_opt$OPT_LEVEL" 1 \
        "$COMPILER" compile src/cli.tl -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root src \
        --opt-level "$OPT_LEVEL"
    [ -s "$asm" ] || fail "self-compile did not write assembly: $asm"
}

echo "[ir-count] compiler: $COMPILER"
echo "[ir-count] output: $WORKDIR"
echo "[ir-count] runs per case: $RUNS"
if [ -n "$CASES" ]; then
    echo "[ir-count] exact benchmark cases: $CASES"
fi

if [ "$MEASURE_BENCHMARKS" -eq 1 ]; then
    measure_benchmarks
fi

if [ "$MEASURE_SELF_COMPILE" -eq 1 ]; then
    measure_self_compile
fi

echo "[ir-count] runs: $RUNS_TSV"
echo "[ir-count] summary: $SUMMARY_TSV"
cat "$SUMMARY_TSV"
