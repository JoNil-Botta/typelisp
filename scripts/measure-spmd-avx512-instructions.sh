#!/usr/bin/env sh
set -eu

# Opt-in, host-keyed AVX-512 retired-instruction measurement. The counter is a
# checked-in TypeLisp launcher using perf_event_open directly; distro `perf`,
# emulators, and cachegrind are deliberately not used.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

CASES=spmd_map,spmd_zip,spmd_reduce,spmd_scan,spmd_shuffle,spmd_short_tail,spmd_mask
SUPPORT_TABLE=${TYPELISP_AVX512_IR_SUPPORT:-$ROOT/perf/spmd-avx512-support.tsv}
BASELINE=${TYPELISP_AVX512_IR_BASELINE:-$ROOT/perf/spmd-avx512-retired-baseline.tsv}
WORKDIR=${TYPELISP_AVX512_IR_OUT:-target/spmd-avx512-instructions}
RUNS=${TYPELISP_AVX512_IR_RUNS:-11}
CPU=${TYPELISP_AVX512_IR_CPU:-4}
CHECK_BASELINE=0
UPDATE_BASELINE=0
SELF_TEST=0
COMPILER_ARG=
TAB=$(printf '\t')
TL_FLAGS="--target linux-x86_64 --backend-mode avx512 --opt-level 2"
C_FLAGS="-O2 -march=x86-64 -mavx512f -mavx512bw -mavx512dq -mno-avx512vl -static"
TOLERANCE_PPM=1000

usage() {
    cat <<'EOF'
usage: scripts/measure-spmd-avx512-instructions.sh [options] [typelisp-bin]

Options:
  --runs N              Recorded runs after one warmup (default: 11)
  --focused             One recorded run for every benchmark row
  --cpu N               Logical CPU used by the counter launcher (default: 4)
  --output DIR          Output root
  --support-table FILE  Checked support/diagnostic table
  --baseline FILE       Host-keyed median baseline
  --check-baseline      Enforce 1000 ppm only for an exact host fingerprint
  --update-baseline     Replace the baseline from this full measurement
  --self-test           Run fast shell/report mutation tests only
  -h, --help            Show this help

Environment mirrors the options with TYPELISP_AVX512_IR_{RUNS,CPU,OUT,
SUPPORT,BASELINE}; TYPELISP_BIN selects the compiler.

Linux/WSL and runnable AVX-512F+BW+DQ are required. Missing ISA or PMU access
is reported and skipped; a host-fingerprint mismatch is report-only.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --runs)
            [ "$#" -ge 2 ] || { echo "missing value for --runs" >&2; exit 2; }
            RUNS=$2
            shift 2
            ;;
        --focused)
            RUNS=1
            shift
            ;;
        --cpu)
            [ "$#" -ge 2 ] || { echo "missing value for --cpu" >&2; exit 2; }
            CPU=$2
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
    echo "[spmd-avx512-ir] $*" >&2
    exit 1
}

