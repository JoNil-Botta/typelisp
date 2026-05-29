#!/usr/bin/env sh
set -eu

# verify-no-rust-stage0.sh - CI/local no-Rust compiler gate.
#
# This script intentionally does not build the Rust compiler. It fetches the
# published stage0 artifact when TYPELISP_BIN is unset, guards against
# accidental cargo/rustc fallback by shadowing those commands with failing
# shims, and on Linux runs capability checks against the freshly bootstrapped
# stage1 compiler that passed the fixpoint gate.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/verify-no-rust-stage0.sh

Runs the repository's no-Rust verification gate.
If TYPELISP_BIN is unset, downloads stage0-latest with scripts/fetch-stage0.sh.
On Linux, TYPELISP_BIN is the seed compiler: the script first runs the
bootstrap fixpoint gate, then runs capability checks against the bootstrapped
stage1 compiler. On Windows, it currently runs host-supported capability checks
against the seed compiler until native stage1 bootstrap/link support lands.
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

    rm -rf "$driver_dir"
    mkdir -p "$driver_dir"
    if ! "$seed" compile "$ROOT/$source" -o "$asm" --target linux-x86_64 --backend-mode scalar --stdlib-root "$ROOT/stdlib" \
        > "$driver_dir/compile.stdout" 2> "$driver_dir/compile.stderr"; then
        echo "stage1 $label driver prebuild failed" >&2
        sed 's/^/  /' "$driver_dir/compile.stdout" >&2 || true
        sed 's/^/  /' "$driver_dir/compile.stderr" >&2 || true
        exit 1
    fi
    as "$asm" -o "$obj"
    ld "$obj" -o "$bin" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc
    ensure_executable "stage1 $label driver" "$bin"
    printf '%s\n' "$bin"
}

build_stage1_repl_driver() {
    seed=$1
    driver_dir="$ROOT/target/no-rust-stage1-repl-driver"
    asm="$driver_dir/selfhost-repl.s"
    obj="$driver_dir/selfhost-repl.o"
    bin="$driver_dir/selfhost-repl"

    command -v as >/dev/null 2>&1 || {
        echo "stage1 repl driver prebuild requires 'as'" >&2
        exit 1
    }
    command -v ld >/dev/null 2>&1 || {
        echo "stage1 repl driver prebuild requires 'ld'" >&2
        exit 1
    }

    rm -rf "$driver_dir"
    mkdir -p "$driver_dir"
    if ! "$seed" compile "$ROOT/selfhost/repl.tl" -o "$asm" --target linux-x86_64 --backend-mode scalar --stdlib-root "$ROOT/stdlib" \
        > "$driver_dir/compile.stdout" 2> "$driver_dir/compile.stderr"; then
        echo "stage1 repl driver prebuild failed" >&2
        sed 's/^/  /' "$driver_dir/compile.stdout" >&2 || true
        sed 's/^/  /' "$driver_dir/compile.stderr" >&2 || true
        exit 1
    fi
    as "$asm" -o "$obj"
    ld "$obj" -o "$bin" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc
    ensure_executable "stage1 repl driver" "$bin"
    printf '%s\n' "$bin"
}

run_with_compiler() {
    compiler=$1
    shift
    TYPELISP_BIN=$compiler
    export TYPELISP_BIN
    run_gate "$@"
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
    STAGE1_DOC_BIN=$(build_stage1_doc_driver "$SEED_TYPELISP_BIN")
    STAGE1_BUILD_BIN=$(build_stage1_build_driver "$SEED_TYPELISP_BIN")
    STAGE1_REPL_BIN=$(build_stage1_repl_driver "$SEED_TYPELISP_BIN")
    STAGE1_TYPELISP_BIN=$(make_stage1_cli_wrapper "$TYPELISP_BIN" "" "$STAGE1_DOC_BIN" "$STAGE1_BUILD_BIN" "$STAGE1_REPL_BIN")
    echo
    echo "[no-rust-stage0] stage1 CLI wrapper=$STAGE1_TYPELISP_BIN"
else
    TYPELISP_BIN=$SEED_TYPELISP_BIN
    echo "[no-rust-stage0] capability compiler=$TYPELISP_BIN"
    echo "[no-rust-stage0] Windows stage1 capability tier is deferred until native bootstrap/link support lands"
fi
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN

run_gate "public tool surface" scripts/verify-public-tools.sh
run_gate "repository doctests" scripts/verify-doc-tests.sh
run_gate "inline TypeLisp tests" scripts/verify-inline-tests.sh
if [ "$HOST_OS" = linux ]; then
    # Building the full selfhost test driver in this hosted no-Rust lane is
    # currently too heavy for the runner; #1401 tracks restoring direct stage1
    # test-command coverage without the host-action driver path.
    TYPELISP_STAGE1_SKIP_TEST_SMOKE=1
    # Building the full selfhost doc driver through stage1 is also too heavy
    # for this hosted lane; #1437 tracks restoring direct stage1 coverage for
    # compiler-sized selfhost drivers.
    TYPELISP_STAGE1_SKIP_DOC_SMOKE=1
    export TYPELISP_STAGE1_SKIP_TEST_SMOKE
    export TYPELISP_STAGE1_SKIP_DOC_SMOKE
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 CLI host-action wrapper smoke" scripts/check-stage1-wrapper.sh
    unset TYPELISP_STAGE1_SKIP_TEST_SMOKE
    unset TYPELISP_STAGE1_SKIP_DOC_SMOKE
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 deterministic assembly" scripts/check-deterministic-asm.sh
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 selfhost compile manifest" env TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE=stage1 scripts/verify-selfhost-compile-manifest.sh
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 stdlib documentation" scripts/verify-stdlib-docs.sh
else
    run_gate "selfhost compile manifest" scripts/verify-selfhost-compile-manifest.sh
    run_gate "deterministic assembly" scripts/check-deterministic-asm.sh
fi
TYPELISP_BIN=$SEED_TYPELISP_BIN
export TYPELISP_BIN
run_gate "TypeLisp source formatting" scripts/check-tl-format.sh
run_gate "native integration corpus" scripts/verify-integration.sh
run_gate "examples" scripts/verify-examples.sh
run_gate "stdlib modules and fixtures" scripts/verify-stdlib.sh

if [ "$HOST_OS" = linux ]; then
    DOC_SITE_OUT="$ROOT/target/no-rust-docs-pages-site"
    export DOC_SITE_OUT
    run_gate "docs Pages build path" scripts/verify-doc-site.sh
    unset DOC_SITE_OUT
    run_gate "selfhost native generated programs" scripts/verify-selfhost-native.sh
    run_gate "selfhost external compiler corpus" scripts/verify-selfhost.sh
else
    echo
    echo "[no-rust-stage0] skipping Linux-only gates on Windows:"
    echo "[no-rust-stage0]   stdlib documentation, selfhost native generated programs,"
    echo "[no-rust-stage0]   selfhost external compiler corpus"
fi

echo
echo "no-Rust stage0 verification passed"
