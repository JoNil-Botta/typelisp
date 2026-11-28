#!/usr/bin/env sh
set -eu

# End-to-end metadata-only dependency catalog verification. The
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
ROOT_EXE="$ROOT_PKG/target/dev/metadata_root$NL_BIN_EXT"
ROOT_ASM="$ROOT_PKG/target/dev/metadata_root.s"
SHARED_TLI="$SHARED_PKG/target/dev/metadata_shared.tli"
SHARED_TLCI="$SHARED_PKG/target/dev/metadata_shared.tlci"
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

GATE_FAIL_PREFIX='[package-metadata-tlci] '
. "$ROOT/scripts/lib-gate.sh"

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
  (kind staticlib))
EOF
cat > "$LEFT_PKG/src/lib.tl" <<'EOF'
(define (left-answer) : i64 10)
EOF

cat > "$RIGHT_PKG/typelisp.pkg" <<'EOF'
(package
  (name "metadata_right")
  (version "1.0.0")
  (kind staticlib))
EOF
cat > "$RIGHT_PKG/src/lib.tl" <<'EOF'
(define (right-answer) : i64 11)
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
(import shared_a.src.lib as shared)
(define (main) : i64
  (+ (left.left-answer) (right.right-answer) (shared.shared-answer)))
EOF

TYPELISP_DEPENDENCY_TLCI_VERIFY=1
export TYPELISP_DEPENDENCY_TLCI_VERIFY

echo "[package-metadata-tlci] trusted pure-library TLI build"
if ! "$COMPILER" build \
    --manifest-path "$ROOT_PKG/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --opt-level 0 > "$NORMAL_OUT" 2> "$NORMAL_ERR"; then
    cat "$NORMAL_OUT" >&2
    cat "$NORMAL_ERR" >&2
    fail "trusted pure-library TLI package build failed"
fi
[ -s "$ROOT_EXE" ] || fail "trusted pure-library build did not create root executable"
[ -s "$ROOT_ASM" ] || fail "trusted pure-library build did not create root assembly"
[ -s "$SHARED_TLI" ] || fail "trusted pure-library build did not create shared .tli"
[ ! -e "$SHARED_TLCI" ] || fail "pure library unexpectedly emitted companion .tlci"
assert_contains "$NORMAL_ERR" \
    "dependency-tlci-verification|phase=runtime-finished|requests=-1|entries=0|"
assert_contains "$NORMAL_ERR" \
    "|tli-active=1|tli-package-bundles=3|tli-hydrated-package-bundles=3|"
assert_contains "$NORMAL_ERR" \
    "|tli-package-hits=3|tli-force-source=0"
cp "$ROOT_ASM" "$NORMAL_ASM"
run_program_42 normal

echo "[package-metadata-tlci] inspect pure-library .tli bundle"
if ! "$COMPILER" inspect "$SHARED_TLI" > "$INSPECT_OUT" 2> "$INSPECT_ERR"; then
    cat "$INSPECT_ERR" >&2
    fail "pure-library .tli inspect failed"
fi
assert_empty "$INSPECT_ERR"
assert_contains "$INSPECT_OUT" "metadata_shared.src.lib"

IMAGE_BEFORE=$(sha256sum "$SHARED_TLI" | awk '{ print $1 }')
ASM_BEFORE=$(sha256sum "$ROOT_ASM" | awk '{ print $1 }')
sleep 1
echo "[package-metadata-tlci] identical no-op build"
if ! "$COMPILER" build \
    --manifest-path "$ROOT_PKG/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --opt-level 0 > "$NOOP_OUT" 2> "$NOOP_ERR"; then
    cat "$NOOP_OUT" >&2
    cat "$NOOP_ERR" >&2
    fail "pure-library no-op build failed"
fi
IMAGE_AFTER=$(sha256sum "$SHARED_TLI" | awk '{ print $1 }')
ASM_AFTER=$(sha256sum "$ROOT_ASM" | awk '{ print $1 }')
[ "$IMAGE_BEFORE" = "$IMAGE_AFTER" ] || fail "pure-library .tli changed on no-op"
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
    fail "forced-source pure-library package build failed"
fi
assert_contains "$SOURCE_ERR" \
    "dependency-tlci-verification|phase=runtime-finished|requests=-1|"
assert_contains "$SOURCE_ERR" \
    "|tli-package-bundles=0|tli-hydrated-package-bundles=0|"
assert_contains "$SOURCE_ERR" \
    "|tli-package-hits=0|tli-force-source=1"
run_program_42 source

echo "[package-metadata-tlci] trusted TLI / forced-source runtime parity passed"
echo "[package-metadata-tlci] canonical pure-library bundles=3 tlci=0"

# The producer names have identical archive manglings. Only the generated
# drop-word is shared. Distinct field hooks expose which body actually ran.
COLLISION="$WORKDIR/cleanup"
mkdir -p "$COLLISION/src"
for side in first second; do
    case "$side" in
        first) package=foo-bar ;;
        second) package=foo_bar ;;
    esac
    mkdir -p "$COLLISION/$side/src"
    cat > "$COLLISION/$side/typelisp.pkg" <<PKG
(package (name "$package") (version "1.0.0") (kind staticlib))
PKG
    cat > "$COLLISION/$side/src/lib.tl" <<TL
(import stdlib.io)
(define (close-$side [_value : i64]) : unit (io.println "$side"))
(defstruct Word (:cleanup drop-word) (x i64 (:cleanup close-$side)))
TL
done
cat > "$COLLISION/typelisp.pkg" <<'PKG'
(package (name "cleanup_pair") (version "1.0.0") (kind "bin")
  (dependencies (foo-bar "first") (foo_bar "second")))
PKG
cat > "$COLLISION/src/main.tl" <<'TL'
(import foo-bar.src.lib as a)
(import foo_bar.src.lib as b)
(define (main) : i64
  (a.drop-word (a.Word 1))
  (b.drop-word (b.Word 2))
  0)
TL
if TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=0 "$COMPILER" build \
    --manifest-path "$COLLISION/typelisp.pkg" --target "$NL_BOOTSTRAP_TARGET" \
    > "$COLLISION/trusted.out" 2> "$COLLISION/trusted.err"; then
    fail "trusted build accepted colliding cleanup definitions"
fi
assert_contains "$COLLISION/trusted.err" "|tli-package-hits=2|tli-force-source=0"
assert_contains "$COLLISION/trusted.err" "conflicting package archive symbol _tl_foo_bar_src_lib_drop_word"
assert_contains "$COLLISION/trusted.err" "foo-bar."
assert_contains "$COLLISION/trusted.err" "foo_bar."
TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1 "$COMPILER" build \
    --manifest-path "$COLLISION/typelisp.pkg" --target "$NL_BOOTSTRAP_TARGET" \
    > "$COLLISION/source.out" 2> "$COLLISION/source.err"
assert_contains "$COLLISION/source.err" "|tli-package-hits=0|tli-force-source=1"
"$COLLISION/target/dev/cleanup_pair$NL_BIN_EXT" > "$COLLISION/program.out"
printf 'first\nsecond\n' > "$COLLISION/expected.out"
tr -d '\r' < "$COLLISION/program.out" | cmp "$COLLISION/expected.out" - ||
    fail "forced-source cleanup bodies ran in the wrong order"
echo "[package-metadata-tlci] conflicting cleanup definitions diagnosed on the trusted route"
