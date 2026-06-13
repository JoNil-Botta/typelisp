#!/usr/bin/env sh
set -eu

# check-opt2-cli-regression.sh - bounded opt2-generated compiler crash gate.
#
# Builds the repository root package as a release opt2 compiler, then verifies
# that generated compiler can compile src/cli.tl at opt2. This protects the
# historical #2515 crash path without running a full second bootstrap.

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

echo "[opt2-cli-gate] generated compiler compiles src/cli.tl at opt2"
if ! run_with_heartbeat_capture \
    "opt2 compiler compiles cli.tl" \
    "$COMPILE_STDOUT" \
    "$COMPILE_STDERR" \
    "$GENERATED" compile src/cli.tl \
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
echo "opt2 cli regression check passed"
