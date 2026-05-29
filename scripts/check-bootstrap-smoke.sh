#!/usr/bin/env sh
set -eu

# check-bootstrap-smoke.sh - bounded CI bootstrap coverage for the selfhost compiler.
#
# The full stage2/stage3 fixpoint in check-bootstrap-fixpoint.sh is intentionally
# preserved as the local/release gate. This smoke check stays within GitHub runner
# memory by building the full selfhost compiler once, then using that stage1
# compiler to compile and run a small program that exercises type-valued comptime
# specialization.
#
# refs #47, #832.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "bootstrap smoke check is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

command -v as >/dev/null 2>&1 || {
    echo "bootstrap smoke check requires 'as'" >&2
    exit 1
}
command -v ld >/dev/null 2>&1 || {
    echo "bootstrap smoke check requires 'ld'" >&2
    exit 1
}

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [typelisp-binary]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    COMPILER=$1
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/bootstrap-smoke"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

STAGE1_ASM="$WORKDIR/stage1.s"
STAGE1_OBJ="$WORKDIR/stage1.o"
STAGE1_BIN="$WORKDIR/stage1"
SMOKE_SRC="$WORKDIR/comptime_type_smoke.tl"
SMOKE_ASM="$WORKDIR/comptime_type_smoke.s"
SMOKE_OBJ="$WORKDIR/comptime_type_smoke.o"
SMOKE_BIN="$WORKDIR/comptime_type_smoke"

cat > "$SMOKE_SRC" <<'EOF'
(define (id [comptime T : type] [value : T]) : T value)
(define (main) : i64 (id (type i64) 42))
EOF

echo "[bootstrap-smoke] stage0 -> stage1.s"
"$COMPILER" compile selfhost/compile.tl -o "$STAGE1_ASM"

echo "[bootstrap-smoke] link stage1"
as "$STAGE1_ASM" -o "$STAGE1_OBJ"
ld "$STAGE1_OBJ" -o "$STAGE1_BIN" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc

echo "[bootstrap-smoke] stage1 compiles comptime type fixture"
"$STAGE1_BIN" compile "$SMOKE_SRC" -o "$SMOKE_ASM" \
    --target linux-x86_64 \
    --backend-mode scalar \
    --opt-level 1 \
    --stdlib-root "$ROOT/stdlib"

echo "[bootstrap-smoke] link fixture"
as "$SMOKE_ASM" -o "$SMOKE_OBJ"
ld "$SMOKE_OBJ" -o "$SMOKE_BIN" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc

echo "[bootstrap-smoke] run fixture"
set +e
"$SMOKE_BIN"
got=$?
set -e

if [ "$got" -ne 42 ]; then
    echo "bootstrap smoke fixture expected exit 42, got $got" >&2
    exit 1
fi

echo "bootstrap smoke check passed"
