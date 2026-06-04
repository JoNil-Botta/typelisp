#!/usr/bin/env sh
set -eu

# verify-no-rust-stage0.sh - CI/local no-Rust compiler gate.
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
usage: scripts/verify-no-rust-stage0.sh

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
    echo
    echo "[no-rust-stage0] $label"
    "$@"
}

stage1_driver_staged_symbols() {
    printf '%s\n' \
        file-read-chunk-status \
        file-write-status \
        file-flush-status \
        append-file-status \
        fs-rename-status
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
    if ! ld "$obj" -o "$bin" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc \
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
        -SUBSYSTEM:CONSOLE msvcrt.lib legacy_stdio_definitions.lib advapi32.lib \
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
run_with_compiler "$SEED_TYPELISP_BIN" "TypeLisp source lint" \
    env TYPELISP_LINT_JOBS="${TYPELISP_LINT_JOBS:-8}" scripts/check-tl-lint.sh
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN

SELFHOST_CLI_BIN="$ROOT/target/no-rust-stage0-cli/typelisp"
if [ "$HOST_OS" = windows ]; then
    SELFHOST_CLI_BIN="$SELFHOST_CLI_BIN.exe"
fi
run_gate "fresh selfhost cli build" scripts/build-stage0.sh "$SEED_TYPELISP_BIN" "$SELFHOST_CLI_BIN"
ensure_executable "fresh selfhost cli" "$SELFHOST_CLI_BIN"
run_with_compiler "$SELFHOST_CLI_BIN" "fresh selfhost cli build/run and chooser smoke" scripts/verify-selfhost-cli-build-run.sh

if [ "$HOST_OS" = linux ]; then
    STAGE1_PATH_FILE="$ROOT/target/no-rust-stage0-stage1.path"
    rm -f "$STAGE1_PATH_FILE"
    TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE=$STAGE1_PATH_FILE
    export TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE
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
    # program? This is the compile-path run-assert capability. When it holds, the
    # Linux safety/integration/examples tiers execute on the artifact we just built
    # (compile + as + ld + run), proving it actually runs programs, instead of being
    # skipped or falling back to the fetched seed. The probe is the safety div-zero
    # fixture (compile->as->ld->run->trap 136); reuse its result for all three tiers
    # so the corpora are only gated on a capability we have positively demonstrated.
    STAGE1_CAN_COMPILE_NATIVE=0
    if stage1_safety_corpus_supported "$BOOTSTRAPPED_STAGE1"; then
        STAGE1_CAN_COMPILE_NATIVE=1
        echo "[no-rust-stage0] stage1 compile->as->ld->run capability confirmed; Linux run-assert tiers execute on the bootstrapped stage1"
    else
        echo "[no-rust-stage0] stage1 compile->as->ld->run probe failed; Linux run-assert tiers stay on the seed/skip path"
    fi

    LINUX_SEED_STAGED_RUNTIME_GAP=0
    if seed_has_staged_runtime_gap "$SEED_TYPELISP_BIN"; then
        LINUX_SEED_STAGED_RUNTIME_GAP=1
        echo "[no-rust-stage0] Linux seed lacks staged runtime symbols used by stdlib modules; limiting stage1 to compile-only gates"
    fi

    STAGE1_DOC_BIN=
    STAGE1_BUILD_BIN=
    STAGE1_REPL_BIN=
    STAGE1_LINT_BIN=
    STAGE1_FORMAT_BIN=
    STAGE1_TEST_BIN=
    STAGE1_LSP_BIN=
    STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=0
    # cli.tl is the single stage0 binary with every toolchain command in-process,
    # so the gates run it directly instead of building per-command driver
    # binaries and a dispatch wrapper. STAGE1_TEST_BIN stays empty (as it always
    # was for a non-bundle seed), so the separate test-driver gates stay skipped.
    SEED_IS_STAGE1_BUNDLE=0
    STAGE1_DOC_BIN=$SEED_TYPELISP_BIN
    STAGE1_BUILD_BIN=$SEED_TYPELISP_BIN
    STAGE1_REPL_BIN=$SEED_TYPELISP_BIN
    STAGE1_LSP_BIN=$SEED_TYPELISP_BIN
    STAGE1_LINT_BIN=$SEED_TYPELISP_BIN
    STAGE1_FORMAT_BIN=$SEED_TYPELISP_BIN
    # This branch still treats the fetched seed as a compatibility compiler for
    # broad gates. Current cli.tl build/run execution is covered by the fresh
    # selfhost cli smoke above; the older seed path keeps build/run-heavy gates
    # disabled because it may not include this branch's direct executor and the
    # package/generated-program tiers still need their own parity work. Force
    # STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=0 so those downstream gates stay on
    # the documented skip path while compile/check/fmt/lint/test/doc gates run.
    STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=0
    if [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -ne 0 ]; then
        echo "[no-rust-stage0] seed lacks staged runtime symbols; toolchain gates limited to compile-only"
    fi
    # Route the compile-path 'stage1' gates (deterministic asm, compile manifest,
    # borrowed-str check) at the freshly bootstrapped stage1, not the fetched
    # seed, so the artifact we built is what gets exercised. The build/run/doc
    # command gates still need a runner with the build/run/doc commands (built in
    # the BUILD-RUNNERS phase below); until those exist the flag stays 0.
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
    echo "[no-rust-stage0] seed is a stage1 wrapper; extended CLI parity gates remain in compatibility tiers"
fi

FRONT_GATE_TYPELISP_BIN=$SEED_TYPELISP_BIN
if [ "$HOST_OS" = linux ] &&
    [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] &&
    [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
    FRONT_GATE_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
fi

# Repository doctests run `typelisp doc --test`, which the stage1 wrapper serves
# through the freshly bootstrapped selfhost doc driver (the same path the stdlib
# documentation gate already uses). On Linux, route them through the wrapper
# whenever the host-action drivers are available so this capability tier no
# longer depends on the seed/published compiler (#1544). When the drivers are
# unavailable the doctest gate is skipped below, so this binary is only used on
# the wrapper-capable path.
DOCTEST_TYPELISP_BIN=$FRONT_GATE_TYPELISP_BIN
if [ "$HOST_OS" = linux ] && [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
    DOCTEST_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
fi

# Repository inline tests run `typelisp test`, which the stage1 wrapper can
# serve through the prebuilt selfhost test driver when a fresh bundle carries
# one (#1609). Older seed bundles do not have that driver, so keep their
# explicit skip below instead of compiling selfhost/test.tl in the hosted lane.
INLINE_TEST_TYPELISP_BIN=$FRONT_GATE_TYPELISP_BIN
if [ "$HOST_OS" = linux ] && [ -n "$STAGE1_TEST_BIN" ]; then
    INLINE_TEST_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
fi

# Borrowed-str stdlib source gate (#1557): verify the borrowed-str stdlib
# fixtures through the bootstrapped stage1 compiler on Linux.
if [ "$HOST_OS" = linux ]; then
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 stdlib borrowed-str source gate" scripts/verify-stdlib.sh --borrowed-str-only
fi

# The public-tool corpus is the broadest CLI behavior witness. On Linux, run it
# against the freshly bootstrapped stage1 wrapper whenever the wrapper's
# host-action drivers are available. The seed path below is only a compatibility
# fallback for old artifacts or missing drivers (#1662).
PUBLIC_TOOLS_TYPELISP_BIN=$FRONT_GATE_TYPELISP_BIN
PUBLIC_TOOLS_LABEL="public tool surface"
if [ "$HOST_OS" = linux ] && [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
    PUBLIC_TOOLS_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
    PUBLIC_TOOLS_LABEL="stage1 public tool surface"
fi

if [ "$WINDOWS_SEED_STAGED_RUNTIME_GAP" -eq 1 ]; then
    echo
    echo "[no-rust-stage0] skipping Windows seed gates that compile selfhost doc/build/run drivers:"
    echo "[no-rust-stage0]   public tool surface, repository doctests"
else
    if [ "$HOST_OS" = linux ] &&
        [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
        run_with_compiler "$PUBLIC_TOOLS_TYPELISP_BIN" "$PUBLIC_TOOLS_LABEL" scripts/verify-public-tools.sh
    elif [ "$HOST_OS" = linux ] &&
        [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] &&
        [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
        echo
        echo "[no-rust-stage0] skipping seed public tool surface until stage1 host-action drivers are available (#1662)"
    elif [ "$HOST_OS" = windows ]; then
        echo
        echo "[no-rust-stage0] running Windows seed public tool surface with selfhost compatibility gates"
        if compiler_rejects_package_kind_manifest "$FRONT_GATE_TYPELISP_BIN"; then
            echo "[no-rust-stage0] Windows seed rejects package kind; using legacy package manifests for public tool surface"
            run_with_compiler "$FRONT_GATE_TYPELISP_BIN" "public tool surface" env TYPELISP_LEGACY_PACKAGE_MANIFEST=1 TYPELISP_PUBLIC_TOOLS_HOST_ACTION_ENABLED=0 TYPELISP_PUBLIC_TOOLS_SKIP_CURRENT_LSP_IMPORT_CLEAR=1 scripts/verify-public-tools.sh
        else
            run_with_compiler "$FRONT_GATE_TYPELISP_BIN" "public tool surface" env TYPELISP_PUBLIC_TOOLS_HOST_ACTION_ENABLED=0 TYPELISP_PUBLIC_TOOLS_SKIP_CURRENT_LSP_IMPORT_CLEAR=1 scripts/verify-public-tools.sh
        fi
    elif [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping public tool surface until bundled stage1 host-action drivers are available (#1662)"
    elif [ "$SEED_STAGE1_WRAPPER" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping seed public tool surface until stage1 wrapper host-action drivers are available (#1662)"
    else
        echo
        echo "[no-rust-stage0] running seed public tool surface with selfhost compatibility gates"
        if compiler_rejects_package_kind_manifest "$PUBLIC_TOOLS_TYPELISP_BIN"; then
            echo "[no-rust-stage0] seed rejects package kind; using legacy package manifests for public tool surface"
            run_with_compiler "$PUBLIC_TOOLS_TYPELISP_BIN" "$PUBLIC_TOOLS_LABEL" env TYPELISP_LEGACY_PACKAGE_MANIFEST=1 TYPELISP_PUBLIC_TOOLS_HOST_ACTION_ENABLED=0 TYPELISP_PUBLIC_TOOLS_SKIP_CURRENT_LSP_IMPORT_CLEAR=1 scripts/verify-public-tools.sh
        else
            run_with_compiler "$PUBLIC_TOOLS_TYPELISP_BIN" "$PUBLIC_TOOLS_LABEL" env TYPELISP_PUBLIC_TOOLS_HOST_ACTION_ENABLED=0 TYPELISP_PUBLIC_TOOLS_SKIP_CURRENT_LSP_IMPORT_CLEAR=1 scripts/verify-public-tools.sh
        fi
    fi
    if [ "$HOST_OS" = linux ] &&
        [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] &&
        [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
        echo
        echo "[no-rust-stage0] skipping repository doctests until staged runtime symbols land in stage0"
    else
        # The single-binary cli.tl seed runs `doc --test` (including runnable
        # ` ```typelisp run ` doctests) in-process, so this gate stays on the seed.
        run_with_compiler "$DOCTEST_TYPELISP_BIN" "repository doctests" scripts/verify-doc-tests.sh
    fi
fi
if [ "$HOST_OS" = linux ] &&
    [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ] &&
    [ -z "$STAGE1_TEST_BIN" ]; then
    echo
    echo "[no-rust-stage0] skipping inline TypeLisp tests until the stage1 bundle carries a selfhost test driver (#1609)"
else
    # The single-binary cli.tl seed runs `typelisp test` (both --check and the
    # in-process test-executable run) directly, so this gate stays on the seed.
    run_with_compiler "$INLINE_TEST_TYPELISP_BIN" "inline TypeLisp tests" scripts/verify-inline-tests.sh
fi
if [ "$HOST_OS" = linux ]; then
    # Building the full selfhost test driver in this hosted no-Rust lane is
    # currently too heavy for the runner. When the stage1 bundle carries the
    # driver, run the wrapper's direct test-command smoke instead of the old
    # host-action plan path.
    if [ -z "$STAGE1_TEST_BIN" ]; then
        TYPELISP_STAGE1_SKIP_TEST_SMOKE=1
        export TYPELISP_STAGE1_SKIP_TEST_SMOKE
    fi
    # Building the full selfhost doc driver through stage1 is also too heavy
    # for this hosted lane; #1437 tracks restoring direct stage1 coverage for
    # compiler-sized selfhost drivers.
    TYPELISP_STAGE1_SKIP_DOC_SMOKE=1
    export TYPELISP_STAGE1_SKIP_DOC_SMOKE
    if [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; then
        TYPELISP_STAGE1_SKIP_PACKAGE_SMOKE=1
        export TYPELISP_STAGE1_SKIP_PACKAGE_SMOKE
    fi
    if [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
        echo
        echo "[no-rust-stage0] skipping stage1 CLI host-action wrapper smoke until staged runtime symbols land in stage0"
    else
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 CLI host-action wrapper smoke" scripts/check-stage1-wrapper.sh
    fi
    unset TYPELISP_STAGE1_SKIP_TEST_SMOKE
    unset TYPELISP_STAGE1_SKIP_DOC_SMOKE
    unset TYPELISP_STAGE1_SKIP_PACKAGE_SMOKE
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 deterministic assembly" scripts/check-deterministic-asm.sh
    run_with_compiler "$SEED_TYPELISP_BIN" "comptime-type specialization smoke" \
        env TYPELISP_BOOTSTRAP_SMOKE_STAGE1_BIN="$BOOTSTRAPPED_STAGE1" scripts/check-bootstrap-smoke.sh
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 selfhost compile manifest" env TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1 scripts/verify-selfhost-compile-manifest.sh
    if [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
        echo
        echo "[no-rust-stage0] skipping stage1 doc/build-driver gates until staged runtime symbols land in stage0:"
        echo "[no-rust-stage0]   stdlib documentation, stdlib selfhost verifier"
    else
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 stdlib documentation" scripts/verify-stdlib-docs.sh
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 stdlib selfhost verifier" scripts/verify-stdlib-selfhost.sh
    fi
else
    # The single-binary cli.tl seed emits module-qualified symbols (the stage1
    # mangling, `_tl_<mod>_u2etl_colon_colon<fn>`), which only the manifest's
    # stage1 expectation mode accepts; stage0 mode expects legacy unqualified
    # labels. STAGE1_HOST_ACTION_DRIVERS_AVAILABLE is always 0 on Windows, so
    # the seed is always cli.tl here (#1662).
    run_gate "selfhost compile manifest" env TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1 scripts/verify-selfhost-compile-manifest.sh
    run_gate "deterministic assembly" scripts/check-deterministic-asm.sh
    if [ "$WINDOWS_SEED_STAGED_RUNTIME_GAP" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping Windows selfhost MSVC link.exe build/run and bootstrap fixpoint until the seed provides staged runtime symbols"
    else
        # The Windows stage2 self-compile allocation ceiling (#1601) is fixed on
        # this branch (it is based on the 1601 branch), and lib-native-link.sh
        # links each bootstrap stage at a 256 MB stack reserve (not the old 16 MB
        # /STACK), so the Windows self-reproduction fixpoint converges. Run it,
        # capture the bootstrapped Windows stage1, and reuse it for the run-assert
        # tiers below so the gate executes real Windows binaries built by the
        # artifact we just produced. (verify-windows-selfhost-msvc-link.sh stays
        # deferred in this compatibility lane. The fixpoint already exercises the
        # MSVC link.exe path through lib-native-link.sh, so MSVC linking is covered.
        # Fresh cli.tl direct build/run coverage is checked earlier by
        # verify-selfhost-cli-build-run.sh.)
        echo
        echo "[no-rust-stage0] skipping windows selfhost MSVC link.exe build/run compatibility gate (MSVC link covered by the fixpoint; direct cli.tl build/run covered by the fresh cli smoke)"
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
                echo "[no-rust-stage0] windows stage1 compile-native probe failed; run-assert tiers stay skipped"
            fi
        else
            echo "[no-rust-stage0] windows fixpoint did not persist a stage1 path; run-assert tiers stay skipped"
        fi
    fi
fi
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN

# The safety corpus is a build/run capability gate, but its fixtures are small
# enough to run through the freshly bootstrapped stage1 wrapper when the Linux
# host-action drivers and checked-trap helpers are available (#1267). Keep the
# seed path only for older artifacts or hosts where the wrapper cannot execute
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
    echo
    echo "[no-rust-stage0] skipping Windows safety corpus until the seed provides staged runtime symbols"
elif [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
    # The safety corpus assembles, links, and runs native trap fixtures. On hosts
    # where the bootstrapped stage1 cannot drive compile->as->ld->run (Windows, or
    # a Linux stage1 that failed the compile-native probe), skip this seed
    # compatibility path; fresh cli.tl build/run is covered above.
    echo
    echo "[no-rust-stage0] skipping safety corpus; needs stage1 compile->as->ld->run in this compatibility path"
else
    run_with_compiler "$SAFETY_GATE_TYPELISP_BIN" "$SAFETY_GATE_LABEL" scripts/verify-safety-corpus.sh
fi
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN

if [ "$STAGE1_CAN_COMPILE_NATIVE" -eq 1 ]; then
    # The bootstrapped stage1 compiles + assembles + links + runs native programs
    # (compile-native probe confirmed), so run the integration corpus and examples
    # on the artifact we built via compile -> assemble -> link -> run (as/ld on
    # Linux, clang/lld-link on Windows), instead of skipping. On Linux, stdlib
    # fixtures use the same compile -> as -> ld path, so they can also execute on
    # the compile-only stage1. Windows stdlib fixtures still need the public
    # `build` host action and remain in the explicit fallback/skip lane.
    run_with_compiler "$BOOTSTRAPPED_STAGE1" "stage1 native integration corpus" scripts/verify-integration.sh
    run_with_compiler "$BOOTSTRAPPED_STAGE1" "stage1 examples" scripts/verify-examples.sh
    if [ "$HOST_OS" = linux ]; then
        run_with_compiler "$BOOTSTRAPPED_STAGE1" "stage1 SPMD SIMD comparison" scripts/verify-spmd-simd.sh
        run_with_compiler "$BOOTSTRAPPED_STAGE1" "stage1 stdlib modules and fixtures" \
            env TYPELISP_STDLIB_BORROWED_STR_BIN="$BOOTSTRAPPED_STAGE1" scripts/verify-stdlib.sh
    else
        echo
        echo "[no-rust-stage0] stdlib modules/fixtures stay deferred on Windows until this lane has a full stage1 build command"
    fi
elif [ "$WINDOWS_SEED_STAGED_RUNTIME_GAP" -eq 1 ] ||
    [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] ||
    [ "$SEED_STAGE1_WRAPPER" -eq 1 ]; then
    echo
    echo "[no-rust-stage0] skipping seed build/run artifact gates until staged runtime symbols and full seed CLI parity land in stage0:"
    echo "[no-rust-stage0]   native integration corpus, examples, stdlib modules and fixtures"
elif [ "$HOST_OS" = linux ] && [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; then
    echo
    echo "[no-rust-stage0] skipping seed build/run artifact gates until the stage1 bundle reaches compiler/runtime parity:"
    echo "[no-rust-stage0]   native integration corpus, examples, stdlib modules and fixtures"
elif [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
    # These gates build and run native programs (integration corpus, examples,
    # stdlib fixtures via `typelisp build`/`run`). Keep them disabled in this
    # compatibility seed path; fresh cli.tl direct build/run is covered earlier,
    # while this broad path still has package/generated-program parity gaps.
    # cli.tl's compile/check coverage for these sources stays exercised by the
    # deterministic assembly + selfhost compile manifest gates and the
    # borrowed-str check gate.
    echo
    echo "[no-rust-stage0] skipping seed build/run artifact gates in the compatibility path:"
    echo "[no-rust-stage0]   native integration corpus, examples, stdlib modules and fixtures"
else
    run_gate "native integration corpus" scripts/verify-integration.sh
    run_gate "examples" scripts/verify-examples.sh
    if [ "$HOST_OS" = linux ]; then
        run_gate "stdlib modules and fixtures" env TYPELISP_STDLIB_BORROWED_STR_BIN="$STAGE1_TYPELISP_BIN" scripts/verify-stdlib.sh
    else
        run_gate "stdlib modules and fixtures" env TYPELISP_STDLIB_SKIP_BORROWED_STR=1 scripts/verify-stdlib.sh
    fi
fi

if [ "$HOST_OS" = linux ]; then
    if [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
        DOC_SITE_OUT="$ROOT/target/no-rust-docs-pages-site"
        export DOC_SITE_OUT
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 docs Pages build path" scripts/verify-doc-site.sh
        unset DOC_SITE_OUT
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 selfhost native generated programs" scripts/verify-selfhost-native.sh
        run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 selfhost external compiler corpus" scripts/verify-selfhost.sh
    elif [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] || [ "$SEED_STAGE1_WRAPPER" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping Linux stage1 generated gates until wrapper host-action drivers are available (#1662):"
        echo "[no-rust-stage0]   docs Pages build path, selfhost native generated programs,"
        echo "[no-rust-stage0]   selfhost external compiler corpus"
    elif [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping Linux stage1 generated gates until bundled host-action drivers are available (#1662):"
        echo "[no-rust-stage0]   docs Pages build path, selfhost native generated programs,"
        echo "[no-rust-stage0]   selfhost external compiler corpus"
    else
        # These gates build/run generated programs (docs Pages site, selfhost
        # native programs, the external selfhost compiler corpus). Keep them on
        # the compatibility skip path until this lane runs a full current cli.tl
        # artifact and the generated-program parity gaps are closed.
        echo
        echo "[no-rust-stage0] skipping Linux generated gates in the compatibility path:"
        echo "[no-rust-stage0]   docs Pages build path, selfhost native generated programs,"
        echo "[no-rust-stage0]   selfhost external compiler corpus"
    fi
else
    echo
    echo "[no-rust-stage0] skipping Linux-only gates on Windows:"
    echo "[no-rust-stage0]   stdlib documentation, selfhost native generated programs,"
    echo "[no-rust-stage0]   selfhost external compiler corpus"
fi

echo
echo "no-Rust stage0 verification passed"
