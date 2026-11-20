#!/usr/bin/env sh
set -eu

# verify-addr-taken-matrix.sh - adversarial matrix for the address-taken-local
# rule (#8190): every program of tests/addr-taken-matrix/ compiles and runs at
# --opt-level 0, 1 and 2.
#
# A local whose address is taken is memory, not a value: a store or call
# through the exposed address redefines it without naming it, so no pass may
# forward a fact about it (docs/compiler-invariants.md, "Address-taken
# locals"). Each program here reproduces one optimizer shape and declares its
# own result in a header comment:
#
#   ;; Expected exit 42 at --opt-level 0, 1 and 2.
#
# The gate compiles the program three times, assembles and links each result
# with as/ld (scripts/lib-native-link.sh), runs it with no arguments, and fails
# when the three exit codes differ or differ from the declared expected exit.
# Programs take no arguments, so io.arg-count is 1.
#
# The programs are independent, so they run in parallel:
# TYPELISP_ADDR_TAKEN_MATRIX_JOBS (default 4) workers, one program at a time.
#
# tests/addr-taken-matrix/pending/ holds the programs whose levels still
# disagree. Their fixes land in separate changes and each moves its own files
# out of pending/; this gate skips that directory.
#
# usage: scripts/verify-addr-taken-matrix.sh
#        scripts/verify-addr-taken-matrix.sh --job FILE   (internal worker)

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

GATE_FAIL_PREFIX='[addr-taken-matrix] '
. "$ROOT/scripts/lib-gate.sh"
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

FIXTURE_DIR=$ROOT/tests/addr-taken-matrix
WORKDIR=$ROOT/target/addr-taken-matrix
JOBS=${TYPELISP_ADDR_TAKEN_MATRIX_JOBS:-4}
# Far above the slowest program's runtime, so a miscompile that stops
# terminating fails its own row instead of the whole CI job.
RUN_DEADLINE_SECONDS=10

# declared_exit FILE
#   Print the program's expected exit: the first `expected exit <N>` of its
#   leading `;;` comment block. A declaration in body prose never counts, and a
#   program without one fails instead of silently passing.
declared_exit() {
    awk '
        !/^;;/ { exit }
        match(tolower($0), /expected exit [0-9]+/) {
            value = substr($0, RSTART, RLENGTH)
            sub(/.* /, "", value)
            print value
            exit
        }
    ' "$1"
}

# run_program FILE
#   One worker: build FILE at opt0/1/2 and record its row. The three codes are
#   recorded even when they disagree, so the summary names them; only a failed
#   compile, link or missing declaration stops this worker.
run_program() {
    _source=$1
    _name=$(basename -- "$_source" .tl)
    _expected=$(declared_exit "$_source")
    [ -n "$_expected" ] || fail "$_source: no 'expected exit <N>' header comment"
    _codes=
    for _level in 0 1 2; do
        _asm=$WORKDIR/work/$_name.opt$_level.s
        _obj=$WORKDIR/work/$_name.opt$_level.$OBJ_EXT
        _bin=$WORKDIR/work/$_name.opt$_level$BIN_EXT
        _log=$WORKDIR/work/$_name.opt$_level.log
        if ! "$COMPILER" compile "$_source" -o "$_asm" \
            --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
            --opt-level "$_level" > "$_log" 2>&1; then
            tail -n 5 "$_log" 2>/dev/null | sed 's/^/  /' >&2 || true
            fail "$_source: opt$_level compile failed (log: $_log)"
        fi
        if ! assemble_and_link "$_name.opt$_level" "$_asm" "$_obj" "$_bin" \
            >> "$_log" 2>&1; then
            tail -n 5 "$_log" 2>/dev/null | sed 's/^/  /' >&2 || true
            fail "$_source: opt$_level assemble/link failed (log: $_log)"
        fi
        _code=0
        timeout -s KILL "$RUN_DEADLINE_SECONDS" "$_bin" \
            > "$_log.run" 2>&1 || _code=$?
        [ "$_code" -ne 137 ] ||
            fail "$_source: opt$_level did not finish within ${RUN_DEADLINE_SECONDS}s"
        _codes=$_codes"	$_code"
    done
    printf '%s\t%s%s\n' "$_name" "$_expected" "$_codes" \
        > "$WORKDIR/rows/$_name.tsv"
}

