#!/usr/bin/env sh
set -eu

# verify-stdlib.sh - Verify canonical stdlib modules through --stdlib-root.
# refs #221, #285

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

verified_modules() {
    cat <<'EOF'
stdlib/string.tl
EOF
}

WORKDIR="$ROOT/target/stdlib-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

expected_manifest="$WORKDIR/expected-modules.txt"
actual_manifest="$WORKDIR/actual-modules.txt"

verified_modules | sort > "$expected_manifest"
find "$ROOT/stdlib" -type f -name '*.tl' | sed "s#^$ROOT/##" | sort > "$actual_manifest"

if ! cmp -s "$expected_manifest" "$actual_manifest"; then
    echo "stdlib verification manifest is out of date" >&2
    echo "expected verified modules:" >&2
    sed 's/^/  /' "$expected_manifest" >&2
    echo "actual stdlib modules:" >&2
    sed 's/^/  /' "$actual_manifest" >&2
    exit 1
fi

while read -r module; do
    [ -n "$module" ] || continue
    if [ ! -f "$ROOT/$module" ]; then
        echo "verified stdlib module does not exist: $module" >&2
        exit 1
    fi
done < "$expected_manifest"

SRC_DIR="$WORKDIR/source"
mkdir -p "$SRC_DIR"
ENTRY="$SRC_DIR/stdlib_witness.tl"

cat > "$ENTRY" <<'EOF'
(import "stdlib/string.tl")

(define (main) : i64
  (if (string-eq (string-trim "  hello  ") "hello")
      (if (string-contains "hello" "ell")
          (if (not (string-contains "hello" "zzz"))
              (if (string-eq (string-replace "hello" "ell" "ipp") "hippo")
                  (if (string-eq (string-replace "abc" "c" "x") "abx")
                      42
                      5)
                  4)
              3)
          2)
      1))
EOF

ASM="$WORKDIR/stdlib_witness.s"
OBJ="$WORKDIR/stdlib_witness.o"
BIN="$WORKDIR/stdlib_witness"

echo "[stdlib] compiling witness through --stdlib-root"
"$COMPILER" compile "$ENTRY" --stdlib-root "$ROOT/stdlib" -o "$ASM"

as "$ASM" -o "$OBJ"
ld "$OBJ" -o "$BIN"

echo "[stdlib] running witness -> expect exit 42"
set +e
"$BIN"
got=$?
set -e

if [ "$got" -ne 42 ]; then
    echo "FAIL: stdlib witness expected exit 42, got $got" >&2
    exit 1
fi

echo "stdlib verification passed for $(verified_modules | wc -l | tr -d ' ') module(s)."
