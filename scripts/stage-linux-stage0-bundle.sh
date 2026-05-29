#!/usr/bin/env sh
set -eu

# stage-linux-stage0-bundle.sh - create the transitional bundled Linux stage0
# release asset. The bundle is relocatable after extraction and installs a
# public `typelisp` launcher at the bundle root.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/stage-linux-stage0-bundle.sh [seed-typelisp] [output-archive]

Builds a TypeLisp stage1 compiler with the supplied Linux seed compiler and
packages a relocatable stage0 bundle archive.

Defaults:
  seed-typelisp:  ${TYPELISP_BIN:-target/release/typelisp}
  output-archive: typelisp-stage0-linux-bundle.tar.gz
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

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "Linux stage0 bundle packaging requires a Linux host" >&2
        exit 1
        ;;
esac

SEED_TYPELISP_BIN=${1:-${TYPELISP_BIN:-target/release/typelisp}}
OUT_ARCHIVE=${2:-typelisp-stage0-linux-bundle.tar.gz}
WORKDIR=${TYPELISP_STAGE0_BUNDLE_WORKDIR:-"$ROOT/target/linux-stage0-bundle"}
BUNDLE_NAME=typelisp-stage0-linux-bundle
BUNDLE_DIR="$WORKDIR/$BUNDLE_NAME"

