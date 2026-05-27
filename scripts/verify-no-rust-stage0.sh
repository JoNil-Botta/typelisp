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
TYPELISP_STAGE1_DRIVER_CACHE_DIR='$wrapper_dir/cache'
export TYPELISP_STAGE1_DRIVER_CACHE_DIR
exec '$ROOT/scripts/stage1-typelisp-wrapper.sh' "\$@"
EOF
    chmod +x "$wrapper"
    printf '%s\n' "$wrapper"
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
    STAGE1_TYPELISP_BIN=$(make_stage1_cli_wrapper "$TYPELISP_BIN")
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
    export TYPELISP_STAGE1_SKIP_TEST_SMOKE
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 CLI host-action wrapper smoke" scripts/check-stage1-wrapper.sh
    unset TYPELISP_STAGE1_SKIP_TEST_SMOKE
    run_with_compiler "$STAGE1_TYPELISP_BIN" "stage1 deterministic assembly" scripts/check-deterministic-asm.sh
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
    run_gate "stdlib documentation" scripts/verify-stdlib-docs.sh
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
