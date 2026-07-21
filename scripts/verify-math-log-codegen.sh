#!/usr/bin/env sh
set -eu

# Verify that freestanding logarithms stay allocation/libm-free and assemble
# for both supported targets.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

[ -x "$COMPILER" ] || {
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
}

WORKDIR="$ROOT/target/math-log-codegen"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

FIXTURE="$WORKDIR/log_codegen.tl"
cat > "$FIXTURE" <<'EOF'
(import stdlib.math)

(define log-input64 : f64 1.25)
(define log-input32 : f32 1.25)

(define (log-probe64 [value : f64])
  (:export-symbol "tl_test_math_log_f64") : f64
  (math.f64-log value))

(define (log-probe32 [value : f32])
  (:export-symbol "tl_test_math_log_f32") : f32
  (math.f32-log value))

(define (main) : i64
  (let
    [sum : f64
      (+
        (log-probe64 log-input64)
        (cast (log-probe32 log-input32) : f64))]
    (if (> sum 0.0)
      0
      1)))
EOF

fail() {
    echo "math log codegen verification failed: $*" >&2
    exit 1
}

verify_assembly() {
    target=$1
    assembly=$2

    "$COMPILER" compile "$FIXTURE" \
        --target "$target" \
        --opt-level 2 \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" \
        -o "$assembly"

    for symbol in tl_test_math_log_f64 tl_test_math_log_f32 math_log_f64_table_entry; do
        grep -F "$symbol" "$assembly" >/dev/null ||
            fail "$target omitted $symbol"
    done

    if grep -E 'global_init.*math_log|call[[:space:]]+.*tl_alloc' "$assembly" >/dev/null; then
        fail "$target log path contains startup or runtime allocation"
    fi
    if grep -Ei '^[[:space:]]*\.(extern|globl?)[[:space:]]+_?logf?([[:space:]]|$)' "$assembly" >/dev/null; then
        fail "$target assembly references an external logarithm"
    fi
    if grep -Ei '^[[:space:]]*(fyl2x|fyl2xp1|f2xm1|fscale|v?fmadd[a-z0-9]*|v?fmsub[a-z0-9]*|v?fnmadd[a-z0-9]*|v?fnmsub[a-z0-9]*)[[:space:]]' "$assembly" >/dev/null; then
        fail "$target assembly contains x87 logarithm or FMA instructions"
    fi
}

LINUX_ASM="$WORKDIR/log-linux.s"
WINDOWS_ASM="$WORKDIR/log-windows.s"
verify_assembly linux-x86_64 "$LINUX_ASM"
verify_assembly windows-x86_64 "$WINDOWS_ASM"

case "$(uname -s)" in
    Linux*)
        if command -v as >/dev/null 2>&1; then
            as "$LINUX_ASM" -o "$WORKDIR/log-linux.o" ||
                fail "GNU as rejected Linux assembly"
        fi
        if command -v clang >/dev/null 2>&1; then
            clang --target=x86_64-pc-windows-msvc \
                -c "$WINDOWS_ASM" \
                -o "$WORKDIR/log-windows.obj" ||
                fail "clang rejected Windows assembly"
        fi
        ;;
    MINGW* | MSYS* | CYGWIN*)
        command -v clang >/dev/null 2>&1 ||
            fail "clang is required to assemble both targets on Windows"
        clang --target=x86_64-unknown-linux-gnu \
            -c "$LINUX_ASM" \
            -o "$WORKDIR/log-linux.o" ||
            fail "clang rejected Linux assembly"
        clang --target=x86_64-pc-windows-msvc \
            -c "$WINDOWS_ASM" \
            -o "$WORKDIR/log-windows.obj" ||
            fail "clang rejected Windows assembly"
        ;;
    *) fail "unsupported host for assembly verification" ;;
esac

echo "math log codegen verification passed for Linux and Windows x86-64"
