#!/usr/bin/env sh
set -eu

# benchmark-size-vs-clang.sh - the size lane's reference instrument.
#
# For every benchmarks/<name>/ pair holding bench.tl and baseline.c, build the
# TypeLisp side with `build --opt-level 2` and the C side with clang at -Os and
# -O2, using the compile-lane flags -std=c11 -DNDEBUG. Strip all three binaries,
# write their byte sizes and TypeLisp/clang ratios to
# target/size-vs-clang/results.tsv, then print the geomean ratios for opt2:-Os
# and opt2:-O2 plus the five largest -Os ratios. A pair whose build or strip
# fails is skipped with a note on stderr; the script is a local measurement, not
# a CI gate.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat <<'EOF'
usage: scripts/benchmark-size-vs-clang.sh [options] [typelisp-compiler]

Options:
  --only NAME     Measure only benchmarks/NAME
  -h, --help      Show this help

Environment:
  TYPELISP_SIZE_VS_CLANG_OUT    Output root (default target/size-vs-clang)
  TYPELISP_SIZE_VS_CLANG_STRIP  Strip tool (default strip, then llvm-strip)
EOF
}

COMPILER=
ONLY=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --only)
            [ "$#" -ge 2 ] || {
                echo "missing value for --only" >&2
                exit 2
            }
            ONLY=$2
            shift 2
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
            [ -z "$COMPILER" ] || {
                echo "unexpected argument: $1" >&2
                usage >&2
                exit 2
            }
            COMPILER=$1
            shift
            ;;
    esac
done

if [ -z "$COMPILER" ]; then
    COMPILER=target/stage0/typelisp
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    echo "fetch the published seed with scripts/fetch-stage0.sh" >&2
    exit 1
fi

case "$ONLY" in
    "") ;;
    *[!A-Za-z0-9_.-]*)
        echo "invalid --only name: $ONLY" >&2
        exit 2
        ;;
esac

EXE=
TL_TARGET_ARGS=
case "$(uname -s)" in
    Linux*) ;;
    MINGW* | MSYS* | CYGWIN*)
        EXE=.exe
        TL_TARGET_ARGS="--target windows-x86_64"
        ;;
    *)
        echo "size-vs-clang benchmarks are unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

command -v clang >/dev/null 2>&1 || {
    echo "missing tool: clang" >&2
    exit 1
}

STRIP=${TYPELISP_SIZE_VS_CLANG_STRIP:-}
if [ -n "$STRIP" ]; then
    command -v "$STRIP" >/dev/null 2>&1 || {
        echo "strip tool is not executable: $STRIP" >&2
        exit 1
    }
elif command -v strip >/dev/null 2>&1; then
    STRIP=strip
elif command -v llvm-strip >/dev/null 2>&1; then
    STRIP=llvm-strip
else
    echo "missing tool: strip or llvm-strip" >&2
    echo "install GNU binutils or LLVM, or set TYPELISP_SIZE_VS_CLANG_STRIP" >&2
    exit 1
fi

if [ -n "$ONLY" ]; then
    if [ ! -f "$ROOT/benchmarks/$ONLY/bench.tl" ] || [ ! -f "$ROOT/benchmarks/$ONLY/baseline.c" ]; then
        echo "no benchmark pair for --only $ONLY" >&2
        echo "need benchmarks/$ONLY/bench.tl and benchmarks/$ONLY/baseline.c" >&2
        exit 2
    fi
fi

WORKDIR=${TYPELISP_SIZE_VS_CLANG_OUT:-"$ROOT/target/size-vs-clang"}
RESULTS="$WORKDIR/results.tsv"
BUILDDIR="$WORKDIR/build"
LOGDIR="$WORKDIR/log"
rm -rf "$WORKDIR"
mkdir -p "$BUILDDIR" "$LOGDIR"
printf 'name\ttl_bytes\tclang_os_bytes\tclang_o2_bytes\tratio_os\tratio_o2\n' > "$RESULTS"

first_log_line() {
    awk 'NF { print substr($0, 1, 300); exit }' "$1" 2>/dev/null || true
}

# build_binary LABEL BIN STEM COMMAND...
#   Run COMMAND with its logs on STEM and require BIN to exist. Sets
#   SKIP_REASON and fails on an error.
build_binary() {
    _bb_label=$1
    _bb_bin=$2
    _bb_stem=$3
    shift 3
    set +e
    "$@" >"$_bb_stem.stdout" 2>"$_bb_stem.stderr"
    _bb_status=$?
    set -e
    if [ "$_bb_status" -ne 0 ]; then
        _bb_reason=$(first_log_line "$_bb_stem.stderr")
        [ -n "$_bb_reason" ] || _bb_reason=$(first_log_line "$_bb_stem.stdout")
        if [ -n "$_bb_reason" ]; then
            SKIP_REASON="$_bb_label: build exited $_bb_status: $_bb_reason"
        else
            SKIP_REASON="$_bb_label: build exited $_bb_status"
        fi
        return 1
    fi
    if [ ! -f "$_bb_bin" ]; then
        SKIP_REASON="$_bb_label: build wrote no executable at $_bb_bin"
        return 1
    fi
}

