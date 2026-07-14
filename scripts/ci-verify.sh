#!/usr/bin/env sh
set -eu

# ci-verify.sh - the repository's CI verification gate.
#
# Fetches the published stage0 artifact when TYPELISP_BIN is unset. The seed
# performs the single compiler build of the flow: the stage1->stage2->stage3
# bootstrap fixpoint over src/main.tl, with a stage4 fallback when needed. Every
# remaining gate then runs on the converged compiler (the branch-built full CLI).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"
. "$ROOT/scripts/lib-ci-timing.sh"

usage() {
    cat >&2 <<'EOF'
usage: scripts/ci-verify.sh

Runs the repository's CI verification gate.
If TYPELISP_BIN is unset, downloads stage0-latest with scripts/fetch-stage0.sh.
TYPELISP_BIN is the seed compiler and performs the single compiler build of
the flow: the bootstrap stage1->stage2->stage3 fixpoint over src/main.tl, with
a stage4 fallback when needed. Every remaining gate runs on the converged
bootstrapped compiler.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ "$#" -ne 0 ]; then
    usage
    exit 2
fi

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "CI verification is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

if [ "${TYPELISP_CI_TIMING:-0}" = 1 ]; then
    ci_timing_init "$ROOT/target/ci-timing/$HOST_OS.tsv" "$HOST_OS"
    trap 'ci_timing_summary "$TYPELISP_CI_TIMING_FILE" 10' EXIT
fi

if [ -z "${TYPELISP_BIN:-}" ]; then
    scripts/fetch-stage0.sh
    SEED_TYPELISP_BIN="$ROOT/target/stage0/typelisp"
    if [ "$HOST_OS" = windows ]; then
        SEED_TYPELISP_BIN="$SEED_TYPELISP_BIN.exe"
    fi
else
    SEED_TYPELISP_BIN=$TYPELISP_BIN
fi

ensure_executable() {
    label=$1
    compiler=$2
    if [ ! -f "$compiler" ]; then
        echo "$label compiler does not exist: $compiler" >&2
        exit 1
    fi
    if [ ! -x "$compiler" ]; then
        chmod +x "$compiler" 2>/dev/null || true
    fi
    if [ ! -x "$compiler" ]; then
        echo "$label compiler is not executable: $compiler" >&2
        exit 1
    fi
}

ensure_executable "seed" "$SEED_TYPELISP_BIN"

run_gate() {
    label=$1
    shift
    previous_timing_gate=${TYPELISP_CI_TIMING_GATE:-}
    TYPELISP_CI_TIMING_GATE=$label
    export TYPELISP_CI_TIMING_GATE
    if ci_timing_enabled; then
        ci_timing_set_now_ms
        start=$CI_TIMING_NOW_MS
    else
        start=$(date +%s)
    fi
    case $- in
        *e*) had_errexit=1 ;;
        *) had_errexit=0 ;;
    esac
    echo
    echo "[ci-verify] START $label"
    set +e
    "$@"
    status=$?
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    fi
    if ci_timing_enabled; then
        ci_timing_set_now_ms
        end=$CI_TIMING_NOW_MS
        elapsed_ms=$((end - start))
        elapsed=$((elapsed_ms / 1000))
        ci_timing_record_elapsed all gate "$elapsed_ms" "$status"
    else
        end=$(date +%s)
        elapsed=$((end - start))
    fi
    TYPELISP_CI_TIMING_GATE=$previous_timing_gate
    export TYPELISP_CI_TIMING_GATE
    if [ "$status" -eq 0 ]; then
        echo "[ci-verify] PASS $label (${elapsed}s)"
    else
        echo "[ci-verify] FAIL $label (${elapsed}s, exit $status)" >&2
    fi
    return "$status"
}

run_with_compiler() {
    compiler=$1
    shift
    TYPELISP_BIN=$compiler
    export TYPELISP_BIN
    run_gate "$@"
}

required_gate_unavailable() {
    gate=$1
    shift
    echo >&2
    echo "[ci-verify] ERROR: CI must run every required gate; skipped gates hide compiler regressions." >&2
    echo "[ci-verify] ERROR: unable to run required gate: $gate" >&2
    for detail in "$@"; do
        echo "[ci-verify]   $detail" >&2
    done
    exit 1
}

