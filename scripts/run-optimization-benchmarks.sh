#!/usr/bin/env sh
set -eu

# run-optimization-benchmarks.sh - local optimizer progress benchmarks.
#
# The harness compares paired TypeLisp and C programs from
# benchmarks/optimization/cases.tsv. It is intentionally a local Linux tool,
# not a correctness CI gate.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "optimization benchmarks are Linux-only (requires clang, as, and ld)"
        exit 0
        ;;
esac

RUNS=${TYPELISP_BENCH_RUNS:-3}
CLANG_OPT=${TYPELISP_BENCH_CLANG_OPT:--O3}
USE_SELFHOST=${TYPELISP_BENCH_SELFHOST:-1}
FILTER=

usage() {
    cat <<'EOF'
usage: scripts/run-optimization-benchmarks.sh [options]

Options:
  --runs N          Runtime repetitions per case (default: TYPELISP_BENCH_RUNS or 3)
  --filter NAME    Run manifest cases whose names match NAME or start with NAME
  --clang-opt OPT  clang optimization flag (default: TYPELISP_BENCH_CLANG_OPT or -O3)
  --selfhost       Compile TypeLisp cases through selfhost/compiler_driver.tl (default)
  --rust-stage0    Compile TypeLisp cases through typelisp compile
  -h, --help       Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --runs)
            [ "$#" -ge 2 ] || {
                echo "missing value for --runs" >&2
                exit 1
            }
            RUNS=$2
            shift 2
            ;;
        --filter)
            [ "$#" -ge 2 ] || {
                echo "missing value for --filter" >&2
                exit 1
            }
            FILTER=$2
            shift 2
            ;;
        --clang-opt)
            [ "$#" -ge 2 ] || {
                echo "missing value for --clang-opt" >&2
                exit 1
            }
            CLANG_OPT=$2
            shift 2
            ;;
        --selfhost)
            USE_SELFHOST=1
            shift
            ;;
        --rust-stage0)
            USE_SELFHOST=0
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$RUNS" in
    "" | *[!0-9]*)
        echo "--runs must be a positive integer: $RUNS" >&2
        exit 1
        ;;
    0)
        echo "--runs must be greater than zero" >&2
        exit 1
        ;;
esac

case "$CLANG_OPT" in
    -O0 | -O1 | -O2 | -O3 | -Os | -Oz | -Og) ;;
    *)
        echo "--clang-opt must be a single clang optimization flag: $CLANG_OPT" >&2
        exit 1
        ;;
esac

case "$USE_SELFHOST" in
    0 | 1) ;;
    *)
        echo "TYPELISP_BENCH_SELFHOST must be 0 or 1: $USE_SELFHOST" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # No-Rust fallback for local development: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

for _tool in as ld clang awk wc date; do
    command -v "$_tool" >/dev/null 2>&1 || {
        echo "missing tool: $_tool" >&2
        exit 1
    }
done

_date_probe=$(date +%s%N)
case "$_date_probe" in
    *N* | "" | *[!0-9]*)
        echo "date +%s%N must return nanoseconds on this host" >&2
        exit 1
        ;;
esac

MANIFEST="$ROOT/benchmarks/optimization/cases.tsv"
WORKDIR="$ROOT/target/optimization-bench"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

now_ns() {
    date +%s%N
}

elapsed_ms() {
    _start=$1
    _end=$2
    printf '%s\n' $(((_end - _start + 999999) / 1000000))
}

file_bytes() {
    wc -c < "$1" | tr -d '[:space:]'
}

instruction_count() {
    awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\./ { next }
        /^[[:space:]]*[A-Za-z_.$][A-Za-z0-9_.$]*:/ { next }
        /^[[:space:]]*[A-Za-z]/ { count++ }
        END { print count + 0 }
    ' "$1"
}

run_capture() {
    _bin=$1
    _stdout=$2
    _stderr=$3
    shift 3

    set +e
    _start=$(now_ns)
    "$_bin" "$@" > "$_stdout" 2> "$_stderr"
    _status=$?
    _end=$(now_ns)
    set -e

    if [ "$_status" -ne 0 ]; then
        echo "FAIL: $_bin exited $_status" >&2
        if [ -s "$_stdout" ]; then sed 's/^/  stdout: /' "$_stdout" >&2; fi
        if [ -s "$_stderr" ]; then sed 's/^/  stderr: /' "$_stderr" >&2; fi
        exit 1
    fi
    if [ -s "$_stderr" ]; then
        echo "FAIL: $_bin wrote stderr" >&2
        sed 's/^/  stderr: /' "$_stderr" >&2
        exit 1
    fi

    RUN_MS=$(elapsed_ms "$_start" "$_end")
}