# strip_binary LABEL BIN STEM
#   Strip BIN, keeping the tool's output on STEM, or set SKIP_REASON and fail.
strip_binary() {
    _sb_label=$1
    _sb_bin=$2
    _sb_stem=$3
    set +e
    "$STRIP" "$_sb_bin" >"$_sb_stem.stdout" 2>"$_sb_stem.stderr"
    _sb_status=$?
    set -e
    if [ "$_sb_status" -ne 0 ]; then
        _sb_reason=$(first_log_line "$_sb_stem.stderr")
        if [ -n "$_sb_reason" ]; then
            SKIP_REASON="$_sb_label: strip exited $_sb_status: $_sb_reason"
        else
            SKIP_REASON="$_sb_label: strip exited $_sb_status"
        fi
        return 1
    fi
}

# file_bytes BIN
#   Print BIN's size in bytes.
file_bytes() {
    wc -c < "$1" | tr -d '[:space:]'
}

# ratio A B
#   Print A/B.
ratio() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6f", a / b }'
}

# geomean_ratio COLUMN
#   Print the geometric mean of COLUMN over the measured rows.
geomean_ratio() {
    awk -F '\t' -v column="$1" '
        NR > 1 {
            total += log($column)
            rows++
        }
        END {
            if (rows == 0) {
                printf "n/a"
                exit
            }
            printf "%.2f", exp(total / rows)
        }' "$RESULTS"
}

# worst_ratios
#   Print the five largest TypeLisp/clang -Os ratios as "name X.XXx, ...".
worst_ratios() {
    awk -F '\t' 'NR > 1 { printf "%.6f\t%s\n", $5, $1 }' "$RESULTS" |
        LC_ALL=C sort -rn -k1,1 |
        head -n 5 |
        awk -F '\t' '{
            if (NR > 1) {
                printf ", "
            }
            printf "%s %.2fx", $2, $1
        }'
}

measured=0
skipped=0
for case_dir in "$ROOT"/benchmarks/*/; do
    [ -f "$case_dir/bench.tl" ] || continue
    [ -f "$case_dir/baseline.c" ] || continue
    name=$(basename -- "$case_dir")
    if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then
        continue
    fi
    echo "[size-vs-clang] $name"
    TL_BIN="$BUILDDIR/$name.tl-opt2$EXE"
    CLANG_OS_BIN="$BUILDDIR/$name.clang-Os$EXE"
    CLANG_O2_BIN="$BUILDDIR/$name.clang-O2$EXE"
    # Host target knobs are intentionally simple space-separated flags.
    # shellcheck disable=SC2086
    if build_binary tl-opt2 "$TL_BIN" "$LOGDIR/$name.tl-opt2" \
        "$COMPILER" build "$case_dir/bench.tl" --opt-level 2 -o "$TL_BIN" $TL_TARGET_ARGS &&
        build_binary clang-Os "$CLANG_OS_BIN" "$LOGDIR/$name.clang-Os" \
            clang -Os -std=c11 -DNDEBUG "$case_dir/baseline.c" -o "$CLANG_OS_BIN" &&
        build_binary clang-O2 "$CLANG_O2_BIN" "$LOGDIR/$name.clang-O2" \
            clang -O2 -std=c11 -DNDEBUG "$case_dir/baseline.c" -o "$CLANG_O2_BIN" &&
        strip_binary tl-opt2 "$TL_BIN" "$LOGDIR/$name.tl-opt2.strip" &&
        strip_binary clang-Os "$CLANG_OS_BIN" "$LOGDIR/$name.clang-Os.strip" &&
        strip_binary clang-O2 "$CLANG_O2_BIN" "$LOGDIR/$name.clang-O2.strip"
    then
        TL_BYTES=$(file_bytes "$TL_BIN")
        CLANG_OS_BYTES=$(file_bytes "$CLANG_OS_BIN")
        CLANG_O2_BYTES=$(file_bytes "$CLANG_O2_BIN")
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" \
            "$TL_BYTES" "$CLANG_OS_BYTES" "$CLANG_O2_BYTES" \
            "$(ratio "$TL_BYTES" "$CLANG_OS_BYTES")" \
            "$(ratio "$TL_BYTES" "$CLANG_O2_BYTES")" >> "$RESULTS"
        measured=$((measured + 1))
    else
        echo "[size-vs-clang] skip $name: $SKIP_REASON" >&2
        skipped=$((skipped + 1))
    fi
done

if [ "$measured" -eq 0 ]; then
    echo "no benchmark pair could be built (skipped $skipped); see the notes above" >&2
    exit 1
fi

printf '[size-vs-clang] %s pairs measured, %s skipped\n' "$measured" "$skipped"
printf '[size-vs-clang] headline: binary bytes TL/clang opt2:-Os %sx, opt2:-O2 %sx; worst -Os: %s\n' \
    "$(geomean_ratio 5)" \
    "$(geomean_ratio 6)" \
    "$(worst_ratios)"
echo "[size-vs-clang] results: $RESULTS"
