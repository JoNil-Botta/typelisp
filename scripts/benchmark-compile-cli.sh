#!/usr/bin/env sh
set -eu

# benchmark-compile-cli.sh - benchmark optimized selfhost CLI self-builds.
#
# For each requested optimization level, the script builds stage1 and stage2
# CLIs, measures the real stage2 CLI compiling selfhost/cli.tl into stage3.s,
# and verifies that stage3.s is byte-identical to stage2.s. A profile-enabled
# compile driver then records phase timing and allocator peak-live counters for
# the same opt-level compile pipeline.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

TYPELISP_WINDOWS_LINK_REPRO=${TYPELISP_WINDOWS_LINK_REPRO:-1}
export TYPELISP_WINDOWS_LINK_REPRO

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
. "$ROOT/scripts/lib-stage0.sh"

usage() {
    cat <<'EOF'
usage: scripts/benchmark-compile-cli.sh [typelisp-seed]

Environment:
  TYPELISP_BIN                         Seed compiler when no argument is given.
  TYPELISP_COMPILE_BENCH_OUT           Output root (default target/compile-cli-benchmark).
  TYPELISP_COMPILE_BENCH_OPT_LEVELS    Space- or comma-separated opt levels (default "0 1 2").
  TYPELISP_COMPILE_BENCH_CHECK         Set to 1 to enforce the opt2/opt1 ratio limit.
  TYPELISP_COMPILE_BENCH_RATIO_LIMIT   Integer opt2/opt1 limit for check mode (default 2).
EOF
}

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
    esac
fi

fetch_stage0_compiler "$ROOT" || exit 1

if [ "$#" -eq 1 ]; then
    SEED=$1
elif [ -n "${TYPELISP_BIN:-}" ]; then
    SEED=$TYPELISP_BIN
else
    SEED=$(stage0_compiler_path "$ROOT") || exit 1
fi

if [ ! -x "$SEED" ]; then
    echo "typelisp seed is not executable: $SEED" >&2
    exit 1
fi

WORKDIR=${TYPELISP_COMPILE_BENCH_OUT:-"$ROOT/target/compile-cli-benchmark"}
# We ship three opt levels: 0 (none), 1 (cheap stack-only), 2 (full optimizer +
# scalar register allocation + inlining). Benchmark all three so every shipped
# level keeps its self-compile fixpoint.
OPT_LEVELS=$(printf '%s' "${TYPELISP_COMPILE_BENCH_OPT_LEVELS:-0 1 2}" | tr ',' ' ')
RATIO_LIMIT=${TYPELISP_COMPILE_BENCH_RATIO_LIMIT:-2}

set -- $OPT_LEVELS
if [ "$#" -eq 0 ]; then
    echo "TYPELISP_COMPILE_BENCH_OPT_LEVELS must name at least one opt level" >&2
    exit 2
fi
for candidate do
    case "$candidate" in
        0 | 1 | 2) ;;
        *)
            echo "TYPELISP_COMPILE_BENCH_OPT_LEVELS must contain only 0, 1, or 2" >&2
            exit 2
            ;;
    esac
done

case "$RATIO_LIMIT" in
    "" | *[!0-9]* | 0)
        echo "TYPELISP_COMPILE_BENCH_RATIO_LIMIT must be a positive integer" >&2
        exit 2
        ;;
esac

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
configure_toolchain

TIMINGS="$WORKDIR/timings.tsv"
PROFILE_TSV="$WORKDIR/profile.tsv"
SUMMARY_TSV="$WORKDIR/summary.tsv"
printf 'opt_level\tphase\telapsed_ms\n' > "$TIMINGS"
printf 'opt_level\tphase\telapsed_ms\talloc_delta_bytes\tlive_delta_bytes\tpeak_live_delta_bytes\n' > "$PROFILE_TSV"
printf 'opt_level\tcompile_ms\tprofile_total_ms\tprofile_peak_live_delta_bytes\n' > "$SUMMARY_TSV"

fail() {
    echo "[compile-bench] $*" >&2
    exit 1
}

