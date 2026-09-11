#!/usr/bin/env sh
set -eu

# Opt-in linearity and peak-RSS measurement for the pure SFrame v3 codec.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

COMPILER=${TYPELISP_BIN:-}
REPORT=${TYPELISP_SFRAME_V3_BENCH_REPORT:-target/sframe-v3-benchmark/report.txt}

usage() {
    cat >&2 <<'EOF'
usage: scripts/measure-sframe-v3-codec.sh --compiler PATH [--report PATH]

Builds the current-tree codec workload, then measures decode/normalize/encode
at 1k, 10k, and 100k functions. The report includes bytes visited, modeled
codec-owned allocations/bytes, output bytes, wall time, and peak RSS.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --compiler)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            COMPILER=$2
            shift 2
            ;;
        --report)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            REPORT=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

[ -n "$COMPILER" ] || { echo "sframe-v3 benchmark: --compiler is required" >&2; exit 2; }
[ -x "$COMPILER" ] || { echo "sframe-v3 benchmark: compiler is not executable: $COMPILER" >&2; exit 2; }
WORK="$ROOT/target/sframe-v3-benchmark"
RUNNER="$WORK/sframe-v3-bench"
mkdir -p "$WORK" "$(dirname -- "$REPORT")"

"$COMPILER" build tools/sframe-v3-bench/main.tl \
    -o "$RUNNER" \
    --opt-level 2 \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src"

: > "$REPORT"
printf 'schema_version=1\n' >> "$REPORT"
printf 'dialect=gnu-sframe-v3-binutils-2.47-amd64-le-v1\n' >> "$REPORT"

run_case() {
    count=$1
    shift
    stdout="$WORK/$count.stdout"
    bounded="$WORK/$count.bounded.kv"
    scripts/run-memory-bounded.sh \
        --limit-mib 1024 \
        --timeout-seconds 120 \
        --report "$bounded" \
        -- "$RUNNER" "$@" > "$stdout"
    printf '\ncase=%s\n' "$count" >> "$REPORT"
    cat "$stdout" >> "$REPORT"
    sed -n 's/^wall_ms=/wall_ms=/p' "$bounded" >> "$REPORT"
    sed -n 's/^peak_memory_bytes=/peak_rss_bytes=/p' "$bounded" >> "$REPORT"
}

run_case 1000
run_case 10000 x
run_case 100000 x x

cat "$REPORT"
