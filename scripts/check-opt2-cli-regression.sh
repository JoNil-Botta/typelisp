#!/usr/bin/env sh
set -eu

# check-opt2-cli-regression.sh - bounded opt2-generated compiler gate.
#
# Builds the repository root package as a release opt2 compiler (from the
# bootstrapped opt1 stage2 in TYPELISP_BIN), then checks two things WITHOUT a
# second bootstrap:
#   1. crash gate (#2515): the opt2-built compiler can compile src/main.tl at
#      opt2 to non-empty assembly.
#   2. correctness cross-fixpoint (#2921 class): the opt2-built compiler must
#      emit byte-identical opt1 assembly to the opt1-built compiler it was built
#      from. A miscompile in the opt2 self-build (e.g. the #2921 magic-division
#      corruption) still produces non-empty output, so the crash gate alone
#      cannot see it; the cross-fixpoint diff can.
# Both checks reuse the single opt2 build below plus a few single-file compiles -
# no extra stage1->stage2->stage3 bootstrap.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -z "${TYPELISP_BIN:-}" ]; then
    echo "check-opt2-cli-regression requires TYPELISP_BIN" >&2
    exit 2
fi

COMPILER=$TYPELISP_BIN
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

WORKDIR="$ROOT/target/opt2-cli-regression"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

GENERATED="$ROOT/target/release/typelisp$NL_BIN_EXT"
ASM="$WORKDIR/cli-opt2.s"
BUILD_STDOUT="$WORKDIR/build.stdout"
BUILD_STDERR="$WORKDIR/build.stderr"
COMPILE_STDOUT="$WORKDIR/compile.stdout"
COMPILE_STDERR="$WORKDIR/compile.stderr"

print_log_pair() {
    label=$1
    stdout=$2
    stderr=$3
    echo "[$label] stdout:" >&2
    sed 's/^/  /' "$stdout" >&2 || true
    echo "[$label] stderr:" >&2
    sed 's/^/  /' "$stderr" >&2 || true
}

print_asm_fingerprint() {
    label=$1
    file=$2
    bytes=$(wc -c < "$file" | tr -d ' ')
    lines=$(wc -l < "$file" | tr -d ' ')
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(sha256sum "$file" | sed 's/[[:space:]].*//')
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(shasum -a 256 "$file" | sed 's/[[:space:]].*//')
    else
        hash=unavailable
    fi
    echo "[opt2-cli-gate]   $label sha256=$hash bytes=$bytes lines=$lines path=$file" >&2
}

rm -f "$GENERATED"

echo "[opt2-cli-gate] build release opt2 compiler ($NL_BOOTSTRAP_TARGET)"
if ! run_with_heartbeat_capture \
    "build release opt2 compiler" \
    "$BUILD_STDOUT" \
    "$BUILD_STDERR" \
    "$COMPILER" build \
    --manifest-path typelisp.pkg \
    --profile release \
    --opt-level 2 \
    --target "$NL_BOOTSTRAP_TARGET" \
    --stdlib-root stdlib \
    --stdlib-root src; then
    print_log_pair "opt2-cli-gate build failed" "$BUILD_STDOUT" "$BUILD_STDERR"
    exit 1
fi

if [ ! -s "$GENERATED" ]; then
    print_log_pair "opt2-cli-gate build output" "$BUILD_STDOUT" "$BUILD_STDERR"
    echo "[opt2-cli-gate] generated compiler is missing or empty: $GENERATED" >&2
    exit 1
fi
if [ ! -x "$GENERATED" ]; then
    chmod +x "$GENERATED" 2>/dev/null || true
fi
if [ ! -x "$GENERATED" ]; then
    echo "[opt2-cli-gate] generated compiler is not executable: $GENERATED" >&2
    exit 1
fi

echo "[opt2-cli-gate] generated compiler compiles src/main.tl at opt2"
if ! run_with_heartbeat_capture \
    "opt2 compiler compiles cli.tl" \
    "$COMPILE_STDOUT" \
    "$COMPILE_STDERR" \
    "$GENERATED" compile src/main.tl \
    -o "$ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --opt-level 2 \
    --stdlib-root stdlib \
    --stdlib-root src; then
    print_log_pair "opt2-cli-gate compile failed" "$COMPILE_STDOUT" "$COMPILE_STDERR"
    exit 1