show_failure_logs() {
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

now_ms() {
    value=$(date +%s%3N 2>/dev/null || true)
    case "$value" in
        *[!0-9]* | "") ;;
        *) printf '%s\n' "$value"; return 0 ;;
    esac
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
}

record_timing() {
    opt_level=$1
    phase=$2
    elapsed=$3
    printf '%s\t%s\t%s\n' "$opt_level" "$phase" "$elapsed" >> "$TIMINGS"
}

sha_files() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@" >&2 || true
    fi
}

strip_if_needed() {
    bin=$1
    if [ "$NL_HOST_OS" = linux ] && command -v strip >/dev/null 2>&1; then
        strip "$bin"
    fi
}

compare_text() {
    label=$1
    left=$2
    right=$3
    echo "[compile-bench] compare $label"
    if ! cmp -s "$left" "$right"; then
        echo "[compile-bench] mismatch: $label" >&2
        sha_files "$left" "$right"
        wc -l "$left" "$right" >&2 || true
        if command -v diff >/dev/null 2>&1; then
            diff -u "$left" "$right" | sed -n '1,200p' >&2 || true
        fi
        exit 1
    fi
}

compile_cli_to_asm() {
    opt_level=$1
    label=$2
    compiler=$3
    asm=$4
    logdir=$5
    stdout="$logdir/$label.stdout"
    stderr="$logdir/$label.stderr"
    echo "[compile-bench] opt$opt_level $label"
    start=$(now_ms)
    if ! run_with_heartbeat "$label" \
        "$compiler" compile selfhost/cli.tl -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root selfhost \
        --opt-level "$opt_level" \
        >"$stdout" 2>"$stderr"; then
        echo "[compile-bench] $label failed" >&2
        show_failure_logs "$stdout" "$stderr"
        exit 1
    fi
    end=$(now_ms)
    record_timing "$opt_level" "$label" "$((end - start))"
    [ -s "$asm" ] || fail "$label did not produce assembly: $asm"
}

measure_step() {
    opt_level=$1
    step_label=$2
    shift 2
    echo "[compile-bench] opt$opt_level $step_label"
    start=$(now_ms)
    if ! "$@"; then
        fail "$step_label failed"
    fi
    end=$(now_ms)
    record_timing "$opt_level" "$step_label" "$((end - start))"
}

measure_compile_cli_to_asm() {
    opt_level=$1
    label=$2
    compiler=$3
    asm=$4
    logdir=$5
    stdout="$logdir/$label.stdout"
    stderr="$logdir/$label.stderr"
    echo "[compile-bench] opt$opt_level measure $label"
    start=$(now_ms)
    if ! run_with_heartbeat "$label" \
        "$compiler" compile selfhost/cli.tl -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root selfhost \
        --opt-level "$opt_level" \
        >"$stdout" 2>"$stderr"; then
        echo "[compile-bench] $label failed" >&2
        show_failure_logs "$stdout" "$stderr"
        exit 1
    fi
    end=$(now_ms)
    LAST_MEASURE_MS=$((end - start))
    record_timing "$opt_level" "$label" "$LAST_MEASURE_MS"
    [ -s "$asm" ] || fail "$label did not produce assembly: $asm"
}

append_profile_rows() {
    opt_level=$1
    stderr=$2
    if ! grep '^compile-profile|' "$stderr" >/dev/null 2>&1; then
        fail "profiled compile did not emit compile-profile rows: $stderr"
    fi
    grep '^compile-profile|' "$stderr" \
        | awk -F'|' -v opt_level="$opt_level" '$2 != "phase" {
              printf "%s\t%s\t%s\t%s\t%s\t%s\n", opt_level, $2, $3, $4, $5, $6
          }' \
        >> "$PROFILE_TSV"
}

profile_total_ms() {
    stderr=$1
    awk -F'|' '$1 == "compile-profile" && $2 == "total" { value = $3 }
        END {
            if (value == "") {
                value = 0
            }
            print value
        }' "$stderr"
}

