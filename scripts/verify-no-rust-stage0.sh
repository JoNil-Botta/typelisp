#!/usr/bin/env sh
set -eu

# verify-no-rust-stage0.sh - CI/local gate for the published stage0 compiler.
#
# This script intentionally does not build the Rust compiler. It fetches the
# published stage0 artifact when TYPELISP_BIN is unset, exports TYPELISP_BIN for
# all child verification scripts, and guards against accidental cargo/rustc
# fallback by shadowing those commands with failing shims.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/verify-no-rust-stage0.sh

Runs the repository's no-Rust verification gate against TYPELISP_BIN.
If TYPELISP_BIN is unset, downloads stage0-latest with scripts/fetch-stage0.sh.
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
    TYPELISP_BIN="$ROOT/target/stage0/typelisp"
    if [ "$HOST_OS" = windows ]; then
        TYPELISP_BIN="$TYPELISP_BIN.exe"
    fi
fi
export TYPELISP_BIN

if [ ! -f "$TYPELISP_BIN" ]; then
    echo "stage0 compiler does not exist: $TYPELISP_BIN" >&2
    exit 1
fi
if [ ! -x "$TYPELISP_BIN" ]; then
    chmod +x "$TYPELISP_BIN" 2>/dev/null || true
fi
if [ ! -x "$TYPELISP_BIN" ]; then
    echo "stage0 compiler is not executable: $TYPELISP_BIN" >&2
    exit 1
fi

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

echo "[no-rust-stage0] host=$HOST_OS compiler=$TYPELISP_BIN"

run_gate "public tool surface" scripts/verify-public-tools.sh
run_gate "repository doctests" scripts/verify-doc-tests.sh
run_gate "inline TypeLisp tests" scripts/verify-inline-tests.sh
run_gate "selfhost compile manifest" scripts/verify-selfhost-compile-manifest.sh
run_gate "deterministic assembly" scripts/check-deterministic-asm.sh
run_gate "TypeLisp source formatting" scripts/check-tl-format.sh
run_gate "native integration corpus" scripts/verify-integration.sh
run_gate "examples" scripts/verify-examples.sh
run_gate "stdlib modules and fixtures" scripts/verify-stdlib.sh

if [ "$HOST_OS" = linux ]; then
    run_gate "stdlib documentation" scripts/verify-stdlib-docs.sh
    run_gate "selfhost native generated programs" scripts/verify-selfhost-native.sh
    run_gate "selfhost external compiler corpus" scripts/verify-selfhost.sh
    run_gate "bootstrap smoke" scripts/check-bootstrap-smoke.sh
else
    echo
    echo "[no-rust-stage0] skipping Linux-only gates on Windows:"
    echo "[no-rust-stage0]   stdlib documentation, selfhost native generated programs,"
    echo "[no-rust-stage0]   selfhost external compiler corpus, bootstrap smoke"
fi

echo
echo "no-Rust stage0 verification passed"