support_lookup() {
    _benchmark=$1
    _row=$(awk -F '\t' -v benchmark="$_benchmark" '
        NR == 1 { next }
        $1 == benchmark && $2 == "avx512" { count++; print $3 "\t" $4 }
        END { if (count != 1) exit 1 }
    ' "$SUPPORT_TABLE") || fail "support table needs one $_benchmark/avx512 row"
    IFS="$TAB" read -r SUPPORT_STATUS SUPPORT_DIAGNOSTIC <<EOF
$_row
EOF
}

validate_support_table() {
    [ -f "$SUPPORT_TABLE" ] || fail "missing support table: $SUPPORT_TABLE"
    awk -F '\t' -v cases="$CASES" '
        function contains(csv, value) {
            return index("," csv ",", "," value ",") != 0
        }
        NR == 1 {
            if ($0 != "benchmark\tmode\tstatus\texpected_diagnostic") failed = 1
            next
        }
        {
            key = $1 SUBSEP $2
            if (NF != 4 || seen[key]++ || !contains(cases, $1) || $2 != "avx512") failed = 1
            if ($3 == "measured" || $3 == "supported") {
                if ($4 != "-") failed = 1
            } else if ($3 == "unsupported") {
                if ($4 !~ /^lower: /) failed = 1
            } else failed = 1
            rows++
        }
        END { exit failed || rows != 7 ? 1 : 0 }
    ' "$SUPPORT_TABLE" || fail "invalid support table: $SUPPORT_TABLE"
    _old_ifs=$IFS
    IFS=,
    for _benchmark in $CASES; do support_lookup "$_benchmark"; done
    IFS=$_old_ifs
}

parse_counter_file() {
    _file=$1
    _expected_exit=$2
    _line=$(awk -F '\t' '
        NF == 6 && $1 == "counter" { count++; print }
        END { if (count != 1) exit 1 }
    ' "$_file") || return 1
    IFS="$TAB" read -r _kind COUNTER_RETIRED COUNTER_EXIT COUNTER_SIGNAL COUNTER_ENABLED COUNTER_RUNNING <<EOF
$_line
EOF
    case "$COUNTER_RETIRED:$COUNTER_EXIT:$COUNTER_SIGNAL:$COUNTER_ENABLED:$COUNTER_RUNNING" in
        *[!0-9:]*) return 1 ;;
    esac
    [ "$COUNTER_RETIRED" -gt 0 ] || return 1
    [ "$COUNTER_ENABLED" -gt 0 ] || return 1
    [ "$COUNTER_RUNNING" -gt 0 ] || return 1
    [ "$COUNTER_ENABLED" = "$COUNTER_RUNNING" ] || return 1
    [ "$COUNTER_SIGNAL" -eq 0 ] || return 1
    [ "$COUNTER_EXIT" -eq "$_expected_exit" ] || return 1
    return 0
}

parity_matches() {
    _tl_status=$1
    _c_status=$2
    _tl_stdout=$3
    _c_stdout=$4
    _tl_stderr=$5
    _c_stderr=$6
    [ "$_tl_status" = "$_c_status" ] &&
        cmp -s "$_tl_stdout" "$_c_stdout" &&
        cmp -s "$_tl_stderr" "$_c_stderr"
}

summarize_runs() {
    _runs_file=$1
    _static_file=$2
    _support_file=$3
    _output=$4
    awk -F '\t' -v runs_file="$_runs_file" -v static_file="$_static_file" \
        -v expected_runs="$RUNS" -v tolerance_ppm="$TOLERANCE_PPM" '
        function problem(message) {
            print "[spmd-avx512-ir] " message > "/dev/stderr"
            failed = 1
        }
        function emit(benchmark, implementation, expected_status,
                      key, n, i, j, tmp_value, median, variance, sd, cv, range_ppm) {
            key = benchmark SUBSEP implementation
            expected_key[key] = 1
            n = count[key] + 0
            if (expected_status == "unsupported") {
                if (n != 1 || run_retired[key SUBSEP 0] != "-" ||
                    run_parity[key SUBSEP 0] != "unsupported") {
                    problem("invalid unsupported row for " benchmark "/" implementation)
                    return
                }
                print benchmark, implementation, "avx512", "unsupported", 0, "-", "-", "-", "-", "-", "-", "-", "-", "-", "-"
                return
            }
            if (n != expected_runs) {
                problem("missing runs for " benchmark "/" implementation ": expected " expected_runs ", got " n)
                return
            }
            for (i = 1; i <= expected_runs; i++) {
                if (!(key SUBSEP i in run_seen) || run_retired[key SUBSEP i] !~ /^[0-9]+$/ ||
                    run_exit[key SUBSEP i] !~ /^[0-9]+$/ || run_parity[key SUBSEP i] != "match") {
                    problem("invalid run " i " for " benchmark "/" implementation)
                    return
                }
                ordered[i] = run_retired[key SUBSEP i] + 0.0
            }
            for (i = 1; i <= expected_runs; i++) {
                for (j = i + 1; j <= expected_runs; j++) {
                    if (ordered[j] < ordered[i]) {
                        tmp_value = ordered[i]; ordered[i] = ordered[j]; ordered[j] = tmp_value
                    }
                }
            }
            if ((expected_runs % 2) == 1) median = ordered[int(expected_runs / 2) + 1]
            else median = (ordered[expected_runs / 2] + ordered[expected_runs / 2 + 1]) / 2.0
            variance = m2[key] / n
            if (variance < 0) variance = 0
            sd = sqrt(variance)
            cv = sd * 1000000.0 / mean[key]
            range_ppm = (max[key] - min[key]) * 1000000.0 / median
            if (range_ppm > tolerance_ppm) {
                problem("unstable run range for " benchmark "/" implementation ": " sprintf("%.3f", range_ppm) " ppm")
                return
            }
            print benchmark, implementation, "avx512", "measured", n,
                sprintf("%.0f", min[key]), sprintf("%.0f", median), sprintf("%.0f", max[key]),
                sprintf("%.3f", mean[key]), sprintf("%.3f", sd), sprintf("%.3f", cv),
                static_hash[key], static_vector[key], static_avx512[key], run_exit[key SUBSEP 1]
            for (i = 1; i <= expected_runs; i++) delete ordered[i]
        }
        FILENAME == runs_file {
            if (FNR == 1) next
            if (NF != 7) { problem("run row must have 7 fields"); next }
            key = $1 SUBSEP $2
            run_key = key SUBSEP $4
            if (run_seen[run_key]++) { problem("duplicate run row"); next }
            raw_key[key] = 1
            count[key]++
            run_retired[run_key] = $5
            run_exit[run_key] = $6
            run_parity[run_key] = $7
            if ($5 ~ /^[0-9]+$/) {
                value = $5 + 0.0
                if (count[key] == 1) { min[key] = value; max[key] = value; mean[key] = value; m2[key] = 0 }
                else {
                    if (value < min[key]) min[key] = value
                    if (value > max[key]) max[key] = value
                    delta = value - mean[key]
                    mean[key] += delta / count[key]
                    m2[key] += delta * (value - mean[key])
                }
            }
            next
        }
        FILENAME == static_file {
            if (FNR == 1) next
            key = $1 SUBSEP $2
            static_hash[key] = $4
            static_vector[key] = $5
            static_avx512[key] = $6
            next
        }
        FNR == 1 {
            print "benchmark", "implementation", "mode", "status", "runs", "min", "median", "max", "mean", "stddev", "cv_ppm", "asm_sha256", "vector_opcode_instructions", "avx512_operand_instructions", "exit_status"
            next
        }
        {
            if ($3 == "unsupported") emit($1, "typelisp", "unsupported")
            else {
                emit($1, "typelisp", "measured")
                emit($1, "clang", "measured")
            }
        }
        END {
            for (key in raw_key) if (!(key in expected_key)) problem("unexpected run row")
            exit failed ? 1 : 0
        }
    ' OFS="$TAB" "$_runs_file" "$_static_file" "$_support_file" > "$_output"
}

generate_comparison() {
    _summary=$1
    _support=$2
    _output=$3
    awk -F '\t' '
        NR == FNR {
            if (FNR == 1) next
            key = $1 SUBSEP $2
            status[key] = $4
            median[key] = $7
            next
        }
        FNR == 1 {
            print "benchmark", "mode", "typelisp_median", "clang_median", "ratio_x", "status"
            next
        }
        {
            tl = $1 SUBSEP "typelisp"; c = $1 SUBSEP "clang"
            if ($3 == "unsupported") print $1, "avx512", "-", "-", "-", "unsupported"
            else {
                ratio = (median[tl] + 0.0) / median[c]
                print $1, "avx512", median[tl], median[c], sprintf("%.6f", ratio), "measured"
                logs += log(ratio); pairs++
            }
        }
        END {
            if (pairs > 0) print "geomean", "avx512", "-", "-", sprintf("%.6f", exp(logs / pairs)), "measured"
        }
    ' OFS="$TAB" "$_summary" "$_support" > "$_output"
}

write_current_baseline() {
    _fingerprint=$1
    _summary=$2
    _output=$3
    awk -F '\t' -v fingerprint="$_fingerprint" '
        BEGIN { OFS = "\t"; print "fingerprint", "benchmark", "implementation", "mode", "status", "median_retired" }
        NR == 1 { next }
        { print fingerprint, $1, $2, $3, $4, $7 }
    ' "$_summary" > "$_output"
}

annotate_baseline() {
    _fingerprint=$1
    _summary=$2
    _baseline=$3
    _output=$4
    _check=$5
    awk -F '\t' -v fingerprint="$_fingerprint" -v tolerance="$TOLERANCE_PPM" -v check="$_check" '
        NR == FNR {
            if (FNR == 1) next
            if ($1 == fingerprint) {
                key = $2 SUBSEP $3 SUBSEP $4
                base_status[key] = $5
                base_median[key] = $6
                matching++
            }
            next
        }
        FNR == 1 { print $0, "baseline_median", "baseline_delta_ppm", "baseline_status"; next }
        {
            key = $1 SUBSEP $2 SUBSEP $3
            if (matching == 0) print $0, "-", "-", "host-mismatch"
            else if (!(key in base_status)) { print $0, "-", "-", "missing-baseline"; failed = 1 }
            else if ($4 == "unsupported") {
                if (base_status[key] == "unsupported") print $0, "-", "-", "ok"
                else { print $0, base_median[key], "-", "STATUS-MISMATCH"; failed = 1 }
            } else {
                delta = (($7 + 0.0) - base_median[key]) * 1000000.0 / base_median[key]
                label = "ok"
                if (delta > tolerance) { label = "REGRESSION"; failed = 1 }
                else if (delta < -tolerance) { label = "IMPROVEMENT"; failed = 1 }
                print $0, base_median[key], sprintf("%+.3f", delta), label
            }
        }
        END { if (check == 1 && matching > 0 && failed) exit 1 }
    ' OFS="$TAB" "$_baseline" "$_summary" > "$_output"
}

run_self_test() {
    [ "$TL_FLAGS" = "--target linux-x86_64 --backend-mode avx512 --opt-level 2" ] || fail "self-test TypeLisp flags"
    [ "$C_FLAGS" = "-O2 -march=x86-64 -mavx512f -mavx512bw -mavx512dq -mno-avx512vl -static" ] || fail "self-test clang flags"
    validate_support_table
    support_lookup spmd_mask
    [ "$SUPPORT_STATUS" = supported ] || fail "self-test supported spmd_mask row"
    [ "$SUPPORT_DIAGNOSTIC" = "-" ] || fail "self-test supported spmd_mask diagnostic"

    _dir="$ROOT/target/spmd-avx512-instruction-self-test"
    rm -rf "$_dir"; mkdir -p "$_dir"
    printf 'counter\t100\t7\t0\t20\t20\n' > "$_dir/counter-ok.tsv"
    parse_counter_file "$_dir/counter-ok.tsv" 7 || fail "self-test counter parser"
    printf 'counter\t0\t7\t0\t20\t20\n' > "$_dir/counter-zero.tsv"
    if parse_counter_file "$_dir/counter-zero.tsv" 7; then fail "self-test accepted zero counter"; fi
    printf 'counter\t100\t132\t4\t20\t20\n' > "$_dir/counter-sigill.tsv"
    if parse_counter_file "$_dir/counter-sigill.tsv" 132; then fail "self-test accepted SIGILL"; fi

    : > "$_dir/a.stdout"; : > "$_dir/b.stdout"; : > "$_dir/a.stderr"; : > "$_dir/b.stderr"
    parity_matches 7 7 "$_dir/a.stdout" "$_dir/b.stdout" "$_dir/a.stderr" "$_dir/b.stderr" || fail "self-test parity match"
    printf x > "$_dir/b.stderr"
    if parity_matches 7 7 "$_dir/a.stdout" "$_dir/b.stdout" "$_dir/a.stderr" "$_dir/b.stderr"; then fail "self-test accepted parity failure"; fi

    _support="$_dir/support.tsv"; _static="$_dir/static.tsv"; _runs="$_dir/runs.tsv"
    printf 'benchmark\tmode\tstatus\texpected_diagnostic\nspmd_map\tavx512\tmeasured\t-\nspmd_mask\tavx512\tunsupported\tlower: expected\n' > "$_support"
    printf 'benchmark\timplementation\tmode\tasm_sha256\tvector_opcode_instructions\tavx512_operand_instructions\nspmd_map\ttypelisp\tavx512\ta\t2\t1\nspmd_map\tclang\tavx512\tb\t3\t2\n' > "$_static"
    printf 'benchmark\timplementation\tmode\trun\tretired_instructions\texit_status\tparity_status\n' > "$_runs"
    for _implementation in typelisp clang; do
        _base=100000
        [ "$_implementation" = clang ] && _base=50000
        printf 'spmd_map\t%s\tavx512\t1\t%s\t7\tmatch\n' "$_implementation" "$_base" >> "$_runs"
        printf 'spmd_map\t%s\tavx512\t2\t%s\t7\tmatch\n' "$_implementation" "$((_base + 1))" >> "$_runs"
        printf 'spmd_map\t%s\tavx512\t3\t%s\t7\tmatch\n' "$_implementation" "$((_base + 2))" >> "$_runs"
    done
    printf 'spmd_mask\ttypelisp\tavx512\t0\t-\t-\tunsupported\n' >> "$_runs"
    _saved_runs=$RUNS; RUNS=3
    summarize_runs "$_runs" "$_static" "$_support" "$_dir/summary.tsv" || fail "self-test summary"
    generate_comparison "$_dir/summary.tsv" "$_support" "$_dir/comparison.tsv"
    grep -F "spmd_map${TAB}avx512${TAB}100001${TAB}50001${TAB}1.999980${TAB}measured" "$_dir/comparison.tsv" >/dev/null || fail "self-test ratio"
    grep -F "geomean${TAB}avx512${TAB}-${TAB}-${TAB}1.999980${TAB}measured" "$_dir/comparison.tsv" >/dev/null || fail "self-test geomean"

    grep -v "spmd_map${TAB}clang${TAB}avx512${TAB}3" "$_runs" > "$_dir/missing.tsv"
    if summarize_runs "$_dir/missing.tsv" "$_static" "$_support" "$_dir/missing-summary.tsv" 2>/dev/null; then fail "self-test accepted missing run"; fi
    sed 's/spmd_map\ttypelisp\tavx512\t3\t100002/spmd_map\ttypelisp\tavx512\t3\t200000/' "$_runs" > "$_dir/unstable.tsv"
    if summarize_runs "$_dir/unstable.tsv" "$_static" "$_support" "$_dir/unstable-summary.tsv" 2>/dev/null; then fail "self-test accepted unstable runs"; fi

    _base="$_dir/baseline.tsv"
    printf 'fingerprint\tbenchmark\timplementation\tmode\tstatus\tmedian_retired\nfp\tspmd_map\ttypelisp\tavx512\tmeasured\t100001\nfp\tspmd_map\tclang\tavx512\tmeasured\t50001\nfp\tspmd_mask\ttypelisp\tavx512\tunsupported\t-\n' > "$_base"
    annotate_baseline other "$_dir/summary.tsv" "$_base" "$_dir/mismatch.tsv" 1 || fail "self-test host mismatch should report only"
    grep -q 'host-mismatch' "$_dir/mismatch.tsv" || fail "self-test host mismatch status"
    annotate_baseline fp "$_dir/summary.tsv" "$_base" "$_dir/matched.tsv" 1 || fail "self-test exact baseline"
    awk -F '\t' 'BEGIN { OFS="\t" } $1=="spmd_map" && $2=="typelisp" { $7=100100 } { print }' "$_dir/summary.tsv" > "$_dir/boundary-summary.tsv"
    sed 's/fp\tspmd_map\ttypelisp\tavx512\tmeasured\t100001/fp\tspmd_map\ttypelisp\tavx512\tmeasured\t100000/' "$_base" > "$_dir/boundary.tsv"
    annotate_baseline fp "$_dir/boundary-summary.tsv" "$_dir/boundary.tsv" "$_dir/boundary-out.tsv" 1 || fail "self-test 1000 ppm boundary"
    awk -F '\t' 'BEGIN { OFS="\t" } $1=="spmd_map" && $2=="typelisp" { $7=100101 } { print }' "$_dir/summary.tsv" > "$_dir/regression-summary.tsv"
    if annotate_baseline fp "$_dir/regression-summary.tsv" "$_dir/boundary.tsv" "$_dir/regression.tsv" 1 2>/dev/null; then fail "self-test accepted tolerance overflow"; fi
    RUNS=$_saved_runs
    echo "SPMD AVX-512 instruction harness self-tests passed"
}

case "$RUNS:$CPU" in
    *[!0-9:]*) echo "--runs and --cpu must be non-negative integers" >&2; exit 2 ;;