profile_peak_live_delta() {
    stderr=$1
    awk -F'|' '$1 == "compile-profile" && $2 != "phase" {
            if (($6 + 0) > peak) {
                peak = $6 + 0
            }
        }
        END { printf "%.0f\n", peak + 0 }' "$stderr"
}

run_opt_level() {
    opt_level=$1
    optdir="$WORKDIR/opt$opt_level"
    mkdir -p "$optdir"

    stage1_asm="$optdir/stage1.s"
    stage1_obj="$optdir/stage1.$NL_OBJ_EXT"
    stage1_bin="$optdir/stage1$NL_BIN_EXT"
    stage2_asm="$optdir/stage2.s"
    stage2_obj="$optdir/stage2.$NL_OBJ_EXT"
    stage2_bin="$optdir/stage2$NL_BIN_EXT"
    stage3_asm="$optdir/stage3.s"
    profile_asm="$optdir/compile_profile.s"
    profile_obj="$optdir/compile_profile.$NL_OBJ_EXT"
    profile_bin="$optdir/compile_profile$NL_BIN_EXT"
    profile_cli_asm="$optdir/profile-cli.s"

    compile_cli_to_asm "$opt_level" "seed-to-stage1" "$SEED" "$stage1_asm" "$optdir"
    measure_step "$opt_level" "stage1-link" assemble_and_link "stage1-opt$opt_level" "$stage1_asm" "$stage1_obj" "$stage1_bin"
    strip_if_needed "$stage1_bin"

    compile_cli_to_asm "$opt_level" "stage1-to-stage2" "$stage1_bin" "$stage2_asm" "$optdir"
    measure_step "$opt_level" "stage2-link" assemble_and_link "stage2-opt$opt_level" "$stage2_asm" "$stage2_obj" "$stage2_bin"
    strip_if_needed "$stage2_bin"

    measure_compile_cli_to_asm "$opt_level" "stage2-to-stage3-cli" "$stage2_bin" "$stage3_asm" "$optdir"
    compile_ms=$LAST_MEASURE_MS
    compare_text "opt$opt_level stage2.s vs measured stage3.s" "$stage2_asm" "$stage3_asm"

    echo "[compile-bench] opt$opt_level build profile-enabled compile driver with stage2"
    profile_build_stdout="$optdir/compile_profile-build.stdout"
    profile_build_stderr="$optdir/compile_profile-build.stderr"
    start=$(now_ms)
    if ! run_with_heartbeat "opt$opt_level-profile-compile-driver" \
        "$stage2_bin" compile selfhost/compile.tl -o "$profile_asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root selfhost \
        --opt-level "$opt_level" \
        --cfg compile-profile \
        >"$profile_build_stdout" \
        2>"$profile_build_stderr"; then
        echo "[compile-bench] profile compile driver build failed" >&2
        show_failure_logs "$profile_build_stdout" "$profile_build_stderr"
        exit 1
    fi
    end=$(now_ms)
    record_timing "$opt_level" "profile-driver-build" "$((end - start))"
    [ -s "$profile_asm" ] || fail "profile driver build did not produce assembly: $profile_asm"
    measure_step "$opt_level" "profile-driver-link" assemble_and_link "compile-profile-opt$opt_level" "$profile_asm" "$profile_obj" "$profile_bin"
    strip_if_needed "$profile_bin"

    echo "[compile-bench] opt$opt_level run profiled phase breakdown"
    profile_run_stdout="$optdir/profile-run.stdout"
    profile_run_stderr="$optdir/profile-run.stderr"
    start=$(now_ms)
    if ! "$profile_bin" compile selfhost/cli.tl -o "$profile_cli_asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root selfhost \
        --opt-level "$opt_level" \
        >"$profile_run_stdout" \
        2>"$profile_run_stderr"; then
        echo "[compile-bench] profiled compile failed" >&2
        show_failure_logs "$profile_run_stdout" "$profile_run_stderr"
        exit 1
    fi
    end=$(now_ms)
    record_timing "$opt_level" "profile-run" "$((end - start))"
    append_profile_rows "$opt_level" "$profile_run_stderr"
    compare_text "opt$opt_level profiled cli asm vs measured stage3.s" "$stage3_asm" "$profile_cli_asm"

    profile_total=$(profile_total_ms "$profile_run_stderr")
    profile_peak=$(profile_peak_live_delta "$profile_run_stderr")
    printf '%s\t%s\t%s\t%s\n' "$opt_level" "$compile_ms" "$profile_total" "$profile_peak" >> "$SUMMARY_TSV"
}

