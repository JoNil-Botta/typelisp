#!/usr/bin/env sh
set -eu

# Exercise the dependency frontend-surface consumer with two direct packages
# sharing one transitive dependency. Trusted and forced-source jobs must emit
# identical assembly and runtime behavior; one malformed surface must disable
# the complete hydrated set rather than leave a mixed prefix.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

# Target-conditioned prefix declarations change the skip totals. Windows also
# builds dependency nodes serially in one process, while Linux workers isolate
# child-node fallback accounting from the root build.
case "$NL_HOST_OS" in
    windows)
        TRUSTED_PREFIX_SKIPPED=223
        FORCED_SOURCE_FALLBACKS=3
        ;;
    *)
        TRUSTED_PREFIX_SKIPPED=218
        FORCED_SOURCE_FALLBACKS=1
        ;;
esac

COMPILER=${1:-${TYPELISP_BIN:-}}
if [ -z "$COMPILER" ]; then
    echo "usage: $0 <profile dependency-tlci-verification compiler>" >&2
    exit 2
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || {
    echo "package surface tlci compiler is not executable: $COMPILER" >&2
    exit 1
}

WORKDIR="$ROOT/target/package-surface-tlci/$NL_HOST_OS"
BASE="$WORKDIR/base"
LEFT="$WORKDIR/left"
RIGHT="$WORKDIR/right"
CONSUMER="$WORKDIR/consumer"
CONSUMER_TARGET="$CONSUMER/target/release"
CONSUMER_ASM="$CONSUMER_TARGET/surface_consumer.s"
CONSUMER_BIN="$CONSUMER_TARGET/surface_consumer$NL_BIN_EXT"
RIGHT_TLCI="$RIGHT/target/release/surface_right.tlci"
NATIVE_ASM="$WORKDIR/surface_consumer.native.s"

fail() {
    echo "[package-surface-tlci] $*" >&2
    exit 1
}

run_consumer_90() {
    label=$1
    set +e
    "$CONSUMER_BIN" > "$WORKDIR/$label.program.out" \
        2> "$WORKDIR/$label.program.err"
    status=$?
    set -e
    [ "$status" -eq 90 ] ||
        fail "$label consumer exited $status, expected 90"
    [ ! -s "$WORKDIR/$label.program.out" ] ||
        fail "$label consumer wrote stdout"
    [ ! -s "$WORKDIR/$label.program.err" ] ||
        fail "$label consumer wrote stderr"
}

assert_surface_route() {
    label=$1
    file=$2
    enabled=$3
    hits=$4
    fallbacks=$5
    macro_skipped=$6
    typecheck_skipped=$7
    grep -F "dependency-tlci-verification|phase=finished|requests=-1|entries=3" \
        "$file" |
        grep -F "|surface-enabled=$enabled|surface-fragments=3|surface-hits=$hits|surface-fallbacks=$fallbacks|" \
        | grep -F "|surface-macro-skipped=$macro_skipped|surface-typecheck-skipped=$typecheck_skipped" \
        >/dev/null || fail "$label dependency surface route mismatch"
}

