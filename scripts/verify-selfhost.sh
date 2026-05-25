#!/usr/bin/env sh
set -eu

# verify-selfhost.sh - drive the selfhost compile_smoke compiler over a corpus.
#
# Builds selfhost/compile_smoke.tl (plus its imported selfhost modules) into a
# native `selfhost-cc` driver once, then runs that driver over every program in
# selfhost/tests/, assembling + linking + running each emitted `.s` and
# asserting the expected exit code / stdout. Programs in selfhost/tests/errors/
# must make the driver exit non-zero with a specific diagnostic on stderr and
# emit no assembly.
#
# refs #524 (covers #520 items 2 & 3; part of #27, complements #47)

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "selfhost verification is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Fallback only for local development; CI should pass a fetched stage0
    # compiler through TYPELISP_BIN until #793/#795 remove Rust stage0.
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

# Every selfhost/tests/*.tl program must be registered here as
# `file|exit-code|stdout`. Keep this manifest in sync with the corpus so new
# programs land with an explicit expectation (the manifest check below fails
# otherwise).
ok_manifest() {
    cat <<'EOF'
let_if_le.tl|1|
define_double.tl|42|
begin_print.tl|7|hi
begin_function_body.tl|42|
set_local.tl|42|
set_function_body.tl|42|
while_loop.tl|42|
multi_let.tl|42|
boolean_ops.tl|42|
EOF
}

# Every selfhost/tests/errors/*.tl program must be registered here as
# `file|expected-stderr`. The driver is expected to exit non-zero, print exactly
# this diagnostic on stderr, and emit no assembly.
err_manifest() {
    cat <<'EOF'
malformed_while.tl|parse: malformed while
empty_begin.tl|parse: empty begin
malformed_if.tl|parse: malformed if
malformed_and.tl|parse: malformed and
malformed_or.tl|parse: malformed or
malformed_not.tl|parse: malformed not
EOF
}

WORKDIR="$ROOT/target/selfhost-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# Manifest sync: the registered program names must exactly match the corpus on
# disk, so a new selfhost/tests file cannot be added without an expectation.
check_manifest() {
    label=$1
    expected=$2
    actual=$3
    if ! cmp -s "$expected" "$actual"; then
        echo "selfhost corpus manifest ($label) is out of date" >&2
        echo "expected programs:" >&2
        sed 's/^/  /' "$expected" >&2
        echo "actual programs:" >&2
        sed 's/^/  /' "$actual" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$expected" "$actual" >&2 || true
        fi
        exit 1
    fi
}

EXPECTED_OK="$WORKDIR/expected-ok.txt"
ACTUAL_OK="$WORKDIR/actual-ok.txt"
ok_manifest | cut -d'|' -f1 | sort > "$EXPECTED_OK"
find selfhost/tests -maxdepth 1 -type f -name '*.tl' | sed 's#^selfhost/tests/##' | sort > "$ACTUAL_OK"
check_manifest "success cases" "$EXPECTED_OK" "$ACTUAL_OK"

EXPECTED_ERR="$WORKDIR/expected-err.txt"
ACTUAL_ERR="$WORKDIR/actual-err.txt"
err_manifest | cut -d'|' -f1 | sort > "$EXPECTED_ERR"
find selfhost/tests/errors -maxdepth 1 -type f -name '*.tl' | sed 's#^selfhost/tests/errors/##' | sort > "$ACTUAL_ERR"
check_manifest "error cases" "$EXPECTED_ERR" "$ACTUAL_ERR"

# Build the selfhost compile_smoke driver once into a reusable native binary.
echo "[selfhost] building compile_smoke driver"
CC_ASM="$WORKDIR/selfhost-cc.s"
CC_OBJ="$WORKDIR/selfhost-cc.o"
CC_BIN="$WORKDIR/selfhost-cc"
"$COMPILER" compile selfhost/compile_smoke.tl -o "$CC_ASM"
as "$CC_ASM" -o "$CC_OBJ"
ld "$CC_OBJ" -o "$CC_BIN"

OK_LIST="$WORKDIR/ok-manifest.txt"
ok_manifest > "$OK_LIST"

