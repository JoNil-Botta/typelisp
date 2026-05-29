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

Downloads the current host's stage0 compiler from a GitHub release. On Linux,
the script prefers the bundled stage0 asset and falls back to the legacy
single-file asset when the bundle is not present.

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
        SINGLE_ASSET=typelisp-stage0-linux
        BUNDLE_ASSET=typelisp-stage0-linux-bundle.tar.gz
        OUTPUT=typelisp
        NEED_EXEC=1
        ;;
    MINGW* | MSYS* | CYGWIN*)
        SINGLE_ASSET=typelisp-stage0-windows.exe
        BUNDLE_ASSET=
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
SUMS_TMP="$TMP_DIR/SHA256SUMS"
SUMS_SELECTED="$TMP_DIR/SHA256SUMS.selected"
DEST="$OUT_DIR/$OUTPUT"
ASSET=
ASSET_TMP=
ASSET_KIND=single

download_asset() {
    asset=$1
    target="$TMP_DIR/$asset"
    if curl -fsSL "$BASE_URL/$asset" -o "$target"; then
        if [ ! -s "$target" ]; then
            echo "downloaded stage0 asset is empty: $asset" >&2
            exit 1
        fi
        ASSET=$asset
        ASSET_TMP=$target
        return 0
    fi
    rm -f "$target"
    return 1
}

install_linux_bundle() {
    archive=$1
    if ! command -v tar >/dev/null 2>&1; then
        echo "Linux stage0 bundle install requires tar" >&2
        exit 1
    fi

    extract_dir="$TMP_DIR/extract"
    install_tmp="$TMP_DIR/install"
    mkdir -p "$extract_dir" "$install_tmp"
    if ! tar -xzf "$archive" -C "$extract_dir"; then
        echo "failed to extract Linux stage0 bundle: $ASSET" >&2
        exit 1
    fi

    if [ -d "$extract_dir/typelisp-stage0-linux-bundle" ]; then
        bundle_root="$extract_dir/typelisp-stage0-linux-bundle"
    else
        bundle_root="$extract_dir"
    fi

    manifest="$bundle_root/STAGE0_BUNDLE"
    if [ ! -s "$manifest" ]; then
        echo "Linux stage0 bundle is missing STAGE0_BUNDLE manifest" >&2
        exit 1
    fi
    first=$(sed -n '1p' "$manifest")
    if [ "$first" != "typelisp-stage0-bundle v1" ]; then
        echo "unsupported Linux stage0 bundle manifest: $first" >&2
        exit 1
    fi

    for required in \
        typelisp \
        scripts/stage1-typelisp-wrapper.sh \
        lib/stage1/typelisp-stage1 \
        lib/stage1/drivers/selfhost-doc \
        lib/stage1/drivers/selfhost-build \
        lib/stage1/drivers/selfhost-repl
    do
        if [ ! -e "$bundle_root/$required" ]; then
            echo "Linux stage0 bundle is missing required path: $required" >&2
            exit 1
        fi
    done
    for required_file in \
        typelisp \
        scripts/stage1-typelisp-wrapper.sh \
        lib/stage1/typelisp-stage1 \
        lib/stage1/drivers/selfhost-doc \
        lib/stage1/drivers/selfhost-build \
        lib/stage1/drivers/selfhost-repl
    do
        if [ ! -s "$bundle_root/$required_file" ]; then
            echo "Linux stage0 bundle contains an empty required file: $required_file" >&2
            exit 1
        fi
    done
    for required_dir in selfhost stdlib; do
        if [ ! -d "$bundle_root/$required_dir" ]; then
            echo "Linux stage0 bundle is missing required directory: $required_dir" >&2
            exit 1
        fi
    done

    cp -R "$bundle_root"/. "$install_tmp"/
    chmod +x \
        "$install_tmp/typelisp" \
        "$install_tmp/scripts/stage1-typelisp-wrapper.sh" \
        "$install_tmp/lib/stage1/typelisp-stage1" \
        "$install_tmp/lib/stage1/drivers/selfhost-doc" \
        "$install_tmp/lib/stage1/drivers/selfhost-build" \
        "$install_tmp/lib/stage1/drivers/selfhost-repl"

    rm -f "$DEST" "$OUT_DIR/STAGE0_BUNDLE"
    rm -rf "$OUT_DIR/lib/stage1" "$OUT_DIR/scripts/stage1-typelisp-wrapper.sh"
    cp -R "$install_tmp"/. "$OUT_DIR"/
}

if [ -n "$BUNDLE_ASSET" ]; then
    echo "[stage0] downloading $BUNDLE_ASSET from $REPO@$TAG"
    if download_asset "$BUNDLE_ASSET"; then
        ASSET_KIND=bundle
    else
        echo "[stage0] bundled Linux stage0 asset not found; falling back to $SINGLE_ASSET"
    fi
fi

if [ -z "$ASSET" ]; then
    echo "[stage0] downloading $SINGLE_ASSET from $REPO@$TAG"
    if ! download_asset "$SINGLE_ASSET"; then
        echo "failed to download $BASE_URL/$SINGLE_ASSET" >&2
        exit 1
    fi
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

if [ "$ASSET_KIND" = bundle ]; then
    echo "[stage0] installing bundled Linux stage0 asset"
    install_linux_bundle "$ASSET_TMP"
else
    mv "$ASSET_TMP" "$DEST"
    if [ "$NEED_EXEC" -eq 1 ]; then
        chmod +x "$DEST"
    fi
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
