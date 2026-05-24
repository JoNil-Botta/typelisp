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
io.tl
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

(define (main) : i64
  (if (string-eq (string-trim "  hello  ") "hello")
      (if (string-contains "hello" "ell")
          (if (string-contains "hello" "zzz")
              3
              (if (string-eq (string-replace "hello" "ell" "ipp") "hippo")
                  (if (string-eq (string-replace "abc" "c" "x") "abx")
                      42
                      5)
                  4))
          2)
      1))
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

TEST_WITNESS="$WORKDIR/stdlib_test_witness.tl"
TEST_ASM="$WORKDIR/stdlib_test_witness.s"
TEST_OBJ="$WORKDIR/stdlib_test_witness.o"
TEST_BIN="$WORKDIR/stdlib_test_witness"
TEST_STDOUT="$WORKDIR/stdlib_test_witness.stdout"
TEST_STDERR="$WORKDIR/stdlib_test_witness.stderr"

cat > "$TEST_WITNESS" <<'EOF'
(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-true true "true should pass")
    (assert-false false "false should pass")
    (assert-bool-eq true true "bool equality should pass")
    (assert-i64-eq 42 42 "i64 equality should pass")
    (assert-i32-eq (cast 7 : i32) (cast 7 : i32) "i32 equality should pass")
    (assert-f64-eq 1.5 1.5 "f64 equality should pass")
    (assert-char-eq #A' #A' "char equality should pass")
    (assert-string-eq "hello" "hello" "string equality should pass")
    42))
EOF

echo "[stdlib] compiling assertion witness with --stdlib-root"
"$COMPILER" compile "$TEST_WITNESS" --stdlib-root "$ROOT/stdlib" -o "$TEST_ASM"

as "$TEST_ASM" -o "$TEST_OBJ"
ld "$TEST_OBJ" -o "$TEST_BIN"

echo "[stdlib] running assertion witness -> expect exit 42"
set +e
"$TEST_BIN" > "$TEST_STDOUT" 2> "$TEST_STDERR"
got=$?
set -e

if [ "$got" -ne 42 ]; then
    echo "FAIL: stdlib assertion witness expected exit 42, got $got" >&2
    if [ -s "$TEST_STDOUT" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$TEST_STDOUT" >&2
    fi
    if [ -s "$TEST_STDERR" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$TEST_STDERR" >&2
    fi
    exit 1
fi

if [ -s "$TEST_STDOUT" ]; then
    echo "FAIL: stdlib assertion witness wrote unexpected stdout" >&2
    sed 's/^/  /' "$TEST_STDOUT" >&2
    exit 1
fi

if [ -s "$TEST_STDERR" ]; then
    echo "FAIL: stdlib assertion witness wrote unexpected stderr" >&2
    sed 's/^/  /' "$TEST_STDERR" >&2
    exit 1
fi

IO_WITNESS="$WORKDIR/stdlib_io_witness.tl"
IO_ASM="$WORKDIR/stdlib_io_witness.s"
IO_OBJ="$WORKDIR/stdlib_io_witness.o"
IO_BIN="$WORKDIR/stdlib_io_witness"
IO_STDOUT="$WORKDIR/stdlib_io_witness.stdout"
IO_STDERR="$WORKDIR/stdlib_io_witness.stderr"

cat > "$IO_WITNESS" <<'EOF'
(import "stdlib/io.tl")

(define (main) : i64
  (begin
    (write-file "target/stdlib-verify/stdlib_io_witness.txt" "alpha")
    (if (string-eq (read-file-or "target/stdlib-verify/stdlib_io_witness.txt" "MISS") "alpha")
      (if (string-eq (read-file-or "target/stdlib-verify/stdlib_io_missing.txt" "MISS") "MISS")
        (begin
          (append-file "target/stdlib-verify/stdlib_io_witness.txt" "-beta")
          (if (string-eq (read-file "target/stdlib-verify/stdlib_io_witness.txt") "alpha-beta")
            (if (file-nonempty? "target/stdlib-verify/stdlib_io_witness.txt")
              (if (file-nonempty? "target/stdlib-verify/stdlib_io_missing.txt")
                10
                42)
              20)
            30))
        40)
      50)))
EOF

echo "[stdlib] compiling file I/O witness with --stdlib-root"
"$COMPILER" compile "$IO_WITNESS" --stdlib-root "$ROOT/stdlib" -o "$IO_ASM"

as "$IO_ASM" -o "$IO_OBJ"
ld "$IO_OBJ" -o "$IO_BIN"

echo "[stdlib] running file I/O witness -> expect exit 42"
set +e
"$IO_BIN" > "$IO_STDOUT" 2> "$IO_STDERR"
got=$?
set -e

if [ "$got" -ne 42 ]; then
    echo "FAIL: stdlib file I/O witness expected exit 42, got $got" >&2
    if [ -s "$IO_STDOUT" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$IO_STDOUT" >&2
    fi
    if [ -s "$IO_STDERR" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$IO_STDERR" >&2
    fi
    exit 1
fi

if [ -s "$IO_STDOUT" ]; then
    echo "FAIL: stdlib file I/O witness wrote unexpected stdout" >&2
    sed 's/^/  /' "$IO_STDOUT" >&2
    exit 1
fi

if [ -s "$IO_STDERR" ]; then
    echo "FAIL: stdlib file I/O witness wrote unexpected stderr" >&2
    sed 's/^/  /' "$IO_STDERR" >&2
    exit 1
fi

echo "stdlib verification passed for $(wc -l < "$EXPECTED" | tr -d ' ') module(s)"