fi

if [ ! -s "$ASM" ]; then
    print_log_pair "opt2-cli-gate compile output" "$COMPILE_STDOUT" "$COMPILE_STDERR"
    echo "[opt2-cli-gate] opt2 compiler did not emit assembly: $ASM" >&2
    exit 1
fi

echo "[opt2-cli-gate] wrote $ASM"

# Correctness cross-fixpoint. The crash gate above only proves the opt2-built
# compiler does not crash and emits non-empty assembly; it cannot see a
# miscompile that still produces output (#2921: the opt2 pipeline corrupted
# constant division when inlined into magic-division, garbling every constant
# `/` and `%`). A CORRECT opt2-built compiler must emit byte-identical opt1
# assembly to the opt1-built compiler it was built from, so we compare
# opt2-built@opt1 against opt1-built@opt1 over src/main.tl. No second bootstrap:
# this reuses $GENERATED (built above) plus two single-file compiles.
REF_OPT1="$WORKDIR/cli-opt1-ref.s"
CROSS_OPT1="$WORKDIR/cli-opt2built-opt1.s"
REF_STDOUT="$WORKDIR/ref.stdout"
REF_STDERR="$WORKDIR/ref.stderr"
CROSS_STDOUT="$WORKDIR/cross.stdout"
CROSS_STDERR="$WORKDIR/cross.stderr"

echo "[opt2-cli-gate] reference: opt1-built compiler compiles src/main.tl at opt1"
if ! run_with_heartbeat_capture \
    "opt1-built compiler compiles cli.tl at opt1" \
    "$REF_STDOUT" \
    "$REF_STDERR" \
    "$COMPILER" compile src/main.tl \
    -o "$REF_OPT1" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --opt-level 1 \
    --stdlib-root stdlib \
    --stdlib-root src; then
    print_log_pair "opt2-cli-gate reference compile failed" "$REF_STDOUT" "$REF_STDERR"
    exit 1
fi

echo "[opt2-cli-gate] cross: opt2-built compiler compiles src/main.tl at opt1"
if ! run_with_heartbeat_capture \
    "opt2-built compiler compiles cli.tl at opt1" \
    "$CROSS_STDOUT" \
    "$CROSS_STDERR" \
    "$GENERATED" compile src/main.tl \
    -o "$CROSS_OPT1" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --opt-level 1 \
    --stdlib-root stdlib \
    --stdlib-root src; then
    print_log_pair "opt2-cli-gate cross compile failed" "$CROSS_STDOUT" "$CROSS_STDERR"
    exit 1
fi

if [ ! -s "$REF_OPT1" ] || [ ! -s "$CROSS_OPT1" ]; then
    echo "[opt2-cli-gate] cross-fixpoint compile produced empty assembly" >&2
    exit 1
fi

if ! cmp -s "$REF_OPT1" "$CROSS_OPT1"; then
    echo "[opt2-cli-gate] CROSS-FIXPOINT MISMATCH: the opt2-built compiler emits" >&2
    echo "[opt2-cli-gate] different opt1 assembly than the opt1-built compiler it" >&2
    echo "[opt2-cli-gate] was built from - an opt2 self-build miscompile (#2921 class)." >&2
    echo "[opt2-cli-gate] fingerprints:" >&2
    print_asm_fingerprint "reference (opt1-built @opt1)" "$REF_OPT1"
    print_asm_fingerprint "cross     (opt2-built @opt1)" "$CROSS_OPT1"
    if command -v diff >/dev/null 2>&1; then
        diff -u "$REF_OPT1" "$CROSS_OPT1" | sed -n '1,120p' >&2 || true
    else
        cmp -l "$REF_OPT1" "$CROSS_OPT1" | sed -n '1,80p' >&2 || true
    fi
    exit 1
fi
echo "[opt2-cli-gate] cross-fixpoint holds (opt2-built @opt1 == opt1-built @opt1)"

echo "opt2 cli regression check passed"
