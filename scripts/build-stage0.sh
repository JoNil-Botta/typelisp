#!/usr/bin/env sh
set -eu

# build-stage0.sh - build the published self-hosted stage0 binary from a seed.
#
# Given a seed compiler (the previously published stage0, fetched via
# scripts/fetch-stage0.sh), compile src/main.tl to assembly and assemble +
# link it into the next stage0 binary using the host toolchain (as/ld on Linux,
# clang + MSVC link.exe on Windows). This is the self-perpetuation step
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

# The first stage may run from a scratch directory to select the legacy
# prelude, so normalize a caller-provided relative seed path while at ROOT.
case "$SEED" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) SEED="$ROOT/$SEED" ;;
esac

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain
. "$ROOT/scripts/lib-bootstrap-ctfe.sh"

WORKDIR="$ROOT/target/build-stage0"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
mkdir -p "$(dirname -- "$OUT")"

SEED_COMPTIME_VARIANT_BRIDGE_ROOT=$(
    bootstrap_seed_comptime_short_variant_bridge_root \
        "$ROOT" "$SEED" "$WORKDIR"
)
SEED_CAPABILITY_ROOT=$ROOT
if [ -n "$SEED_COMPTIME_VARIANT_BRIDGE_ROOT" ]; then
    SEED_CAPABILITY_ROOT=$SEED_COMPTIME_VARIANT_BRIDGE_ROOT
fi
SEED_CTFE_COMPAT_STDLIB=$(
    bootstrap_seed_ctfe_macro_builders_legacy_stdlib \
        "$SEED_CAPABILITY_ROOT" "$SEED" "$WORKDIR"
)
if [ -n "$SEED_CTFE_COMPAT_STDLIB" ]; then
    echo "[build-stage0] seed lacks current CTFE macro builders; using the legacy prelude for stage1"
else
    echo "[build-stage0] seed supports current CTFE macro builders; using iterative core macros"
fi

