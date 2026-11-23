#!/usr/bin/env sh

# Shared opt-in hardware cycle measurement for the two Cachegrind harnesses.
# Native samples run the same executables and check against Cachegrind outputs.

bench_cycles_parse() {
    LC_ALL=C awk -F ';' '
        $3 == "cycles:u" {
            if (++events != 1 || $1 !~ /^[0-9]+$/ || $1 + 0 <= 0 ||
                $5 !~ /^[0-9]+([.][0-9]+)?$/ || $5 + 0 != 100) {
                invalid = 1
            }
            count = $1
        }
        END {
            if (events != 1 || invalid) exit 1
            print count
        }
    ' "$1"
}

bench_cycles_stat() {
    _bcs_file=$1
    shift
    env -i LC_ALL=C "$BENCH_PERF" stat --no-big-num -x ';' -o "$_bcs_file" -e cycles:u -- "$@"
}

bench_cycles_init() {
    BENCH_PERF=$(command -v perf) || fail "--cycles requires Linux perf"
    case "$CYCLE_RUNS" in
        '' | *[!0-9]*) fail "--cycle-runs requires a positive integer" ;;
    esac
    [ "$CYCLE_RUNS" -gt 0 ] || fail "--cycle-runs requires a positive integer"
    _bci_probe="$WORKDIR/logs/cycles-probe.stat"
    if ! bench_cycles_stat "$_bci_probe" /bin/true || ! bench_cycles_parse "$_bci_probe" >/dev/null; then
        [ ! -f "$_bci_probe" ] || cat "$_bci_probe" >&2
        fail "perf stat could not count cycles:u with full counter coverage"
    fi
    {
        printf 'key\tvalue\n'
        printf 'perf\t%s\n' "$("$BENCH_PERF" --version)"
        printf 'event\tcycles:u\n'
        printf 'scope\twhole process, user mode\n'
        printf 'runs\t%s\n' "$CYCLE_RUNS"
        printf 'cpu_model\t%s\n' "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
        awk '/^Cpus_allowed_list:/ {print "cpu_affinity\t" $2}' /proc/self/status
        printf 'kernel\t%s\n' "$(uname -r)"
    } > "$WORKDIR/cycle-metadata.tsv"
    printf 'benchmark\tmode\timplementation\trun\tcycles\n' > "$WORKDIR/cycle-runs.tsv"
    printf 'benchmark\tmode\timplementation\tmedian_cycles\tmin_cycles\tmax_cycles\truns\n' \
        > "$WORKDIR/cycle-summary.tsv"
}

# Run native samples against the Cachegrind status, stdout and stderr.
bench_cycles_measure() (
    benchmark=$1 mode=$2 implementation=$3 expected_status=$4
    expected_stdout=$5 expected_stderr=$6
    shift 6
    label="$benchmark/$mode/$implementation"
    log="$WORKDIR/logs/$(bench_safe_name "$label")"
    samples="$log.cycles"
    : > "$samples"
    run=1
    while [ "$run" -le "$CYCLE_RUNS" ]; do
        stat="$log.$run.stat"
        status=0
        bench_cycles_stat "$stat" "$@" > "$log.$run.native.stdout" 2> "$log.$run.native.stderr" || status=$?
        count=$(bench_cycles_parse "$stat") || {
            [ ! -f "$stat" ] || cat "$stat" >&2
            bench_show_logs "$log.$run.native.stdout" "$log.$run.native.stderr"
            fail "missing or multiplexed cycles:u for $label run $run"
        }
        if [ "$status" -ne "$expected_status" ] ||
           ! cmp -s "$expected_stdout" "$log.$run.native.stdout" ||
           ! cmp -s "$expected_stderr" "$log.$run.native.stderr"; then
            bench_show_logs "$log.$run.native.stdout" "$log.$run.native.stderr"
            fail "native output or exit status differs from Cachegrind for $label run $run"
        fi
        printf '%s\n' "$count" >> "$samples"
        printf '%s\t%s\t%s\t%s\t%s\n' "$benchmark" "$mode" "$implementation" "$run" "$count" \
            >> "$WORKDIR/cycle-runs.tsv"
        run=$((run + 1))
    done
    LC_ALL=C sort -n "$samples" | awk -v benchmark="$benchmark" -v mode="$mode" \
        -v implementation="$implementation" '
        { counts[NR] = $1 }
        END {
            median = (counts[int((NR + 1) / 2)] + counts[int((NR + 2) / 2)]) / 2
            printf "%s\t%s\t%s\t%.0f\t%s\t%s\t%d\n", benchmark, mode,
                implementation, median, counts[1], counts[NR], NR
        }
    ' >> "$WORKDIR/cycle-summary.tsv"
)