case "$WORKDIR" in
    "$ROOT"/target/package-surface-tlci/*) ;;
    *) fail "refusing unsafe workdir: $WORKDIR" ;;
esac
rm -rf "$WORKDIR"
mkdir -p \
    "$BASE/src" \
    "$LEFT/src" \
    "$RIGHT/src" \
    "$CONSUMER/src"

cat > "$BASE/typelisp.pkg" <<'EOF'
(package
  (name "surface_base")
  (version "1.0.0")
  (kind "lib"))
EOF
cat > "$BASE/src/lib.tl" <<'EOF'
(module base.src.lib)

(defmacro (typed-add [T : type] [value : Expr]) : Expr
  `(cast (+ (cast ,value : i64) 2) : ,T))
EOF

cat > "$LEFT/typelisp.pkg" <<'EOF'
(package
  (name "surface_left")
  (version "1.0.0")
  (kind "lib")
  (dependencies
    (base "../base")))
EOF
cat > "$LEFT/src/lib.tl" <<'EOF'
(module left.src.lib)

(import base.src.lib as base)

(defmacro (adjust [value : Expr]) : Expr
  `(base.typed-add i64 (+ ,value 3)))

(defmacro (generated) : Module
  `(begin
    (module surface_left.generated)
    (define (value) : i64 4)))

(define (same [value : i64]) : i64
  (+ value 11))

(define (left-value [value : i64]) : i64
  (+ value 11))

(define (lane-add [value : i64] [scale : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result varying)
      (index-param 0)))
  : i64
  (+ value scale))
EOF

cat > "$RIGHT/typelisp.pkg" <<'EOF'
(package
  (name "surface_right")
  (version "1.0.0")
  (kind "lib")
  (dependencies
    (base "../base")))
EOF
cat > "$RIGHT/src/lib.tl" <<'EOF'
(module right.src.lib)

(import base.src.lib as base)

(defmacro (adjust [value : Expr]) : Expr
  `(base.typed-add i64 (+ ,value 5)))

(defmacro (generated) : Decls
  `(begin
    (define (right-generated-value) : i64 6)))

(define (same [value : i64]) : i64
  (+ value 21))

(define (right-value [value : i64]) : i64
  (+ value 21))

(define (lane-double [value : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result varying)
      (index-param 0)))
  : i64
  (+ value value))
EOF

cat > "$CONSUMER/typelisp.pkg" <<'EOF'
(package
  (name "surface_consumer")
  (version "1.0.0")
  (kind "bin")
  (dependencies
    (left "../left")
    (right "../right")))
EOF
cat > "$CONSUMER/src/main.tl" <<'EOF'
(module consumer.src.main)

(import stdlib.array)
(import left.src.lib as left)
(import right.src.lib as right)
(import (left.generated) as left-generated)
(right.generated)

(define (fill [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (+ (left.lane-add i 3) (right.lane-double i)))))

(define (main) : i64
  (let
    [out : (__tl_dyn-array i64) (array.make-array i64 4)]
    (begin
      (fill out 4)
      (if (= (array-ref out 3) 12)
        (+
          (left.left-value (left.adjust 1))
          (right.right-value (right.adjust 1))
          (left.same 1)
          (right.same 1)
          (left-generated.value)
          (right-generated-value))
        1))))
EOF

TYPELISP_DEPENDENCY_TLCI_VERIFY=1
export TYPELISP_DEPENDENCY_TLCI_VERIFY
unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true

echo "[package-surface-tlci] trusted two-package diamond"
if ! "$COMPILER" build \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$WORKDIR/native.out" 2> "$WORKDIR/native.err"; then
    cat "$WORKDIR/native.out" >&2
    cat "$WORKDIR/native.err" >&2
    fail "trusted diamond build failed"
fi
[ -s "$CONSUMER_ASM" ] || fail "trusted consumer assembly is missing"
[ -x "$CONSUMER_BIN" ] || fail "trusted consumer executable is missing"
[ -s "$RIGHT_TLCI" ] || fail "right dependency TLCI is missing"
assert_surface_route trusted "$WORKDIR/native.err" 1 2 0 \
    "$TRUSTED_PREFIX_SKIPPED" "$TRUSTED_PREFIX_SKIPPED"
cp "$CONSUMER_ASM" "$NATIVE_ASM"
grep -F "call _tl_surface_left_src_lib_left_src_lib_same" "$CONSUMER_ASM" \
    >/dev/null || fail "trusted consumer omitted left.same canonical call"
grep -F "call _tl_surface_right_src_lib_right_src_lib_same" "$CONSUMER_ASM" \
    >/dev/null || fail "trusted consumer omitted right.same canonical call"
run_consumer_90 trusted

case "$CONSUMER/target" in
    "$WORKDIR"/consumer/target) ;;
    *) fail "refusing unsafe consumer target cleanup" ;;
esac
rm -rf "$CONSUMER/target"
TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE

echo "[package-surface-tlci] forced-source diamond"
if ! "$COMPILER" build \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$WORKDIR/source.out" 2> "$WORKDIR/source.err"; then
    cat "$WORKDIR/source.out" >&2
    cat "$WORKDIR/source.err" >&2
    fail "forced-source diamond build failed"
fi
assert_surface_route forced-source "$WORKDIR/source.err" 0 0 \
    "$FORCED_SOURCE_FALLBACKS" 0 0
cmp "$NATIVE_ASM" "$CONSUMER_ASM" >/dev/null ||
    fail "trusted and forced-source diamond assembly differ"
run_consumer_90 forced-source

unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true
rm -rf "$CONSUMER/target"
TYPELISP_DEPENDENCY_TLCI_VERIFY_SURFACE_REJECT_LAST=1
export TYPELISP_DEPENDENCY_TLCI_VERIFY_SURFACE_REJECT_LAST

echo "[package-surface-tlci] malformed-fragment all-source fallback"
if ! "$COMPILER" build \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$WORKDIR/malformed.out" 2> "$WORKDIR/malformed.err"; then
    cat "$WORKDIR/malformed.out" >&2
    cat "$WORKDIR/malformed.err" >&2
    fail "malformed-fragment fallback build failed"
fi
assert_surface_route malformed "$WORKDIR/malformed.err" 0 0 1 0 0
cmp "$NATIVE_ASM" "$CONSUMER_ASM" >/dev/null ||
    fail "malformed fallback and trusted diamond assembly differ"
run_consumer_90 malformed
unset TYPELISP_DEPENDENCY_TLCI_VERIFY_SURFACE_REJECT_LAST || true

echo "[package-surface-tlci] diamond hydration, parity, and rollback passed"
