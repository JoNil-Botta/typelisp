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
# The seed must be a stage0 published on or after 2026-08-30. There are no
# compatibility bridges for older seeds: the seed compiles the current sources
# directly (docs/testing-and-bootstrap.md).
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

# Normalize a caller-provided relative seed path while at ROOT.
case "$SEED" in
    /* | [A-Za-z]:[\\/]*) ;;
    *) SEED="$ROOT/$SEED" ;;
esac

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain
. "$ROOT/scripts/lib-build-provenance.sh"

WORKDIR="$ROOT/target/build-stage0"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
mkdir -p "$(dirname -- "$OUT")"

COMPILE_STDOUT="$WORKDIR/compile.stdout"
COMPILE_STDERR="$WORKDIR/compile.stderr"
VERSION_STDOUT="$WORKDIR/version.stdout"
VERSION_STDERR="$WORKDIR/version.stderr"
BUILD_GIT_HASH=$(build_provenance_hash "$0")
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

# Iterate to the converged stage and publish that. The seed is the previously
# published stage0, so a backend codegen fix can take two self-host rounds to
# propagate; the published binary is stage4 -- byte-identical to the converged
# stage3 (scripts/check-bootstrap-fixpoint.sh) -- not the seed's one-shot output,
# so it never ships the seed's unconverged codegen. Built at --opt-level 2.
STAGES=4
PREV="$SEED"
case "${TYPELISP_STAGE0_SIZE_REPORT:-0}" in
    0 | 1) ;;
    *)
        echo "TYPELISP_STAGE0_SIZE_REPORT must be 0 or 1" >&2
        exit 2
        ;;
esac

i=1
while [ "$i" -le "$STAGES" ]; do
    STAGE_PRODUCER=$PREV
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
        # Stage2 and later contain the trusted image; native stdlib macro
        # routing is the default policy of an embedded-stdlib-tlci build.
        EMBEDDED_STDLIB_TLCI_ARGS="--cfg embedded-stdlib-tlci"
    fi
    echo "[build-stage0] stage$i: compile src/main.tl ($NL_BOOTSTRAP_TARGET)"
    if ! run_with_heartbeat_capture "compile stage$i" "$COMPILE_STDOUT" "$COMPILE_STDERR" \
        "$PREV" compile src/main.tl -o "$STAGE_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib --stdlib-root src --opt-level 2 \
        --cfg stage0-build-version $EMBEDDED_STDLIB_TLCI_ARGS; then
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

echo "[build-stage0] retained linked-size attribution object: $STAGE_OBJ"
if [ "${TYPELISP_STAGE0_SIZE_REPORT:-0}" -eq 1 ]; then
    SIZE_REPORT_TEXT="$WORKDIR/size-attribution.txt"
    SIZE_REPORT_TSV="$WORKDIR/size-attribution.tsv"
    scripts/analyze-selfhost-build-asm-size.sh \
        --asm "$STAGE_ASM" \
        --object "$STAGE_OBJ" \
        --binary "$OUT" \
        --target "$NL_BOOTSTRAP_TARGET" \
        --opt-level 2 \
        --producer-binary "$STAGE_PRODUCER" \
        --tsv "$SIZE_REPORT_TSV" \
        > "$SIZE_REPORT_TEXT"
    cat "$SIZE_REPORT_TEXT"
    echo "[build-stage0] size attribution TSV: $SIZE_REPORT_TSV"
fi

echo "[build-stage0] built $OUT"
