#!/usr/bin/env sh
set -eu

# Deterministic one-vs-five compact vector compile-cost measurement.
#
# This is a diagnostic harness, not a baseline gate. It measures one compiler
# binary compiling fixed fixtures under Cachegrind, then builds a
# compile-profile variant of that compiler and reports matching phase/counter
# deltas. It never rewrites perf/insn-exec-baseline.tsv.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

RUNS=${TYPELISP_VECTOR_COST_RUNS:-1}
WORKDIR=${TYPELISP_VECTOR_COST_OUT:-target/vector-instantiation-cost}
OPT_LEVEL=${TYPELISP_VECTOR_COST_OPT_LEVEL:-1}
COMPILER_ARG=

usage() {
    cat <<'EOF'
usage: scripts/measure-vector-instantiation-cost.sh [options] [typelisp-compiler]

Options:
  --runs N       Cachegrind runs per fixture (default: 1)
  --output DIR   Output under target/ (default: target/vector-instantiation-cost)
  --opt-level N  Fixture compile opt level: 0, 1, or 2 (default: 1)
  -h, --help     Show this help

Environment:
  TYPELISP_BIN                    Compiler when no positional path is supplied
  TYPELISP_VECTOR_COST_RUNS       Default --runs
  TYPELISP_VECTOR_COST_OUT        Default --output
  TYPELISP_VECTOR_COST_OPT_LEVEL  Default --opt-level
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --runs)
            [ "$#" -ge 2 ] || { echo "missing value for --runs" >&2; exit 2; }
            RUNS=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { echo "missing value for --output" >&2; exit 2; }
            WORKDIR=$2
            shift 2
            ;;
        --opt-level)
            [ "$#" -ge 2 ] || { echo "missing value for --opt-level" >&2; exit 2; }
            OPT_LEVEL=$2
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
            [ -z "$COMPILER_ARG" ] || {
                echo "only one typelisp compiler may be provided" >&2
                exit 2
            }
            COMPILER_ARG=$1
            shift
            ;;
    esac
done

case "$RUNS" in
    "" | *[!0-9]* | 0) echo "--runs must be a positive integer: $RUNS" >&2; exit 2 ;;
esac
case "$OPT_LEVEL" in
    0 | 1 | 2) ;;
    *) echo "--opt-level must be 0, 1, or 2: $OPT_LEVEL" >&2; exit 2 ;;
esac
case "$WORKDIR" in
    "" | / | . | ..) echo "unsafe --output path: $WORKDIR" >&2; exit 2 ;;
esac
case "$(uname -s)" in
    Linux*) ;;
    *) echo "vector instantiation Cachegrind measurement is Linux-only" >&2; exit 1 ;;
esac
TARGET_ROOT=$(realpath -m -- "$ROOT/target")
WORKDIR=$(realpath -m -- "$WORKDIR")
case "$WORKDIR" in
    "$TARGET_ROOT"/?*) ;;
    *)
        echo "--output must resolve inside $TARGET_ROOT: $WORKDIR" >&2
        exit 2
        ;;
esac
command -v valgrind >/dev/null 2>&1 || {
    echo "valgrind is required for vector instantiation measurement" >&2
    exit 1
}

fail() {
    echo "[vector-cost] $*" >&2
    exit 1
}

show_logs() {
    _stdout=$1
    _stderr=$2
    [ ! -s "$_stdout" ] || { echo "stdout:" >&2; sed 's/^/  /' "$_stdout" >&2; }
    [ ! -s "$_stderr" ] || { echo "stderr:" >&2; sed 's/^/  /' "$_stderr" >&2; }
}

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