best_runtime_ms() {
    _bin=$1
    _label=$2
    shift 2
    _best=
    _i=1
    while [ "$_i" -le "$RUNS" ]; do
        run_capture "$_bin" "$WORKDIR/$_label.run.$_i.stdout" "$WORKDIR/$_label.run.$_i.stderr" "$@"
        if [ -z "$_best" ] || [ "$RUN_MS" -lt "$_best" ]; then
            _best=$RUN_MS
        fi
        _i=$((_i + 1))
    done
    BEST_MS=$_best
}

compile_tl_stage0() {
    _src=$1
    _asm=$2
    _out=$3
    _err=$4

    set +e
    _start=$(now_ns)
    "$COMPILER" compile "$_src" -o "$_asm" > "$_out" 2> "$_err"
    _status=$?
    _end=$(now_ns)
    set -e

    if [ "$_status" -ne 0 ]; then
        echo "FAIL: typelisp compile exited $_status for $_src" >&2
        if [ -s "$_out" ]; then sed 's/^/  stdout: /' "$_out" >&2; fi
        if [ -s "$_err" ]; then sed 's/^/  stderr: /' "$_err" >&2; fi
        exit 1
    fi

    TL_COMPILE_MS=$(elapsed_ms "$_start" "$_end")
}

compile_tl_selfhost() {
    _driver=$1
    _src=$2
    _asm=$3
    _out=$4
    _err=$5

    set +e
    _start=$(now_ns)
    "$_driver" "$_src" "$_asm" > "$_out" 2> "$_err"
    _status=$?
    _end=$(now_ns)
    set -e

    if [ "$_status" -ne 0 ]; then
        echo "FAIL: selfhost compiler driver exited $_status for $_src" >&2
        if [ -s "$_out" ]; then sed 's/^/  stdout: /' "$_out" >&2; fi
        if [ -s "$_err" ]; then sed 's/^/  stderr: /' "$_err" >&2; fi
        exit 1
    fi
    if [ -s "$_out" ] || [ -s "$_err" ]; then
        echo "FAIL: selfhost compiler driver wrote unexpected output for $_src" >&2
        if [ -s "$_out" ]; then sed 's/^/  stdout: /' "$_out" >&2; fi
        if [ -s "$_err" ]; then sed 's/^/  stderr: /' "$_err" >&2; fi
        exit 1
    fi

    TL_COMPILE_MS=$(elapsed_ms "$_start" "$_end")
}

compile_c() {
    _src=$1
    _bin=$2
    _asm=$3
    _out=$4
    _err=$5

    set +e
    _start=$(now_ns)
    clang "$CLANG_OPT" -std=c11 -DNDEBUG "$_src" -o "$_bin" > "$_out" 2> "$_err"
    _status=$?
    _end=$(now_ns)
    set -e

    if [ "$_status" -ne 0 ]; then
        echo "FAIL: clang exited $_status for $_src" >&2
        if [ -s "$_out" ]; then sed 's/^/  stdout: /' "$_out" >&2; fi
        if [ -s "$_err" ]; then sed 's/^/  stderr: /' "$_err" >&2; fi
        exit 1
    fi

    C_COMPILE_MS=$(elapsed_ms "$_start" "$_end")

    clang "$CLANG_OPT" -std=c11 -DNDEBUG -S "$_src" -o "$_asm"
}

SELFHOST_DRIVER=
if [ "$USE_SELFHOST" -eq 1 ]; then
    SELFHOST_DRIVER="$WORKDIR/compiler_driver"
    echo "# building selfhost compiler driver: $SELFHOST_DRIVER" >&2
    "$COMPILER" build selfhost/compiler_driver.tl -o "$SELFHOST_DRIVER"
    [ -x "$SELFHOST_DRIVER" ] || fail "compiler_driver build did not write executable"
fi

printf 'case,category,tl_ms,c_ms,ratio,tl_compile_ms,c_compile_ms,tl_exe_bytes,c_exe_bytes,tl_asm_bytes,c_asm_bytes,tl_insns,c_insns\n'

