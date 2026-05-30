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

make_stage1_cli_wrapper() {
    stage1_bin=$1
    stage1_test_bin=${2:-}
    stage1_doc_bin=${3:-}
    stage1_build_bin=${4:-}
    stage1_repl_bin=${5:-}
    stage1_lsp_bin=${6:-}
    stage1_lint_bin=${7:-}
    stage1_format_bin=${8:-}
    wrapper_dir="$ROOT/target/no-rust-stage1-wrapper"
    wrapper="$wrapper_dir/typelisp"
    rm -rf "$wrapper_dir"
    mkdir -p "$wrapper_dir"
    cat > "$wrapper" <<EOF
#!/usr/bin/env sh
set -eu
TYPELISP_STAGE1_BIN='$stage1_bin'
export TYPELISP_STAGE1_BIN
TYPELISP_STAGE1_TEST_BIN='$stage1_test_bin'
export TYPELISP_STAGE1_TEST_BIN
TYPELISP_STAGE1_DOC_BIN='$stage1_doc_bin'
export TYPELISP_STAGE1_DOC_BIN
TYPELISP_STAGE1_BUILD_BIN='$stage1_build_bin'
export TYPELISP_STAGE1_BUILD_BIN
TYPELISP_STAGE1_REPL_BIN='$stage1_repl_bin'
export TYPELISP_STAGE1_REPL_BIN
TYPELISP_STAGE1_LSP_BIN='$stage1_lsp_bin'
export TYPELISP_STAGE1_LSP_BIN
TYPELISP_STAGE1_LINT_BIN='$stage1_lint_bin'
export TYPELISP_STAGE1_LINT_BIN
TYPELISP_STAGE1_FORMAT_BIN='$stage1_format_bin'
export TYPELISP_STAGE1_FORMAT_BIN
TYPELISP_STAGE1_DRIVER_CACHE_DIR='$wrapper_dir/cache'
export TYPELISP_STAGE1_DRIVER_CACHE_DIR
exec '$ROOT/scripts/stage1-typelisp-wrapper.sh' "\$@"
EOF
    chmod +x "$wrapper"
    printf '%s\n' "$wrapper"
}

build_stage1_doc_driver() {
    build_stage1_wrapper_driver "$1" doc selfhost/doc.tl selfhost-doc
}

build_stage1_build_driver() {
    build_stage1_wrapper_driver "$1" build selfhost/build.tl selfhost-build
}

build_stage1_repl_driver() {
    build_stage1_wrapper_driver "$1" repl selfhost/repl.tl selfhost-repl
}

build_stage1_lsp_driver() {
    build_stage1_wrapper_driver "$1" lsp selfhost/lsp_frame.tl selfhost-lsp
}

build_stage1_lint_driver() {
    build_stage1_wrapper_driver "$1" lint selfhost/lint.tl selfhost-lint
}

build_stage1_format_driver() {
    build_stage1_wrapper_driver "$1" format selfhost/format.tl selfhost-format
}

