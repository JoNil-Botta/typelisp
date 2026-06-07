#!/usr/bin/env sh
set -eu

# ci-verify.sh - CI/local no-Rust compiler gate.
#
# This script intentionally does not build the Rust compiler. It fetches the
# published stage0 artifact when TYPELISP_BIN is unset, guards against
# accidental cargo/rustc fallback by shadowing those commands with failing
# shims. Linux runs capability checks against a freshly bootstrapped stage1
# compiler; Windows runs the native MSVC link smoke and bootstrap fixpoint when
# the published seed has the required staged runtime symbols.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/ci-verify.sh

Runs the repository's no-Rust verification gate.
If TYPELISP_BIN is unset, downloads stage0-latest with scripts/fetch-stage0.sh.
On Linux, TYPELISP_BIN is the seed compiler: the script first runs the
bootstrap stage1 build, then runs capability checks against the bootstrapped
stage1 compiler. On Windows, TYPELISP_BIN is the seed compiler for capability
checks and the script runs the native MSVC link smoke plus the bootstrap
fixpoint gate when the seed has the required staged runtime symbols.
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

stage1_driver_staged_symbols() {
    printf '%s\n' \
        file-open-status \
        file-close-status \
        file-read-chunk-status \
        file-read-chunk-bytes \
        file-read-chunk-eof? \
        file-write-status \
        file-flush-status \
        append-file-status \
        fs-mkdir-status \
        fs-remove-file-status \
        fs-remove-dir-status \
        fs-rename-status \
        fs-read-dir-status \
        fs-read-dir \
        fs-file-size-status \
        fs-file-size
}

stage1_driver_prebuild_failed_for_staged_symbol() {
    driver_dir=$1
    staged_runtime_symbol_in_files "$driver_dir/compile.stdout" "$driver_dir/compile.stderr"
}

staged_runtime_symbol_in_files() {
    for symbol in $(stage1_driver_staged_symbols); do
        for file in "$@"; do
            [ -f "$file" ] || continue
            grep -qF "$symbol" "$file" && return 0
        done
    done
    return 1
}

windows_seed_has_staged_runtime_gap() {
    seed_has_staged_runtime_gap "$TYPELISP_BIN"
}

seed_has_staged_runtime_gap() {
    compiler=$1
    probe_dir="$ROOT/target/no-rust-stage0-staged-probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    for source in "$ROOT/stdlib/io.tl" "$ROOT/stdlib/fs.tl"; do
        safe_source=$(printf '%s' "$source" | sed 's#[/\\:]#_#g')
        set +e
        "$compiler" check "$source" --stdlib-root "$ROOT/stdlib" \
            > "$probe_dir/$safe_source.stdout" 2> "$probe_dir/$safe_source.stderr"
        probe_code=$?
        set -e
        if [ "$probe_code" -ne 0 ] &&
            staged_runtime_symbol_in_files "$probe_dir/$safe_source.stdout" "$probe_dir/$safe_source.stderr"; then
            return 0
        fi
    done
    return 1
}

compiler_is_stage1_wrapper() {
    compiler=$1
    "$compiler" --help 2>&1 | grep -q "stage1 wrapper commands"
}

