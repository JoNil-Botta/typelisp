#!/usr/bin/env sh
set -eu

# run-rustc-oracle.sh - optional dev-only differential borrow/ownership oracle
# comparing `typelisp check` against local `rustc --crate-type lib`.
#
# Never a build dependency: skips cleanly with exit 0 when `rustc` is absent.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT_PATH="$ROOT/scripts/$(basename -- "$0")"

usage() {
    cat >&2 <<'EOF'
usage: scripts/run-rustc-oracle.sh [options]

Options:
  --seeds N           Number of paired seeds to run (default: 100)
  --seed-start N      Starting seed integer (default: 1)
  --compiler PATH     Path to typelisp compiler (default: target/stage0/typelisp)
  --jobs N            Parallel worker count (default: auto)
  --out-dir DIR       Disposable output directory (default: target/exp/rustc-oracle)
  -h, --help          Show this help
EOF
}

detect_jobs() {
    cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    if [ "$cpus" -gt 16 ]; then
        echo 16
    elif [ "$cpus" -lt 1 ]; then
        echo 1
    else
        echo "$cpus"
    fi
}

# Internal per-seed worker invoked via xargs -P.
if [ "${1:-}" = "--_worker" ]; then
    shift
    COMPILER=$1
    STDLIB_ROOT=$2
    OUT_DIR=$3
    SEED=$4
    CATEGORY=$5
    EXPECTED=$6
    TL_SRC=$7
    RS_SRC=$8

    WORK="$OUT_DIR/work/case_$SEED"
    RES="$OUT_DIR/results/case_$SEED.tsv"
    mkdir -p "$WORK"

    tl_rc=0
    "$COMPILER" check "$TL_SRC" --stdlib-root "$STDLIB_ROOT" \
        >"$WORK/tl.out" 2>"$WORK/tl.err" || tl_rc=$?

    rs_rc=0
    rustc --crate-type lib --edition 2021 -A warnings --emit=metadata \
        --crate-name "oracle_case_$SEED" -o "$WORK/case_$SEED.rmeta" "$RS_SRC" \
        >"$WORK/rs.out" 2>"$WORK/rs.err" || rs_rc=$?

    tl_v="reject"
    [ "$tl_rc" -eq 0 ] && tl_v="accept"
    rs_v="reject"
    [ "$rs_rc" -eq 0 ] && rs_v="accept"

    agree=0
    if [ "$tl_v" = "$rs_v" ]; then
        agree=1
    else
        DIS_DIR="$OUT_DIR/disagreements/case_$SEED"
        mkdir -p "$DIS_DIR"
        cp "$TL_SRC" "$DIS_DIR/"
        cp "$RS_SRC" "$DIS_DIR/"
        cp "$WORK/tl.err" "$DIS_DIR/"
        cp "$WORK/rs.err" "$DIS_DIR/"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$SEED" "$CATEGORY" "$EXPECTED" "$tl_v" "$rs_v" "$agree" > "$RES"
    rm -rf "$WORK"
    exit 0
fi

SEEDS=100
SEED_START=1
COMPILER=${TYPELISP_BIN:-"$ROOT/target/stage0/typelisp"}
JOBS=$(detect_jobs)
OUT_DIR="$ROOT/target/exp/rustc-oracle"

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
        --out-dir)
            OUT_DIR=${2:?missing value for --out-dir}
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "rustc-oracle: unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

case "$SEEDS" in '' | 0 | *[!0-9]*) echo "rustc-oracle: --seeds must be a positive integer" >&2; exit 2 ;; esac
case "$SEED_START" in '' | *[!0-9]*) echo "rustc-oracle: --seed-start must be a non-negative integer" >&2; exit 2 ;; esac
case "$JOBS" in '' | 0 | *[!0-9]*) echo "rustc-oracle: --jobs must be a positive integer" >&2; exit 2 ;; esac

if ! command -v rustc >/dev/null 2>&1; then
    echo "rustc-oracle: rustc not found in PATH; skipping cleanly"
    exit 0
fi

case "$COMPILER" in
    /*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "rustc-oracle: compiler not executable: $COMPILER" >&2
    exit 1
fi

RUSTC_VER=$(rustc --version)
START_TS=$(date +%s)

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/cases" "$OUT_DIR/work" "$OUT_DIR/results" "$OUT_DIR/disagreements"

GEN_BIN="$OUT_DIR/rustc-oracle-gen"
"$COMPILER" build "$ROOT/tools/diff-fuzzer/rustc_oracle.tl" \
    --opt-level 1 \
    --stdlib-root "$ROOT/stdlib" \
    -o "$GEN_BIN"

"$GEN_BIN" --batch "$SEED_START" "$SEEDS" "$OUT_DIR/cases"

xargs -P "$JOBS" -n 5 sh "$SCRIPT_PATH" --_worker \
    "$COMPILER" "$ROOT/stdlib" "$OUT_DIR" \
    < "$OUT_DIR/cases/manifest.tsv"

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

SUMMARY="$OUT_DIR/summary.tsv"
find "$OUT_DIR/results" -type f -name 'case_*.tsv' | LC_ALL=C sort | xargs cat > "$SUMMARY"

awk -F '\t' -v elapsed="$ELAPSED" -v rustc_ver="$RUSTC_VER" \
    -v compiler="$COMPILER" -v out_dir="$OUT_DIR" '
BEGIN {
    total = 0; agreed = 0;
    both_accept = 0; both_reject = 0;
    tl_only = 0; rs_only = 0;
}
{
    total++
    cat = $2
    tl = $4
    rs = $5
    ag = $6
    cat_total[cat]++
    if (ag == "1") {
        agreed++
        cat_agree[cat]++
    }
    if (tl == "accept" && rs == "accept") both_accept++
    else if (tl == "reject" && rs == "reject") both_reject++
    else if (tl == "accept" && rs == "reject") {
        tl_only++
        if (tl_only + rs_only <= 20) {
            samples[tl_only + rs_only] = "seed=" $1 " cat=" cat " tl=" tl " rs=" rs
        }
    } else {
        rs_only++
        if (tl_only + rs_only <= 20) {
            samples[tl_only + rs_only] = "seed=" $1 " cat=" cat " tl=" tl " rs=" rs
        }
    }
}
END {
    rate = (total > 0) ? (100.0 * agreed / total) : 0.0
    printf "rustc-oracle: compiler=%s rustc=\"%s\" elapsed=%ds\n", compiler, rustc_ver, elapsed
    printf "rustc-oracle: total=%d agreed=%d (%.2f%%) both-accept=%d both-reject=%d tl-accept-rs-reject=%d tl-reject-rs-accept=%d\n",
        total, agreed, rate, both_accept, both_reject, tl_only, rs_only
    for (c in cat_total) {
        printf "  - %-20s %d/%d agreed\n", c, cat_agree[c] + 0, cat_total[c]
    }
    dis = tl_only + rs_only
    if (dis > 0) {
        printf "rustc-oracle: disagreements saved in %s/disagreements/:\n", out_dir
        limit = (dis < 20) ? dis : 20
        for (i = 1; i <= limit; i++) {
            printf "  * %s\n", samples[i]
        }
    }
}
' "$SUMMARY"