# Agent/contributor note: do not make CI pass by skipping gates when a PR needs
# a new compiler/runtime capability. Split that work instead: first land the
# compiler/runtime support, then land a follow-up PR that uses the new feature.
# A short green run caused by skipped gates is a CI bug, not a successful check.
#
# NO-RETRY POLICY (#1204): the verify-* gates run each `typelisp` invocation
# exactly once. A crash (segfault / Windows access violation / illegal
# instruction) is a real compiler/runtime bug, NOT transient infra flake — fix
# the bug. Do NOT re-introduce a retry loop or a `VERIFY_*_ATTEMPTS`-style knob
# to retry crashing invocations: that only hides the bug behind a green run, as
# the old #1204 retry masking did for months. (The release-republish retry in
# fetch-stage0.sh is unrelated — it rides out a genuinely transient mutable-asset
# race, not a compiler crash.)

# Generated payload freshness must fail before the expensive bootstrap. The
# exact-source verifier uses only stage0-supported language/runtime surfaces.
run_gate "CI timing helper self-tests" scripts/verify-ci-timing.sh
run_gate \
    "SPMD AVX-512 instruction harness self-tests" \
    scripts/measure-spmd-avx512-instructions.sh \
    --self-test
run_gate \
    "SPMD mode instruction-count harness self-tests" \
    scripts/measure-spmd-mode-instruction-counts.sh \
    --self-test
run_with_compiler \
    "$SEED_TYPELISP_BIN" \
    "embedded stdlib generated payload" \
    scripts/verify-embedded-stdlib-payload.sh

stage2_safety_corpus_supported() {
    compiler=$1
    probe_dir="$ROOT/target/ci-verify-safety-probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    asm="$probe_dir/division_by_zero_trap.s"
    obj="$probe_dir/division_by_zero_trap.o"
    bin="$probe_dir/division_by_zero_trap"

    if ! "$compiler" compile "$ROOT/tests/safety/division_by_zero_trap.tl" \
        --target linux-x86_64 \
        --stdlib-root "$ROOT/stdlib" \
        -o "$asm" \
        > "$probe_dir/compile.stdout" 2> "$probe_dir/compile.stderr"; then
        echo "[ci-verify] stage2 safety probe compile failed"
        sed 's/^/  /' "$probe_dir/compile.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/compile.stderr" >&2 || true
        return 1
    fi
    if ! as "$asm" -o "$obj" > "$probe_dir/assemble.stdout" 2> "$probe_dir/assemble.stderr"; then
        echo "[ci-verify] stage2 safety probe assemble failed"
        sed 's/^/  /' "$probe_dir/assemble.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/assemble.stderr" >&2 || true
        return 1
    fi
    if ! ld "$obj" -o "$bin" -static -e "$(linux_entry_symbol_for_asm "$asm")" \
        > "$probe_dir/link.stdout" 2> "$probe_dir/link.stderr"; then
        echo "[ci-verify] stage2 safety probe link failed"
        sed 's/^/  /' "$probe_dir/link.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/link.stderr" >&2 || true
        return 1
    fi

    set +e
    "$bin" > "$probe_dir/run.stdout" 2> "$probe_dir/run.stderr"
    probe_status=$?
    set -e
    if [ "$probe_status" -ne 135 ]; then
        echo "[ci-verify] stage2 safety probe expected guarded div-zero exit 135, got $probe_status"
        sed 's/^/  /' "$probe_dir/run.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/run.stderr" >&2 || true
        return 1
    fi
    if ! grep -F "tl: integer division or remainder error" "$probe_dir/run.stderr" >/dev/null; then
        echo "[ci-verify] stage2 safety probe missing guarded div-zero stderr" >&2
        sed 's/^/  /' "$probe_dir/run.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/run.stderr" >&2 || true
        return 1
    fi
    return 0
}

