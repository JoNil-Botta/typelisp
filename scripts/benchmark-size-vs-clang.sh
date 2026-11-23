#!/usr/bin/env sh
set -eu

# benchmark-size-vs-clang.sh - the size lane's reference instrument.
#
# For every benchmarks/<name>/ pair holding bench.tl and baseline.c, build the
# TypeLisp side with `build --opt-level LEVEL` (default 2) and the C side with
# clang at -Os and -O2, using the compile-lane flags -std=c11 -DNDEBUG. Read
# each unstripped binary's .text, user .text (the FUNC symbols in .text minus
# the runtime's own entry and startup helpers), .rodata and .data sizes, strip
# all three binaries, write their byte sizes, section sizes and TypeLisp/clang
# ratios to target/size-vs-clang/results.tsv, then print the geomean ratios, the
# sums and the five largest -Os ratios for the stripped bytes and each section.
# A pair whose build or strip fails is skipped with a note on stderr; the script
# is a local measurement, not a CI gate. clang links glibc dynamically and
# TypeLisp links statically with its own runtime, so each ratio includes that
# fixed runtime floor (about 14 KB for clang, 17 KB for TypeLisp on an empty
# program).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat <<'EOF'
usage: scripts/benchmark-size-vs-clang.sh [options] [typelisp-compiler]

Options:
  --opt-level LEVEL  TypeLisp optimizer level: 0, 1 or 2 (default 2)
  --only NAME        Measure only benchmarks/NAME
  -h, --help         Show this help

Environment:
  TYPELISP_SIZE_VS_CLANG_OUT    Output root (default target/size-vs-clang)
  TYPELISP_SIZE_VS_CLANG_STRIP  Strip tool (default strip, then llvm-strip)
EOF
}

COMPILER=
ONLY=
OPT_LEVEL=2
while [ "$#" -gt 0 ]; do
    case "$1" in
        --opt-level)
            [ "$#" -ge 2 ] || {
                echo "missing value for --opt-level" >&2
                exit 2
            }
            OPT_LEVEL=$2
            shift 2
            ;;
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
case "$OPT_LEVEL" in
    0 | 1 | 2) ;;
    *)
        echo "invalid --opt-level: $OPT_LEVEL (expected 0, 1 or 2)" >&2
        exit 2
        ;;
esac
TL_LABEL="tl-opt$OPT_LEVEL"

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

READELF=
if command -v readelf >/dev/null 2>&1; then
    READELF=readelf
elif command -v llvm-readelf >/dev/null 2>&1; then
    READELF=llvm-readelf
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
printf 'name\ttl_bytes\tclang_os_bytes\tclang_o2_bytes\tratio_os\tratio_o2\ttl_text\ttl_user_text\ttl_rodata\ttl_data\tclang_os_text\tclang_os_user_text\tclang_os_rodata\tclang_os_data\tclang_o2_text\tclang_o2_user_text\tclang_o2_rodata\tclang_o2_data\ttext_ratio_os\ttext_ratio_o2\tuser_text_ratio_os\tuser_text_ratio_o2\trodata_ratio_os\trodata_ratio_o2\tdata_ratio_os\tdata_ratio_o2\n' > "$RESULTS"

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

