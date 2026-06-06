#!/usr/bin/env sh
set -eu

# build-stage0.sh - build the published self-hosted stage0 binary from a seed.
#
# Given a seed compiler (the previously published stage0, fetched via
# scripts/fetch-stage0.sh), compile selfhost/cli.tl to assembly and assemble +
# link it into the next stage0 binary using the host toolchain (as/ld on Linux,
# clang + MSVC link.exe on Windows). This is the no-Rust self-perpetuation step
# used by .github/workflows/bootstrap-stage0.yml: each published stage0 builds
# its successor.
#
# This script uses `compile` + the native link path, matching
# scripts/check-bootstrap-fixpoint.sh, so stage0 publication does not depend on
# an already-working `build` command in the seed compiler.
#
# usage: scripts/build-stage0.sh <seed-compiler> <output-binary>

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <seed-compiler> <output-binary>" >&2
    exit 2
fi

SEED=$1
OUT=$2

if [ ! -x "$SEED" ]; then
    echo "seed compiler is not executable: $SEED" >&2
    exit 1
fi

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

WORKDIR="$ROOT/target/build-stage0"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
mkdir -p "$(dirname -- "$OUT")"

ASM="$WORKDIR/cli.s"
OBJ="$WORKDIR/cli.$NL_OBJ_EXT"
COMPILE_STDOUT="$WORKDIR/compile.stdout"
COMPILE_STDERR="$WORKDIR/compile.stderr"

echo "[build-stage0] compile selfhost/cli.tl with seed ($NL_BOOTSTRAP_TARGET)"
if ! run_with_heartbeat_capture "compile cli.tl" "$COMPILE_STDOUT" "$COMPILE_STDERR" \
    "$SEED" compile selfhost/cli.tl -o "$ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib --stdlib-root selfhost --opt-level 1; then
    echo "[build-stage0] seed compiler failed while compiling selfhost/cli.tl" >&2
    echo "[build-stage0] compiler stdout:" >&2
    sed 's/^/  /' "$COMPILE_STDOUT" >&2 || true
    echo "[build-stage0] compiler stderr:" >&2
    sed 's/^/  /' "$COMPILE_STDERR" >&2 || true
    exit 1
fi
cat "$COMPILE_STDOUT"
cat "$COMPILE_STDERR" >&2
[ -s "$ASM" ] || {
    echo "[build-stage0] seed did not emit assembly for selfhost/cli.tl" >&2
    exit 1
}

assemble_and_link "stage0" "$ASM" "$OBJ" "$OUT"

if [ "$NL_HOST_OS" = linux ] && command -v strip >/dev/null 2>&1; then
    strip "$OUT"
fi

if [ ! -s "$OUT" ]; then
    echo "[build-stage0] output binary is empty: $OUT" >&2
    exit 1
fi

echo "[build-stage0] built $OUT"
