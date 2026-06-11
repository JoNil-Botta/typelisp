#!/usr/bin/env sh
set -eu

# ci-verify.sh - CI/local no-Rust compiler gate.
#
# This script intentionally does not build the Rust compiler. It fetches the
# published stage0 artifact when TYPELISP_BIN is unset and guards against
# accidental cargo/rustc fallback by shadowing those commands with failing
# shims. The seed performs the single compiler build of the flow: the
# stage1->stage2->stage3 bootstrap fixpoint over selfhost/cli.tl. Every
# remaining gate then runs on the freshly bootstrapped stage2 compiler (the
# branch-built full CLI).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

usage() {
    cat >&2 <<'EOF'
usage: scripts/ci-verify.sh

Runs the repository's no-Rust verification gate.
If TYPELISP_BIN is unset, downloads stage0-latest with scripts/fetch-stage0.sh.
TYPELISP_BIN is the seed compiler and performs the single compiler build of
the flow: the bootstrap stage1->stage2->stage3 fixpoint over selfhost/cli.tl.
Every remaining gate runs on the bootstrapped stage2 compiler.
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
        echo "no-Rust stage0 verification is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

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

GUARD_DIR="$ROOT/target/no-rust-stage0-guard"
rm -rf "$GUARD_DIR"
mkdir -p "$GUARD_DIR"
cat > "$GUARD_DIR/cargo" <<'EOF'
#!/usr/bin/env sh
echo "ERROR: no-Rust stage0 verification must not invoke cargo" >&2
exit 127
EOF
cp "$GUARD_DIR/cargo" "$GUARD_DIR/rustc"
chmod +x "$GUARD_DIR/cargo" "$GUARD_DIR/rustc"
PATH="$GUARD_DIR:$PATH"
export PATH

run_gate() {
    label=$1
    shift
    start=$(date +%s)
    case $- in
        *e*) had_errexit=1 ;;
        *) had_errexit=0 ;;
    esac
    echo
    echo "[no-rust-stage0] START $label"
    set +e
    "$@"
    status=$?
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    fi
    end=$(date +%s)
    elapsed=$((end - start))
    if [ "$status" -eq 0 ]; then
        echo "[no-rust-stage0] PASS $label (${elapsed}s)"
    else
        echo "[no-rust-stage0] FAIL $label (${elapsed}s, exit $status)" >&2
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
    echo "[no-rust-stage0] ERROR: CI must run every required gate; skipped gates hide compiler regressions." >&2
    echo "[no-rust-stage0] ERROR: unable to run required gate: $gate" >&2
    for detail in "$@"; do
        echo "[no-rust-stage0]   $detail" >&2
    done
    exit 1
}

# Agent/contributor note: do not make CI pass by skipping gates when a PR needs
# a new compiler/runtime capability. Split that work instead: first land the
# compiler/runtime support, then land a follow-up PR that uses the new feature.
# A short green run caused by skipped gates is a CI bug, not a successful check.

stage2_safety_corpus_supported() {
    compiler=$1
    probe_dir="$ROOT/target/no-rust-stage2-safety-probe"
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
        echo "[no-rust-stage0] stage2 safety probe compile failed"
        sed 's/^/  /' "$probe_dir/compile.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/compile.stderr" >&2 || true
        return 1
    fi
    if ! as "$asm" -o "$obj" > "$probe_dir/assemble.stdout" 2> "$probe_dir/assemble.stderr"; then
        echo "[no-rust-stage0] stage2 safety probe assemble failed"
        sed 's/^/  /' "$probe_dir/assemble.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/assemble.stderr" >&2 || true
        return 1
    fi
    if ! ld "$obj" -o "$bin" -static -e "$(linux_entry_symbol_for_asm "$asm")" \
        > "$probe_dir/link.stdout" 2> "$probe_dir/link.stderr"; then
        echo "[no-rust-stage0] stage2 safety probe link failed"
        sed 's/^/  /' "$probe_dir/link.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/link.stderr" >&2 || true
        return 1
    fi

    set +e
    "$bin" > "$probe_dir/run.stdout" 2> "$probe_dir/run.stderr"
    probe_status=$?
    set -e
    if [ "$probe_status" -ne 135 ]; then
        echo "[no-rust-stage0] stage2 safety probe expected guarded div-zero exit 135, got $probe_status"
        sed 's/^/  /' "$probe_dir/run.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/run.stderr" >&2 || true
        return 1
    fi
    if ! grep -F "tl: integer division or remainder error" "$probe_dir/run.stderr" >/dev/null; then
        echo "[no-rust-stage0] stage2 safety probe missing guarded div-zero stderr" >&2
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
    probe_dir="$ROOT/target/no-rust-stage2-win-probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    asm="$probe_dir/probe.s"
    obj="$probe_dir/probe.obj"
    bin="$probe_dir/probe.exe"
    if ! "$compiler" compile "$ROOT/tests/safety/integer_wrap_cast_defined.tl" \
        --target windows-x86_64 --stdlib-root "$ROOT/stdlib" -o "$asm" \
        > "$probe_dir/compile.out" 2>&1; then
        echo "[no-rust-stage0] windows stage2 compile-native probe compile failed"
        sed 's/^/  /' "$probe_dir/compile.out" >&2 || true
        return 1
    fi
    if ! clang --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj" \
        > "$probe_dir/asm.out" 2>&1; then
        echo "[no-rust-stage0] windows stage2 compile-native probe assemble failed"
        sed 's/^/  /' "$probe_dir/asm.out" >&2 || true
        return 1
    fi
    if ! lld-link -NOLOGO "$(cygpath -aw "$obj")" "-OUT:$(cygpath -aw "$bin")" \
        -SUBSYSTEM:CONSOLE -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib \
        > "$probe_dir/link.out" 2>&1; then
        echo "[no-rust-stage0] windows stage2 compile-native probe link failed"
        sed 's/^/  /' "$probe_dir/link.out" >&2 || true
        return 1
    fi
    set +e
    "$bin" < /dev/null > "$probe_dir/run.out" 2>&1
    probe_status=$?
    set -e
    if [ "$probe_status" -ne 42 ]; then
        echo "[no-rust-stage0] windows stage2 compile-native probe expected exit 42, got $probe_status"
        return 1
    fi
    return 0
}

