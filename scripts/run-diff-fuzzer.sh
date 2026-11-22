#!/usr/bin/env sh
set -eu

# run-diff-fuzzer.sh - thin POSIX driver for the self-hosted TypeLisp
# differential fuzzer (tools/diff-fuzzer/main.tl).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT_PATH="$ROOT/scripts/$(basename -- "$0")"

usage() {
    cat >&2 <<'EOF'
usage: scripts/run-diff-fuzzer.sh [options]

Options:
  --seeds N           Number of seeds to run (default: 500)
  --seed-start N      Starting seed integer (default: 1)
  --compiler PATH     Path to typelisp compiler (default: target/stage0/typelisp)
  --jobs N            Parallel worker count (default: auto)
  --verify-ir         Enable --verify-ir checks (default)
  --no-verify-ir      Disable --verify-ir checks
  --out-dir DIR       Disposable output directory (default: target/exp/diff-fuzzer)
  -h, --help          Show this help
EOF
}

detect_jobs() {
    cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    if [ "$cpus" -gt 32 ]; then
        echo 32
    elif [ "$cpus" -lt 1 ]; then
        echo 1
    else
        echo "$cpus"
    fi
}

host_has_avx2() {
    if [ -r /proc/cpuinfo ] && grep -qm1 -w avx2 /proc/cpuinfo 2>/dev/null; then
        return 0
    fi
    return 1
}

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 15s "$@"
    else
        "$@"
    fi
}

