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
  tag:        ${TYPELISP_STAGE0_TAG:-stage0-20260822-184622-r32590855062}
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

# #6785 recovery pin: stage0-latest published from #6767 crashes while loading
# dotted stdlib imports, before it can compile the source repair. Both PR CI and
# the self-publication workflow use this default. Explicit tags are unchanged.
# Remove the pin after a healthy successor has replaced stage0-latest.
TAG=${1:-${TYPELISP_STAGE0_TAG:-stage0-20260822-184622-r32590855062}}
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
        BUNDLE_ASSET=
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
            echo "[stage0] downloaded stage0 asset is empty (possibly mid-republish): $asset" >&2
            rm -f "$target"
            return 1
        fi
        ASSET=$asset
        ASSET_TMP=$target
        return 0
    fi
    rm -f "$target"
    return 1
}

# Download the host asset (Linux: bundle first, single fallback) plus the
# SHA256SUMS manifest, and verify them together. Returns non-zero on any
# transient miss so the caller can retry the whole download+verify as one unit.
#
# The mutable stage0-latest release is promoted from a fully uploaded draft on
# every push to main (see .github/workflows/bootstrap-stage0.yml). GitHub cannot
# atomically replace the old release/tag alias, so a concurrent fetch can still
# observe a brief 404 during the two API mutations or CDN propagation. Fetching
# the asset and SHA256SUMS together on every fresh attempt keeps that bounded
# cutover safe instead of failing the whole CI gate.
fetch_and_verify() {
    ASSET=
    ASSET_TMP=
    ASSET_KIND=single

    if [ -n "$BUNDLE_ASSET" ]; then
        echo "[stage0] downloading $BUNDLE_ASSET from $REPO@$TAG"
        if download_asset "$BUNDLE_ASSET"; then
            ASSET_KIND=bundle
        else
            echo "[stage0] bundled Linux stage0 asset not present yet; trying $SINGLE_ASSET"
        fi
    fi

    if [ -z "$ASSET" ]; then
        echo "[stage0] downloading $SINGLE_ASSET from $REPO@$TAG"
        if ! download_asset "$SINGLE_ASSET"; then
            echo "[stage0] could not download $BASE_URL/$SINGLE_ASSET" >&2
            return 1
        fi
    fi

    if curl -fsSL "$BASE_URL/SHA256SUMS" -o "$SUMS_TMP" 2>/dev/null; then
        if ! command -v sha256sum >/dev/null 2>&1; then
            echo "SHA256SUMS is published but sha256sum is not available" >&2
            exit 1
        fi
        if ! grep "  $ASSET\$" "$SUMS_TMP" > "$SUMS_SELECTED"; then
            echo "[stage0] SHA256SUMS does not yet list $ASSET (republish in progress?)" >&2
            return 1
        fi
        if ! (cd "$TMP_DIR" && sha256sum -c "$(basename "$SUMS_SELECTED")"); then
            echo "[stage0] SHA256SUMS verification failed for $ASSET (republish in progress?)" >&2
            return 1
        fi
    else
        if [ "$TAG" = stage0-latest ]; then
            echo "[stage0] SHA256SUMS is not visible for stage0-latest yet" >&2
            return 1
        fi
        echo "[stage0] warning: SHA256SUMS not found for $TAG; verified non-empty asset only" >&2
    fi

    return 0
}

FETCH_ATTEMPTS=${TYPELISP_STAGE0_FETCH_ATTEMPTS:-6}
FETCH_RETRY_DELAY=${TYPELISP_STAGE0_FETCH_RETRY_DELAY:-5}
case "$FETCH_ATTEMPTS" in '' | *[!0-9]*) FETCH_ATTEMPTS=6 ;; esac
case "$FETCH_RETRY_DELAY" in '' | *[!0-9]*) FETCH_RETRY_DELAY=5 ;; esac

attempt=1
while :; do
    if fetch_and_verify; then
        break
    fi
    if [ "$attempt" -ge "$FETCH_ATTEMPTS" ]; then
        echo "failed to fetch a consistent stage0 from $REPO@$TAG after $attempt attempt(s)" >&2
        echo "(stage0-latest may be mid-republish, or the asset is genuinely missing)" >&2
        exit 1
    fi
    echo "[stage0] attempt $attempt/$FETCH_ATTEMPTS did not yield a consistent release (likely a stage0-latest republish in progress); retrying in ${FETCH_RETRY_DELAY}s" >&2
    attempt=$((attempt + 1))
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    sleep "$FETCH_RETRY_DELAY"
done

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
