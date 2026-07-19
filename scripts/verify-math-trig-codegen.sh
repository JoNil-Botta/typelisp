#!/usr/bin/env sh
set -eu

# Verify that the freestanding trig implementation stays allocation/libm-free
# and remains valid assembly for both supported targets.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/math-trig-codegen"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

FIXTURE="$WORKDIR/trig_codegen.tl"
cat > "$FIXTURE" <<'EOF'
(import stdlib.math)

(define trig-input64 : f64 1.25)
(define trig-input32 : f32 1.25)

(define (main) : i64
  (let
    [sum : f64
      (+
        (math.f64-sin trig-input64)
        (math.f64-cos trig-input64)
        (math.f64-tan trig-input64)
        (cast (math.f32-sin trig-input32) : f64)
        (cast (math.f32-cos trig-input32) : f64)
        (cast (math.f32-tan trig-input32) : f64))]
    (if (> sum 0.0)
      0
      1)))
EOF

fail() {
    echo "math trig codegen verification failed: $*" >&2
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

    for symbol in f64_sin f64_cos f64_tan f32_sin f32_cos f32_tan; do
        grep -F "$symbol" "$assembly" >/dev/null ||
            fail "$target omitted $symbol"
    done

    if grep -E 'global_init.*math_trig|call[[:space:]]+.*tl_alloc' "$assembly" >/dev/null; then
        fail "$target trig path contains startup or runtime allocation"
    fi
    if grep -Ei '^[[:space:]]*\.(extern|globl?)[[:space:]]+_?(sin|cos|tan)f?([[:space:]]|$)' "$assembly" >/dev/null; then
        fail "$target assembly references an external trig function"
    fi
    if grep -Ei '^[[:space:]]*(fsin|fcos|fptan|fsincos|v?fmadd[a-z0-9]*|v?fmsub[a-z0-9]*|v?fnmadd[a-z0-9]*|v?fnmsub[a-z0-9]*)[[:space:]]' "$assembly" >/dev/null; then
        fail "$target assembly contains x87 trig or FMA instructions"
    fi
}

LINUX_ASM="$WORKDIR/trig-linux.s"
WINDOWS_ASM="$WORKDIR/trig-windows.s"
verify_assembly linux-x86_64 "$LINUX_ASM"
verify_assembly windows-x86_64 "$WINDOWS_ASM"

case "$(uname -s)" in
    Linux*)
        if command -v as >/dev/null 2>&1; then
            as "$LINUX_ASM" -o "$WORKDIR/trig-linux.o" ||
                fail "GNU as rejected Linux assembly"
        fi
        if command -v clang >/dev/null 2>&1; then
            clang --target=x86_64-pc-windows-msvc \
                -c "$WINDOWS_ASM" \
                -o "$WORKDIR/trig-windows.obj" ||
                fail "clang rejected Windows assembly"
        fi
        ;;
    MINGW* | MSYS* | CYGWIN*)
        command -v clang >/dev/null 2>&1 ||
            fail "clang is required to assemble both targets on Windows"
        clang --target=x86_64-unknown-linux-gnu \
            -c "$LINUX_ASM" \
            -o "$WORKDIR/trig-linux.o" ||
            fail "clang rejected Linux assembly"
        clang --target=x86_64-pc-windows-msvc \
            -c "$WINDOWS_ASM" \
            -o "$WORKDIR/trig-windows.obj" ||
            fail "clang rejected Windows assembly"
        ;;
    *) fail "unsupported host for assembly verification" ;;
esac

echo "math trig codegen verification passed for Linux and Windows x86-64"