if [ "${1:-}" = --job ]; then
    [ "$#" -eq 2 ] || { echo "usage: $0 --job FILE" >&2; exit 2; }
    configure_toolchain
    gate_compiler
    gate_compiler_absolute
    gate_require_compiler
    run_program "$2"
    exit 0
fi
[ "$#" -eq 0 ] || { sed -n '/^# usage:/,/^$/p' "$0" >&2; exit 2; }

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "[addr-taken-matrix] native matrix needs as + ld: Linux only"
        exit 0
        ;;
esac
case "$JOBS" in
    '' | *[!0-9]*)
        echo "TYPELISP_ADDR_TAKEN_MATRIX_JOBS must be an integer from 1 to 16: $JOBS" >&2
        exit 2
        ;;
esac
if [ "$JOBS" -lt 1 ] || [ "$JOBS" -gt 16 ]; then
    echo "TYPELISP_ADDR_TAKEN_MATRIX_JOBS must be an integer from 1 to 16: $JOBS" >&2
    exit 2
fi
for _tool in as ld timeout; do
    command -v "$_tool" >/dev/null 2>&1 || fail "missing tool: $_tool"
done

gate_compiler
gate_compiler_absolute
gate_require_compiler

# Enumerate once: an empty directory must fail rather than pass trivially.
set -- "$FIXTURE_DIR"/*.tl
[ -f "$1" ] || fail "no programs in ${FIXTURE_DIR#"$ROOT"/}"
program_count=$#

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/work" "$WORKDIR/rows"

echo "[addr-taken-matrix] $program_count program(s) at opt0/1/2 with $JOBS worker(s)"
export TYPELISP_BIN=$COMPILER
if ! printf '%s\n' "$@" | xargs -P "$JOBS" -L 1 "$0" --job; then
    fail "a program did not compile, link or declare an expected exit"
fi

printf 'program\texpected\topt0\topt1\topt2\n' > "$WORKDIR/matrix.tsv"
sort "$WORKDIR"/rows/*.tsv >> "$WORKDIR/matrix.tsv"
rows=$(ls "$WORKDIR/rows" | wc -l | tr -d ' ')
[ "$rows" -eq "$program_count" ] ||
    fail "recorded $rows of $program_count programs (table: $WORKDIR/matrix.tsv)"

failed=0
_line=0
while IFS="	" read -r _name _expected _o0 _o1 _o2; do
    _line=$((_line + 1))
    [ "$_line" -gt 1 ] || continue
    _file=${FIXTURE_DIR#"$ROOT"/}/$_name.tl
    if [ "$_o0" != "$_o1" ] || [ "$_o1" != "$_o2" ]; then
        echo "[addr-taken-matrix] FAIL $_file: opt0=$_o0 opt1=$_o1 opt2=$_o2," \
            "levels disagree (expected exit $_expected)" >&2
        failed=$((failed + 1))
    elif [ "$_o0" != "$_expected" ]; then
        echo "[addr-taken-matrix] FAIL $_file: opt0=$_o0 opt1=$_o1 opt2=$_o2," \
            "expected exit $_expected" >&2
        failed=$((failed + 1))
    fi
done < "$WORKDIR/matrix.tsv"

if [ "$failed" -gt 0 ]; then
    fail "$failed of $program_count program(s) did not agree at opt0/1/2" \
        "(table: $WORKDIR/matrix.tsv)"
fi
echo "[addr-taken-matrix] $program_count program(s) agree at opt0/1/2 and with" \
    "their declared exit (table: $WORKDIR/matrix.tsv)"
