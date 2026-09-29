#!/usr/bin/env sh
set -eu

# Opt-in linearity and peak-RSS measurement for the pure .eh_frame codec.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

COMPILER=${TYPELISP_BIN:-}
REPORT=${TYPELISP_EH_FRAME_BENCH_REPORT:-target/eh-frame-benchmark/report.txt}

usage() {
    cat >&2 <<'EOF'
usage: scripts/measure-eh-frame-codec.sh --compiler PATH [--report PATH]

Builds the current-tree codec workload, then measures decode, canonical encode
and search-header encode/decode at 1k, 10k, and 100k FDEs. The report includes
bytes visited, input/output/header bytes, wall time, and peak RSS.
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

[ -n "$COMPILER" ] || { echo "eh-frame benchmark: --compiler is required" >&2; exit 2; }
[ -x "$COMPILER" ] || { echo "eh-frame benchmark: compiler is not executable: $COMPILER" >&2; exit 2; }
WORK="$ROOT/target/eh-frame-benchmark"
RUNNER="$WORK/eh-frame-bench"
mkdir -p "$WORK" "$(dirname -- "$REPORT")"

"$COMPILER" build tools/eh-frame-bench/main.tl \
    -o "$RUNNER" \
    --opt-level 2 \
    --stdlib-root "$ROOT/stdlib" \
    --stdlib-root "$ROOT/src"

: > "$REPORT"
printf 'schema_version=1\n' >> "$REPORT"
printf 'profile=dwarf32-cie1-zR-pcrel-sdata4-x86-64\n' >> "$REPORT"

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