# elf_metrics BIN KIND
#   Print BIN's .text, user .text, .rodata and .data sizes as four tab-separated
#   decimal numbers. KIND is tl or c and selects the runtime helpers left out of
#   user .text: TypeLisp's tl_*/__tl_* runtime, _tl_start, _tl_stdlib_* and
#   _tl___global_init_stdlib_*, and C's crt entry, clone and destructor helpers.
#   User .text sums the FUNC symbols in the .text section once per distinct
#   address and size, so aliases do not count twice. A host without an ELF
#   reader, or a binary that is not ELF, reports zeros and the derived ratios
#   print n/a.
elf_metrics() {
    if [ -z "$READELF" ]; then
        printf '0\t0\t0\t0\n'
        return 0
    fi
    case "$2" in
        tl)
            _em_exclude='^(tl_.*|__tl_.*|_tl_start|_tl_stdlib_.*|_tl___global_init_stdlib_.*)$'
            ;;
        c)
            _em_exclude='^(_start|_dl_relocate_static_pie|deregister_tm_clones|register_tm_clones|__do_global_dtors_aux|frame_dummy|__libc_csu_init|__libc_csu_fini)$'
            ;;
    esac
    {
        echo '@sections'
        "$READELF" -SW "$1" 2>/dev/null || true
        echo '@symbols'
        "$READELF" -sW "$1" 2>/dev/null || true
    } | awk -v exclude="$_em_exclude" '
        function decimal(value, text, i) {
            text = tolower(value)
            sub(/^0[xX]/, "", text)
            value = 0
            for (i = 1; i <= length(text); i++) {
                value = (value * 16) + index("0123456789abcdef", substr(text, i, 1)) - 1
            }
            return value
        }
        $0 == "@sections" { part = "sections"; next }
        $0 == "@symbols" { part = "symbols"; next }
        part == "sections" && /^[ \t]*\[[ \t]*[0-9]+\]/ {
            if ($1 == "[") {
                section = $2
                sub(/\]$/, "", section)
                name = $3
                size = $7
            } else {
                section = $1
                gsub(/[^0-9]/, "", section)
                name = $2
                size = $6
            }
            if (name == ".text" && !have_text) {
                text_section = section + 0
                text = decimal(size)
                have_text = 1
            } else if (name == ".rodata") {
                rodata = decimal(size)
            } else if (name == ".data") {
                data = decimal(size)
            }
            next
        }
        part == "symbols" && have_text && $4 == "FUNC" && $7 == text_section {
            alias = $2 ":" $3
            if (alias in seen) next
            seen[alias] = 1
            name = $8
            sub(/@.*/, "", name)
            if (name ~ exclude) next
            user += $3
        }
        END { printf "%d\t%d\t%d\t%d\n", text + 0, user + 0, rodata + 0, data + 0 }
    '
}

# ratio A B
#   Print A/B, or n/a when B is zero.
ratio() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (b == 0) {
            printf "n/a"
            exit
        }
        printf "%.6f", a / b
    }'
}

# geomean_ratio COLUMN
#   Print the geometric mean of COLUMN over the measured rows, or n/a when no
#   row holds a positive number.
geomean_ratio() {
    awk -F '\t' -v column="$1" '
        NR > 1 && $column + 0 > 0 {
            total += log($column)
            rows++
        }
        END {
            if (rows == 0) {
                printf "n/a"
                exit
            }
            printf "%.2fx", exp(total / rows)
        }' "$RESULTS"
}

# sum_column COLUMN
#   Print the total of COLUMN over the measured rows.
sum_column() {
    awk -F '\t' -v column="$1" 'NR > 1 { total += $column } END { printf "%.0f", total + 0 }' "$RESULTS"
}

# worst_ratios COLUMN
#   Print the five largest entries of COLUMN as "name X.XXx, ...".
worst_ratios() {
    awk -F '\t' -v column="$1" 'NR > 1 && $column != "n/a" { printf "%.6f\t%s\n", $column, $1 }' "$RESULTS" |
        LC_ALL=C sort -rn -k1,1 |
        head -n 5 |
        awk -F '\t' '{
            if (NR > 1) {
                printf ", "
            }
            printf "%s %.2fx", $2, $1
        }'
}