echo "[no-rust-stage0] host=$HOST_OS seed=$SEED_TYPELISP_BIN"

TYPELISP_NO_RUST_STAGE0=1
export TYPELISP_NO_RUST_STAGE0

# The single compiler build of the flow: the seed bootstraps selfhost/cli.tl to
# stage1, stage1 rebuilds it to stage2, and the stage2/stage3 fixpoint must
# hold. Every gate below runs on the resulting stage2 compiler - the
# branch-built full CLI - so the artifact under test is the one the bootstrap
# just produced. Do not add per-gate compiler rebuilds here.
STAGE1_PATH_FILE="$ROOT/target/no-rust-stage0-stage1.path"
STAGE2_PATH_FILE="$ROOT/target/no-rust-stage0-stage2.path"
rm -f "$STAGE1_PATH_FILE" "$STAGE2_PATH_FILE"
TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE=$STAGE1_PATH_FILE
TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE=$STAGE2_PATH_FILE
export TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE
run_gate "bootstrap stage1->stage2->stage3 fixpoint" scripts/check-bootstrap-fixpoint.sh "$SEED_TYPELISP_BIN"
unset TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE TYPELISP_BOOTSTRAP_STAGE2_PATH_FILE
if [ ! -s "$STAGE2_PATH_FILE" ]; then
    required_gate_unavailable "bootstrap fixpoint stage2 capture" \
        "bootstrap did not persist a stage2 compiler path for the downstream gates"
fi
STAGE2_BIN=$(sed -n '1p' "$STAGE2_PATH_FILE")
ensure_executable "stage2" "$STAGE2_BIN"
echo "[no-rust-stage0] every gate runs the freshly bootstrapped stage2 compiler: $STAGE2_BIN"

# Fail-closed run-capability probe: stage2 must compile -> assemble -> link ->
# RUN a native program before the run-assert tiers below may execute. A failed
# probe is a CI failure, never a reason to omit gates.
if [ "$HOST_OS" = linux ]; then
    if ! stage2_safety_corpus_supported "$STAGE2_BIN"; then
        required_gate_unavailable "Linux stage2 compile->as->ld->run probe" \
            "safety, integration, examples, SPMD, and stdlib run-assert tiers depend on this probe"
    fi
    echo "[no-rust-stage0] stage2 compile->as->ld->run capability confirmed"
else
    if ! stage2_can_compile_native_windows "$STAGE2_BIN"; then
        required_gate_unavailable "Windows stage2 compile->clang->lld-link->run probe" \
            "safety, integration, and examples run-assert tiers depend on this probe"
    fi
    echo "[no-rust-stage0] stage2 compile->clang->lld-link->run capability confirmed"
fi