# Windows analog of stage2_safety_corpus_supported: can the bootstrapped Windows
# stage1 compile -> clang -> lld-link -> RUN a native program? Uses a normal
# exit-42 fixture (not a trap: bare hardware traps surface as Windows structured
# exceptions whose shell exit code is unstable under MSYS/Git Bash).
stage2_can_compile_native_windows() {
    compiler=$1
    probe_dir="$ROOT/target/ci-verify-win-probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    asm="$probe_dir/probe.s"
    obj="$probe_dir/probe.obj"
    bin="$probe_dir/probe.exe"
    if ! "$compiler" compile "$ROOT/tests/safety/integer_wrap_cast_defined.tl" \
        --target windows-x86_64 --stdlib-root "$ROOT/stdlib" -o "$asm" \
        > "$probe_dir/compile.out" 2>&1; then
        echo "[ci-verify] windows stage2 compile-native probe compile failed"
        sed 's/^/  /' "$probe_dir/compile.out" >&2 || true
        return 1
    fi
    if ! clang --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj" \
        > "$probe_dir/asm.out" 2>&1; then
        echo "[ci-verify] windows stage2 compile-native probe assemble failed"
        sed 's/^/  /' "$probe_dir/asm.out" >&2 || true
        return 1
    fi
    if ! lld-link -NOLOGO "$(cygpath -aw "$obj")" "-OUT:$(cygpath -aw "$bin")" \
        -SUBSYSTEM:CONSOLE -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib \
        > "$probe_dir/link.out" 2>&1; then
        echo "[ci-verify] windows stage2 compile-native probe link failed"
        sed 's/^/  /' "$probe_dir/link.out" >&2 || true
        return 1
    fi
    set +e
    "$bin" < /dev/null > "$probe_dir/run.out" 2>&1
    probe_status=$?
    set -e
    if [ "$probe_status" -ne 42 ]; then
        echo "[ci-verify] windows stage2 compile-native probe expected exit 42, got $probe_status"
        return 1
    fi
    return 0
}

echo "[ci-verify] host=$HOST_OS seed=$SEED_TYPELISP_BIN"

# The single compiler build of the flow: the seed bootstraps src/main.tl through
# successive stages at opt2 until the compiler's own code converges (normally
# stage2 == stage3, with a stage3 == stage4 fallback). Every gate below runs on
# the resulting converged compiler -
# the branch-built full CLI, handed over via the compatibility-named stage2 path
# file - so the artifact under test is the one the bootstrap just produced. Do
# not add per-gate compiler rebuilds here.
STAGE1_PATH_FILE="$ROOT/target/ci-verify-stage1.path"
STAGE2_PATH_FILE="$ROOT/target/ci-verify-stage2.path"
rm -f "$STAGE1_PATH_FILE" "$STAGE2_PATH_FILE"
TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE=$STAGE1_PATH_FILE
TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE=$STAGE2_PATH_FILE
export TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE
run_gate "bootstrap adaptive control flow" scripts/verify-bootstrap-fixpoint-control.sh
run_gate "bootstrap fixpoint" scripts/check-bootstrap-fixpoint.sh "$SEED_TYPELISP_BIN"
unset TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE
if [ ! -s "$STAGE2_PATH_FILE" ]; then
    required_gate_unavailable "bootstrap fixpoint compiler capture" \
        "bootstrap did not persist a converged compiler path for the downstream gates"
fi
STAGE2_BIN=$(sed -n '1p' "$STAGE2_PATH_FILE")
ensure_executable "bootstrapped compiler" "$STAGE2_BIN"
echo "[ci-verify] every gate runs the converged bootstrapped compiler: $STAGE2_BIN"

# Fail-closed run-capability probe: stage2 must compile -> assemble -> link ->
# RUN a native program before the run-assert tiers below may execute. A failed
# probe is a CI failure, never a reason to omit gates.
if [ "$HOST_OS" = linux ]; then
    if ! stage2_safety_corpus_supported "$STAGE2_BIN"; then
        required_gate_unavailable "Linux stage2 compile->as->ld->run probe" \
            "safety, integration, examples, SPMD, and stdlib run-assert tiers depend on this probe"
    fi
    echo "[ci-verify] stage2 compile->as->ld->run capability confirmed"
else
    if ! stage2_can_compile_native_windows "$STAGE2_BIN"; then
        required_gate_unavailable "Windows stage2 compile->clang->lld-link->run probe" \
            "safety, integration, and examples run-assert tiers depend on this probe"
    fi
    echo "[ci-verify] stage2 compile->clang->lld-link->run capability confirmed"
fi

