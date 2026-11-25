#!/usr/bin/env sh
set -eu

# check-opt2-cli-regression.sh - bounded opt2-generated compiler gate.
#
# Builds the repository root package as a release opt2 compiler (from the
# converged opt2-built compiler in TYPELISP_BIN), then checks two things WITHOUT
# a second bootstrap:
#   1. crash gate: the opt2-built compiler can compile src/main.tl at opt2 to
#      non-empty assembly.
#   2. correctness cross-fixpoint: the opt2-built compiler must emit
#      byte-identical opt1 assembly to the validated reference compiler.
#      A miscompile in the opt2 self-build still produces non-empty output,
#      so the crash gate alone cannot see it; the cross-fixpoint diff can.
#      Linux CI reuses the stage4 opt1 output already validated by
#      check-build-invariance.sh; standalone and Windows invocations compile
#      that reference locally.
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

REFERENCE_SUPPLIED=0
REF_OPT1="$WORKDIR/cli-opt1-ref.s"
if [ "${TYPELISP_OPT2_CLI_REFERENCE_ASM+x}" = x ]; then
    REFERENCE_SUPPLIED=1
    REF_OPT1=$TYPELISP_OPT2_CLI_REFERENCE_ASM
    if [ -z "$REF_OPT1" ]; then
        echo "[opt2-cli-gate] supplied opt1 reference path is empty" >&2
        exit 2
    fi
    case "$REF_OPT1" in
        /* | [A-Za-z]:[/\\]*) ;;
        *) REF_OPT1="$ROOT/$REF_OPT1" ;;
    esac
    if [ ! -s "$REF_OPT1" ]; then
        echo "[opt2-cli-gate] supplied opt1 reference is missing or empty: $REF_OPT1" >&2
        exit 1
    fi
fi

GENERATED="$ROOT/target/release/typelisp$NL_BIN_EXT"
ASM="$WORKDIR/cli-opt2.s"
BUILD_STDOUT="$WORKDIR/build.stdout"
BUILD_STDERR="$WORKDIR/build.stderr"
COMPILE_STDOUT="$WORKDIR/compile.stdout"
COMPILE_STDERR="$WORKDIR/compile.stderr"
OPTIMIZER_STDOUT="$WORKDIR/optimizer-tests.stdout"
OPTIMIZER_STDERR="$WORKDIR/optimizer-tests.stderr"

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
mkdir -p "$WORKDIR/work-smoke"

CROSS_OPT1="$WORKDIR/cli-opt2built-opt1.s"
REF_STDOUT="$WORKDIR/ref.stdout"
REF_STDERR="$WORKDIR/ref.stderr"
CROSS_STDOUT="$WORKDIR/cross.stdout"
CROSS_STDERR="$WORKDIR/cross.stderr"

ACTIVE_BG_PIDS=
cleanup_bg_pids() {
    for _bg_pid in $ACTIVE_BG_PIDS; do
        kill "$_bg_pid" 2>/dev/null || true
    done
    for _bg_pid in $ACTIVE_BG_PIDS; do
        wait "$_bg_pid" 2>/dev/null || true
    done
    ACTIVE_BG_PIDS=
}
trap 'cleanup_bg_pids' EXIT
trap 'cleanup_bg_pids; exit 1' HUP INT TERM

# Phase 1: build the release opt2 compiler concurrently with the independent
# optimizer inline tests (and, on Windows/standalone runs without a supplied
# reference assembly, the converged reference @opt1 compile). Both workers stay
# within the gate's 7680 MiB budget while keeping isolated outputs/workdirs.
echo "[opt2-cli-gate] build release opt2 compiler ($NL_BOOTSTRAP_TARGET) alongside optimizer inline tests at opt2"
if [ "$REFERENCE_SUPPLIED" -eq 1 ]; then
    echo "[opt2-cli-gate] reference: reuse validated build-invariance stage4 src/main @ opt1 assembly"
    echo "[opt2-cli-gate] reference path: $REF_OPT1"
else
    echo "[opt2-cli-gate] reference: converged compiler compiles src/main.tl at opt1 (after optimizer inline tests)"
fi

(
    scripts/run-memory-bounded.sh --limit-mib 8192 \
        --report "$WORKDIR/build.memory" -- \
        "$COMPILER" build \
        --manifest-path typelisp.pkg \
        --profile release \
        --opt-level 2 \
        --target "$NL_BOOTSTRAP_TARGET" \
        --stdlib-root stdlib \
        --stdlib-root src \
        >"$BUILD_STDOUT" 2>"$BUILD_STDERR"
) &
_pid_build=$!

(
    optimizer_status=0
    (
        cd "$WORKDIR/work-smoke" &&
        "$COMPILER" test "$ROOT/src/tests/compiler_optimize_smoke.tl" \
            --stdlib-root "$ROOT/stdlib" \
            --stdlib-root "$ROOT/src" \
            --opt-level 2
    ) >"$OPTIMIZER_STDOUT" 2>"$OPTIMIZER_STDERR" || optimizer_status=$?
    printf '%s\n' "$optimizer_status" > "$WORKDIR/optimizer.status"
    [ "$optimizer_status" -eq 0 ] || exit "$optimizer_status"
    if [ "$REFERENCE_SUPPLIED" -eq 0 ]; then
        ref_status=0
        "$COMPILER" compile src/main.tl \
            -o "$REF_OPT1" \
            --target "$NL_BOOTSTRAP_TARGET" \
            $(native_target_cfg_args) \
            --opt-level 1 \
            --stdlib-root stdlib \
            --stdlib-root src \
            >"$REF_STDOUT" 2>"$REF_STDERR" || ref_status=$?
        printf '%s\n' "$ref_status" > "$WORKDIR/ref.status"
        [ "$ref_status" -eq 0 ] || exit "$ref_status"
    fi
) &
_pid_aux=$!
ACTIVE_BG_PIDS="$_pid_build $_pid_aux"

_rc_build=0
_rc_aux=0
wait "$_pid_build" || _rc_build=$?
wait "$_pid_aux" || _rc_aux=$?
ACTIVE_BG_PIDS=

optimizer_status=$(cat "$WORKDIR/optimizer.status" 2>/dev/null || printf '1')
if [ "$optimizer_status" -ne 0 ]; then
    print_log_pair \
        "opt2 optimizer inline tests failed (status $optimizer_status)" \
        "$OPTIMIZER_STDOUT" \
        "$OPTIMIZER_STDERR"
    exit 1
fi
if [ "$REFERENCE_SUPPLIED" -eq 0 ]; then
    ref_status=$(cat "$WORKDIR/ref.status" 2>/dev/null || printf '1')
    if [ "$ref_status" -ne 0 ]; then
        print_log_pair "opt2-cli-gate reference compile failed" "$REF_STDOUT" "$REF_STDERR"
        exit 1
    fi
fi
if [ "$_rc_aux" -ne 0 ]; then
    echo "[opt2-cli-gate] auxiliary worker failed (status $_rc_aux)" >&2
    exit 1
fi
if [ "$_rc_build" -ne 0 ]; then
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

# Phase 2: run the crash gate ($GENERATED@opt2) and cross-fixpoint compile
# ($GENERATED@opt1) concurrently. Both read the same immutable $GENERATED
# binary and source tree while writing distinct output paths.
echo "[opt2-cli-gate] generated compiler compiles src/main.tl at opt2 and opt1 concurrently"
"$GENERATED" compile src/main.tl \
    -o "$ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --opt-level 2 \
    --stdlib-root stdlib \
    --stdlib-root src \
    >"$COMPILE_STDOUT" 2>"$COMPILE_STDERR" &
_pid_opt2=$!

"$GENERATED" compile src/main.tl \
    -o "$CROSS_OPT1" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --opt-level 1 \
    --stdlib-root stdlib \
    --stdlib-root src \
    >"$CROSS_STDOUT" 2>"$CROSS_STDERR" &
_pid_opt1=$!
ACTIVE_BG_PIDS="$_pid_opt2 $_pid_opt1"

_rc_opt2=0
_rc_opt1=0
wait "$_pid_opt2" || _rc_opt2=$?
wait "$_pid_opt1" || _rc_opt1=$?
ACTIVE_BG_PIDS=

if [ "$_rc_opt2" -ne 0 ]; then
    print_log_pair "opt2-cli-gate compile failed" "$COMPILE_STDOUT" "$COMPILE_STDERR"
    exit 1
fi
if [ ! -s "$ASM" ]; then
    print_log_pair "opt2-cli-gate compile output" "$COMPILE_STDOUT" "$COMPILE_STDERR"
    echo "[opt2-cli-gate] opt2 compiler did not emit assembly: $ASM" >&2
    exit 1
fi
echo "[opt2-cli-gate] wrote $ASM"

if [ "$_rc_opt1" -ne 0 ]; then
    print_log_pair "opt2-cli-gate cross compile failed" "$CROSS_STDOUT" "$CROSS_STDERR"
    exit 1
fi

if [ ! -s "$REF_OPT1" ] || [ ! -s "$CROSS_OPT1" ]; then
    echo "[opt2-cli-gate] cross-fixpoint compile produced empty assembly" >&2
    exit 1
fi

if ! cmp -s "$REF_OPT1" "$CROSS_OPT1"; then
    echo "[opt2-cli-gate] CROSS-FIXPOINT MISMATCH: the opt2-built compiler emits" >&2
    echo "[opt2-cli-gate] different opt1 assembly than the validated reference" >&2
    echo "[opt2-cli-gate] compiler - an opt2 self-build miscompile (#2921 class)." >&2
    echo "[opt2-cli-gate] fingerprints:" >&2
    print_asm_fingerprint "reference (validated @opt1)" "$REF_OPT1"
    print_asm_fingerprint "cross     (opt2-built @opt1)" "$CROSS_OPT1"
    if command -v diff >/dev/null 2>&1; then
        diff -u "$REF_OPT1" "$CROSS_OPT1" | sed -n '1,120p' >&2 || true
    else
        cmp -l "$REF_OPT1" "$CROSS_OPT1" | sed -n '1,80p' >&2 || true
    fi
    exit 1
fi
echo "[opt2-cli-gate] cross-fixpoint holds (opt2-built @opt1 == validated reference @opt1)"

echo "opt2 cli regression check passed"
