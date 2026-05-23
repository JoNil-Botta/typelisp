#!/usr/bin/env sh
set -eu

# verify-stdlib.sh - verify canonical stdlib modules through --stdlib-root.
# refs #285

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "stdlib verification is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

# Every canonical stdlib module must be listed here. Keep this manifest in sync
# with stdlib/README.md so new modules land with an explicit verification
# decision.
stdlib_manifest() {
    cat <<'EOF'
string.tl
test.tl
EOF
}

WORKDIR="$ROOT/target/stdlib-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

EXPECTED="$WORKDIR/expected-stdlib-files.txt"
ACTUAL="$WORKDIR/actual-stdlib-files.txt"

stdlib_manifest | sort > "$EXPECTED"
find stdlib -type f -name '*.tl' | sed 's#^stdlib/##' | sort > "$ACTUAL"

if ! cmp -s "$EXPECTED" "$ACTUAL"; then
    echo "stdlib verification manifest is out of date" >&2
    echo "expected modules:" >&2
    sed 's/^/  /' "$EXPECTED" >&2
    echo "actual modules:" >&2
    sed 's/^/  /' "$ACTUAL" >&2
    if command -v diff >/dev/null 2>&1; then
        diff -u "$EXPECTED" "$ACTUAL" >&2 || true
    fi
    exit 1
fi

WITNESS="$WORKDIR/stdlib_string_witness.tl"
ASM="$WORKDIR/stdlib_string_witness.s"
OBJ="$WORKDIR/stdlib_string_witness.o"
BIN="$WORKDIR/stdlib_string_witness"
STDOUT="$WORKDIR/stdlib_string_witness.stdout"
STDERR="$WORKDIR/stdlib_string_witness.stderr"

cat > "$WITNESS" <<'EOF'
(import "stdlib/string.tl")
(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-string-eq (string-trim "  hello  ") "hello" "string trim assertion failed")
    (assert-true (string-contains "hello" "ell") "string contains assertion failed")
    (assert-false (string-contains "hello" "zzz") "string missing assertion failed")
    (assert-string-eq (string-replace "hello" "ell" "ipp") "hippo" "string replace middle assertion failed")
    (assert-string-eq (string-replace "abc" "c" "x") "abx" "string replace tail assertion failed")
    42))
EOF

echo "[stdlib] compiling witness with --stdlib-root"
"$COMPILER" compile "$WITNESS" --stdlib-root "$ROOT/stdlib" -o "$ASM"

as "$ASM" -o "$OBJ"
ld "$OBJ" -o "$BIN"

echo "[stdlib] running witness -> expect exit 42"
set +e
"$BIN" > "$STDOUT" 2> "$STDERR"
got=$?
set -e

if [ "$got" -ne 42 ]; then
    echo "FAIL: stdlib witness expected exit 42, got $got" >&2
    if [ -s "$STDOUT" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$STDOUT" >&2
    fi
    if [ -s "$STDERR" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$STDERR" >&2
    fi
    exit 1
fi

if [ -s "$STDOUT" ]; then
    echo "FAIL: stdlib witness wrote unexpected stdout" >&2
    sed 's/^/  /' "$STDOUT" >&2
    exit 1
fi

if [ -s "$STDERR" ]; then
    echo "FAIL: stdlib witness wrote unexpected stderr" >&2
    sed 's/^/  /' "$STDERR" >&2
    exit 1
fi

FAIL_WITNESS="$WORKDIR/stdlib_test_fail_witness.tl"
FAIL_ASM="$WORKDIR/stdlib_test_fail_witness.s"
FAIL_OBJ="$WORKDIR/stdlib_test_fail_witness.o"
FAIL_BIN="$WORKDIR/stdlib_test_fail_witness"
FAIL_STDOUT="$WORKDIR/stdlib_test_fail_witness.stdout"
FAIL_STDERR="$WORKDIR/stdlib_test_fail_witness.stderr"

cat > "$FAIL_WITNESS" <<'EOF'
(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-i64-eq 1 2 "intentional stdlib assertion failure")
    0))
EOF

echo "[stdlib] compiling failing assertion witness with --stdlib-root"
"$COMPILER" compile "$FAIL_WITNESS" --stdlib-root "$ROOT/stdlib" -o "$FAIL_ASM"

as "$FAIL_ASM" -o "$FAIL_OBJ"
ld "$FAIL_OBJ" -o "$FAIL_BIN"

echo "[stdlib] running failing assertion witness -> expect abort"
set +e
"$FAIL_BIN" > "$FAIL_STDOUT" 2> "$FAIL_STDERR"
got=$?
set -e

if [ "$got" -ne 134 ]; then
    echo "FAIL: failing assertion witness expected exit 134, got $got" >&2
    exit 1
fi

if [ -s "$FAIL_STDOUT" ]; then
    echo "FAIL: failing assertion witness wrote unexpected stdout" >&2
    sed 's/^/  /' "$FAIL_STDOUT" >&2
    exit 1
fi

if ! grep -F "intentional stdlib assertion failure" "$FAIL_STDERR" >/dev/null 2>&1; then
    echo "FAIL: failing assertion stderr did not include supplied message" >&2
    sed 's/^/  /' "$FAIL_STDERR" >&2
    exit 1
fi

echo "stdlib verification passed for $(wc -l < "$EXPECTED" | tr -d ' ') module(s)"