# The selfhost compile manifest is one of the highest-memory Windows gates.
# Run it before the long format/lint/public-tool stretch; this keeps coverage
# identical while limiting job-level memory pressure before the gate.
# The current cli.tl emits stage1-qualified symbols, so the manifest uses the
# stage1 expectation mode on both hosts.
run_with_compiler "$STAGE2_BIN" "stage2 selfhost compile manifest" env TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1 scripts/verify-selfhost-compile-manifest.sh
# The deterministic assembly gate reuses the manifest's emitted .s as its first
# compile for overlapping sources, so it must run after the manifest gate.
run_with_compiler "$STAGE2_BIN" "stage2 deterministic assembly" env TYPELISP_DETERMINISTIC_ASM_MANIFEST_DIR="$ROOT/target/selfhost-compile-manifest" scripts/check-deterministic-asm.sh
run_with_compiler "$STAGE2_BIN" "TypeLisp source formatting" scripts/check-tl-format.sh
run_with_compiler "$STAGE2_BIN" "TypeLisp source lint" scripts/check-tl-lint.sh
# The freshly bootstrapped compiler (and the programs it builds) must depend on
# no C runtime: kernel32 only on Windows, nothing dynamic on Linux.
run_with_compiler "$STAGE2_BIN" "no-libc dependency guard" scripts/verify-no-libc.sh
run_with_compiler "$STAGE2_BIN" "stage2 cli build/run and chooser smoke" scripts/verify-selfhost-cli-build-run.sh
run_with_compiler "$STAGE2_BIN" "stage2 public tool surface" scripts/verify-public-tools.sh
run_with_compiler "$STAGE2_BIN" "stage2 result-import harness integrity" scripts/verify-result-import-harness.sh
if [ "$HOST_OS" = linux ]; then
    OPT2_REFERENCE_PATH_FILE="$ROOT/target/ci-verify-opt2-reference.path"
    rm -f "$OPT2_REFERENCE_PATH_FILE"
    run_with_compiler \
        "$STAGE2_BIN" \
        "stage2 opt1/opt2 build-invariance" \
        env TYPELISP_BUILD_INVARIANCE_OPT1_REFERENCE_PATH_FILE="$OPT2_REFERENCE_PATH_FILE" \
        scripts/check-build-invariance.sh
    if [ ! -s "$OPT2_REFERENCE_PATH_FILE" ]; then
        required_gate_unavailable "build-invariance opt1 reference handoff" \
            "build-invariance did not publish its validated stage4 src/main @ opt1 assembly path"
    fi
    OPT2_REFERENCE_ASM=$(sed -n '1p' "$OPT2_REFERENCE_PATH_FILE")
    if [ ! -s "$OPT2_REFERENCE_ASM" ]; then
        required_gate_unavailable "build-invariance opt1 reference handoff" \
            "published assembly is missing or empty: $OPT2_REFERENCE_ASM"
    fi
    echo "[ci-verify] opt2 gate reuses build-invariance reference: $OPT2_REFERENCE_ASM"
    run_with_compiler \
        "$STAGE2_BIN" \
        "stage2 opt2-built CLI compile + cross-fixpoint regression" \
        env TYPELISP_OPT2_CLI_REFERENCE_ASM="$OPT2_REFERENCE_ASM" \
        scripts/check-opt2-cli-regression.sh
else
    # Windows has no build-invariance gate, so the opt2 gate retains its
    # standalone reference compile.
    run_with_compiler \
        "$STAGE2_BIN" \
        "stage2 opt2-built CLI compile + cross-fixpoint regression" \
        scripts/check-opt2-cli-regression.sh