matched=0
while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
        "" | \#*) continue ;;
    esac

    _fields=$(printf '%s\n' "$_line" | awk -F'|' '{ print NF }')
    [ "$_fields" -eq 3 ] || fail "manifest line must have 3 fields: $_line"

    IFS='|' read -r _name _category _args <<EOF
$_line
EOF

    case "$_name" in
        "" | *[!A-Za-z0-9_]*)
            fail "invalid case name: $_name"
            ;;
    esac
    case "$_category" in
        "" | *[!A-Za-z0-9_-]*)
            fail "invalid category for $_name: $_category"
            ;;
    esac
    if [ -n "$FILTER" ]; then
        case "$_name" in
            "$FILTER" | "$FILTER"*) ;;
            *) continue ;;
        esac
    fi

    matched=$((matched + 1))
    _tl_src="$ROOT/benchmarks/optimization/tl/$_name.tl"
    _c_src="$ROOT/benchmarks/optimization/c/$_name.c"
    [ -f "$_tl_src" ] || fail "missing TypeLisp benchmark: $_tl_src"
    [ -f "$_c_src" ] || fail "missing C benchmark: $_c_src"

    _tl_asm="$WORKDIR/$_name.tl.s"
    _tl_obj="$WORKDIR/$_name.tl.o"
    _tl_bin="$WORKDIR/$_name.tl"
    _c_asm="$WORKDIR/$_name.c.s"
    _c_bin="$WORKDIR/$_name.c"

    if [ "$USE_SELFHOST" -eq 1 ]; then
        compile_tl_selfhost "$SELFHOST_DRIVER" "$_tl_src" "$_tl_asm" "$WORKDIR/$_name.tl.compile.stdout" "$WORKDIR/$_name.tl.compile.stderr"
    else
        compile_tl_stage0 "$_tl_src" "$_tl_asm" "$WORKDIR/$_name.tl.compile.stdout" "$WORKDIR/$_name.tl.compile.stderr"
    fi
    as "$_tl_asm" -o "$_tl_obj"
    ld "$_tl_obj" -o "$_tl_bin"

    compile_c "$_c_src" "$_c_bin" "$_c_asm" "$WORKDIR/$_name.c.compile.stdout" "$WORKDIR/$_name.c.compile.stderr"

    # Manifest args are intentionally simple space-separated benchmark knobs.
    # shellcheck disable=SC2086
    run_capture "$_tl_bin" "$WORKDIR/$_name.tl.once.stdout" "$WORKDIR/$_name.tl.once.stderr" $_args
    # shellcheck disable=SC2086
    run_capture "$_c_bin" "$WORKDIR/$_name.c.once.stdout" "$WORKDIR/$_name.c.once.stderr" $_args
    if ! cmp -s "$WORKDIR/$_name.tl.once.stdout" "$WORKDIR/$_name.c.once.stdout"; then
        echo "FAIL: output mismatch for $_name" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$WORKDIR/$_name.c.once.stdout" "$WORKDIR/$_name.tl.once.stdout" >&2 || true
        fi
        exit 1
    fi

    # shellcheck disable=SC2086
    best_runtime_ms "$_tl_bin" "$_name.tl" $_args
    _tl_ms=$BEST_MS
    # shellcheck disable=SC2086
    best_runtime_ms "$_c_bin" "$_name.c" $_args
    _c_ms=$BEST_MS

    _ratio=$(awk -v tl="$_tl_ms" -v c="$_c_ms" 'BEGIN { if (c <= 0) { printf "inf" } else { printf "%.3f", tl / c } }')
    _tl_exe_bytes=$(file_bytes "$_tl_bin")
    _c_exe_bytes=$(file_bytes "$_c_bin")
    _tl_asm_bytes=$(file_bytes "$_tl_asm")
    _c_asm_bytes=$(file_bytes "$_c_asm")
    _tl_insns=$(instruction_count "$_tl_asm")
    _c_insns=$(instruction_count "$_c_asm")

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$_name" \
        "$_category" \
        "$_tl_ms" \
        "$_c_ms" \
        "$_ratio" \
        "$TL_COMPILE_MS" \
        "$C_COMPILE_MS" \
        "$_tl_exe_bytes" \
        "$_c_exe_bytes" \
        "$_tl_asm_bytes" \
        "$_c_asm_bytes" \
        "$_tl_insns" \
        "$_c_insns"
done < "$MANIFEST"

if [ "$matched" -eq 0 ]; then
    fail "no benchmark cases matched filter: $FILTER"
fi