# Cachegrind has already checked case coverage and parity. An SPMD case
# unsupported by TypeLisp has a clang measurement but no paired ratio.
bench_cycles_report() {
    _bcr_cases=$1
    awk -F '\t' -v OFS="$(printf '\t')" '
        BEGIN { print "benchmark", "mode", "reference", "typelisp_cycles", "reference_cycles", "ratio_x" }
        FNR == 1 { next }
        NR == FNR { if ($3 == "typelisp") tl[$1, $2] = $4; next }
        $3 != "typelisp" && ($1, $2) in tl {
            printf "%s\t%s\t%s\t%s\t%s\t%.6f\n", $1, $2, $3, tl[$1, $2], $4, tl[$1, $2] / $4
        }
    ' "$WORKDIR/cycle-summary.tsv" "$WORKDIR/cycle-summary.tsv" > "$WORKDIR/cycle-ratios.tsv"
    awk -F '\t' -v OFS="$(printf '\t')" -v cases="$_bcr_cases" '
        BEGIN {
            n = split(cases, names, ",")
            for (i = 1; i <= n; i++) selected[names[i]] = 1
            print "mode", "reference", "pairs", "geomean_cycles_ratio_x"
        }
        NR > 1 && (cases == "" || $1 in selected) {
            key = $2 SUBSEP $3
            if (!(key in pairs)) order[++groups] = key
            pairs[key]++
            sums[key] += log($4 / $5)
        }
        END {
            for (i = 1; i <= groups; i++) {
                key = order[i]
                split(key, fields, SUBSEP)
                printf "%s\t%s\t%d\t%.6f\n", fields[1], fields[2], pairs[key], exp(sums[key] / pairs[key])
            }
        }
    ' "$WORKDIR/cycle-ratios.tsv" > "$WORKDIR/cycle-geomeans.tsv"
    cat "$WORKDIR/cycle-ratios.tsv"
    cat "$WORKDIR/cycle-geomeans.tsv"
}

bench_cycles_self_test() (
    WORKDIR="$1/cycle-self-test"
    mkdir -p "$WORKDIR"
    _bcst_file="$WORKDIR/sample.stat"
    printf '# perf stat\n1234;;cycles:u;13150;100.00;;\n' > "$_bcst_file"
    [ "$(bench_cycles_parse "$_bcst_file")" = 1234 ] || fail "valid cycle sample rejected"
    for _bcst_row in '<not counted>;;cycles:u;0;0.00;;' '1234;;cycles:u;13150;85.00;;' \
                     '0;;cycles:u;13150;100.00;;' '1234;;instructions:u;13150;100.00;;'; do
        printf '%s\n' "$_bcst_row" > "$_bcst_file"
        if bench_cycles_parse "$_bcst_file"; then fail "invalid cycle sample accepted"; fi
    done
    printf '1234;;cycles:u;13150;100.00;;\n1234;;cycles:u;13150;100.00;;\n' > "$_bcst_file"
    if bench_cycles_parse "$_bcst_file"; then fail "duplicate cycle sample accepted"; fi
    printf '%s\n' 'benchmark	mode	implementation	median_cycles	min_cycles	max_cycles	runs' \
        'kernel	default	typelisp	100	90	110	5' \
        'kernel	default	c-scalar	50	45	55	5' \
        'micro	default	typelisp	100	90	110	5' \
        'micro	default	c-scalar	200	180	220	5' \
        'unsupported	avx2	clang	100	90	110	5' > "$WORKDIR/cycle-summary.tsv"
    bench_cycles_report kernel >/dev/null
    awk -F '\t' '
        NR == 1 && $4 != "geomean_cycles_ratio_x" { exit 1 }
        NR == 2 && $0 != "default\tc-scalar\t1\t2.000000" { exit 1 }
        END { if (NR != 2) exit 1 }
    ' "$WORKDIR/cycle-geomeans.tsv" || fail "cycle geomean used the wrong case set"
    [ "$(wc -l < "$WORKDIR/cycle-ratios.tsv")" -eq 3 ] ||
        fail "cycle ratios included an unsupported pair"
    echo "[bench-cycles] perf stat parser and report self-tests passed"
)
