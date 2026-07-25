#!/usr/bin/env sh
set -eu

# Build a producer and consumer as separate packages, then prove that the
# consumer selected TLCI-described private SPMD entry points and linked them
# from the producer archive instead of regenerating helper bodies locally.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

HOST_OS=linux
EXE_SUFFIX=
ARCHIVE_PREFIX=lib
ARCHIVE_SUFFIX=.a
case "$(uname -s)" in
    Linux*) ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        EXE_SUFFIX=.exe
        ARCHIVE_PREFIX=
        ARCHIVE_SUFFIX=.lib
        ;;
    *)
        echo "spmd package-call verification is unsupported on this host" >&2
        exit 1
        ;;
esac

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

PRODUCER="$ROOT/tests/spmd/package_callable"
CONSUMER="$ROOT/tests/spmd/package_consumer"
PROFILE=release
PRODUCER_TARGET="$PRODUCER/target/$PROFILE"
CONSUMER_TARGET="$CONSUMER/target/$PROFILE"
PRODUCER_ASM="$PRODUCER_TARGET/spmd_fixture.s"
PRODUCER_ARCHIVE="$PRODUCER_TARGET/${ARCHIVE_PREFIX}spmd_fixture$ARCHIVE_SUFFIX"
PRODUCER_TLCI="$PRODUCER_TARGET/spmd_fixture.tlci"
CONSUMER_ASM="$CONSUMER_TARGET/spmd_consumer.s"
CONSUMER_BIN="$CONSUMER_TARGET/spmd_consumer$EXE_SUFFIX"

fail() {
    echo "spmd-package-calls: $*" >&2
    exit 1
}

run_consumer() {
    mode=$1
    set +e
    "$CONSUMER_BIN"
    code=$?
    set -e
    [ "$code" -eq 42 ] || fail "$mode consumer exited $code, expected 42"
}

verify_mode() {
    mode=$1
    execute=$2
    rm -rf "$PRODUCER/target" "$CONSUMER/target"

    "$COMPILER" build \
        --manifest-path "$CONSUMER/typelisp.pkg" \
        --profile "$PROFILE" \
        --backend-mode "$mode"

    [ -s "$PRODUCER_ASM" ] || fail "$mode producer assembly is missing"
    [ -s "$PRODUCER_ARCHIVE" ] || fail "$mode producer archive is missing"
    [ -s "$PRODUCER_TLCI" ] || fail "$mode producer TLCI is missing"
    [ -s "$CONSUMER_ASM" ] || fail "$mode consumer assembly is missing"
    [ -x "$CONSUMER_BIN" ] || fail "$mode consumer executable is missing"

    grep -E 'call[q]? .*_tl_.*spmd_pkg_' "$CONSUMER_ASM" >/dev/null \
        || fail "$mode consumer does not call an imported package helper"
    grep -a -E 'spmd_pkg_' "$PRODUCER_ARCHIVE" >/dev/null \
        || fail "$mode producer archive does not define a package helper"
    if grep -E '^\.globl .*spmd_pkg_' "$CONSUMER_ASM" >/dev/null; then
        fail "$mode consumer regenerated a package helper locally"
    fi

    if [ "$execute" = yes ]; then
        run_consumer "$mode"
        echo "spmd-package-calls: $mode build/link/run passed"
    else
        echo "spmd-package-calls: $mode build/link passed; execution skipped"
    fi
}

verify_mode scalar yes

SIMD_ISAS=$(sh "$ROOT/scripts/detect-simd-isa.sh" | tr -d '\r')
if printf '%s\n' "$SIMD_ISAS" | grep -qx avx512; then
    AVX512_EXECUTE=yes
else
    AVX512_EXECUTE=no
fi
verify_mode avx512 "$AVX512_EXECUTE"
grep -E '(%zmm|%k[0-7])' "$CONSUMER_ASM" >/dev/null \
    || fail "avx512 consumer assembly has no vector/opmask operands"
if grep -E 'vpbroadcastd .*%ymm' "$PRODUCER_ASM" >/dev/null; then
    fail "avx512 uniform i64 package helper used a dword/ymm splat"
fi