# headline_metric LABEL RATIO_OS RATIO_O2 TL_COLUMN OS_COLUMN O2_COLUMN
#   Print one headline line: the geomean TL/clang ratios, the TL and clang sums
#   and the five largest -Os ratios for the metric held in those columns.
headline_metric() {
    _hm_worst=$(worst_ratios "$2")
    printf '[size-vs-clang] headline: %s TL/clang opt%s:-Os %s, opt%s:-O2 %s; sums TL %s B, clang -Os %s B, clang -O2 %s B; worst -Os: %s\n' \
        "$1" "$OPT_LEVEL" "$(geomean_ratio "$2")" "$OPT_LEVEL" "$(geomean_ratio "$3")" \
        "$(sum_column "$4")" "$(sum_column "$5")" "$(sum_column "$6")" \
        "${_hm_worst:-n/a}"
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
    TL_BIN="$BUILDDIR/$name.$TL_LABEL$EXE"
    CLANG_OS_BIN="$BUILDDIR/$name.clang-Os$EXE"
    CLANG_O2_BIN="$BUILDDIR/$name.clang-O2$EXE"
    # Host target knobs are intentionally simple space-separated flags.
    # shellcheck disable=SC2086
    if build_binary "$TL_LABEL" "$TL_BIN" "$LOGDIR/$name.$TL_LABEL" \
        "$COMPILER" build "$case_dir/bench.tl" --opt-level "$OPT_LEVEL" -o "$TL_BIN" $TL_TARGET_ARGS &&
        build_binary clang-Os "$CLANG_OS_BIN" "$LOGDIR/$name.clang-Os" \
            clang -Os -std=c11 -DNDEBUG "$case_dir/baseline.c" -o "$CLANG_OS_BIN" &&
        build_binary clang-O2 "$CLANG_O2_BIN" "$LOGDIR/$name.clang-O2" \
            clang -O2 -std=c11 -DNDEBUG "$case_dir/baseline.c" -o "$CLANG_O2_BIN" &&
        TL_METRICS=$(elf_metrics "$TL_BIN" tl) &&
        CLANG_OS_METRICS=$(elf_metrics "$CLANG_OS_BIN" c) &&
        CLANG_O2_METRICS=$(elf_metrics "$CLANG_O2_BIN" c) &&
        strip_binary "$TL_LABEL" "$TL_BIN" "$LOGDIR/$name.$TL_LABEL.strip" &&
        strip_binary clang-Os "$CLANG_OS_BIN" "$LOGDIR/$name.clang-Os.strip" &&
        strip_binary clang-O2 "$CLANG_O2_BIN" "$LOGDIR/$name.clang-O2.strip"
    then
        TL_BYTES=$(file_bytes "$TL_BIN")
        CLANG_OS_BYTES=$(file_bytes "$CLANG_OS_BIN")
        CLANG_O2_BYTES=$(file_bytes "$CLANG_O2_BIN")
        # Each metrics line holds four tab-separated numbers.
        # shellcheck disable=SC2086
        set -- $TL_METRICS
        TL_TEXT=$1 TL_USER_TEXT=$2 TL_RODATA=$3 TL_DATA=$4
        # shellcheck disable=SC2086
        set -- $CLANG_OS_METRICS
        CLANG_OS_TEXT=$1 CLANG_OS_USER_TEXT=$2 CLANG_OS_RODATA=$3 CLANG_OS_DATA=$4
        # shellcheck disable=SC2086
        set -- $CLANG_O2_METRICS
        CLANG_O2_TEXT=$1 CLANG_O2_USER_TEXT=$2 CLANG_O2_RODATA=$3 CLANG_O2_DATA=$4
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" \
            "$TL_BYTES" "$CLANG_OS_BYTES" "$CLANG_O2_BYTES" \
            "$(ratio "$TL_BYTES" "$CLANG_OS_BYTES")" \
            "$(ratio "$TL_BYTES" "$CLANG_O2_BYTES")" \
            "$TL_TEXT" "$TL_USER_TEXT" "$TL_RODATA" "$TL_DATA" \
            "$CLANG_OS_TEXT" "$CLANG_OS_USER_TEXT" "$CLANG_OS_RODATA" "$CLANG_OS_DATA" \
            "$CLANG_O2_TEXT" "$CLANG_O2_USER_TEXT" "$CLANG_O2_RODATA" "$CLANG_O2_DATA" \
            "$(ratio "$TL_TEXT" "$CLANG_OS_TEXT")" \
            "$(ratio "$TL_TEXT" "$CLANG_O2_TEXT")" \
            "$(ratio "$TL_USER_TEXT" "$CLANG_OS_USER_TEXT")" \
            "$(ratio "$TL_USER_TEXT" "$CLANG_O2_USER_TEXT")" \
            "$(ratio "$TL_RODATA" "$CLANG_OS_RODATA")" \
            "$(ratio "$TL_RODATA" "$CLANG_O2_RODATA")" \
            "$(ratio "$TL_DATA" "$CLANG_OS_DATA")" \
            "$(ratio "$TL_DATA" "$CLANG_O2_DATA")" >> "$RESULTS"
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
headline_metric 'binary bytes' 5 6 2 3 4
headline_metric '.text' 19 20 7 11 15
headline_metric 'user .text' 21 22 8 12 16
headline_metric '.rodata' 23 24 9 13 17
headline_metric '.data' 25 26 10 14 18
echo "[size-vs-clang] results: $RESULTS"
