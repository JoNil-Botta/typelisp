#!/usr/bin/env sh
set -eu

# fetch-stage0.sh - download the published stage0 compiler for this host.
#
# Defaults to the mutable stage0-latest release, using release asset URLs rather
# than git tags so local tag state cannot make the "latest" pointer stale.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/fetch-stage0.sh [tag] [output-dir]

Downloads the current host's stage0 compiler from a GitHub release.

Defaults:
  tag:        ${TYPELISP_STAGE0_TAG:-stage0-latest}
  output-dir: ${TYPELISP_STAGE0_DIR:-target/stage0}
  repo:       ${TYPELISP_STAGE0_REPO:-JoNil-Botta/typelisp}

The downloaded binary is written as:
  target/stage0/typelisp      on Linux
  target/stage0/typelisp.exe  on Windows Git Bash/MSYS/Cygwin
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 2 ]; then
    usage
    exit 2
fi

TAG=${1:-${TYPELISP_STAGE0_TAG:-stage0-latest}}
OUT_DIR=${2:-${TYPELISP_STAGE0_DIR:-target/stage0}}
REPO=${TYPELISP_STAGE0_REPO:-JoNil-Botta/typelisp}

case "$TAG" in
    "")
        echo "stage0 tag must not be empty" >&2
        exit 2
        ;;
esac

case "$(uname -s)" in
    Linux*)
        ASSET=typelisp-stage0-linux
        OUTPUT=typelisp
        NEED_EXEC=1
        ;;
    MINGW* | MSYS* | CYGWIN*)
        ASSET=typelisp-stage0-windows.exe
        OUTPUT=typelisp.exe
        NEED_EXEC=0
        ;;
    *)
        echo "stage0 fetch is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    echo "stage0 fetch requires curl" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
TMP_DIR="$OUT_DIR/.stage0-download.$$"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

BASE_URL="https://github.com/$REPO/releases/download/$TAG"
ASSET_TMP="$TMP_DIR/$ASSET"
SUMS_TMP="$TMP_DIR/SHA256SUMS"
SUMS_SELECTED="$TMP_DIR/SHA256SUMS.selected"
DEST="$OUT_DIR/$OUTPUT"

echo "[stage0] downloading $ASSET from $REPO@$TAG"
if ! curl -fsSL "$BASE_URL/$ASSET" -o "$ASSET_TMP"; then
    echo "failed to download $BASE_URL/$ASSET" >&2
    exit 1
fi

if [ ! -s "$ASSET_TMP" ]; then
    echo "downloaded stage0 asset is empty: $ASSET" >&2
    exit 1
fi

if curl -fsSL "$BASE_URL/SHA256SUMS" -o "$SUMS_TMP" 2>/dev/null; then
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo "SHA256SUMS is published but sha256sum is not available" >&2
        exit 1
    fi
    if ! grep "  $ASSET\$" "$SUMS_TMP" > "$SUMS_SELECTED"; then
        echo "SHA256SUMS does not contain $ASSET" >&2
        exit 1
    fi
    (cd "$TMP_DIR" && sha256sum -c "$(basename "$SUMS_SELECTED")")
else
    echo "[stage0] warning: SHA256SUMS not found for $TAG; verified non-empty asset only" >&2
fi

mv "$ASSET_TMP" "$DEST"
if [ "$NEED_EXEC" -eq 1 ]; then
    chmod +x "$DEST"
fi

if [ ! -s "$DEST" ]; then
    echo "stage0 compiler is empty after install: $DEST" >&2
    exit 1
fi
if [ "$NEED_EXEC" -eq 1 ] && [ ! -x "$DEST" ]; then
    echo "stage0 compiler is not executable after install: $DEST" >&2
    exit 1
fi

echo "[stage0] installed $DEST"
