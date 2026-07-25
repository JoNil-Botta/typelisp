#!/usr/bin/env sh
set -eu

# verify-prelude-mutation.sh - prove the prelude macro bodies actually execute.
#
# Every other test of the core prelude compares *output*, and a compiler-owned
# expander produces the same output as the stdlib body. That is not hypothetical:
# #4794/#4800 removed the compiler-owned `and`/`or`/`cond` expanders, #4896
# silently reintroduced them while merging a pre-#4800 branch, and nothing
# noticed, because `tests/integration/implicit_core_prelude.tl` passes
# identically either way. #5322 closed the violation and named this gap in its
# own acceptance criteria; this is that gate.
#
# Method: copy the checked-in stdlib to a scratch root, replace one macro's body
# with a constant, and compile the fixture against that root. If the observable
# outcome does not change, something other than the stdlib body decided the
# result -- a privileged compiler path -- and the gate fails naming that macro.
#
# The mutation is derived from the checked-in source every run, so there is no
# second copy of `core_macros.tl` to drift.
#
# refs #5704, #5322, #4896, #4800.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-prelude-mutation.sh" >&2
    exit 2
fi

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || {
    echo "prelude mutation guard requires an executable compiler: $COMPILER" >&2
    exit 1
}

WORKDIR=${PRELUDE_MUTATION_DIR:-target/exp/prelude-mutation}
case "$WORKDIR" in
    target/*) ;;
    *)
        echo "PRELUDE_MUTATION_DIR must stay below target/: $WORKDIR" >&2
        exit 2
        ;;
esac
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

SOURCE_MACROS=stdlib/core_macros.tl
[ -f "$SOURCE_MACROS" ] || {
    echo "missing $SOURCE_MACROS" >&2
    exit 1
}

# Replace one top-level `(defmacro (<name> ...)` form's body with `replacement`,
# keeping its signature line so the arity and result type still parse. The form
# ends at the next line that starts a new top-level form in column 0.
mutate_macro() {
    _name=$1
    _replacement=$2
    _in=$3
    _out=$4
    awk -v name="$_name" -v repl="$_replacement" '
        BEGIN { state = "before" }
        state == "before" && $0 ~ ("^\\(defmacro \\(" name "[ )]") {
            print $0
            print repl
            state = "skipping"
            next
        }
        state == "skipping" {
            # A new top-level form begins at column 0 with "(".
            if ($0 ~ /^\(/) { state = "after" } else { next }
        }
        { print }
        END {
            if (state == "before") { exit 3 }
        }
    ' "$_in" > "$_out"
}

# Run the fixture against a stdlib root and echo the exit status.
run_fixture() {
    _fixture=$1
    _stdlib=$2
    _log=$3
    set +e
    "$COMPILER" run "$_fixture" --stdlib-root "$_stdlib" > "$_log" 2>&1
    _status=$?
    set -e
    echo "$_status"
}

failed=0

# macro | fixture | constant body replacing the original
#
# The replacement only has to make the *outcome* differ. A mutation that fails
# to compile is an equally valid signal -- it proves the body was consulted --
# so these are chosen for obvious semantic change rather than for type fidelity.
check_macro() {
    _macro=$1
    _fixture=$2
    _repl=$3

    _scratch="$WORKDIR/$_macro/stdlib"
    mkdir -p "$_scratch"
    cp stdlib/*.tl "$_scratch/"
    if [ -d stdlib/tests ]; then
        mkdir -p "$_scratch/tests"
        cp stdlib/tests/*.tl "$_scratch/tests/" 2>/dev/null || true
    fi

    if ! mutate_macro "$_macro" "$_repl" "$SOURCE_MACROS" "$_scratch/core_macros.tl"; then
        echo "prelude mutation guard: no top-level (defmacro ($_macro ...) in $SOURCE_MACROS" >&2
        failed=1
        return
    fi
    if cmp -s "$SOURCE_MACROS" "$_scratch/core_macros.tl"; then
        echo "prelude mutation guard: mutation of $_macro changed nothing in the source" >&2
        failed=1
        return
    fi

    if ! grep -qE "\($_macro([ )]|\$)" "$_fixture"; then
        echo "prelude mutation guard: $_fixture does not use ($_macro ...), so a mutation of it cannot be observed. Pair '$_macro' with a fixture that exercises it -- this is a gate setup error, not a compiler regression." >&2
        failed=1
        return
    fi

    _base_status=$(run_fixture "$_fixture" "$ROOT/stdlib" "$WORKDIR/$_macro/baseline.log")
    _mut_status=$(run_fixture "$_fixture" "$_scratch" "$WORKDIR/$_macro/mutated.log")

    if [ "$_base_status" -ne 42 ]; then
        echo "prelude mutation guard: $_fixture exited $_base_status unmutated, expected 42" >&2
        sed 's/^/  /' "$WORKDIR/$_macro/baseline.log" >&2 || true
        failed=1
        return
    fi

    if [ "$_base_status" -eq "$_mut_status" ]; then
        echo "prelude mutation guard: mutating '$_macro' did not change the outcome of" \
            "$_fixture (both exited $_base_status)." >&2
        echo "  The stdlib body is not deciding the result -- a compiler-owned" \
            "expander for '$_macro' has been reintroduced. See #5322 and #4896." >&2
        failed=1
        return
    fi

    echo "[prelude-mutation] $_macro: baseline $_base_status -> mutated $_mut_status (body executes)"
}

check_macro and tests/integration/implicit_core_prelude.tl '  `false)'
check_macro or tests/integration/implicit_core_prelude.tl '  `false)'
check_macro cond tests/integration/cond.tl '  `0)'
check_macro for tests/integration/for_macro.tl '  `unit)'

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "prelude mutation guard passed: and, or, cond, for bodies all execute"
