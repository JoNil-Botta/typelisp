#!/usr/bin/env sh
set -eu

# check-bootstrap-smoke.sh - bounded CI bootstrap coverage for the selfhost compiler.
#
# The full stage2/stage3 fixpoint in check-bootstrap-fixpoint.sh is intentionally
# preserved as the local/release gate. This smoke check stays within GitHub runner
# memory by using a stage1 compiler to compile and run a small program that
# exercises type-valued comptime specialization.
#
# Set TYPELISP_BOOTSTRAP_SMOKE_STAGE1_BIN to reuse a stage1 binary already built
# by check-bootstrap-fixpoint.sh; otherwise this script builds stage1 from the
# supplied seed compiler for standalone local use.
#
# refs #47, #832.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

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

REUSE_STAGE1_BIN=${TYPELISP_BOOTSTRAP_SMOKE_STAGE1_BIN:-}

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [typelisp-binary]" >&2
    exit 2
fi

if [ -z "$REUSE_STAGE1_BIN" ]; then
    if [ "$#" -eq 1 ]; then
        COMPILER=$1
    elif [ -n "${TYPELISP_BIN:-}" ]; then
        COMPILER=$TYPELISP_BIN
    else
        # Local-development fallback: fetch the published
        # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
        . "$ROOT/scripts/lib-stage0.sh"
        COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    fi

    if [ ! -x "$COMPILER" ]; then
        echo "typelisp compiler is not executable: $COMPILER" >&2
        exit 1
    fi
else
    case "$REUSE_STAGE1_BIN" in
        /* | [A-Za-z]:[/\\]*) ;;
        *) REUSE_STAGE1_BIN="$ROOT/$REUSE_STAGE1_BIN" ;;
    esac
    if [ ! -x "$REUSE_STAGE1_BIN" ]; then
        echo "reused stage1 compiler is not executable: $REUSE_STAGE1_BIN" >&2
        exit 1
    fi
fi

WORKDIR="$ROOT/target/bootstrap-smoke"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

STAGE1_ASM="$WORKDIR/stage1.s"
STAGE1_OBJ="$WORKDIR/stage1.o"
STAGE1_BIN="$WORKDIR/stage1"
if [ -n "$REUSE_STAGE1_BIN" ]; then
    STAGE1_BIN=$REUSE_STAGE1_BIN
fi
SMOKE_SRC="$WORKDIR/comptime_type_smoke.tl"
SMOKE_ASM="$WORKDIR/comptime_type_smoke.s"
SMOKE_OBJ="$WORKDIR/comptime_type_smoke.o"
SMOKE_BIN="$WORKDIR/comptime_type_smoke"

cat > "$SMOKE_SRC" <<'EOF'
(define (id [comptime T : type] [value : T]) : T value)
(define (main) : i64 (id (type i64) 42))
EOF

if [ -n "$REUSE_STAGE1_BIN" ]; then
    echo "[bootstrap-smoke] reuse stage1 $STAGE1_BIN"
else
    echo "[bootstrap-smoke] stage0 -> stage1.s"
    "$COMPILER" compile selfhost/compile.tl -o "$STAGE1_ASM"

    echo "[bootstrap-smoke] link stage1"
    as "$STAGE1_ASM" -o "$STAGE1_OBJ"
    ld "$STAGE1_OBJ" -o "$STAGE1_BIN" -static -e "$(linux_entry_symbol_for_asm "$STAGE1_ASM")"
fi

echo "[bootstrap-smoke] stage1 compiles comptime type fixture"
"$STAGE1_BIN" compile "$SMOKE_SRC" -o "$SMOKE_ASM" \
    --target linux-x86_64 \
    --backend-mode scalar \
    --opt-level 1 \
    --stdlib-root "$ROOT/stdlib"

echo "[bootstrap-smoke] link fixture"
as "$SMOKE_ASM" -o "$SMOKE_OBJ"
ld "$SMOKE_OBJ" -o "$SMOKE_BIN" -static -e "$(linux_entry_symbol_for_asm "$SMOKE_ASM")"

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