# Looping over a redirected file (not a pipe) keeps the body in this shell so
# `exit 1` aborts the whole script on the first failure.
while IFS='|' read -r name want_exit want_stdout; do
    [ -n "$name" ] || continue
    src="selfhost/tests/$name"
    base=${name%.tl}
    asm="$WORKDIR/$base.s"
    obj="$WORKDIR/$base.o"
    bin="$WORKDIR/$base"
    drv_out="$WORKDIR/$base.driver.out"
    drv_err="$WORKDIR/$base.driver.err"

    echo "[selfhost] $name -> emit assembly"
    set +e
    "$CC_BIN" "$src" "$asm" > "$drv_out" 2> "$drv_err"
    drv_code=$?
    set -e
    if [ "$drv_code" -ne 0 ]; then
        echo "FAIL: $name driver exited $drv_code (expected 0)" >&2
        if [ -s "$drv_err" ]; then sed 's/^/  /' "$drv_err" >&2; fi
        exit 1
    fi
    if [ -s "$drv_out" ]; then
        echo "FAIL: $name driver wrote unexpected stdout" >&2
        sed 's/^/  /' "$drv_out" >&2
        exit 1
    fi
    if [ -s "$drv_err" ]; then
        echo "FAIL: $name driver wrote unexpected stderr" >&2
        sed 's/^/  /' "$drv_err" >&2
        exit 1
    fi

    as "$asm" -o "$obj"
    ld "$obj" -o "$bin"

    prog_out="$WORKDIR/$base.out"
    prog_err="$WORKDIR/$base.err"
    echo "[selfhost] $name -> run (expect exit $want_exit)"
    set +e
    "$bin" > "$prog_out" 2> "$prog_err"
    got=$?
    set -e

    if [ "$got" -ne "$want_exit" ]; then
        echo "FAIL: $name expected exit $want_exit, got $got" >&2
        if [ -s "$prog_out" ]; then echo "stdout:" >&2; sed 's/^/  /' "$prog_out" >&2; fi
        if [ -s "$prog_err" ]; then echo "stderr:" >&2; sed 's/^/  /' "$prog_err" >&2; fi
        exit 1
    fi

    got_stdout=$(cat "$prog_out")
    if [ "$got_stdout" != "$want_stdout" ]; then
        echo "FAIL: $name expected stdout [$want_stdout], got [$got_stdout]" >&2
        exit 1
    fi
    if [ -s "$prog_err" ]; then
        echo "FAIL: $name wrote unexpected stderr" >&2
        sed 's/^/  /' "$prog_err" >&2
        exit 1
    fi

    echo "PASS: $name -> exit $got"
done < "$OK_LIST"

ERR_LIST="$WORKDIR/err-manifest.txt"
err_manifest > "$ERR_LIST"

while IFS='|' read -r name want_stderr; do
    [ -n "$name" ] || continue
    src="selfhost/tests/errors/$name"
    base=${name%.tl}
    asm="$WORKDIR/err-$base.s"
    drv_out="$WORKDIR/err-$base.out"
    drv_err="$WORKDIR/err-$base.err"
    rm -f "$asm"

    echo "[selfhost] error $name -> expect diagnostic"
    set +e
    "$CC_BIN" "$src" "$asm" > "$drv_out" 2> "$drv_err"
    drv_code=$?
    set -e

    if [ "$drv_code" -eq 0 ]; then
        echo "FAIL: error case $name unexpectedly succeeded (exit 0)" >&2
        exit 1
    fi
    if [ -s "$drv_out" ]; then
        echo "FAIL: error case $name wrote stdout" >&2
        sed 's/^/  /' "$drv_out" >&2
        exit 1
    fi
    got_stderr=$(cat "$drv_err")
    if [ "$got_stderr" != "$want_stderr" ]; then
        echo "FAIL: error case $name expected stderr [$want_stderr], got [$got_stderr]" >&2
        exit 1
    fi
    if [ -f "$asm" ]; then
        echo "FAIL: error case $name emitted assembly despite a diagnostic" >&2
        exit 1
    fi

    echo "PASS: error $name -> $want_stderr"
done < "$ERR_LIST"

ok_count=$(wc -l < "$OK_LIST" | tr -d ' ')
err_count=$(wc -l < "$ERR_LIST" | tr -d ' ')
echo "selfhost verification passed: $ok_count program(s), $err_count error case(s)"
