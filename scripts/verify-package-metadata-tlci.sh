#!/usr/bin/env sh
set -eu

# End-to-end metadata-only dependency catalog verification (#2778). The
# supplied compiler is built with `dependency-tlci-verification`; runtime
# telemetry exposes only stable catalog counts and admitted section totals.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

COMPILER=${1:-${TYPELISP_BIN:-}}
if [ -z "$COMPILER" ]; then
    echo "usage: $0 <dependency-tlci-verification compiler>" >&2
    exit 2
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
if [ ! -x "$COMPILER" ]; then
    echo "package metadata tlci compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/package-metadata-tlci/$NL_HOST_OS"
FIXTURE="$WORKDIR/fixture"
ROOT_PKG="$FIXTURE/root"
LEFT_PKG="$FIXTURE/left"
RIGHT_PKG="$FIXTURE/right"
SHARED_PKG="$FIXTURE/shared"
NORMAL_OUT="$WORKDIR/normal.out"
NORMAL_ERR="$WORKDIR/normal.err"
NOOP_OUT="$WORKDIR/noop.out"
NOOP_ERR="$WORKDIR/noop.err"
SOURCE_OUT="$WORKDIR/source.out"
SOURCE_ERR="$WORKDIR/source.err"
INSPECT_OUT="$WORKDIR/inspect.out"
INSPECT_ERR="$WORKDIR/inspect.err"
ROOT_EXE="$ROOT_PKG/target/release/metadata_root$NL_BIN_EXT"
ROOT_ASM="$ROOT_PKG/target/release/metadata_root.s"
SHARED_TLCI="$SHARED_PKG/target/release/metadata_shared.tlci"
NORMAL_ASM="$WORKDIR/metadata_root.normal.s"

