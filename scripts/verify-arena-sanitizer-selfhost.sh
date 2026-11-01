#!/usr/bin/env sh
# verify-arena-sanitizer-selfhost.sh - the compiler's own workloads under the
# arena sanitizer (#7872; #8449 item 10).
#
# Builds the converged compiler again with the bootstrap's stage2 flags plus
# --cfg compiler-arena-sanitizer, which enables the runtime's retirement
# quarantine before global initializers: destroyed and dropped arena chunks
# and whole rewound pages stay reserved but inaccessible, so a stale access to
# them faults. The instrumented compiler then runs, each under the 8 GiB
# sanitizer workload cap of #7872:
#   - a check of the compiler itself;
#   - an opt1 self-compile, whose assembly must equal the ordinary compiler's
#     (the instrumentation must not change what the compiler emits);
#   - one batch typecheck of every stdlib inline-test file, which repeats
#     driver sessions and retires their scratch owners in one process.
# The embedded stdlib image validated by the embedded-stdlib-tlci-image gate
# is reused, so macros take the production native-comptime route.
#
# Limits: partial-page poison, suballocation and arena-to-arena address reuse
# are not detected by page protection; tools/ownership-model's allocation
# model covers those cases. Stack frames and ABI homes are outside the
# sanitizer. The runtime's fault modes themselves are the native-manifest
# arena_sanitizer_* cases. Linux only: the Windows decommit route compiles
# and assembles but has not been executed natively.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
[ "$NL_HOST_OS" = linux ] || fail "arena sanitizer self-host runs on Linux only"
configure_toolchain
COMPILER=${TYPELISP_BIN:?arena sanitizer self-host requires TYPELISP_BIN}
WORKDIR="$ROOT/target/arena-sanitizer-selfhost"
mkdir -p "$WORKDIR"
LIMIT_MIB=8192

for payload in \
    target/embedded-stdlib-tlci/stdlib.tlci \
    target/embedded-stdlib-tlci/stdlib.tlci.tlch \
    target/embedded-stdlib-tlci/modules.txt \
    target/embedded-stdlib-tlci/prelude-surface-linux.rodata \
    target/embedded-stdlib-tlci/source-hash.txt; do
    [ -s "$payload" ] || fail "validated embedded tlci input is missing: $payload"
done
PRODUCER_IDENTITY=$("$COMPILER" --producer-identity 2>/dev/null) ||
    fail "compiler reported no producer identity"
printf '%s\n' "$PRODUCER_IDENTITY" | grep -Eq '^[0-9a-f]{40}$' ||
    fail "compiler reported malformed producer identity: $PRODUCER_IDENTITY"
mkdir -p target/build-stage0
COMPILER_COMMIT=$("$COMPILER" --version | awk 'NR == 1 && $1 == "typelisp" { print $2 }')
printf '%s\n' "$COMPILER_COMMIT" | grep -Eq '^[0-9a-f]{40}$' ||
    fail "compiler reported malformed commit: $COMPILER_COMMIT"
printf '%s' "$COMPILER_COMMIT" > target/build-stage0/git-hash.txt
printf '%s' "$PRODUCER_IDENTITY" > target/build-stage0/tree-hash.txt

# bounded PHASE COMMAND...: run under the workload cap; stdout and stderr go
# to PHASE files. A cap, timeout or crash (a sanitizer fault is SIGSEGV, exit
# 139) fails the gate with the phase's artifacts.
bounded() {
    _phase=$1
    shift
    rm -f "$WORKDIR/$_phase.report" "$WORKDIR/$_phase.stdout" \
        "$WORKDIR/$_phase.stderr"
    _status=0
    "$ROOT/scripts/run-memory-bounded.sh" --limit-mib "$LIMIT_MIB" \
        --timeout-seconds 1800 --report "$WORKDIR/$_phase.report" \
        -- sh -c 'out=$1; err=$2; shift 2; exec "$@" >"$out" 2>"$err"' \
        sh "$WORKDIR/$_phase.stdout" "$WORKDIR/$_phase.stderr" "$@" \
        > "$WORKDIR/$_phase.wrapper.stdout" \
        2> "$WORKDIR/$_phase.wrapper.stderr" || _status=$?
    if [ "$_status" -ne 0 ] ||
        ! grep -Fx reason=success "$WORKDIR/$_phase.report" >/dev/null; then
        cat "$WORKDIR/$_phase.stdout" "$WORKDIR/$_phase.stderr" \
            "$WORKDIR/$_phase.wrapper.stderr" >&2 || true
        fail "$_phase failed with status $_status; artifacts: $WORKDIR"
    fi
    echo "[arena-sanitizer] $_phase: $(grep -E '^(peak_memory_bytes|wall_ms)=' \
        "$WORKDIR/$_phase.report" | tr '\n' ' ')"
}

# native_target_cfg_args emits only fixed, whitespace-free flag tokens.
# shellcheck disable=SC2046
bounded build-instrumented "$COMPILER" compile src/main.tl \
    -o "$WORKDIR/sanitized.s" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --cfg compiler-build-identity \
    --cfg embedded-stdlib-tlci --cfg compiler-arena-sanitizer \
    --stdlib-root stdlib --stdlib-root src --opt-level 2
grep -F 'call tl_arena_sanitize_enable' "$WORKDIR/sanitized.s" >/dev/null ||
    fail "instrumented compiler does not enable the arena sanitizer"
assemble_and_link arena-sanitizer-compiler "$WORKDIR/sanitized.s" \
    "$WORKDIR/sanitized.$NL_OBJ_EXT" "$WORKDIR/sanitized$NL_BIN_EXT" \
    > "$WORKDIR/link.stdout"
SANITIZED="$WORKDIR/sanitized$NL_BIN_EXT"

bounded check-compiler "$SANITIZED" check src/main.tl \
    --stdlib-root stdlib --stdlib-root src
grep -Fx 'Type checking passed!' "$WORKDIR/check-compiler.stdout" >/dev/null ||
    fail "instrumented check of the compiler did not pass"

# shellcheck disable=SC2046
bounded selfhost-instrumented "$SANITIZED" compile src/main.tl \
    -o "$WORKDIR/selfhost-instrumented.s" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src \
    --opt-level 1
# shellcheck disable=SC2046
bounded selfhost-ordinary "$COMPILER" compile src/main.tl \
    -o "$WORKDIR/selfhost-ordinary.s" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib --stdlib-root src \
    --opt-level 1
cmp "$WORKDIR/selfhost-instrumented.s" "$WORKDIR/selfhost-ordinary.s" ||
    fail "instrumented self-compile emitted different assembly"

find stdlib -name '*.tl' ! -path 'stdlib/tests/*' | LC_ALL=C sort | while read -r source; do
    if grep -Eq '\((test|cfg test)[[:space:])]' "$source"; then
        printf '%s\n' "$source"
    fi
done > "$WORKDIR/inline-tests.txt"
[ -s "$WORKDIR/inline-tests.txt" ] || fail "no stdlib inline-test files found"
bounded inline-test-batch "$SANITIZED" test --check \
    --batch "$WORKDIR/inline-tests.txt" --stdlib-root stdlib --stdlib-root src
grep -E '^TypeLisp test batch typecheck passed: [0-9]+ test\(s\) in [0-9]+ file\(s\)$' \
    "$WORKDIR/inline-test-batch.stdout" >/dev/null ||
    fail "instrumented inline-test batch did not pass"

echo "arena sanitizer self-host passed: compiler check, identical opt1 self-compile, $(wc -l < "$WORKDIR/inline-tests.txt" | tr -d ' ') inline-test files in one session"
