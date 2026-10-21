#!/usr/bin/env sh
set -eu

# The maintainer approved Intel's Simplified Software License for CI (#8664).
# Keep the complete, unmodified distribution, including its license notices.
# stdout is the executable path; download/verification receipts go to stderr.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$#" -le 1 ] || { echo "usage: scripts/fetch-sde.sh [cache-dir]" >&2; exit 2; }
SDE_CACHE=${1:-$ROOT/target/sde}
SDE_RELEASE=10.13.1-2026-07-28
case "$(uname -s)" in
    Linux*)
        SDE_PLATFORM=lin
        SDE_EXE=sde64
        SDE_SHA256=94e97d623fec54385686e1e7ba65ebc9941748c05ee451423948334892bf2b50
        ;;
    MINGW* | MSYS* | CYGWIN*)
        SDE_PLATFORM=win
        SDE_EXE=sde.exe
        SDE_SHA256=74e626ede09b0baa5011fc9e51b58627ea92c3fc0bae5fd7db34b490f335f651
        ;;
    *) echo "Intel SDE is unsupported on this host" >&2; exit 1 ;;
esac
SDE_PACKAGE=sde-external-$SDE_RELEASE-$SDE_PLATFORM
mkdir -p "$SDE_CACHE"
SDE_CACHE=$(CDPATH= cd -- "$SDE_CACHE" && pwd)
SDE_ARCHIVE=$SDE_CACHE/$SDE_PACKAGE.tar.xz
if [ ! -f "$SDE_ARCHIVE" ]; then
    SDE_DOWNLOAD=$SDE_ARCHIVE.download.$$
    trap 'rm -f "$SDE_DOWNLOAD"' EXIT HUP INT TERM
    curl --fail --location --silent --show-error --retry 3 \
        "https://downloadmirror.intel.com/924984/$SDE_PACKAGE.tar.xz" \
        -o "$SDE_DOWNLOAD"
    printf '%s  %s\n' "$SDE_SHA256" "$SDE_DOWNLOAD" | sha256sum --check >&2
    mv "$SDE_DOWNLOAD" "$SDE_ARCHIVE"
fi
# A cache hit is not provenance: reverify and extract the authenticated archive
# every time, so an old or modified extracted executable cannot be reused.
printf '%s  %s\n' "$SDE_SHA256" "$SDE_ARCHIVE" | sha256sum --check >&2
rm -rf "$SDE_CACHE/$SDE_PACKAGE"
tar -xJf "$SDE_ARCHIVE" -C "$SDE_CACHE"
[ -x "$SDE_CACHE/$SDE_PACKAGE/$SDE_EXE" ] || {
    echo "Intel SDE archive lacks $SDE_EXE" >&2
    exit 1
}
printf '%s\n' "$SDE_CACHE/$SDE_PACKAGE/$SDE_EXE"
