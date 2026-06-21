#!/usr/bin/env sh
set -eu

# debug-1204-repro.sh - AMPLIFIED reproduction of the transient Windows #1204
# segfault (corrupt borrowed-str read in string-eq-borrowed). Builds one
# debug-instrumented stage1 (self-poison + Windows region_reset 0xA5 fill) and
# then loops the crash-prone workloads many times so the rare crash surfaces in
# a single CI run. WER LocalDumps (configured by ci.yml) captures a minidump on
# the crash; the job's artifact upload publishes it.
#
# DEBUG-ONLY: not part of the real CI flow. Remove with the rest of the #1204
# instrumentation once the root cause is fixed.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

WORK="$ROOT/target/dbg1204"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "[repro] fetch published stage0 seed"
scripts/fetch-stage0.sh
SEED="$ROOT/target/stage0/typelisp"
[ "$HOST_OS" = windows ] && SEED="$SEED.exe"

echo "[repro] build debug stage1 (self-poison + Windows poison fill)"
"$SEED" compile src/main.tl -o "$WORK/stage1.s" \
    --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root stdlib --stdlib-root src --opt-level 1
assemble_and_link "stage1" "$WORK/stage1.s" "$WORK/stage1.$OBJ_EXT" "$WORK/stage1$BIN_EXT"
BIN="$WORK/stage1$BIN_EXT"
echo "[repro] debug stage1 ready: $BIN"

# Discover documented files (same policy as verify-doc-tests.sh).
DISC="$WORK/discovered.txt"
: > "$DISC"
for root in stdlib src examples tests; do
    [ -d "$root" ] && find "$root" -type f -name '*.tl' \
        ! -path '*/target/*' ! -path '*/.typelisp-doctest/*'
done | sort | while IFS= read -r f; do
    if grep -Eq '^[[:space:]]*(;#|;:)|```[[:space:]]*(typelisp|tl)([[:space:]]|$)' "$f"; then
        printf '%s\n' "$f" >> "$DISC"
    fi
done
CORPUS=$(ls tests/integration/*.tl stdlib/*.tl 2>/dev/null || true)

# A crash-shaped exit: Windows access violation / illegal instruction (NTSTATUS),
# or POSIX signal codes. A clean diagnostic exit (1) is NOT a crash.
is_crash() {
    case "$1" in
        139 | 134 | 132 | 135) return 0 ;;
        -1073741819 | 3221225477) return 0 ;;
        -1073741795 | 3221225501) return 0 ;;
        *) return 1 ;;
    esac
}

run() {
    # run <label> <cmd...>; on a crash-shaped exit, report + fail the job.
    _lbl=$1
    shift
    set +e
    "$@" > "$WORK/out" 2> "$WORK/err"
    _rc=$?
    set -e
    if is_crash "$_rc"; then
        echo "[repro] *** CRASH rc=$_rc at $_lbl (iter $ITER) ***" >&2
        sed 's/^/  err: /' "$WORK/err" >&2 || true
        ls -la "$ROOT/target/dumps" 2>/dev/null >&2 || true
        exit 1
    fi
    return 0
}

DEADLINE=$(( $(date +%s) + 6000 ))   # ~100 min; job timeout is 120 min
ITER=0
echo "[repro] start amplified loop (deadline ${DEADLINE}s)"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    ITER=$((ITER + 1))
    # Heavy self-compile: maximal string-eq + region_reset churn under the
    # memory-pressured runner (no swap).
    run "self-compile@opt1" "$BIN" compile src/main.tl -o "$WORK/self.s" \
        --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) \
        --stdlib-root stdlib --stdlib-root src --opt-level 1
    run "self-compile@opt2" "$BIN" compile src/main.tl -o "$WORK/self2.s" \
        --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) \
        --stdlib-root stdlib --stdlib-root src --opt-level 2
    # The originally-reported failing operation.
    run "doctest-batch" "$BIN" doc --test --batch "$DISC" --stdlib-root stdlib
    # Many short process invocations: amplify the natural rare crash.
    for f in $CORPUS; do
        set +e
        "$BIN" doc --test "$f" --stdlib-root stdlib > "$WORK/out" 2> "$WORK/err"
        rc=$?
        set -e
        if is_crash "$rc"; then
            echo "[repro] *** CRASH rc=$rc at doc-test $f (iter $ITER) ***" >&2
            sed 's/^/  err: /' "$WORK/err" >&2 || true
            exit 1
        fi
    done
    echo "[repro] iter $ITER ok ($(( DEADLINE - $(date +%s) ))s left, dumps=$(ls "$ROOT/target/dumps"/*.dmp 2>/dev/null | wc -l))"
done
echo "[repro] no crash reproduced in $ITER iteration(s)"