stage1_driver_staged_symbols() {
    printf '%s\n' \
        file-read-chunk-status \
        file-write-status \
        file-flush-status \
        append-file-status
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
    set +e
    "$compiler" check "$ROOT/stdlib/io.tl" --stdlib-root "$ROOT/stdlib" \
        > "$probe_dir/compile.stdout" 2> "$probe_dir/compile.stderr"
    probe_code=$?
    set -e
    [ "$probe_code" -ne 0 ] || return 1
    staged_runtime_symbol_in_files "$probe_dir/compile.stdout" "$probe_dir/compile.stderr"
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

try_build_stage1_wrapper_driver() {
    compiler=$1
    label=$2
    source=$3
    stem=$4
    driver_dir=$5
    asm="$driver_dir/$stem.s"
    obj="$driver_dir/$stem.o"
    bin="$driver_dir/$stem"

    rm -rf "$driver_dir"
    mkdir -p "$driver_dir"
    if ! "$compiler" compile "$ROOT/$source" -o "$asm" --target linux-x86_64 --backend-mode scalar --stdlib-root "$ROOT/stdlib" \
        > "$driver_dir/compile.stdout" 2> "$driver_dir/compile.stderr"; then
        return 1
    fi
    if ! as "$asm" -o "$obj" >> "$driver_dir/compile.stdout" 2>> "$driver_dir/compile.stderr"; then
        return 1
    fi
    if ! ld "$obj" -o "$bin" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc \
        >> "$driver_dir/compile.stdout" 2>> "$driver_dir/compile.stderr"; then
        return 1
    fi
    ensure_executable "stage1 $label driver" "$bin"
    printf '%s\n' "$bin"
}

build_stage1_wrapper_driver() {
    seed=$1
    label=$2
    source=$3
    stem=$4
    driver_dir="$ROOT/target/no-rust-stage1-$label-driver"
    asm="$driver_dir/$stem.s"
    obj="$driver_dir/$stem.o"
    bin="$driver_dir/$stem"

    command -v as >/dev/null 2>&1 || {
        echo "stage1 $label driver prebuild requires 'as'" >&2
        exit 1
    }
    command -v ld >/dev/null 2>&1 || {
        echo "stage1 $label driver prebuild requires 'ld'" >&2
        exit 1
    }

    if try_build_stage1_wrapper_driver "$seed" "$label" "$source" "$stem" "$driver_dir"; then
        return 0
    fi

    # The seed compiler can lag behind freshly added runtime primitives while
    # the current selfhost compiler already knows them. Keep the seed path for
    # speed, but retry with the bootstrapped stage1 compiler for that staged
    # symbol gap so no-Rust verification can cover the rest of the change.
    if [ -n "${TYPELISP_BIN:-}" ] && [ "$seed" != "$TYPELISP_BIN" ] &&
        stage1_driver_prebuild_failed_for_staged_symbol "$driver_dir"; then
        echo "stage1 $label driver prebuild with seed hit a staged runtime symbol; retrying with stage1 compiler" >&2
        if try_build_stage1_wrapper_driver "$TYPELISP_BIN" "$label" "$source" "$stem" "$driver_dir"; then
            return 0
        fi
    fi

    show_stage1_driver_prebuild_failure "$label" "$driver_dir"
    exit 1
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
    if [ "$probe_status" -ne 135 ] ||
        ! grep -qF "tl: integer division or remainder error" "$probe_dir/run.stderr"; then
        echo "[no-rust-stage0] stage1 safety probe expected div-zero trap exit 135"
        sed 's/^/  /' "$probe_dir/run.stdout" >&2 || true
        sed 's/^/  /' "$probe_dir/run.stderr" >&2 || true
        return 1
    fi
    return 0
}

echo "[no-rust-stage0] host=$HOST_OS seed=$SEED_TYPELISP_BIN"

if [ "$HOST_OS" = linux ]; then
    STAGE1_PATH_FILE="$ROOT/target/no-rust-stage0-stage1.path"
    rm -f "$STAGE1_PATH_FILE"
    TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE=$STAGE1_PATH_FILE
    TYPELISP_BOOTSTRAP_STAGE1_ONLY=1
    export TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE
    export TYPELISP_BOOTSTRAP_STAGE1_ONLY
    run_gate "bootstrap stage1 build" scripts/check-bootstrap-fixpoint.sh "$SEED_TYPELISP_BIN"
    unset TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE
    unset TYPELISP_BOOTSTRAP_STAGE1_ONLY
    if [ -s "$STAGE1_PATH_FILE" ]; then
        TYPELISP_BIN=$(sed -n '1p' "$STAGE1_PATH_FILE")
    else
        TYPELISP_BIN="$ROOT/target/bootstrap-fixpoint/stage1"
    fi
    ensure_executable "stage1" "$TYPELISP_BIN"

    LINUX_SEED_STAGED_RUNTIME_GAP=0
    if seed_has_staged_runtime_gap "$SEED_TYPELISP_BIN"; then
        LINUX_SEED_STAGED_RUNTIME_GAP=1
        echo "[no-rust-stage0] Linux seed lacks staged runtime symbols used by stdlib/io.tl; limiting stage1 to compile-only gates"
    fi

    STAGE1_DOC_BIN=
    STAGE1_BUILD_BIN=
    STAGE1_REPL_BIN=
    STAGE1_LINT_BIN=
    STAGE1_FORMAT_BIN=
    STAGE1_TEST_BIN=
    STAGE1_LSP_BIN=
    STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=0
    SEED_IS_STAGE1_BUNDLE=0
    SEED_DIR=$(CDPATH= cd -- "$(dirname -- "$SEED_TYPELISP_BIN")" && pwd)
    if [ -x "$SEED_DIR/lib/stage1/typelisp-stage1" ]; then
        SEED_IS_STAGE1_BUNDLE=1
    fi
    BUNDLED_STAGE1_DRIVER_DIR="$SEED_DIR/lib/stage1/drivers"
    if [ -x "$BUNDLED_STAGE1_DRIVER_DIR/selfhost-test" ]; then
        STAGE1_TEST_BIN="$BUNDLED_STAGE1_DRIVER_DIR/selfhost-test"
    fi
    if [ -x "$BUNDLED_STAGE1_DRIVER_DIR/selfhost-doc" ] &&
        [ -x "$BUNDLED_STAGE1_DRIVER_DIR/selfhost-build" ] &&
        [ -x "$BUNDLED_STAGE1_DRIVER_DIR/selfhost-repl" ]; then
        STAGE1_DOC_BIN="$BUNDLED_STAGE1_DRIVER_DIR/selfhost-doc"
        STAGE1_BUILD_BIN="$BUNDLED_STAGE1_DRIVER_DIR/selfhost-build"
        STAGE1_REPL_BIN="$BUNDLED_STAGE1_DRIVER_DIR/selfhost-repl"
        if [ -x "$BUNDLED_STAGE1_DRIVER_DIR/selfhost-lsp" ]; then
            STAGE1_LSP_BIN="$BUNDLED_STAGE1_DRIVER_DIR/selfhost-lsp"
        elif [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 0 ]; then
            STAGE1_LSP_BIN=$(build_stage1_lsp_driver "$SEED_TYPELISP_BIN")
        fi
        STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=1
        echo "[no-rust-stage0] using bundled stage1 doc/build/repl drivers"
    elif [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 0 ]; then
        STAGE1_DOC_BIN=$(build_stage1_doc_driver "$SEED_TYPELISP_BIN")
        STAGE1_BUILD_BIN=$(build_stage1_build_driver "$SEED_TYPELISP_BIN")
        STAGE1_REPL_BIN=$(build_stage1_repl_driver "$SEED_TYPELISP_BIN")
        STAGE1_LSP_BIN=$(build_stage1_lsp_driver "$SEED_TYPELISP_BIN")
        STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=1
    else
        echo "[no-rust-stage0] skipping eager stage1 doc/build/repl/lsp driver prebuild until staged runtime symbols land in stage0"
    fi
    if [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
        if [ -x "$BUNDLED_STAGE1_DRIVER_DIR/selfhost-lint" ]; then
            STAGE1_LINT_BIN="$BUNDLED_STAGE1_DRIVER_DIR/selfhost-lint"
            echo "[no-rust-stage0] using bundled stage1 lint driver"
        else
            STAGE1_LINT_BIN=$(build_stage1_lint_driver "$SEED_TYPELISP_BIN")
        fi
        if [ -x "$BUNDLED_STAGE1_DRIVER_DIR/selfhost-format" ]; then
            STAGE1_FORMAT_BIN="$BUNDLED_STAGE1_DRIVER_DIR/selfhost-format"
            echo "[no-rust-stage0] using bundled stage1 format driver"
        else
            STAGE1_FORMAT_BIN=$(build_stage1_format_driver "$SEED_TYPELISP_BIN")
        fi
    fi
    STAGE1_TYPELISP_BIN=$(make_stage1_cli_wrapper "$TYPELISP_BIN" "$STAGE1_TEST_BIN" "$STAGE1_DOC_BIN" "$STAGE1_BUILD_BIN" "$STAGE1_REPL_BIN" "$STAGE1_LSP_BIN" "$STAGE1_LINT_BIN" "$STAGE1_FORMAT_BIN")
    echo
    echo "[no-rust-stage0] stage1 CLI wrapper=$STAGE1_TYPELISP_BIN"
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
    echo "[no-rust-stage0] Windows seed lacks staged runtime symbols used by stdlib/io.tl"
fi
if [ "$HOST_OS" != linux ]; then
    LINUX_SEED_STAGED_RUNTIME_GAP=0
    STAGE1_HOST_ACTION_DRIVERS_AVAILABLE=0
    SEED_IS_STAGE1_BUNDLE=0
fi
SEED_STAGE1_WRAPPER=0
if compiler_is_stage1_wrapper "$SEED_TYPELISP_BIN"; then
    SEED_STAGE1_WRAPPER=1
    echo "[no-rust-stage0] seed is a stage1 wrapper; full Rust CLI parity gates remain in the Rust lane"
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

# The public-tool corpus is the broadest CLI behavior witness. On Linux, run it
# against the freshly bootstrapped stage1 wrapper whenever the wrapper's
# host-action drivers are available. The seed path below is only a compatibility
# fallback for old artifacts or missing drivers (#1327).
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
        echo "[no-rust-stage0] skipping seed public tool surface until stage1 host-action drivers are available (#1327)"
    elif [ "$HOST_OS" = windows ]; then
        if compiler_rejects_package_kind_manifest "$FRONT_GATE_TYPELISP_BIN"; then
            echo
            echo "[no-rust-stage0] Windows seed rejects package kind; using legacy package manifests for public tool surface"
            run_with_compiler "$FRONT_GATE_TYPELISP_BIN" "public tool surface" env TYPELISP_LEGACY_PACKAGE_MANIFEST=1 scripts/verify-public-tools.sh
        else
            run_with_compiler "$FRONT_GATE_TYPELISP_BIN" "public tool surface" scripts/verify-public-tools.sh
        fi
    elif [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping public tool surface until bundled stage1 host-action drivers are available (#1327)"
    elif [ "$SEED_STAGE1_WRAPPER" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping seed public tool surface until stage1 wrapper host-action drivers are available (#1327)"
    else
        echo
        echo "[no-rust-stage0] falling back to seed for public tool surface; stage1 host-action drivers are unavailable (#1327)"
        if compiler_rejects_package_kind_manifest "$PUBLIC_TOOLS_TYPELISP_BIN"; then
            echo "[no-rust-stage0] seed rejects package kind; using legacy package manifests for public tool surface"
            run_with_compiler "$PUBLIC_TOOLS_TYPELISP_BIN" "$PUBLIC_TOOLS_LABEL" env TYPELISP_LEGACY_PACKAGE_MANIFEST=1 scripts/verify-public-tools.sh
        else
            run_with_compiler "$PUBLIC_TOOLS_TYPELISP_BIN" "$PUBLIC_TOOLS_LABEL" scripts/verify-public-tools.sh
        fi
    fi
    if [ "$HOST_OS" = linux ] &&
        [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] &&
        [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ]; then
        echo
        echo "[no-rust-stage0] skipping repository doctests until staged runtime symbols land in stage0"
    else
        run_with_compiler "$DOCTEST_TYPELISP_BIN" "repository doctests" scripts/verify-doc-tests.sh
    fi
fi
if [ "$HOST_OS" = linux ] &&
    [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ] &&
    [ -z "$STAGE1_TEST_BIN" ]; then
    echo
    echo "[no-rust-stage0] skipping inline TypeLisp tests until the stage1 bundle carries a selfhost test driver"
else
    run_with_compiler "$FRONT_GATE_TYPELISP_BIN" "inline TypeLisp tests" scripts/verify-inline-tests.sh
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
    run_gate "selfhost compile manifest" scripts/verify-selfhost-compile-manifest.sh
    run_gate "deterministic assembly" scripts/check-deterministic-asm.sh
    if [ "$WINDOWS_SEED_STAGED_RUNTIME_GAP" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping Windows selfhost MSVC link.exe build/run and bootstrap fixpoint until the seed provides staged runtime symbols"
    else
        run_gate "windows selfhost MSVC link.exe build/run" scripts/verify-windows-selfhost-msvc-link.sh
        run_gate "windows bootstrap fixpoint" scripts/check-bootstrap-fixpoint.sh "$SEED_TYPELISP_BIN"
    fi
fi
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN
# The repository format gate runs `typelisp fmt --check` over the whole TypeLisp
# corpus. On Linux, serve it through the stage1 wrapper's cached selfhost format
# driver whenever the host-action drivers are available so the fmt capability
# tier no longer depends on the seed/published compiler (#1544). The wrapper's
# format driver is built once and reused across the batched invocations. When
# the drivers are unavailable (or on Windows) the seed compiler keeps the gate.
FORMAT_GATE_TYPELISP_BIN=$SEED_TYPELISP_BIN
if [ "$HOST_OS" = linux ] && [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
    FORMAT_GATE_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
fi
run_with_compiler "$FORMAT_GATE_TYPELISP_BIN" "TypeLisp source formatting" scripts/check-tl-format.sh
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN

# The safety corpus is a build/run capability gate, but its fixtures are small
# enough to run through the freshly bootstrapped stage1 wrapper when the Linux
# host-action drivers and checked-trap helpers are available (#1267). Keep the
# seed path only for older artifacts or hosts where the wrapper cannot execute
# native programs yet.
SAFETY_GATE_TYPELISP_BIN=$SEED_TYPELISP_BIN
SAFETY_GATE_LABEL="safety corpus"
SAFETY_GATE_STAGE1_PROBE_FAILED=0
if [ "$HOST_OS" = linux ] && [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 1 ]; then
    if stage1_safety_corpus_supported "$STAGE1_TYPELISP_BIN"; then
        SAFETY_GATE_TYPELISP_BIN=$STAGE1_TYPELISP_BIN
        SAFETY_GATE_LABEL="stage1 safety corpus"
    else
        SAFETY_GATE_STAGE1_PROBE_FAILED=1
    fi
fi
if [ "$WINDOWS_SEED_STAGED_RUNTIME_GAP" -eq 1 ]; then
    echo
    echo "[no-rust-stage0] skipping Windows safety corpus until the seed provides staged runtime symbols"
elif [ "$HOST_OS" = linux ] &&
    [ "$SAFETY_GATE_STAGE1_PROBE_FAILED" -eq 1 ] &&
    { [ "$SEED_STAGE1_WRAPPER" -eq 1 ] || [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; }; then
    echo
    echo "[no-rust-stage0] skipping safety corpus until stage1 checked trap helpers land (#1455)"
elif [ "$HOST_OS" = linux ] &&
    [ "$STAGE1_HOST_ACTION_DRIVERS_AVAILABLE" -eq 0 ] &&
    { [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] ||
        [ "$SEED_STAGE1_WRAPPER" -eq 1 ] ||
        [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; }; then
    echo
    echo "[no-rust-stage0] skipping safety corpus until stage1 host-action drivers are available"
else
    if [ "$HOST_OS" = linux ] && [ "$SAFETY_GATE_STAGE1_PROBE_FAILED" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] using seed safety corpus until stage1 checked trap helpers land (#1455)"
    fi
    run_with_compiler "$SAFETY_GATE_TYPELISP_BIN" "$SAFETY_GATE_LABEL" scripts/verify-safety-corpus.sh
fi
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN

if [ "$WINDOWS_SEED_STAGED_RUNTIME_GAP" -eq 1 ] ||
    [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] ||
    [ "$SEED_STAGE1_WRAPPER" -eq 1 ]; then
    echo
    echo "[no-rust-stage0] skipping seed build/run artifact gates until staged runtime symbols and full seed CLI parity land in stage0:"
    echo "[no-rust-stage0]   native integration corpus, examples, stdlib modules and fixtures"
elif [ "$HOST_OS" = linux ] && [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; then
    echo
    echo "[no-rust-stage0] skipping seed build/run artifact gates until the stage1 bundle reaches compiler/runtime parity:"
    echo "[no-rust-stage0]   native integration corpus, examples, stdlib modules and fixtures"
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
    elif [ "$LINUX_SEED_STAGED_RUNTIME_GAP" -eq 1 ] || [ "$SEED_STAGE1_WRAPPER" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping Linux stage1 generated gates until wrapper host-action drivers are available (#1327):"
        echo "[no-rust-stage0]   docs Pages build path, selfhost native generated programs,"
        echo "[no-rust-stage0]   selfhost external compiler corpus"
    elif [ "$SEED_IS_STAGE1_BUNDLE" -eq 1 ]; then
        echo
        echo "[no-rust-stage0] skipping Linux stage1 generated gates until bundled host-action drivers are available (#1327):"
        echo "[no-rust-stage0]   docs Pages build path, selfhost native generated programs,"
        echo "[no-rust-stage0]   selfhost external compiler corpus"
    else
        echo
        echo "[no-rust-stage0] falling back to seed for Linux generated gates; stage1 host-action drivers are unavailable (#1327)"
        DOC_SITE_OUT="$ROOT/target/no-rust-docs-pages-site"
        export DOC_SITE_OUT
        run_gate "seed docs Pages build path" scripts/verify-doc-site.sh
        unset DOC_SITE_OUT
        run_gate "seed selfhost native generated programs" scripts/verify-selfhost-native.sh
        run_gate "seed selfhost external compiler corpus" scripts/verify-selfhost.sh
    fi
else
    echo
    echo "[no-rust-stage0] skipping Linux-only gates on Windows:"
    echo "[no-rust-stage0]   stdlib documentation, selfhost native generated programs,"
    echo "[no-rust-stage0]   selfhost external compiler corpus"
fi

echo
echo "no-Rust stage0 verification passed"