COMPILE_STDOUT="$WORKDIR/compile.stdout"
COMPILE_STDERR="$WORKDIR/compile.stderr"
VERSION_STDOUT="$WORKDIR/version.stdout"
VERSION_STDERR="$WORKDIR/version.stderr"
BUILD_GIT_HASH=$(git rev-parse --verify HEAD)
BUILD_GIT_HASH_FILE="$WORKDIR/git-hash.txt"
BUILD_DATE=$(date -u +%Y-%m-%d)
BUILD_DATE_FILE="$WORKDIR/build-date.txt"
RUN_OUT=$OUT
case "$RUN_OUT" in
    */* | *\\* | [A-Za-z]:*) ;;
    *) RUN_OUT="./$RUN_OUT" ;;
esac
printf '%s' "$BUILD_GIT_HASH" > "$BUILD_GIT_HASH_FILE"
printf '%s' "$BUILD_DATE" > "$BUILD_DATE_FILE"

stage_seed_bootstrap_cfg_args() {
    stage_number=$1
    if [ "$stage_number" -eq 1 ]; then
        printf '%s\n' --cfg stage0-seed-bootstrap
    fi
}

# Iterate to the converged stage and publish that. The seed is the previously
# published stage0, so a backend codegen fix can take two self-host rounds to
# propagate; the published binary is stage4 -- byte-identical to the converged
# stage3 (scripts/check-bootstrap-fixpoint.sh) -- not the seed's one-shot output,
# so it never ships the seed's unconverged codegen. Built at --opt-level 2.
STAGES=4
PREV="$SEED"

if [ -n "$SEED_COMPTIME_VARIANT_BRIDGE_ROOT" ]; then
    echo "[build-stage0] seed pins prefixed comptime variants; building a short-variant bridge"
    BRIDGE_DIR="$WORKDIR/comptime-short-variant-seed-bridge"
    BRIDGE_ASM="$BRIDGE_DIR/bridge.s"
    BRIDGE_OBJ="$BRIDGE_DIR/bridge.$NL_OBJ_EXT"
    BRIDGE_BIN="$BRIDGE_DIR/bridge$NL_BIN_EXT"
    BRIDGE_CWD="$BRIDGE_DIR/cwd"
    mkdir -p "$BRIDGE_CWD"
    bridge_compile_failed=0
    if [ -n "$SEED_CTFE_COMPAT_STDLIB" ]; then
        if ! (
            cd "$BRIDGE_CWD"
            run_with_heartbeat_capture \
                "compile short-variant bridge" \
                "$COMPILE_STDOUT" "$COMPILE_STDERR" \
                "$SEED" compile \
                "$SEED_COMPTIME_VARIANT_BRIDGE_ROOT/src/main.tl" \
                -o "$BRIDGE_ASM" \
                --target "$NL_BOOTSTRAP_TARGET" \
                $(native_target_cfg_args) \
                --cfg stage0-seed-bootstrap \
                --stdlib-root "$SEED_COMPTIME_VARIANT_BRIDGE_ROOT/bootstrap/stdlib" \
                --stdlib-root "$SEED_COMPTIME_VARIANT_BRIDGE_ROOT/stdlib" \
                --stdlib-root "$SEED_COMPTIME_VARIANT_BRIDGE_ROOT/src" \
                --opt-level 2
        ); then
            bridge_compile_failed=1
        fi
    else
        if ! run_with_heartbeat_capture \
            "compile short-variant bridge" \
            "$COMPILE_STDOUT" "$COMPILE_STDERR" \
            "$SEED" compile \
            "$SEED_COMPTIME_VARIANT_BRIDGE_ROOT/src/main.tl" \
            -o "$BRIDGE_ASM" \
            --target "$NL_BOOTSTRAP_TARGET" \
            $(native_target_cfg_args) \
            --cfg stage0-seed-bootstrap \
            --stdlib-root "$SEED_COMPTIME_VARIANT_BRIDGE_ROOT/stdlib" \
            --stdlib-root "$SEED_COMPTIME_VARIANT_BRIDGE_ROOT/src" \
            --opt-level 2; then
            bridge_compile_failed=1
        fi
    fi
    if [ "$bridge_compile_failed" -ne 0 ]; then
        echo "[build-stage0] seed failed while compiling the short-variant bridge" >&2
        sed 's/^/  /' "$COMPILE_STDOUT" >&2 || true
        sed 's/^/  /' "$COMPILE_STDERR" >&2 || true
        exit 1
    fi
    assemble_and_link \
        "comptime short-variant bridge" \
        "$BRIDGE_ASM" "$BRIDGE_OBJ" "$BRIDGE_BIN"
    PREV=$BRIDGE_BIN
    SEED_CTFE_COMPAT_STDLIB=
    echo "[build-stage0] short-variant bridge ready; building stage1 from current sources"
fi

i=1
while [ "$i" -le "$STAGES" ]; do
    STAGE_ASM="$WORKDIR/stage$i.s"
    STAGE_OBJ="$WORKDIR/stage$i.$NL_OBJ_EXT"
    if [ "$i" -eq "$STAGES" ]; then
        STAGE_BIN="$OUT"
    else
        STAGE_BIN="$WORKDIR/stage$i$NL_BIN_EXT"
    fi
    EMBEDDED_STDLIB_TLCI_ARGS=
    if [ "$i" -gt 1 ]; then
        scripts/build-embedded-stdlib-tlci.sh \
            "$PREV" target/embedded-stdlib-tlci/stdlib.tlci "$NL_HOST_OS"
        EMBEDDED_STDLIB_TLCI_ARGS="--cfg embedded-stdlib-tlci"
    fi
    echo "[build-stage0] stage$i: compile src/main.tl ($NL_BOOTSTRAP_TARGET)"
    stage_compile_failed=0
    if [ "$i" -eq 1 ] && [ -n "$SEED_CTFE_COMPAT_STDLIB" ]; then
        SEED_BOOTSTRAP_CWD="$WORKDIR/seed-bootstrap-cwd"
        mkdir -p "$SEED_BOOTSTRAP_CWD"
        if ! (
            cd "$SEED_BOOTSTRAP_CWD"
            run_with_heartbeat_capture "compile stage$i" "$COMPILE_STDOUT" "$COMPILE_STDERR" \
                "$PREV" compile "$ROOT/src/main.tl" -o "$STAGE_ASM" \
                --target "$NL_BOOTSTRAP_TARGET" \
                $(native_target_cfg_args) \
                --stdlib-root "$SEED_CTFE_COMPAT_STDLIB" --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" --opt-level 2 \
                --cfg stage0-build-version $(stage_seed_bootstrap_cfg_args "$i") $EMBEDDED_STDLIB_TLCI_ARGS
        ); then
            stage_compile_failed=1
        fi
    else
        if ! run_with_heartbeat_capture "compile stage$i" "$COMPILE_STDOUT" "$COMPILE_STDERR" \
            "$PREV" compile src/main.tl -o "$STAGE_ASM" \
            --target "$NL_BOOTSTRAP_TARGET" \
            $(native_target_cfg_args) \
            --stdlib-root stdlib --stdlib-root src --opt-level 2 \
            --cfg stage0-build-version $(stage_seed_bootstrap_cfg_args "$i") $EMBEDDED_STDLIB_TLCI_ARGS; then
            stage_compile_failed=1
        fi
    fi
    if [ "$stage_compile_failed" -ne 0 ]; then
        echo "[build-stage0] stage$i compiler failed while compiling src/main.tl" >&2
        echo "[build-stage0] compiler stdout:" >&2
        sed 's/^/  /' "$COMPILE_STDOUT" >&2 || true
        echo "[build-stage0] compiler stderr:" >&2
        sed 's/^/  /' "$COMPILE_STDERR" >&2 || true
        exit 1
    fi
    [ -s "$STAGE_ASM" ] || {
        echo "[build-stage0] stage$i emitted no assembly for src/main.tl" >&2
        exit 1
    }
    bootstrap_seed_runtime_small_arena_compat "$STAGE_ASM"
    assemble_and_link "stage$i" "$STAGE_ASM" "$STAGE_OBJ" "$STAGE_BIN"
    PREV="$STAGE_BIN"
    i=$((i + 1))
done

if [ "$NL_HOST_OS" = linux ] && command -v strip >/dev/null 2>&1; then
    strip "$OUT"
fi

if [ ! -s "$OUT" ]; then
    echo "[build-stage0] output binary is empty: $OUT" >&2
    exit 1
fi

if ! "$RUN_OUT" --version > "$VERSION_STDOUT" 2> "$VERSION_STDERR"; then
    echo "[build-stage0] built compiler failed --version" >&2
    echo "[build-stage0] stdout:" >&2
    sed 's/^/  /' "$VERSION_STDOUT" >&2 || true
    echo "[build-stage0] stderr:" >&2
    sed 's/^/  /' "$VERSION_STDERR" >&2 || true
    exit 1
fi
if ! grep -F -- "typelisp $BUILD_GIT_HASH built $BUILD_DATE" "$VERSION_STDOUT" >/dev/null; then
    echo "[build-stage0] built compiler did not report git hash $BUILD_GIT_HASH and build date $BUILD_DATE" >&2
    echo "[build-stage0] stdout:" >&2
    sed 's/^/  /' "$VERSION_STDOUT" >&2 || true
    exit 1
fi
if [ -s "$VERSION_STDERR" ]; then
    echo "[build-stage0] built compiler wrote unexpected --version stderr" >&2
    sed 's/^/  /' "$VERSION_STDERR" >&2 || true
    exit 1
fi

echo "[build-stage0] built $OUT"