summary_value() {
    opt_level=$1
    column=$2
    awk -F'\t' -v opt_level="$opt_level" -v column="$column" '
        NR > 1 && $1 == opt_level {
            print $column
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }' "$SUMMARY_TSV"
}

check_ratio() {
    name=$1
    base=$2
    candidate=$3
    limit=$((base * RATIO_LIMIT))
    if [ "$candidate" -gt "$limit" ]; then
        fail "opt2 (quality) $name $candidate exceeds ${RATIO_LIMIT}x opt1 (cheap) $base"
    fi
    echo "[compile-bench] opt2 (quality) $name $candidate within ${RATIO_LIMIT}x opt1 (cheap) $base"
}

# The headline number: the high-quality (opt2-built, register-allocated) stage2
# compiling cli.tl at the CHEAP level (opt1). A fast binary doing cheap work --
# this is "stage2 compiling stage3" for the goal. Its output must match the
# cheap-built stage2's cheap output (cross-fixpoint), since both run opt1 logic.
run_cross_level() {
    cheap=1
    quality=2
    quality_bin="$WORKDIR/opt$quality/stage2$NL_BIN_EXT"
    cheap_ref="$WORKDIR/opt$cheap/stage3.s"
    if [ ! -x "$quality_bin" ] || [ ! -f "$cheap_ref" ]; then
        echo "[compile-bench] cross-level metric skipped (need opt$cheap and opt$quality builds)" >&2
        return 0
    fi
    crossdir="$WORKDIR/cross"
    mkdir -p "$crossdir"
    main_asm="$crossdir/main.s"
    measure_compile_cli_to_asm "$cheap" "cross-main-metric" "$quality_bin" "$main_asm" "$crossdir"
    CROSS_MAIN_MS=$LAST_MEASURE_MS
    compare_text "cross-fixpoint (opt$quality-built @opt$cheap == opt$cheap stage3)" "$cheap_ref" "$main_asm"
    printf 'cross\t%s\t%s\t%s\n' "$CROSS_MAIN_MS" "" "" >> "$SUMMARY_TSV"
    echo "[compile-bench] ============================================================"
    echo "[compile-bench] MAIN METRIC opt$quality-built stage2 @opt$cheap: ${CROSS_MAIN_MS}ms   <-- goal < 500ms"
    echo "[compile-bench] ============================================================"
}

for opt_level in $OPT_LEVELS; do
    run_opt_level "$opt_level"
done

run_cross_level

if [ "${TYPELISP_COMPILE_BENCH_CHECK:-}" = 1 ]; then
    opt1_compile=$(summary_value 1 2 || true)
    opt2_compile=$(summary_value 2 2 || true)
    opt1_peak=$(summary_value 1 4 || true)
    opt2_peak=$(summary_value 2 4 || true)
    if [ -n "$opt1_compile" ] && [ -n "$opt2_compile" ] && [ -n "$opt1_peak" ] && [ -n "$opt2_peak" ]; then
        check_ratio "compile_ms" "$opt1_compile" "$opt2_compile"
        check_ratio "profile_peak_live_delta_bytes" "$opt1_peak" "$opt2_peak"
    else
        fail "check mode requires opt1 and opt2 summaries"
    fi
fi

echo "[compile-bench] summary: $SUMMARY_TSV"
cat "$SUMMARY_TSV"
echo "[compile-bench] timings: $TIMINGS"
cat "$TIMINGS"
echo "[compile-bench] profile: $PROFILE_TSV"
cat "$PROFILE_TSV"
echo "[compile-bench] artifacts: $WORKDIR"