run_with_compiler "$STAGE2_BIN" "TypeLisp source formatting" scripts/check-tl-format.sh
run_with_compiler "$STAGE2_BIN" "TypeLisp source lint" scripts/check-tl-lint.sh
# The freshly bootstrapped compiler (and the programs it builds) must depend on
# no C runtime: kernel32 only on Windows, nothing dynamic on Linux.
run_with_compiler "$STAGE2_BIN" "no-libc dependency guard" scripts/verify-no-libc.sh
run_with_compiler "$STAGE2_BIN" "stage2 cli build/run and chooser smoke" scripts/verify-selfhost-cli-build-run.sh
run_with_compiler "$STAGE2_BIN" "stage2 public tool surface" scripts/verify-public-tools.sh
run_with_compiler "$STAGE2_BIN" "stage2 SPMD runtime dispatch" scripts/verify-spmd-runtime-dispatch.sh
run_with_compiler "$STAGE2_BIN" "stage2 repository doctests" scripts/verify-doc-tests.sh
run_with_compiler "$STAGE2_BIN" "stage2 inline TypeLisp tests" scripts/verify-inline-tests.sh
# The current cli.tl emits stage1-qualified symbols, so the manifest uses the
# stage1 expectation mode on both hosts.
run_with_compiler "$STAGE2_BIN" "stage2 selfhost compile manifest" env TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1 scripts/verify-selfhost-compile-manifest.sh
# The deterministic assembly gate reuses the manifest's emitted .s as its first
# compile for overlapping sources, so it must run after the manifest gate.
run_with_compiler "$STAGE2_BIN" "stage2 deterministic assembly" env TYPELISP_DETERMINISTIC_ASM_MANIFEST_DIR="$ROOT/target/selfhost-compile-manifest" scripts/check-deterministic-asm.sh
run_with_compiler "$STAGE2_BIN" "stage2 codegen target parity" scripts/check-codegen-target-parity.sh
run_with_compiler "$STAGE2_BIN" "stage2 safety corpus" scripts/verify-safety-corpus.sh
run_with_compiler "$STAGE2_BIN" "stage2 native integration corpus" scripts/verify-integration.sh
run_with_compiler "$STAGE2_BIN" "stage2 examples" scripts/verify-examples.sh
run_with_compiler "$STAGE2_BIN" "stage2 benchmark comparison correctness" scripts/bench.sh --correctness
run_with_compiler "$STAGE2_BIN" "stage2 optimization corpus correctness" scripts/run-optimization-benchmarks.sh --correctness
run_with_compiler "$STAGE2_BIN" "stage2 stdlib modules and fixtures" scripts/verify-stdlib.sh

if [ "$HOST_OS" = linux ]; then
    run_with_compiler "$STAGE2_BIN" "stage2 CLI host-action smoke" scripts/check-stage1-wrapper.sh
    run_with_compiler "$STAGE2_BIN" "comptime-type specialization smoke" \
        env TYPELISP_BOOTSTRAP_SMOKE_STAGE1_BIN="$STAGE2_BIN" scripts/check-bootstrap-smoke.sh
    run_with_compiler "$STAGE2_BIN" "stage2 stdlib documentation" scripts/verify-stdlib-docs.sh
    run_with_compiler "$STAGE2_BIN" "stage2 stdlib selfhost verifier" scripts/verify-stdlib-selfhost.sh
    run_with_compiler "$STAGE2_BIN" "stage2 SPMD SIMD comparison" scripts/verify-spmd-simd.sh
    if command -v valgrind >/dev/null 2>&1; then
        run_with_compiler "$STAGE2_BIN" "Linux instruction-count baseline" \
            env TYPELISP_IR_CHECK_COMPILER="$STAGE2_BIN" scripts/check-instruction-counts.sh
    else
        echo "[no-rust-stage0] SKIP Linux instruction-count baseline: valgrind not found"
    fi
    DOC_SITE_OUT="$ROOT/target/no-rust-docs-pages-site"
    export DOC_SITE_OUT
    run_with_compiler "$STAGE2_BIN" "stage2 docs Pages build path" scripts/verify-doc-site.sh
    unset DOC_SITE_OUT
    run_with_compiler "$STAGE2_BIN" "stage2 native link generated programs" scripts/verify-native-link-linux.sh
    run_with_compiler "$STAGE2_BIN" "stage2 selfhost external compiler corpus" scripts/verify-selfhost.sh
else
    run_with_compiler "$STAGE2_BIN" "windows native link build/run" scripts/verify-native-link-windows.sh
    echo
    echo "[no-rust-stage0] Linux-only GNU as/ld gates are not Windows-applicable:"
    echo "[no-rust-stage0]   host-action smoke, comptime specialization smoke,"
    echo "[no-rust-stage0]   stdlib documentation, stdlib selfhost verifier,"
    echo "[no-rust-stage0]   SPMD SIMD comparison, instruction counts, docs Pages build path,"
    echo "[no-rust-stage0]   native link generated programs, selfhost external compiler corpus"
fi

echo
echo "no-Rust stage0 verification passed"