show_stage1_driver_prebuild_failure() {
    label=$1
    driver_dir=$2
    echo "stage1 $label driver prebuild failed" >&2
    sed 's/^/  /' "$driver_dir/compile.stdout" >&2 || true
    sed 's/^/  /' "$driver_dir/compile.stderr" >&2 || true
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

compiler_rejects_package_kind_manifest() {
    compiler=$1
    probe_dir="$ROOT/target/no-rust-stage0-package-kind-probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir/src"
    cat > "$probe_dir/typelisp.pkg" <<'EOF'
(package
  (name "package_kind_probe")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
    cat > "$probe_dir/src/main.tl" <<'EOF'
(define (main) : i64 0)
EOF

    set +e
    "$compiler" build --manifest-path "$probe_dir/typelisp.pkg" --backend-mode scalar \
        > "$probe_dir/build.stdout" 2> "$probe_dir/build.stderr"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        return 1
    fi
    if grep -qF 'unknown manifest field `kind`' "$probe_dir/build.stdout" "$probe_dir/build.stderr"; then
        return 0
    fi
    return 1
}

stage1_safety_corpus_supported() {
    compiler=$1
    probe_dir="$ROOT/target/no-rust-stage1-safety-probe"
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
        echo "[no-rust-stage0] stage1 safety probe compile failed"
        sed 's/^/  /' "$probe_dir/compile.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/compile.stderr" >&2 || true
        return 1
    fi
    if ! as "$asm" -o "$obj" > "$probe_dir/assemble.stdout" 2> "$probe_dir/assemble.stderr"; then
        echo "[no-rust-stage0] stage1 safety probe assemble failed"
        sed 's/^/  /' "$probe_dir/assemble.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/assemble.stderr" >&2 || true
        return 1
    fi
    if ! ld "$obj" -o "$bin" -static \
        > "$probe_dir/link.stdout" 2> "$probe_dir/link.stderr"; then
        echo "[no-rust-stage0] stage1 safety probe link failed"
        sed 's/^/  /' "$probe_dir/link.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/link.stderr" >&2 || true
        return 1
    fi

    set +e
    "$bin" > "$probe_dir/run.stdout" 2> "$probe_dir/run.stderr"
    probe_status=$?
    set -e
    if [ "$probe_status" -ne 135 ]; then
        echo "[no-rust-stage0] stage1 safety probe expected guarded div-zero exit 135, got $probe_status"
        sed 's/^/  /' "$probe_dir/run.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/run.stderr" >&2 || true
        return 1
    fi
    if ! grep -F "tl: integer division or remainder error" "$probe_dir/run.stderr" >/dev/null; then
        echo "[no-rust-stage0] stage1 safety probe missing guarded div-zero stderr" >&2
        sed 's/^/  /' "$probe_dir/run.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/run.stderr" >&2 || true
        return 1
    fi
    return 0
}

# Windows analog of stage1_safety_corpus_supported: can the bootstrapped Windows
# stage1 compile -> clang -> lld-link -> RUN a native program? Uses a normal
# exit-42 fixture (not a trap: bare hardware traps surface as Windows structured
# exceptions whose shell exit code is unstable under MSYS/Git Bash).
stage1_can_compile_native_windows() {
    compiler=$1
    probe_dir="$ROOT/target/no-rust-stage1-win-probe"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    asm="$probe_dir/probe.s"
    obj="$probe_dir/probe.obj"
    bin="$probe_dir/probe.exe"
    if ! "$compiler" compile "$ROOT/tests/safety/integer_wrap_cast_defined.tl" \
        --target windows-x86_64 --stdlib-root "$ROOT/stdlib" -o "$asm" \
        > "$probe_dir/compile.out" 2>&1; then
        echo "[no-rust-stage0] windows stage1 compile-native probe compile failed"
        sed 's/^/  /' "$probe_dir/compile.out" >&2 || true
        return 1
    fi
    if ! clang --target=x86_64-pc-windows-msvc -c "$asm" -o "$obj" \
        > "$probe_dir/asm.out" 2>&1; then
        echo "[no-rust-stage0] windows stage1 compile-native probe assemble failed"
        sed 's/^/  /' "$probe_dir/asm.out" >&2 || true
        return 1
    fi
    if ! lld-link -NOLOGO "$(cygpath -aw "$obj")" "-OUT:$(cygpath -aw "$bin")" \
        -SUBSYSTEM:CONSOLE -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib \
        > "$probe_dir/link.out" 2>&1; then
        echo "[no-rust-stage0] windows stage1 compile-native probe link failed"
        sed 's/^/  /' "$probe_dir/link.out" >&2 || true
        return 1
    fi
    set +e
    "$bin" < /dev/null > "$probe_dir/run.out" 2>&1
    probe_status=$?
    set -e
    if [ "$probe_status" -ne 42 ]; then
        echo "[no-rust-stage0] windows stage1 compile-native probe expected exit 42, got $probe_status"
        return 1
    fi
    return 0
}

echo "[no-rust-stage0] host=$HOST_OS seed=$SEED_TYPELISP_BIN"

run_with_compiler "$SEED_TYPELISP_BIN" "TypeLisp source formatting" scripts/check-tl-format.sh
run_with_compiler "$SEED_TYPELISP_BIN" "TypeLisp source lint" scripts/check-tl-lint.sh
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN

SELFHOST_CLI_BIN="$ROOT/target/no-rust-stage0-cli/typelisp"
if [ "$HOST_OS" = windows ]; then
    SELFHOST_CLI_BIN="$SELFHOST_CLI_BIN.exe"
fi
run_gate "fresh selfhost cli build" scripts/build-stage0.sh "$SEED_TYPELISP_BIN" "$SELFHOST_CLI_BIN"
ensure_executable "fresh selfhost cli" "$SELFHOST_CLI_BIN"

# The freshly self-built compiler (and the programs it builds) must depend on
# no C runtime: kernel32 only on Windows, nothing dynamic on Linux.
run_with_compiler "$SELFHOST_CLI_BIN" "no-libc dependency guard" scripts/verify-no-libc.sh

SELFHOST_CLI_REFRESHED_PATH_FILE="$ROOT/target/no-rust-stage0-cli/refreshed.path"
rm -f "$SELFHOST_CLI_REFRESHED_PATH_FILE"
TYPELISP_SELFHOST_CLI_REFRESHED_PATH_FILE=$SELFHOST_CLI_REFRESHED_PATH_FILE
export TYPELISP_SELFHOST_CLI_REFRESHED_PATH_FILE
run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost cli build/run and chooser smoke" scripts/verify-selfhost-cli-build-run.sh
unset TYPELISP_SELFHOST_CLI_REFRESHED_PATH_FILE
if [ ! -s "$SELFHOST_CLI_REFRESHED_PATH_FILE" ]; then
    echo "[no-rust-stage0] fresh selfhost cli smoke did not write refreshed compiler path: $SELFHOST_CLI_REFRESHED_PATH_FILE" >&2
    exit 1
fi
SELFHOST_CLI_BIN=$(sed -n '1p' "$SELFHOST_CLI_REFRESHED_PATH_FILE")
ensure_executable "refreshed selfhost cli" "$SELFHOST_CLI_BIN"
echo "[no-rust-stage0] downstream fresh CLI gates use refreshed selfhost cli: $SELFHOST_CLI_BIN"
run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI TypeLisp source lint" scripts/check-tl-lint.sh

if [ "$HOST_OS" = linux ]; then
    STAGE1_PATH_FILE="$ROOT/target/no-rust-stage0-stage1.path"
    rm -f "$STAGE1_PATH_FILE"
    TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE=$STAGE1_PATH_FILE
    export TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE

    LINUX_SEED_STAGED_RUNTIME_GAP=0
    if seed_has_staged_runtime_gap "$SEED_TYPELISP_BIN"; then
        LINUX_SEED_STAGED_RUNTIME_GAP=1
        echo "[no-rust-stage0] Linux seed lacks staged runtime symbols used by stdlib modules; Linux gates still run through branch-built compilers"
    fi

    run_gate "bootstrap stage1->stage2->stage3 fixpoint" scripts/check-bootstrap-fixpoint.sh "$SEED_TYPELISP_BIN"
    unset TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE
    if [ -s "$STAGE1_PATH_FILE" ]; then
        TYPELISP_BIN=$(sed -n '1p' "$STAGE1_PATH_FILE")
    else
        TYPELISP_BIN="$ROOT/target/bootstrap-fixpoint/stage1"
    fi
    ensure_executable "stage1" "$TYPELISP_BIN"
    # The freshly bootstrapped stage1 (from selfhost/compile.tl: the compiler-only
    # entry, so it has `compile`/`check` but NOT the build/run/doc/test commands).
    # Capture it immutably and reuse it for the compile-path gates so we actually
    # exercise the artifact we just built, instead of re-running the fetched seed.
    BOOTSTRAPPED_STAGE1=$TYPELISP_BIN

    # Distinct from the full cli.tl build/run smoke above: can the freshly
    # bootstrapped compile-only stage1 compile -> assemble -> link -> RUN a native
    # program? This is the compile-path run-assert capability. Linux is the
    # coverage-bearing lane, so a failed probe is a CI failure rather than a
    # reason to omit the safety/integration/examples tiers.
    STAGE1_CAN_COMPILE_NATIVE=0
    if stage1_safety_corpus_supported "$BOOTSTRAPPED_STAGE1"; then
        STAGE1_CAN_COMPILE_NATIVE=1
        echo "[no-rust-stage0] stage1 compile->as->ld->run capability confirmed; Linux run-assert tiers execute on the bootstrapped stage1"
    else
        required_gate_unavailable "Linux stage1 compile->as->ld->run probe" \
            "safety, integration, examples, SPMD, and stdlib run-assert tiers depend on this probe"
    fi

    STAGE1_DOC_BIN=
    STAGE1_BUILD_BIN=
    STAGE1_REPL_BIN=
    STAGE1_LINT_BIN=
    STAGE1_FORMAT_BIN=
    STAGE1_TEST_BIN=
    STAGE1_LSP_BIN=
    STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=0
    # cli.tl is the single stage0 binary with every toolchain command in-process.
    # When the compile-only stage1 lacks a host-action surface, those gates run
    # on the fresh branch-built cli.tl instead of being removed from coverage.
    SEED_IS_STAGE1_BUNDLE=0
    STAGE1_DOC_BIN=$SEED_TYPELISP_BIN
    STAGE1_BUILD_BIN=$SEED_TYPELISP_BIN
    STAGE1_REPL_BIN=$SEED_TYPELISP_BIN
    STAGE1_LSP_BIN=$SEED_TYPELISP_BIN
    STAGE1_LINT_BIN=$SEED_TYPELISP_BIN
    STAGE1_FORMAT_BIN=$SEED_TYPELISP_BIN
    # Linux CI is intentionally fail-closed: do not add branch-local bypass flags
    # or compatibility bypasses here. Important gates must either run on the
    # bootstrapped stage1 compiler or on the fresh branch-built cli.tl above.
    STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=0
    if [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -ne 0 ]; then
        echo "[no-rust-stage0] seed lacks staged runtime symbols; Linux host-action gates use the fresh selfhost CLI"
    fi
    # Route the narrow compile-path stage1 gates at the freshly bootstrapped
    # stage1, not the fetched seed, so the artifact we built is what gets
    # exercised. Host-action gates use the fresh selfhost CLI when the
    # compile-only stage1 lacks that surface.
    STAGE1_TYPELISP_BIN=$BOOTSTRAPPED_STAGE1
    echo "[no-rust-stage0] stage1 compile-path gates run the freshly bootstrapped stage1; full cli.tl build/run coverage is in the fresh cli smoke"
else
    TYPELISP_BIN=$SEED_TYPELISP_BIN
    echo "[no-rust-stage0] capability compiler=$TYPELISP_BIN"
fi
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN
TYPELISP_NO_RUST_STAGE0=1
export TYPELISP_NO_RUST_STAGE0

WINDOWS_SEED_STAGED_RUNTIME_GAP=0
if [ "$HOST_OS" = windows ] && windows_seed_has_staged_runtime_gap; then
    WINDOWS_SEED_STAGED_RUNTIME_GAP=1
    echo "[no-rust-stage0] Windows seed lacks staged runtime symbols used by stdlib modules"
fi
if [ "$HOST_OS" != linux ]; then
    LINUX_SEED_STAGED_RUNTIME_GAP=0
    STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=0
    SEED_IS_STAGE1_BUNDLE=0
    # The compile->as->ld->run capability is Linux-only (the corpora drive the GNU
    # as/ld toolchain). Windows run-asserts go through the build/run host-action
    # drivers, gated separately on STAGE1_HOST_ACTION_DRIVERS_AVAILABLE.
    STAGE1_CAN_COMPILE_NATIVE=0
fi
SEED_STAGE1_WRAPPER=0
if compiler_is_stage1_wrapper "$SEED_TYPELISP_BIN"; then
    SEED_STAGE1_WRAPPER=1
    echo "[no-rust-stage0] seed exposes the legacy stage1 wrapper help; extended CLI parity gates remain in compatibility tiers"
fi

FRONT_GATE_TYPELISP_BIN=$SEED_TYPELISP_BIN
if [ "$HOST_OS" = linux ] &&
    [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] &&
    [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
    FRONT_GATE_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
fi

# Repository doctests run `typelisp doc --test`. On Linux, route them through a
# host-action compiler when one is available; otherwise the gate runs on the
# fresh branch-built cli.tl.
DOCTEST_TYPELISP_BIN=$FRONT_GATE_TYPELISP_BIN
if [ "$HOST_OS" = linux ] && [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
    DOCTEST_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
fi

# Repository inline tests run `typelisp test`, which a retained host-action
# compiler can serve through the prebuilt selfhost test driver when a fresh
# bundle carries one (#1609). Otherwise the gate runs on the fresh branch-built
# cli.tl.
INLINE_TEST_TYPELISP_BIN=$FRONT_GATE_TYPELISP_BIN
if [ "$HOST_OS" = linux ] && [ -n "$STAGE1_TEST_BIN" ]; then
    INLINE_TEST_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
fi

# The public-tool corpus is the broadest CLI behavior witness. On Linux it must
# run on a branch-built compiler; use the fresh cli.tl artifact when the
# compile-only stage1 does not expose host-action commands.
PUBLIC_TOOLS_TYPELISP_BIN=$FRONT_GATE_TYPELISP_BIN
PUBLIC_TOOLS_LABEL="public tool surface"
if [ "$HOST_OS" = linux ] && [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
    PUBLIC_TOOLS_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
    PUBLIC_TOOLS_LABEL="stage1 public tool surface"
fi

if [ "$HOST_OS" = linux ]; then
    run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI public tool surface" scripts/verify-public-tools.sh
    run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI SPMD runtime dispatch" scripts/verify-spmd-runtime-dispatch.sh
    run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI repository doctests" scripts/verify-doc-tests.sh
elif [ "$HOST_OS" = windows ]; then
    run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI public tool surface" scripts/verify-public-tools.sh
    run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI SPMD runtime dispatch" scripts/verify-spmd-runtime-dispatch.sh
    run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI repository doctests" scripts/verify-doc-tests.sh
fi
if [ "$HOST_OS" = linux ] || [ "$HOST_OS" = windows ]; then
    run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI inline TypeLisp tests" scripts/verify-inline-tests.sh
else
    # The single-binary cli.tl seed runs `typelisp test` (both --check and the
    # in-process test-executable run) directly, so this gate stays on the seed.
    run_with_compiler "$INLINE_TEST_TYPELISP_BIN" "inline TypeLisp tests" scripts/verify-inline-tests.sh
fi
if [ "$HOST_OS" = linux ]; then
    if [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
        run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI host-action smoke" scripts/check-stage1-wrapper.sh
    else
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 CLI host-action smoke" scripts/check-stage1-wrapper.sh
    fi
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 deterministic assembly" scripts/check-deterministic-asm.sh
    run_with_compiler "$SEED_TYPELISP_BIN" "comptime-type specialization smoke" \
        env TYPELISP_BOOTSTRAP_SMOKE_STAGE1_BIN="$BOOTSTRAPPED_STAGE1" scripts/check-bootstrap-smoke.sh
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 selfhost compile manifest" env TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1 scripts/verify-selfhost-compile-manifest.sh
    if [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
        run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI stdlib documentation" scripts/verify-stdlib-docs.sh
        run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI stdlib selfhost verifier" scripts/verify-stdlib-selfhost.sh
    else
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 stdlib documentation" scripts/verify-stdlib-docs.sh
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 stdlib selfhost verifier" scripts/verify-stdlib-selfhost.sh
    fi
else
    # Keep the same Windows compile/check corpora, but run the compile-heavy
    # gates through the fresh selfhost CLI built above. This matches Linux's
    # branch-built compile-path coverage instead of spending the manifest on the
    # fetched compatibility seed. The current cli.tl emits stage1-qualified
    # symbols, so the manifest still uses stage1 expectation mode.
    run_with_compiler "$SELFHOST_CLI_BIN" "selfhost compile manifest" env TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1 scripts/verify-selfhost-compile-manifest.sh
    run_with_compiler "$SELFHOST_CLI_BIN" "deterministic assembly" scripts/check-deterministic-asm.sh
    run_with_compiler "$SELFHOST_CLI_BIN" "windows selfhost MSVC link.exe build/run" scripts/verify-windows-selfhost-msvc-link.sh

    # The Windows stage2 self-compile allocation ceiling (#1601) is fixed on
    # this branch (it is based on the 1601 branch), and lib-native-link.sh
    # links each bootstrap stage at a 256 MB stack reserve (not the old 16 MB
    # /STACK). Capture the bootstrapped Windows stage1 and reuse it for the
    # run-assert tiers below so the gate executes real Windows binaries built by
    # the artifact we just produced.
    if [ "$WINDOWS_SEED_STAGED_RUNTIME_GAP" -eq 1 ]; then
        echo "[no-rust-stage0] Windows seed lacks staged runtime symbols; bootstrap fixpoint still runs with the seed and must pass"
    fi
    WINDOWS_STAGE1_PATH_FILE="$ROOT/target/no-rust-stage0-win-stage1.path"
    rm -f "$WINDOWS_STAGE1_PATH_FILE"
    TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE=$WINDOWS_STAGE1_PATH_FILE
    export TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE
    run_gate "windows bootstrap fixpoint" scripts/check-bootstrap-fixpoint.sh "$SEED_TYPELISP_BIN"
    unset TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE
    if [ -s "$WINDOWS_STAGE1_PATH_FILE" ]; then
        BOOTSTRAPPED_STAGE1=$(sed -n '1p' "$WINDOWS_STAGE1_PATH_FILE")
        ensure_executable "windows stage1" "$BOOTSTRAPPED_STAGE1"
        if stage1_can_compile_native_windows "$BOOTSTRAPPED_STAGE1"; then
            STAGE1_CAN_COMPILE_NATIVE=1
            echo "[no-rust-stage0] windows stage1 compile->clang->lld-link->run capability confirmed; run-assert tiers execute on the bootstrapped stage1"
        else
            required_gate_unavailable "Windows stage1 compile->clang->lld-link->run probe" \
                "safety, integration, and examples run-assert tiers depend on this probe"
        fi
    else
        required_gate_unavailable "Windows bootstrap fixpoint" \
            "bootstrap did not persist a stage1 path for downstream run-assert tiers"
    fi
fi
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN

# The safety corpus is a build/run capability gate, but its fixtures are small
# enough to run through the freshly bootstrapped stage1 compiler when the Linux
# host-action commands and checked-trap helpers are available (#1267). Keep the
# seed path only for older artifacts or hosts where that compiler cannot execute
# native programs yet.
SAFETY_GATE_TYPELISP_BIN=$SEED_TYPELISP_BIN
SAFETY_GATE_LABEL="safety corpus"
if [ "$STAGE1_CAN_COMPILE_NATIVE" -eq 1 ]; then
    # The freshly bootstrapped stage1 compiles + assembles + links + runs native
    # programs (confirmed by the compile-native probe above), so exercise the
    # safety corpus's trap/exit fixtures on the artifact we built, not the seed.
    SAFETY_GATE_TYPELISP_BIN=$BOOTSTRAPPED_STAGE1
    SAFETY_GATE_LABEL="stage1 safety corpus"
    run_with_compiler "$SAFETY_GATE_TYPELISP_BIN" "$SAFETY_GATE_LABEL" scripts/verify-safety-corpus.sh
elif [ "$WINDOWS_SEED_STAGED_RUNTIME_GAP" -eq 1 ]; then
    required_gate_unavailable "Windows safety corpus" \
        "the seed has staged runtime gaps and no bootstrapped stage1 run capability was established"
elif [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
    # The safety corpus assembles, links, and runs native trap fixtures. On hosts
    # where the bootstrapped stage1 cannot drive compile->as->ld->run (Windows, or
    # a Linux stage1 that failed the compile-native probe), fail the seed
    # compatibility path; fresh cli.tl build/run is covered above.
    required_gate_unavailable "safety corpus" \
        "stage1 compile/link/run capability was not established"
else
    run_with_compiler "$SAFETY_GATE_TYPELISP_BIN" "$SAFETY_GATE_LABEL" scripts/verify-safety-corpus.sh
fi
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN

if [ "$STAGE1_CAN_COMPILE_NATIVE" -eq 1 ]; then
    # The bootstrapped stage1 compiles + assembles + links + runs native programs
    # (compile-native probe confirmed), so run the integration corpus and examples
    # on the artifact we built via compile -> assemble -> link -> run (as/ld on
    # Linux, clang/lld-link on Windows). On Linux, stdlib fixtures use the same
    # compile -> as -> ld path, so they can also execute on the compile-only
    # stage1. Windows stdlib fixtures run through the fresh branch-built cli.tl
    # because they require the public `build` host action.
    run_with_compiler "$BOOTSTRAPPED_STAGE1" "stage1 native integration corpus" scripts/verify-integration.sh
    run_with_compiler "$BOOTSTRAPPED_STAGE1" "stage1 examples" scripts/verify-examples.sh
    if [ "$HOST_OS" = linux ]; then
        run_with_compiler "$BOOTSTRAPPED_STAGE1" "stage1 SPMD SIMD comparison" scripts/verify-spmd-simd.sh
        run_with_compiler "$BOOTSTRAPPED_STAGE1" "stage1 SPMD runtime dispatch" scripts/verify-spmd-runtime-dispatch.sh
        run_with_compiler "$BOOTSTRAPPED_STAGE1" "stage1 stdlib modules and fixtures" \
            scripts/verify-stdlib.sh
    else
        run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI stdlib modules and fixtures" \
            scripts/verify-stdlib.sh
    fi
elif [ "$WINDOWS_SEED_STAGED_RUNTIME_GAP" -eq 1 ] ||
    [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] ||
    [ "$SEED_STAGE1_WRAPPER" -eq 1 ]; then
    required_gate_unavailable "native integration corpus, examples, stdlib modules and fixtures" \
        "staged runtime symbols or seed CLI parity are unavailable and no stage1 run capability was established"
elif [ "$HOST_OS" = linux ] && [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; then
    required_gate_unavailable "native integration corpus, examples, stdlib modules and fixtures" \
        "stage1 bundle compiler/runtime parity is unavailable"
elif [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
    # These gates build and run native programs (integration corpus, examples,
    # stdlib fixtures via `typelisp build`/`run`). This compatibility seed path
    # fails closed; fresh cli.tl direct build/run is covered earlier,
    # while this broad path still has package/generated-program parity gaps.
    # cli.tl's compile/check coverage for these sources stays exercised by the
    # deterministic assembly + selfhost compile manifest gates.
    required_gate_unavailable "native integration corpus, examples, stdlib modules and fixtures" \
        "stage1 host-action drivers are unavailable"
else
    run_gate "native integration corpus" scripts/verify-integration.sh
    run_gate "examples" scripts/verify-examples.sh
    run_gate "stdlib modules and fixtures" scripts/verify-stdlib.sh
fi

if [ "$HOST_OS" = linux ]; then
    if [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
        DOC_SITE_OUT="$ROOT/target/no-rust-docs-pages-site"
        export DOC_SITE_OUT
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 docs Pages build path" scripts/verify-doc-site.sh
        unset DOC_SITE_OUT
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 selfhost native generated programs" scripts/verify-selfhost-native.sh
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 selfhost external compiler corpus" scripts/verify-selfhost.sh
    else
        DOC_SITE_OUT="$ROOT/target/no-rust-docs-pages-site"
        export DOC_SITE_OUT
        run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI docs Pages build path" scripts/verify-doc-site.sh
        unset DOC_SITE_OUT
        run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI selfhost native generated programs" scripts/verify-selfhost-native.sh
        run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost CLI selfhost external compiler corpus" scripts/verify-selfhost.sh
    fi
else
    echo
    echo "[no-rust-stage0] Linux-only GNU as/ld gates are not Windows-applicable:"
    echo "[no-rust-stage0]   stdlib documentation, selfhost native generated programs,"
    echo "[no-rust-stage0]   selfhost external compiler corpus"
fi

echo
echo "no-Rust stage0 verification passed"