case "$WORKDIR" in
    "$ROOT"/target/package-metadata-tlci/*) ;;
    *) echo "refusing unsafe metadata tlci workdir: $WORKDIR" >&2; exit 1 ;;
esac
rm -rf "$WORKDIR"
mkdir -p \
    "$ROOT_PKG/src" \
    "$LEFT_PKG/src" \
    "$RIGHT_PKG/src" \
    "$SHARED_PKG/src"

fail() {
    echo "[package-metadata-tlci] $*" >&2
    exit 1
}

assert_contains() {
    grep -F -- "$2" "$1" >/dev/null ||
        fail "$(basename "$1") does not contain: $2"
}

assert_empty() {
    [ ! -s "$1" ] || fail "$(basename "$1") is not empty: $(cat "$1")"
}

run_program_42() {
    label=$1
    stdout="$WORKDIR/$label.program.out"
    stderr="$WORKDIR/$label.program.err"
    set +e
    "$ROOT_EXE" > "$stdout" 2> "$stderr"
    status=$?
    set -e
    [ "$status" -eq 42 ] || fail "$label program exited $status, expected 42"
    assert_empty "$stdout"
    assert_empty "$stderr"
}

cat > "$SHARED_PKG/typelisp.pkg" <<'EOF'
(package
  (name "metadata_shared")
  (version "1.0.0")
  (kind staticlib))
EOF
cat > "$SHARED_PKG/src/lib.tl" <<'EOF'
(define (shared-answer) : i64 21)
EOF

cat > "$LEFT_PKG/typelisp.pkg" <<'EOF'
(package
  (name "metadata_left")
  (version "1.0.0")
  (kind staticlib)
  (dependencies
    (shared "../shared")))
EOF
cat > "$LEFT_PKG/src/lib.tl" <<'EOF'
(import shared.src.lib as shared)
(define (left-answer) : i64 (shared.shared-answer))
EOF

cat > "$RIGHT_PKG/typelisp.pkg" <<'EOF'
(package
  (name "metadata_right")
  (version "1.0.0")
  (kind staticlib)
  (dependencies
    (shared "../shared")))
EOF
cat > "$RIGHT_PKG/src/lib.tl" <<'EOF'
(import shared.src.lib as shared)
(define (right-answer) : i64 (shared.shared-answer))
EOF

cat > "$ROOT_PKG/typelisp.pkg" <<'EOF'
(package
  (name "metadata_root")
  (version "1.0.0")
  (kind bin)
  (dependencies
    (left "../left")
    (right "../right")
    (shared_a "../shared")
    (shared_b ".././shared")))
EOF
cat > "$ROOT_PKG/src/main.tl" <<'EOF'
(import left.src.lib as left)
(import right.src.lib as right)
(define (main) : i64 (+ (left.left-answer) (right.right-answer)))
EOF

TYPELISP_DEPENDENCY_TLCI_VERIFY=1
export TYPELISP_DEPENDENCY_TLCI_VERIFY

echo "[package-metadata-tlci] trusted metadata build"
if ! "$COMPILER" build \
    --manifest-path "$ROOT_PKG/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --opt-level 0 > "$NORMAL_OUT" 2> "$NORMAL_ERR"; then
    cat "$NORMAL_OUT" >&2
    cat "$NORMAL_ERR" >&2
    fail "trusted metadata package build failed"
fi
[ -s "$ROOT_EXE" ] || fail "trusted metadata build did not create root executable"
[ -s "$ROOT_ASM" ] || fail "trusted metadata build did not create root assembly"
[ -s "$SHARED_TLCI" ] || fail "trusted metadata build did not create shared tlci"
assert_contains "$NORMAL_ERR" \
    "dependency-tlci-verification|phase=prepared|requests=4|entries=3|generation=3|unavailable=0|metadata=3|code=0|code-bytes=0|fixup-bytes=0|entry-bytes=0|import-bytes=0"
cp "$ROOT_ASM" "$NORMAL_ASM"
run_program_42 normal

echo "[package-metadata-tlci] inspect zero-entry image"
if ! "$COMPILER" inspect "$SHARED_TLCI" > "$INSPECT_OUT" 2> "$INSPECT_ERR"; then
    cat "$INSPECT_ERR" >&2
    fail "metadata-only dependency inspect failed"
fi
assert_empty "$INSPECT_ERR"
assert_contains "$INSPECT_OUT" "image-classification: metadata-only"
assert_contains "$INSPECT_OUT" "source-set-binding-schema: 1"
assert_contains "$INSPECT_OUT" "code: offset=0 bytes=0"
assert_contains "$INSPECT_OUT" "fixups: offset=0 records=0 bytes=0"
assert_contains "$INSPECT_OUT" "entries: offset=0 records=0 bytes=0"
assert_contains "$INSPECT_OUT" "imports: offset=0 records=0 bytes=0"

IMAGE_BEFORE=$(sha256sum "$SHARED_TLCI" | awk '{ print $1 }')
ASM_BEFORE=$(sha256sum "$ROOT_ASM" | awk '{ print $1 }')
sleep 1
echo "[package-metadata-tlci] identical no-op build"
if ! "$COMPILER" build \
    --manifest-path "$ROOT_PKG/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --opt-level 0 > "$NOOP_OUT" 2> "$NOOP_ERR"; then
    cat "$NOOP_OUT" >&2
    cat "$NOOP_ERR" >&2
    fail "metadata-only no-op build failed"
fi
IMAGE_AFTER=$(sha256sum "$SHARED_TLCI" | awk '{ print $1 }')
ASM_AFTER=$(sha256sum "$ROOT_ASM" | awk '{ print $1 }')
[ "$IMAGE_BEFORE" = "$IMAGE_AFTER" ] || fail "metadata-only image changed on no-op"
[ "$ASM_BEFORE" = "$ASM_AFTER" ] || fail "consumer assembly changed on no-op"
assert_contains "$NOOP_OUT" "Fresh"
run_program_42 noop

case "$ROOT_PKG/target" in
    "$WORKDIR"/*/target) ;;
    *) fail "refusing unsafe consumer target cleanup" ;;
esac
rm -rf "$ROOT_PKG/target"
TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE
echo "[package-metadata-tlci] forced-source differential build"
if ! "$COMPILER" build \
    --manifest-path "$ROOT_PKG/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --opt-level 0 > "$SOURCE_OUT" 2> "$SOURCE_ERR"; then
    cat "$SOURCE_OUT" >&2
    cat "$SOURCE_ERR" >&2
    fail "forced-source metadata package build failed"
fi
assert_contains "$SOURCE_ERR" \
    "dependency-tlci-verification|phase=prepared|requests=4|entries=3|generation=3|unavailable=3|metadata=0|code=0|code-bytes=0|fixup-bytes=0|entry-bytes=0|import-bytes=0"
cmp "$NORMAL_ASM" "$ROOT_ASM" >/dev/null ||
    fail "trusted metadata and forced-source consumer assembly differ"
run_program_42 source

echo "[package-metadata-tlci] trusted/forced-source assembly and runtime parity passed"
echo "[package-metadata-tlci] canonical dependency requests=4 entries=3 metadata=3 native-sections=0"