fi
run_with_compiler "$STAGE2_BIN" "stage2 SPMD runtime dispatch" scripts/verify-spmd-runtime-dispatch.sh
run_with_compiler "$STAGE2_BIN" "ISPC perfbench loads corpus contract" scripts/verify-ispc-perfbench-loads.sh
run_with_compiler "$STAGE2_BIN" "ISPC perfbench stores corpus contract" scripts/verify-ispc-perfbench-stores.sh
run_with_compiler "$STAGE2_BIN" "stage2 repository doctests" scripts/verify-doc-tests.sh
run_with_compiler "$STAGE2_BIN" "stage2 inline TypeLisp tests" scripts/verify-inline-tests.sh
run_with_compiler "$STAGE2_BIN" "stage2 compile-profile verifier" scripts/verify-compile-profile.sh
run_with_compiler "$STAGE2_BIN" "stage2 allocation-profile verifier" scripts/verify-allocation-profile.sh
run_with_compiler "$STAGE2_BIN" "stage2 codegen target parity" scripts/check-codegen-target-parity.sh
run_with_compiler "$STAGE2_BIN" "stage2 backend target assembly parity" scripts/check-backend-target-asm-parity.sh
run_with_compiler "$STAGE2_BIN" "stage2 PIC relocation verifier" scripts/verify-pic-relocations.sh
run_with_compiler "$STAGE2_BIN" "stage2 safety corpus" scripts/verify-safety-corpus.sh
run_gate "integration manifest validator self-tests" scripts/verify-integration-manifest-validator.sh
run_with_compiler "$STAGE2_BIN" "integration compile-failure diagnostics" scripts/verify-integration.sh --self-test-empty-compile-diagnostic
run_with_compiler "$STAGE2_BIN" "stage2 native integration corpus" scripts/verify-integration.sh
if [ "$HOST_OS" = linux ]; then
    run_with_compiler "$STAGE2_BIN" "stage2 regalloc/backend asm shape gates" scripts/verify-asm-shape-gates.sh
fi
run_with_compiler "$STAGE2_BIN" "stage2 examples" scripts/verify-examples.sh
run_with_compiler "$STAGE2_BIN" "stage2 benchmark comparison correctness" scripts/bench.sh --correctness
run_with_compiler "$STAGE2_BIN" "stage2 optimization corpus correctness" scripts/run-optimization-benchmarks.sh --correctness
run_with_compiler "$STAGE2_BIN" "stage2 optimization corpus opt2 runtime correctness" \
    scripts/run-optimization-benchmarks.sh --correctness --tl-opt-level 2
run_with_compiler "$STAGE2_BIN" "stage2 stdlib modules and fixtures" scripts/verify-stdlib.sh
run_with_compiler "$STAGE2_BIN" "stage2 stdlib selfhost verifier" scripts/verify-stdlib-selfhost.sh
run_with_compiler "$STAGE2_BIN" "stage2 SPMD SIMD comparison" scripts/verify-spmd-simd.sh
run_with_compiler "$STAGE2_BIN" "stage2 SPMD lane identity" scripts/verify-spmd-lane-identity.sh
run_with_compiler "$STAGE2_BIN" "stage2 SPMD broadcast" scripts/verify-spmd-broadcast.sh
DOC_SITE_OUT="$ROOT/target/ci-verify-docs-pages-site"
export DOC_SITE_OUT
run_with_compiler "$STAGE2_BIN" "stage2 docs Pages build path" scripts/verify-doc-site.sh
unset DOC_SITE_OUT

if [ "$HOST_OS" = linux ]; then
    run_with_compiler "$STAGE2_BIN" "stage2 CLI host-action smoke" scripts/check-stage1-wrapper.sh
    run_with_compiler "$STAGE2_BIN" "stage2 stdlib documentation" scripts/verify-stdlib-docs.sh
    if ! command -v valgrind >/dev/null 2>&1; then
        required_gate_unavailable "Linux instruction-count baseline" \
            "valgrind is required on Linux; install valgrind rather than skipping this gate"
    fi
    run_with_compiler "$STAGE2_BIN" "Linux instruction-count baseline" \
        env TYPELISP_IR_CHECK_COMPILER="$STAGE2_BIN" scripts/check-instruction-counts.sh
    run_with_compiler "$STAGE2_BIN" "stage2 native link generated programs" scripts/verify-native-link-linux.sh
else
    run_with_compiler "$STAGE2_BIN" "windows native link build/run" scripts/verify-native-link-windows.sh
    echo
    echo "[ci-verify] Linux-only gates not applicable on Windows:"
    echo "[ci-verify]   opt1/opt2 build-invariance, host-action smoke (as/ld),"
    echo "[ci-verify]   stdlib documentation (doc target selection), instruction"
    echo "[ci-verify]   counts (valgrind), native link generated programs"
    echo "[ci-verify]   (Linux linker inputs)"
fi

echo
echo "CI verification passed"