if [ -n "$COMPILER_ARG" ]; then
    COMPILER=$COMPILER_ARG
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
case "$COMPILER" in
    /*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || fail "compiler is not executable: $COMPILER"

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/logs" "$WORKDIR/profile"

ONE_FIXTURE=tests/integration/compile_profile_vector_one_core.tl
FIVE_FIXTURE=tests/integration/compile_profile_vector_five_core.tl
VALGRIND=$(command -v valgrind)

compile_args() {
    _fixture=$1
    _asm=$2
    printf '%s\n' \
        compile "$_fixture" \
        -o "$_asm" \
        --target "$NL_BOOTSTRAP_TARGET"
    native_target_cfg_args
    printf '%s\n' \
        --stdlib-root . \
        --stdlib-root stdlib \
        --opt-level "$OPT_LEVEL"
}

cachegrind_ir() {
    awk '
        /^events:/ {
            ir_col = 0
            for (i = 2; i <= NF; i++) {
                if ($i == "Ir") ir_col = i - 1
            }
        }
        /^summary:/ && ir_col > 0 {
            value = $(ir_col + 1)
            gsub(/,/, "", value)
            print value
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$1"
}

run_cachegrind_case() {
    _name=$1
    _fixture=$2
    _run=$3
    _asm="$WORKDIR/$_name.opt$OPT_LEVEL.s"
    _cgout="$WORKDIR/logs/$_name-$_run.cachegrind.out"
    _stdout="$WORKDIR/logs/$_name-$_run.stdout"
    _stderr="$WORKDIR/logs/$_name-$_run.stderr"

    echo "[vector-cost] cachegrind $_name run $_run"
    set +e
    env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C "$VALGRIND" \
        --quiet --tool=cachegrind --cachegrind-out-file="$_cgout" \
        "$COMPILER" $(compile_args "$_fixture" "$_asm") \
        > "$_stdout" 2> "$_stderr"
    _status=$?
    set -e
    if [ "$_status" -ne 0 ]; then
        show_logs "$_stdout" "$_stderr"
        fail "$_name run $_run exited $_status"
    fi
    [ -s "$_asm" ] || fail "$_name run $_run did not emit assembly"
    [ -s "$_cgout" ] || fail "$_name run $_run did not emit Cachegrind data"
    LAST_IR=$(cachegrind_ir "$_cgout") ||
        fail "could not parse Cachegrind Ir for $_name run $_run"
    case "$LAST_IR" in
        "" | *[!0-9]*) fail "non-numeric Ir for $_name run $_run: $LAST_IR" ;;
    esac
}

measure_case() {
    _name=$1
    _fixture=$2
    _run=1
    _first=
    _min=
    _max=
    while [ "$_run" -le "$RUNS" ]; do
        run_cachegrind_case "$_name" "$_fixture" "$_run"
        if [ -z "$_first" ]; then
            _first=$LAST_IR
            _min=$LAST_IR
            _max=$LAST_IR
        else
            [ "$LAST_IR" -ge "$_min" ] || _min=$LAST_IR
            [ "$LAST_IR" -le "$_max" ] || _max=$LAST_IR
        fi
        _run=$((_run + 1))
    done
    [ "$_min" = "$_max" ] ||
        fail "$_name Ir was unstable across $RUNS runs: min=$_min max=$_max"
    LAST_CASE_IR=$_first
}

signed() {
    if [ "$1" -gt 0 ]; then printf '+%s' "$1"; else printf '%s' "$1"; fi
}

measure_case one "$ONE_FIXTURE"
ONE_IR=$LAST_CASE_IR
measure_case five "$FIVE_FIXTURE"
FIVE_IR=$LAST_CASE_IR
IR_DELTA=$((FIVE_IR - ONE_IR))
{
    printf 'case\tir_count\tdelta_from_one\n'
    printf 'one\t%s\t0\n' "$ONE_IR"
    printf 'five\t%s\t%s\n' "$FIVE_IR" "$(signed "$IR_DELTA")"
} > "$WORKDIR/instruction-summary.tsv"

PROFILE_ASM="$WORKDIR/profile/typelisp-profile.s"
PROFILE_OBJ="$WORKDIR/profile/typelisp-profile.$NL_OBJ_EXT"
PROFILE_BIN="$WORKDIR/profile/typelisp-profile$NL_BIN_EXT"
PROFILE_BUILD_STDOUT="$WORKDIR/profile/build.stdout"
PROFILE_BUILD_STDERR="$WORKDIR/profile/build.stderr"

echo "[vector-cost] build compile-profile compiler"
if ! "$COMPILER" compile src/main.tl \
    -o "$PROFILE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --opt-level "$OPT_LEVEL" \
    --cfg compile-profile \
    > "$PROFILE_BUILD_STDOUT" 2> "$PROFILE_BUILD_STDERR"; then
    show_logs "$PROFILE_BUILD_STDOUT" "$PROFILE_BUILD_STDERR"
    fail "compile-profile compiler build failed"
fi
if ! assemble_and_link vector-instantiation-profile \
    "$PROFILE_ASM" "$PROFILE_OBJ" "$PROFILE_BIN" \
    >> "$PROFILE_BUILD_STDOUT" 2>> "$PROFILE_BUILD_STDERR"; then
    show_logs "$PROFILE_BUILD_STDOUT" "$PROFILE_BUILD_STDERR"
    fail "compile-profile compiler link failed"
fi

run_profile_case() {
    _name=$1
    _fixture=$2
    _asm="$WORKDIR/profile/$_name.s"
    _stdout="$WORKDIR/profile/$_name.stdout"
    _stderr="$WORKDIR/profile/$_name.stderr"
    echo "[vector-cost] profile $_name"
    if ! "$PROFILE_BIN" $(compile_args "$_fixture" "$_asm") \
        > "$_stdout" 2> "$_stderr"; then
        show_logs "$_stdout" "$_stderr"
        fail "compile-profile fixture failed: $_name"
    fi
    grep '^compile-profile|' "$_stderr" > "$WORKDIR/profile/$_name.tsv" ||
        fail "compile-profile fixture emitted no rows: $_name"
}

run_profile_case one "$ONE_FIXTURE"
run_profile_case five "$FIVE_FIXTURE"

profile_value() {
    _file=$1
    _phase=$2
    _column=$3
    awk -F'|' -v phase="$_phase" -v column="$_column" '
        $1 == "compile-profile" && $2 == phase {
            print $column + 0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$_file"
}

append_metric() {
    _kind=$1
    _phase=$2
    _column=$3
    if ! _one=`profile_value \
        "$WORKDIR/profile/one.tsv" "$_phase" "$_column"`; then
        fail "missing one profile row: $_phase"
    fi
    if ! _five=`profile_value \
        "$WORKDIR/profile/five.tsv" "$_phase" "$_column"`; then
        fail "missing five profile row: $_phase"
    fi
    _delta=$((_five - _one))
    _signed_delta=`signed "$_delta"`
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$_kind" "$_phase" "$_one" "$_five" "$_signed_delta" \
        >> "$WORKDIR/profile-summary.tsv"
}

printf 'kind\tmetric\tone\tfive\tdelta\n' > "$WORKDIR/profile-summary.tsv"
for phase in \
    lower.macro_expand \
    lower.specialize \
    lower.prune \
    lower.typecheck \
    lower.prune_apply \
    lower.decls \
    lower \
    optimize \
    backend \
    total; do
    append_metric elapsed_ms "$phase" 3
    append_metric alloc_bytes "$phase" 4
done
for counter in \
    typecheck.macro.generated_module_materializations \
    typecheck.macro.generated_module_memo_hits \
    typecheck.macro.generated_decl_checks; do
    append_metric counter "$counter" 3
done
for counter in \
    lower.checked_program.pre_decls.decls \
    lower.checked_program.pre_decls.functions \
    lower.checked_program.reachable.decls \
    lower.checked_program.reachable.functions \
    lower.ir.after_decls.functions \
    lower.ir.after_decls.blocks \
    lower.ir.after_decls.instructions; do
    append_metric counter "$counter" 5
done

echo "[vector-cost] instruction summary: $WORKDIR/instruction-summary.tsv"
cat "$WORKDIR/instruction-summary.tsv"
echo "[vector-cost] profile summary: $WORKDIR/profile-summary.tsv"
cat "$WORKDIR/profile-summary.tsv"