case "$SEED_TYPELISP_BIN" in
    /*) ;;
    *) SEED_TYPELISP_BIN="$ROOT/$SEED_TYPELISP_BIN" ;;
esac

case "$OUT_ARCHIVE" in
    /*) OUT_ARCHIVE_ABS=$OUT_ARCHIVE ;;
    *) OUT_ARCHIVE_ABS="$ROOT/$OUT_ARCHIVE" ;;
esac

ensure_executable() {
    label=$1
    path=$2
    if [ ! -f "$path" ]; then
        echo "$label does not exist: $path" >&2
        exit 1
    fi
    if [ ! -x "$path" ]; then
        chmod +x "$path" 2>/dev/null || true
    fi
    if [ ! -x "$path" ]; then
        echo "$label is not executable: $path" >&2
        exit 1
    fi
}

require_tool() {
    tool=$1
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Linux stage0 bundle packaging requires '$tool'" >&2
        exit 1
    fi
}

try_build_driver() {
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

show_driver_failure() {
    label=$1
    driver_dir=$2
    echo "stage1 $label driver build failed" >&2
    sed 's/^/  /' "$driver_dir/compile.stdout" >&2 || true
    sed 's/^/  /' "$driver_dir/compile.stderr" >&2 || true
}

build_driver() {
    seed=$1
    stage1=$2
    label=$3
    source=$4
    stem=$5
    driver_dir="$WORKDIR/build-$label-driver"

    if try_build_driver "$seed" "$label" "$source" "$stem" "$driver_dir"; then
        return 0
    fi

    echo "[stage0-bundle] seed build for $label driver failed; retrying with stage1 compiler" >&2
    if try_build_driver "$stage1" "$label" "$source" "$stem" "$driver_dir"; then
        return 0
    fi

    show_driver_failure "$label" "$driver_dir"
    exit 1
}

ensure_executable "seed compiler" "$SEED_TYPELISP_BIN"
require_tool as
require_tool ld
require_tool tar

rm -rf "$WORKDIR"
mkdir -p "$BUNDLE_DIR/lib/stage1/drivers" "$BUNDLE_DIR/lib/stage1/cache" "$BUNDLE_DIR/scripts"

STAGE1_PATH_FILE="$WORKDIR/stage1.path"
echo "[stage0-bundle] building stage1 compiler with $SEED_TYPELISP_BIN"
TYPELISP_BOOTSTRAP_STAGE1_PATH_FILE=$STAGE1_PATH_FILE \
TYPELISP_BOOTSTRAP_STAGE1_ONLY=1 \
    "$ROOT/scripts/check-bootstrap-fixpoint.sh" "$SEED_TYPELISP_BIN"

if [ -s "$STAGE1_PATH_FILE" ]; then
    STAGE1_BIN=$(sed -n '1p' "$STAGE1_PATH_FILE")
else
    STAGE1_BIN="$ROOT/target/bootstrap-fixpoint/stage1"
fi
ensure_executable "stage1 compiler" "$STAGE1_BIN"

echo "[stage0-bundle] staging runtime files"
cp "$STAGE1_BIN" "$BUNDLE_DIR/lib/stage1/typelisp-stage1"
cp "$ROOT/scripts/stage1-typelisp-wrapper.sh" "$BUNDLE_DIR/scripts/stage1-typelisp-wrapper.sh"
cp -R "$ROOT/selfhost" "$BUNDLE_DIR/selfhost"
cp -R "$ROOT/stdlib" "$BUNDLE_DIR/stdlib"

DOC_DRIVER=$(build_driver "$SEED_TYPELISP_BIN" "$STAGE1_BIN" doc selfhost/doc.tl selfhost-doc)
BUILD_DRIVER=$(build_driver "$SEED_TYPELISP_BIN" "$STAGE1_BIN" build selfhost/build.tl selfhost-build)
REPL_DRIVER=$(build_driver "$SEED_TYPELISP_BIN" "$STAGE1_BIN" repl selfhost/repl.tl selfhost-repl)

cp "$DOC_DRIVER" "$BUNDLE_DIR/lib/stage1/drivers/selfhost-doc"
cp "$BUILD_DRIVER" "$BUNDLE_DIR/lib/stage1/drivers/selfhost-build"
cp "$REPL_DRIVER" "$BUNDLE_DIR/lib/stage1/drivers/selfhost-repl"

cat > "$BUNDLE_DIR/STAGE0_BUNDLE" <<'EOF'
typelisp-stage0-bundle v1
platform linux-x86_64
launcher typelisp
wrapper scripts/stage1-typelisp-wrapper.sh
stage1 lib/stage1/typelisp-stage1
driver doc lib/stage1/drivers/selfhost-doc
driver build lib/stage1/drivers/selfhost-build
driver repl lib/stage1/drivers/selfhost-repl
source-tree selfhost
stdlib stdlib
EOF

cat > "$BUNDLE_DIR/typelisp" <<'EOF'
#!/usr/bin/env sh
set -eu
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TYPELISP_STAGE1_BIN="$SELF_DIR/lib/stage1/typelisp-stage1"
export TYPELISP_STAGE1_BIN
TYPELISP_STAGE1_DOC_BIN="$SELF_DIR/lib/stage1/drivers/selfhost-doc"
export TYPELISP_STAGE1_DOC_BIN
TYPELISP_STAGE1_BUILD_BIN="$SELF_DIR/lib/stage1/drivers/selfhost-build"
export TYPELISP_STAGE1_BUILD_BIN
TYPELISP_STAGE1_REPL_BIN="$SELF_DIR/lib/stage1/drivers/selfhost-repl"
export TYPELISP_STAGE1_REPL_BIN
TYPELISP_STAGE1_DRIVER_CACHE_DIR="$SELF_DIR/lib/stage1/cache"
export TYPELISP_STAGE1_DRIVER_CACHE_DIR
exec "$SELF_DIR/scripts/stage1-typelisp-wrapper.sh" "$@"
EOF

chmod +x \
    "$BUNDLE_DIR/typelisp" \
    "$BUNDLE_DIR/scripts/stage1-typelisp-wrapper.sh" \
    "$BUNDLE_DIR/lib/stage1/typelisp-stage1" \
    "$BUNDLE_DIR/lib/stage1/drivers/selfhost-doc" \
    "$BUNDLE_DIR/lib/stage1/drivers/selfhost-build" \
    "$BUNDLE_DIR/lib/stage1/drivers/selfhost-repl"

mkdir -p "$(dirname -- "$OUT_ARCHIVE_ABS")"
rm -f "$OUT_ARCHIVE_ABS"
echo "[stage0-bundle] writing $OUT_ARCHIVE_ABS"
(cd "$WORKDIR" && tar -czf "$OUT_ARCHIVE_ABS" "$BUNDLE_NAME")

if [ ! -s "$OUT_ARCHIVE_ABS" ]; then
    echo "stage0 bundle archive is empty: $OUT_ARCHIVE_ABS" >&2
    exit 1
fi

ls -lh "$OUT_ARCHIVE_ABS"
