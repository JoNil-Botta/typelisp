#!/usr/bin/env sh
set -eu

# verify-stage0-smoke.sh - minimal publication smoke for a freshly built stage0.
#
# The bootstrap workflow publishes this compiler as stage0-latest, so keep this
# gate focused on failures that make the released binary unusable before wider
# CI can consume it.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/verify-stage0-smoke.sh <typelisp-binary>

Checks that a freshly built stage0 can typecheck ordinary sources through both
the source-stdlib override path and the embedded no-root path.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

TL=$1

if [ ! -f "$TL" ]; then
    echo "stage0 binary does not exist: $TL" >&2
    exit 1
fi
if [ ! -x "$TL" ]; then
    chmod +x "$TL" 2>/dev/null || true
fi
if [ ! -x "$TL" ]; then
    echo "stage0 binary is not executable: $TL" >&2
    exit 1
fi

mkdir -p "$ROOT/target"
VERSION_OUT="$ROOT/target/stage0-smoke-version.out"
VERSION_ERR="$ROOT/target/stage0-smoke-version.err"

echo "[stage0-smoke] report compiler version"
if ! "$TL" --version > "$VERSION_OUT" 2> "$VERSION_ERR"; then
    echo "stage0 --version failed" >&2
    sed 's/^/  /' "$VERSION_OUT" >&2 || true
    sed 's/^/  /' "$VERSION_ERR" >&2 || true
    exit 1
fi
if ! grep -F -- "typelisp " "$VERSION_OUT" >/dev/null; then
    echo "stage0 --version did not report a typelisp version line" >&2
    sed 's/^/  /' "$VERSION_OUT" >&2 || true
    exit 1
fi
if ! grep -F -- " built " "$VERSION_OUT" >/dev/null; then
    echo "stage0 --version did not report a build date field" >&2
    sed 's/^/  /' "$VERSION_OUT" >&2 || true
    exit 1
fi
if [ -s "$VERSION_ERR" ]; then
    echo "stage0 --version wrote unexpected stderr" >&2
    sed 's/^/  /' "$VERSION_ERR" >&2 || true
    exit 1
fi

if command -v llvm-readobj >/dev/null 2>&1 \
    || command -v readelf >/dev/null 2>&1 \
    || command -v objdump >/dev/null 2>&1; then
    echo "[stage0-smoke] report stage0 binary size"
    scripts/analyze-stage0-size.sh "$TL"
else
    echo "[stage0-smoke] skip stage0 binary size report; no section reader found"
fi

echo "[stage0-smoke] check examples/hello.tl with source stdlib"
"$TL" check examples/hello.tl --stdlib-root stdlib

echo "[stage0-smoke] check examples/hello.tl with embedded stdlib"
"$TL" check examples/hello.tl

echo "[stage0-smoke] check src/main.tl with compiler roots"
"$TL" check src/main.tl --stdlib-root stdlib --stdlib-root src

echo "[stage0-smoke] passed"