esac
[ "$RUNS" -gt 0 ] || { echo "--runs must be positive" >&2; exit 2; }
[ "$CPU" -le 1023 ] || { echo "--cpu must be at most 1023" >&2; exit 2; }
[ "$UPDATE_BASELINE" -eq 0 ] || [ "$RUNS" -eq 11 ] || {
    echo "--update-baseline requires the full 11 recorded runs" >&2; exit 2;
}
[ "$CHECK_BASELINE" -eq 0 ] || [ "$UPDATE_BASELINE" -eq 0 ] || {
    echo "--check-baseline and --update-baseline are mutually exclusive" >&2; exit 2;
}

if [ "$SELF_TEST" -eq 1 ]; then run_self_test; exit 0; fi

case "$(uname -s)" in
    Linux*) ;;
    *) echo "SPMD AVX-512 retired-instruction measurement is Linux/WSL-only"; exit 0 ;;
esac

for _tool in awk clang as ld sha256sum cmp grep sed tr uname git; do
    command -v "$_tool" >/dev/null 2>&1 || fail "missing tool: $_tool"
done
if [ -n "$COMPILER_ARG" ]; then COMPILER=$COMPILER_ARG
elif [ -n "${TYPELISP_BIN:-}" ]; then COMPILER=$TYPELISP_BIN
else . "$ROOT/scripts/lib-stage0.sh"; COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
case "$COMPILER" in /*) ;; *) COMPILER="$ROOT/$COMPILER" ;; esac
[ -x "$COMPILER" ] || fail "typelisp compiler is not executable: $COMPILER"
validate_support_table

rm -rf "$WORKDIR"; mkdir -p "$WORKDIR/bin" "$WORKDIR/asm" "$WORKDIR/logs"
COUNTER="$WORKDIR/bin/counter"
"$COMPILER" build tools/spmd-avx512-perf/counter.tl -o "$COUNTER" \
    --target linux-x86_64 --opt-level 2 --stdlib-root stdlib --stdlib-root src >/dev/null

ISAS=$(sh scripts/detect-simd-isa.sh)
if ! printf '%s\n' "$ISAS" | grep -qx avx512; then
    echo "[spmd-avx512-ir] skip: runnable AVX-512F+BW+DQ is required"
    exit 0
fi
grep -Eq "^processor[[:space:]]*:[[:space:]]*$CPU$" /proc/cpuinfo || fail "logical CPU $CPU is absent"

_probe_stdout="$WORKDIR/logs/counter-probe.stdout"; _probe_stderr="$WORKDIR/logs/counter-probe.stderr"
set +e; "$COUNTER" --cpu "$CPU" -- /bin/true >"$_probe_stdout" 2>"$_probe_stderr"; _probe_status=$?; set -e
PERMISSION_STATE=available
if [ "$_probe_status" -ne 0 ] || ! parse_counter_file "$_probe_stdout" 0; then
    PERMISSION_STATE=unavailable
fi

cpu_field() {
    _field=$1
    awk -F ':' -v cpu="$CPU" -v field="$_field" '
        $1 ~ /^processor[[:space:]]*$/ { current=$2; gsub(/[[:space:]]/, "", current) }
        current == cpu && index($1, field) == 1 { value=$2; sub(/^[[:space:]]+/, "", value); print value; exit }
    ' /proc/cpuinfo
}
CPU_VENDOR=$(cpu_field vendor_id); CPU_FAMILY=$(cpu_field 'cpu family'); CPU_MODEL=$(cpu_field model); CPU_STEPPING=$(cpu_field stepping)
CLANG_VERSION=$(clang --version | sed -n '1p'); AS_VERSION=$(as --version | sed -n '1p'); LD_VERSION=$(ld --version | sed -n '1p')
TL_VERSION=$("$COMPILER" --version | sed -n '1p'); TL_HASH=$(sha256sum "$COMPILER" | awk '{print $1}')
COUNTER_SOURCE_HASH=$(sha256sum tools/spmd-avx512-perf/counter.tl | awk '{print $1}')
if GIT_HEAD=$(git -c safe.directory="$ROOT" rev-parse HEAD 2>/dev/null); then
    :
elif command -v git.exe >/dev/null 2>&1 &&
    git.exe --version >/dev/null 2>&1 &&
    command -v wslpath >/dev/null 2>&1
then
    GIT_HEAD=$(git.exe -C "$(wslpath -w "$ROOT")" rev-parse HEAD | tr -d '\r')
else
    GIT_HEAD=unknown
fi
KERNEL=$(uname -r); OS=$(uname -s)
ISA_TOKENS=$(printf '%s\n' "$ISAS" | awk 'NF && !seen[$0]++' | tr '\n' ',' | sed 's/,$//')
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unknown)

METADATA="$WORKDIR/metadata.tsv"; FINGERPRINT_INPUT="$WORKDIR/fingerprint-input.tsv"
printf 'key\tvalue\n' > "$METADATA"
for _pair in \
    "schema_version${TAB}1" "git_head${TAB}$GIT_HEAD" "typelisp_compiler${TAB}$COMPILER" \
    "typelisp_version${TAB}$TL_VERSION" "typelisp_sha256${TAB}$TL_HASH" \
    "counter_source_sha256${TAB}$COUNTER_SOURCE_HASH" \
    "clang_version${TAB}$CLANG_VERSION" "assembler_version${TAB}$AS_VERSION" "linker_version${TAB}$LD_VERSION" \
    "typelisp_flags${TAB}$TL_FLAGS" "clang_flags${TAB}$C_FLAGS" "os${TAB}$OS" "kernel${TAB}$KERNEL" \
    "cpu_vendor${TAB}$CPU_VENDOR" "cpu_family${TAB}$CPU_FAMILY" "cpu_model${TAB}$CPU_MODEL" \
    "cpu_stepping${TAB}$CPU_STEPPING" "processor_id${TAB}$CPU" "isa_tokens${TAB}$ISA_TOKENS" \
    "counter_event${TAB}PERF_TYPE_HARDWARE/PERF_COUNT_HW_INSTRUCTIONS" \
    "counter_filters${TAB}inherit=1,exclude_kernel=1,exclude_hv=1,enable_on_exec=1" \
    "perf_event_paranoid${TAB}$PARANOID" "permission_state${TAB}$PERMISSION_STATE"; do
    printf '%s\n' "$_pair" >> "$METADATA"
done
awk -F '\t' '$1 ~ /^(counter_source_sha256|clang_version|assembler_version|linker_version|typelisp_flags|clang_flags|os|kernel|cpu_vendor|cpu_family|cpu_model|cpu_stepping|processor_id|isa_tokens|counter_event|counter_filters|perf_event_paranoid)$/ { print }' "$METADATA" > "$FINGERPRINT_INPUT"
FINGERPRINT=$(sha256sum "$FINGERPRINT_INPUT" | awk '{print $1}')
printf 'host_tool_fingerprint\t%s\n' "$FINGERPRINT" >> "$METADATA"
if [ "$PERMISSION_STATE" != available ]; then
    cat "$_probe_stderr" >&2 || true
    echo "[spmd-avx512-ir] skip: PMU access unavailable; metadata: $METADATA"
    exit 0
fi

RUNS_TSV="$WORKDIR/runs.tsv"; STATIC_TSV="$WORKDIR/static.tsv"; SUMMARY_BASE="$WORKDIR/summary-base.tsv"
SUMMARY_TSV="$WORKDIR/summary.tsv"; COMPARISON_TSV="$WORKDIR/comparison.tsv"; CURRENT_BASELINE="$WORKDIR/current-baseline.tsv"
printf 'benchmark\timplementation\tmode\trun\tretired_instructions\texit_status\tparity_status\n' > "$RUNS_TSV"
printf 'benchmark\timplementation\tmode\tasm_sha256\tvector_opcode_instructions\tavx512_operand_instructions\n' > "$STATIC_TSV"

static_row() {
    _benchmark=$1; _implementation=$2; _asm=$3
    _hash=$(sha256sum "$_asm" | awk '{print $1}')
    _vector=$(grep -Ec '^[[:space:]]+v[a-zA-Z0-9]+' "$_asm" || true)
    _avx512=$(grep -Ec '(%zmm|%k[0-7])' "$_asm" || true)
    printf '%s\t%s\tavx512\t%s\t%s\t%s\n' "$_benchmark" "$_implementation" "$_hash" "$_vector" "$_avx512" >> "$STATIC_TSV"
}

measure_one() {
    _benchmark=$1; _implementation=$2; _binary=$3; _expected_exit=$4
    _warm="$WORKDIR/logs/$_benchmark.$_implementation.warmup"
    "$COUNTER" --cpu "$CPU" -- "$_binary" >"$_warm.stdout" 2>"$_warm.stderr" || fail "counter warmup failed for $_benchmark/$_implementation"
    parse_counter_file "$_warm.stdout" "$_expected_exit" || fail "invalid warmup counter row for $_benchmark/$_implementation"
    _run=1
    while [ "$_run" -le "$RUNS" ]; do
        _log="$WORKDIR/logs/$_benchmark.$_implementation.$_run"
        "$COUNTER" --cpu "$CPU" -- "$_binary" >"$_log.stdout" 2>"$_log.stderr" || fail "counter failed for $_benchmark/$_implementation run $_run"
        parse_counter_file "$_log.stdout" "$_expected_exit" || fail "invalid/zero/signal counter row for $_benchmark/$_implementation run $_run"
        printf '%s\t%s\tavx512\t%s\t%s\t%s\tmatch\n' "$_benchmark" "$_implementation" "$_run" "$COUNTER_RETIRED" "$COUNTER_EXIT" >> "$RUNS_TSV"
        _run=$((_run + 1))
    done
}

for _benchmark in $(printf '%s' "$CASES" | tr ',' ' '); do
    support_lookup "$_benchmark"
    _tl_src="benchmarks/$_benchmark/bench.tl"; _c_src="benchmarks/$_benchmark/baseline.c"
    if [ "$SUPPORT_STATUS" = unsupported ]; then
        set +e
        "$COMPILER" build "$_tl_src" -o "$WORKDIR/bin/$_benchmark.unsupported" $TL_FLAGS --stdlib-root stdlib --stdlib-root src >"$WORKDIR/logs/$_benchmark.unsupported.stdout" 2>"$WORKDIR/logs/$_benchmark.unsupported.stderr"
        _status=$?; set -e
        [ "$_status" -ne 0 ] || fail "unsupported $_benchmark unexpectedly compiled"
        _actual=$(sed -n 's/^.*: lower: /lower: /p' "$WORKDIR/logs/$_benchmark.unsupported.stderr")
        [ "$_actual" = "$SUPPORT_DIAGNOSTIC" ] || fail "unsupported diagnostic mismatch for $_benchmark"
        printf '%s\ttypelisp\tavx512\t0\t-\t-\tunsupported\n' "$_benchmark" >> "$RUNS_TSV"
        continue
    fi
    _tl_asm1="$WORKDIR/asm/$_benchmark.typelisp.1.s"; _tl_asm2="$WORKDIR/asm/$_benchmark.typelisp.2.s"
    # TL_FLAGS is a checked script constant.
    # shellcheck disable=SC2086
    "$COMPILER" compile "$_tl_src" -o "$_tl_asm1" $TL_FLAGS --stdlib-root stdlib --stdlib-root src >/dev/null
    # shellcheck disable=SC2086
    "$COMPILER" compile "$_tl_src" -o "$_tl_asm2" $TL_FLAGS --stdlib-root stdlib --stdlib-root src >/dev/null
    cmp -s "$_tl_asm1" "$_tl_asm2" || fail "non-deterministic TypeLisp assembly for $_benchmark"
    _tl_bin="$WORKDIR/bin/$_benchmark.typelisp"
    # shellcheck disable=SC2086
    "$COMPILER" build "$_tl_src" -o "$_tl_bin" $TL_FLAGS --stdlib-root stdlib --stdlib-root src >/dev/null
    _c_asm1="$WORKDIR/asm/$_benchmark.clang.1.s"; _c_asm2="$WORKDIR/asm/$_benchmark.clang.2.s"; _c_bin="$WORKDIR/bin/$_benchmark.clang"
    # C_FLAGS is a checked script constant.
    # shellcheck disable=SC2086
    clang $C_FLAGS -S "$_c_src" -o "$_c_asm1"
    # shellcheck disable=SC2086
    clang $C_FLAGS -S "$_c_src" -o "$_c_asm2"
    cmp -s "$_c_asm1" "$_c_asm2" || fail "non-deterministic clang assembly for $_benchmark"
    # shellcheck disable=SC2086
    clang $C_FLAGS "$_c_src" -o "$_c_bin"
    static_row "$_benchmark" typelisp "$_tl_asm1"; static_row "$_benchmark" clang "$_c_asm1"
    set +e; "$_tl_bin" >"$WORKDIR/logs/$_benchmark.typelisp.parity.stdout" 2>"$WORKDIR/logs/$_benchmark.typelisp.parity.stderr"; _tl_status=$?
    "$_c_bin" >"$WORKDIR/logs/$_benchmark.clang.parity.stdout" 2>"$WORKDIR/logs/$_benchmark.clang.parity.stderr"; _c_status=$?; set -e
    parity_matches "$_tl_status" "$_c_status" "$WORKDIR/logs/$_benchmark.typelisp.parity.stdout" "$WORKDIR/logs/$_benchmark.clang.parity.stdout" "$WORKDIR/logs/$_benchmark.typelisp.parity.stderr" "$WORKDIR/logs/$_benchmark.clang.parity.stderr" || fail "observable parity failed for $_benchmark"
    measure_one "$_benchmark" typelisp "$_tl_bin" "$_tl_status"
    measure_one "$_benchmark" clang "$_c_bin" "$_c_status"
done

summarize_runs "$RUNS_TSV" "$STATIC_TSV" "$SUPPORT_TABLE" "$SUMMARY_BASE" || fail "missing or unstable AVX-512 runs"
generate_comparison "$SUMMARY_BASE" "$SUPPORT_TABLE" "$COMPARISON_TSV"
write_current_baseline "$FINGERPRINT" "$SUMMARY_BASE" "$CURRENT_BASELINE"
if [ "$UPDATE_BASELINE" -eq 1 ]; then
    mkdir -p "$(dirname "$BASELINE")"
    cp "$CURRENT_BASELINE" "$BASELINE"
fi
if [ -f "$BASELINE" ]; then
    annotate_baseline "$FINGERPRINT" "$SUMMARY_BASE" "$BASELINE" "$SUMMARY_TSV" "$CHECK_BASELINE" || fail "matching-host AVX-512 baseline differs"
else
    awk -F '\t' 'BEGIN { OFS="\t" } NR==1 { print $0,"baseline_median","baseline_delta_ppm","baseline_status"; next } { print $0,"-","-","missing-baseline" }' "$SUMMARY_BASE" > "$SUMMARY_TSV"
fi
echo "[spmd-avx512-ir] fingerprint: $FINGERPRINT"
echo "[spmd-avx512-ir] metadata: $METADATA"
echo "[spmd-avx512-ir] runs: $RUNS_TSV"
echo "[spmd-avx512-ir] summary: $SUMMARY_TSV"; cat "$SUMMARY_TSV"
echo "[spmd-avx512-ir] comparison: $COMPARISON_TSV"; cat "$COMPARISON_TSV"