# Internal per-seed worker invoked via xargs -P.
if [ "${1:-}" = "--_worker" ]; then
    shift
    COMPILER=$1
    STDLIB_ROOT=$2
    OUT_DIR=$3
    VERIFY_IR=$4
    HAS_AVX2=$5
    SEED=$6
    KIND=$7
    HAS_ARENA=$8
    HAS_SPMD=$9
    SRC=${10}

    WORK="$OUT_DIR/work/seed_$SEED"
    RES="$OUT_DIR/results/seed_$SEED.tsv"
    FAIL_DIR="$OUT_DIR/failures/seed_$SEED"
    mkdir -p "$WORK"

    save_failure() {
        reason=$1
        detail=$2
        mkdir -p "$FAIL_DIR"
        cp "$SRC" "$FAIL_DIR/seed_$SEED.tl"
        for f in "$WORK"/*.out "$WORK"/*.err; do
            [ -f "$f" ] && cp "$f" "$FAIL_DIR/"
        done
        printf 'seed=%s kind=%s arena=%s spmd=%s reason=%s detail=%s\n' \
            "$SEED" "$KIND" "$HAS_ARENA" "$HAS_SPMD" "$reason" "$detail" > "$FAIL_DIR/failure.txt"
        printf '%s\t%s\t%s\t%s\tfail\t%s\t%s\n' \
            "$SEED" "$KIND" "$HAS_ARENA" "$HAS_SPMD" "$reason" "$detail" > "$RES"
        rm -rf "$WORK"
        exit 0
    }

    # 1. Check vs build(opt0) agreement.
    check_rc=0
    "$COMPILER" check "$SRC" --stdlib-root "$STDLIB_ROOT" \
        >"$WORK/check.out" 2>"$WORK/check.err" || check_rc=$?

    build0_rc=0
    "$COMPILER" build "$SRC" --opt-level 0 --backend-mode scalar \
        --stdlib-root "$STDLIB_ROOT" -o "$WORK/bin0" \
        >"$WORK/build0.out" 2>"$WORK/build0.err" || build0_rc=$?

    if [ "$check_rc" -ne 0 ] && [ "$build0_rc" -eq 0 ]; then
        save_failure "check-build-mismatch" "check=$check_rc,build0=0"
    fi
    if [ "$check_rc" -eq 0 ] && [ "$build0_rc" -ne 0 ]; then
        save_failure "check-build-mismatch" "check=0,build0=$build0_rc"
    fi
    if [ "$check_rc" -ne 0 ] && [ "$build0_rc" -ne 0 ]; then
        printf '%s\t%s\t%s\t%s\tinvalid\tcheck-reject\tcheck=%s\n' \
            "$SEED" "$KIND" "$HAS_ARENA" "$HAS_SPMD" "$check_rc" > "$RES"
        rm -rf "$WORK"
        exit 0
    fi

    # 2. Build opt1 and opt2 (fusing --verify-ir compile + native link when enabled).
    if [ "$VERIFY_IR" -eq 1 ]; then
        v0_rc=0
        "$COMPILER" compile "$SRC" --verify-ir --opt-level 0 \
            --backend-mode scalar --stdlib-root "$STDLIB_ROOT" \
            -o "$WORK/v0.s" >"$WORK/v0.out" 2>"$WORK/v0.err" || v0_rc=$?
        if [ "$v0_rc" -ne 0 ]; then
            save_failure "verify-ir-opt0-fail" "rc=$v0_rc"
        fi

        for opt in 1 2; do
            vrc=0
            "$COMPILER" compile "$SRC" --verify-ir --opt-level "$opt" \
                --backend-mode scalar --stdlib-root "$STDLIB_ROOT" \
                -o "$WORK/v${opt}.s" >"$WORK/v${opt}.out" 2>"$WORK/v${opt}.err" || vrc=$?
            if [ "$vrc" -ne 0 ]; then
                save_failure "verify-ir-opt${opt}-fail" "rc=$vrc"
            fi
            lrc=0
            as "$WORK/v${opt}.s" -o "$WORK/v${opt}.o" 2>"$WORK/link${opt}.err" && \
                ld -static -e _tl_start "$WORK/v${opt}.o" -o "$WORK/bin${opt}" 2>>"$WORK/link${opt}.err" || lrc=$?
            if [ "$lrc" -ne 0 ]; then
                save_failure "build-opt${opt}-fail" "link-rc=$lrc"
            fi
        done
    else
        for opt in 1 2; do
            brc=0
            "$COMPILER" build "$SRC" --opt-level "$opt" --backend-mode scalar \
                --stdlib-root "$STDLIB_ROOT" -o "$WORK/bin${opt}" \
                >"$WORK/build${opt}.out" 2>"$WORK/build${opt}.err" || brc=$?
            if [ "$brc" -ne 0 ]; then
                save_failure "build-opt${opt}-fail" "rc=$brc"
            fi
        done
    fi

    # 3. Run opt0, opt1, opt2 and verify no crash + exact exit/stdout parity.
    rc0=0
    run_with_timeout "$WORK/bin0" >"$WORK/run0.out" 2>"$WORK/run0.err" || rc0=$?
    rc1=0
    run_with_timeout "$WORK/bin1" >"$WORK/run1.out" 2>"$WORK/run1.err" || rc1=$?
    rc2=0
    run_with_timeout "$WORK/bin2" >"$WORK/run2.out" 2>"$WORK/run2.err" || rc2=$?

    if [ "$rc0" -ge 128 ] || [ "$rc1" -ge 128 ] || [ "$rc2" -ge 128 ]; then
        if [ "$HAS_ARENA" -eq 1 ]; then
            save_failure "arena-poison-crash" "rc0=$rc0,rc1=$rc1,rc2=$rc2"
        fi
        save_failure "runtime-crash" "rc0=$rc0,rc1=$rc1,rc2=$rc2"
    fi

    if [ "$rc0" -ne "$rc1" ] || [ "$rc0" -ne "$rc2" ] || \
       ! cmp -s "$WORK/run0.out" "$WORK/run1.out" || \
       ! cmp -s "$WORK/run0.out" "$WORK/run2.out"; then
        save_failure "opt-parity-mismatch" "rc0=$rc0,rc1=$rc1,rc2=$rc2"
    fi

    # 4. SPMD scalar vs avx2 parity (on SPMD seeds when host has AVX2).
    if [ "$HAS_SPMD" -eq 1 ] && [ "$HAS_AVX2" -eq 1 ]; then
        if [ "$VERIFY_IR" -eq 1 ]; then
            v_avx_rc=0
            "$COMPILER" compile "$SRC" --verify-ir --opt-level 2 \
                --backend-mode avx2 --stdlib-root "$STDLIB_ROOT" \
                -o "$WORK/v_avx2.s" >"$WORK/v_avx2.out" 2>"$WORK/v_avx2.err" || v_avx_rc=$?
            if [ "$v_avx_rc" -ne 0 ]; then
                save_failure "verify-ir-avx2-fail" "rc=$v_avx_rc"
            fi
            l_avx_rc=0
            as "$WORK/v_avx2.s" -o "$WORK/v_avx2.o" 2>"$WORK/link_avx2.err" && \
                ld -static -e _tl_start "$WORK/v_avx2.o" -o "$WORK/bin_avx2" 2>>"$WORK/link_avx2.err" || l_avx_rc=$?
            if [ "$l_avx_rc" -ne 0 ]; then
                save_failure "build-avx2-fail" "link-rc=$l_avx_rc"
            fi
        else
            b_avx_rc=0
            "$COMPILER" build "$SRC" --opt-level 2 --backend-mode avx2 \
                --stdlib-root "$STDLIB_ROOT" -o "$WORK/bin_avx2" \
                >"$WORK/build_avx2.out" 2>"$WORK/build_avx2.err" || b_avx_rc=$?
            if [ "$b_avx_rc" -ne 0 ]; then
                save_failure "build-avx2-fail" "rc=$b_avx_rc"
            fi
        fi
        rc_avx=0
        run_with_timeout "$WORK/bin_avx2" >"$WORK/run_avx2.out" 2>"$WORK/run_avx2.err" || rc_avx=$?
        if [ "$rc_avx" -ge 128 ]; then
            save_failure "spmd-avx2-crash" "rc_avx2=$rc_avx"
        fi
        if [ "$rc_avx" -ne "$rc2" ] || ! cmp -s "$WORK/run2.out" "$WORK/run_avx2.out"; then
            save_failure "spmd-scalar-avx2-mismatch" "scalar=$rc2,avx2=$rc_avx"
        fi
    fi

    printf '%s\t%s\t%s\t%s\tpass\tok\trc=%s\n' \
        "$SEED" "$KIND" "$HAS_ARENA" "$HAS_SPMD" "$rc0" > "$RES"
    rm -rf "$WORK"
    exit 0
fi

SEEDS=500
SEED_START=1
COMPILER=${TYPELISP_BIN:-"$ROOT/target/stage0/typelisp"}
JOBS=$(detect_jobs)
VERIFY_IR=1
OUT_DIR="$ROOT/target/exp/diff-fuzzer"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --seeds)
            SEEDS=${2:?missing value for --seeds}
            shift 2
            ;;
        --seed-start)
            SEED_START=${2:?missing value for --seed-start}
            shift 2
            ;;
        --compiler)
            COMPILER=${2:?missing value for --compiler}
            shift 2
            ;;
        --jobs)
            JOBS=${2:?missing value for --jobs}
            shift 2
            ;;
        --verify-ir)
            VERIFY_IR=1
            shift
            ;;
        --no-verify-ir)
            VERIFY_IR=0
            shift
            ;;
        --out-dir)
            OUT_DIR=${2:?missing value for --out-dir}
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "diff-fuzzer: unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

case "$SEEDS" in '' | 0 | *[!0-9]*) echo "diff-fuzzer: --seeds must be a positive integer" >&2; exit 2 ;; esac
case "$SEED_START" in '' | *[!0-9]*) echo "diff-fuzzer: --seed-start must be a non-negative integer" >&2; exit 2 ;; esac
case "$JOBS" in '' | 0 | *[!0-9]*) echo "diff-fuzzer: --jobs must be a positive integer" >&2; exit 2 ;; esac

case "$COMPILER" in
    /*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "diff-fuzzer: compiler not executable: $COMPILER" >&2
    exit 1
fi

HAS_AVX2=0
if host_has_avx2; then
    HAS_AVX2=1
fi

START_TS=$(date +%s)

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/cases" "$OUT_DIR/work" "$OUT_DIR/results" "$OUT_DIR/failures"

GEN_BIN="$OUT_DIR/diff-fuzzer-gen"
"$COMPILER" build "$ROOT/tools/diff-fuzzer/main.tl" \
    --opt-level 1 \
    --stdlib-root "$ROOT/stdlib" \
    -o "$GEN_BIN"

"$GEN_BIN" --batch "$SEED_START" "$SEEDS" "$OUT_DIR/cases"

xargs -P "$JOBS" -n 5 sh "$SCRIPT_PATH" --_worker \
    "$COMPILER" "$ROOT/stdlib" "$OUT_DIR" "$VERIFY_IR" "$HAS_AVX2" \
    < "$OUT_DIR/cases/manifest.tsv"

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

SUMMARY="$OUT_DIR/summary.tsv"
find "$OUT_DIR/results" -type f -name 'seed_*.tsv' | LC_ALL=C sort | xargs cat > "$SUMMARY"

awk -F '\t' -v elapsed="$ELAPSED" -v verify_ir="$VERIFY_IR" -v has_avx2="$HAS_AVX2" \
    -v compiler="$COMPILER" -v out_dir="$OUT_DIR" '
BEGIN {
    total = 0; pass = 0; invalid = 0; fail = 0;
    arena_total = 0; spmd_total = 0;
}
{
    total++
    status = $5
    reason = $6
    if ($3 == "1") arena_total++
    if ($4 == "1") spmd_total++
    if (status == "pass") pass++
    else if (status == "invalid") invalid++
    else {
        fail++
        reasons[reason]++
        if (fail <= 20) {
            fail_samples[fail] = "seed=" $1 " kind=" $2 " reason=" reason " (" $7 ")"
        }
    }
}
END {
    valid = pass + fail
    valid_pct = (total > 0) ? (100.0 * valid / total) : 0.0
    invalid_pct = (total > 0) ? (100.0 * invalid / total) : 0.0
    printf "diff-fuzzer: compiler=%s verify-ir=%d avx2=%d elapsed=%ds\n", compiler, verify_ir, has_avx2, elapsed
    printf "diff-fuzzer: total=%d valid=%d (%.2f%%) invalid=%d (%.2f%%) pass=%d fail=%d\n",
        total, valid, valid_pct, invalid, invalid_pct, pass, fail
    printf "diff-fuzzer: arena-seeds=%d spmd-seeds=%d\n", arena_total, spmd_total
    if (fail > 0) {
        printf "diff-fuzzer: failure-breakdown:\n"
        for (r in reasons) {
            printf "  - %s: %d\n", r, reasons[r]
        }
        printf "diff-fuzzer: sample-failures (repros in %s/failures/):\n", out_dir
        limit = (fail < 20) ? fail : 20
        for (i = 1; i <= limit; i++) {
            printf "  * %s\n", fail_samples[i]
        }
    }
    if (invalid_pct >= 5.0) {
        printf "diff-fuzzer: FAIL invalid-seed rate %.2f%% >= 5.00%%\n", invalid_pct
        exit 1
    }
    if (fail > 0) {
        exit 1
    }
}
' "$SUMMARY"
