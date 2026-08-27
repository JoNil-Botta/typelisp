#!/usr/bin/env sh
set -eu

# Exercise dependency native macros and frontend surfaces with two direct
# packages sharing one transitive dependency. Exact route counters, physical
# defining-catalog rows, repeated generated identities, a terminal shell, and
# bounded failure twins make this a non-vacuous native/source differential. One
# malformed surface must still disable the complete hydrated set rather than
# leave a mixed prefix.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

# Target-conditioned prefix declarations change the skip totals. The explicit
# compiler-owned-view import from the by-value ownership cutover contributes
# one declaration on both hosts. Windows also builds dependency nodes serially
# in one process, while Linux workers isolate child-node fallback accounting
# from the root build.
case "$NL_HOST_OS" in
    windows)
        TRUSTED_PREFIX_SKIPPED=220
        FAILURE_PREFIX_SKIPPED=208
        FORCED_SOURCE_FALLBACKS=3
        ;;
    *)
        TRUSTED_PREFIX_SKIPPED=215
        FAILURE_PREFIX_SKIPPED=203
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
SUCCESS_SOURCE="$WORKDIR/surface_consumer.success.tl"

fail() {
    echo "[package-surface-tlci] $*" >&2
    exit 1
}

profile_sum() {
    phase=$1
    file=$2
    awk -F '|' -v wanted="typecheck.macro.$phase" \
        '$1 == "compile-profile" && $2 == wanted { total += $3 } \
         END { print total + 0 }' "$file"
}

assert_profile_eq() {
    phase=$1
    wanted=$2
    file=$3
    actual=$(profile_sum "$phase" "$file")
    [ "$actual" -eq "$wanted" ] ||
        fail "$phase is $actual, expected $wanted"
}

assert_macro_row() {
    label=$1
    identity=$2
    arity=$3
    calls=$4
    file=$5
    grep -F "|$identity arity=$arity calls=$calls" "$file" >/dev/null ||
        fail "$label lacks exact macro row $identity arity=$arity calls=$calls"
}

verification_field() {
    phase=$1
    field=$2
    file=$3
    awk -F '|' -v wanted_phase="phase=$phase" -v wanted_field="$field" '
        $1 == "dependency-tlci-verification" && $2 == wanted_phase &&
            $3 == "requests=3" && $4 == "entries=3" {
            for (i = 3; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == wanted_field) {
                    print pair[2]
                    exit
                }
            }
        }
    ' "$file"
}

assert_catalog_state() {
    label=$1
    file=$2
    unavailable=$3
    code=$4
    grep -F "dependency-tlci-verification|phase=prepared|requests=3|entries=3" \
        "$file" |
        grep -F "|unavailable=$unavailable|metadata=0|code=$code|" >/dev/null ||
        fail "$label dependency catalog census mismatch"
    code_bytes=$(verification_field prepared code-bytes "$file")
    [ -n "$code_bytes" ] || fail "$label omitted dependency code bytes"
    if [ "$code" -eq 0 ]; then
        [ "$code_bytes" -eq 0 ] || fail "$label retained mapped dependency code"
    else
        [ "$code_bytes" -gt 0 ] || fail "$label mapped no dependency code"
    fi
}

filter_diagnostic() {
    grep -v -E '^(compile-profile|compile-batch-profile|dependency-tlci-verification)' "$1" |
        sed '/^[[:space:]]*$/d' > "$2"
}

filter_attribution() {
    sed -n '/^  --> /,$p' "$1" > "$2"
}

write_failure_source() {
    case_name=$1
    output=$2
    case "$case_name" in
        authored)
            invocation='(right.authored-failure bool)'
            ;;
        fuel)
            invocation='(right.fuel-failure bool)'
            ;;
        *) fail "unknown dependency failure fixture: $case_name" ;;
    esac
    cat > "$output" <<EOF
(module consumer.src.main)

(import right.src.lib as right)

(define (main) : i64
  $invocation)
EOF
}

run_failure_pair() {
    case_name=$1
    expected=$2
    failure_source="$WORKDIR/failure-$case_name.tl"
    write_failure_source "$case_name" "$failure_source"
    cp "$failure_source" "$CONSUMER/src/main.tl"

    unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true
    rm -rf "$CONSUMER/target"
    set +e
    "$COMPILER" build \
        --manifest-path "$CONSUMER/typelisp.pkg" \
        --target "$NL_BOOTSTRAP_TARGET" \
        --backend-mode scalar \
        --opt-level 0 > "$WORKDIR/failure-$case_name-native.out" \
        2> "$WORKDIR/failure-$case_name-native.err"
    native_status=$?
    set -e
    [ "$native_status" -ne 0 ] || fail "$case_name native route did not fail"
    assert_catalog_state "$case_name native" \
        "$WORKDIR/failure-$case_name-native.err" 0 3
    assert_surface_route "$case_name native" \
        "$WORKDIR/failure-$case_name-native.err" 1 1 0 \
        "$FAILURE_PREFIX_SKIPPED" 0 14
    assert_macro_row "$case_name native" \
        right.src.lib/$case_name-failure 1 1 \
        "$WORKDIR/failure-$case_name-native.err"

    TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
    export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE
    rm -rf "$CONSUMER/target"
    set +e
    "$COMPILER" build \
        --manifest-path "$CONSUMER/typelisp.pkg" \
        --target "$NL_BOOTSTRAP_TARGET" \
        --backend-mode scalar \
        --opt-level 0 > "$WORKDIR/failure-$case_name-source.out" \
        2> "$WORKDIR/failure-$case_name-source.err"
    source_status=$?
    set -e
    [ "$source_status" -ne 0 ] || fail "$case_name source route did not fail"
    assert_catalog_state "$case_name source" \
        "$WORKDIR/failure-$case_name-source.err" 3 0
    assert_surface_route "$case_name source" \
        "$WORKDIR/failure-$case_name-source.err" 0 0 \
        "$FORCED_SOURCE_FALLBACKS" 0 0 0
    assert_macro_row "$case_name source" \
        right.src.lib/$case_name-failure 1 1 \
        "$WORKDIR/failure-$case_name-source.err"

    filter_diagnostic "$WORKDIR/failure-$case_name-native.err" \
        "$WORKDIR/failure-$case_name-native.diag"
    filter_diagnostic "$WORKDIR/failure-$case_name-source.err" \
        "$WORKDIR/failure-$case_name-source.diag"
    grep -F "$expected" "$WORKDIR/failure-$case_name-native.diag" >/dev/null ||
        fail "$case_name native diagnostic omitted semantic text"
    grep -F "$expected" "$WORKDIR/failure-$case_name-source.diag" >/dev/null ||
        fail "$case_name source diagnostic omitted semantic text"
    grep -F "macro right.src.lib/$case_name-failure" \
        "$WORKDIR/failure-$case_name-native.diag" >/dev/null ||
        fail "$case_name native diagnostic omitted defining package attribution"
    grep -F "right.src.lib/$case_name-failure" \
        "$WORKDIR/failure-$case_name-native.diag" >/dev/null ||
        fail "$case_name native diagnostic omitted expansion attribution"
    grep -F "right.src.lib/$case_name-failure" \
        "$WORKDIR/failure-$case_name-source.diag" >/dev/null ||
        fail "$case_name source diagnostic omitted expansion attribution"
    grep -F "invoked here" "$WORKDIR/failure-$case_name-native.diag" >/dev/null ||
        fail "$case_name native diagnostic omitted invocation attribution"
    grep -F "invoked here" "$WORKDIR/failure-$case_name-source.diag" >/dev/null ||
        fail "$case_name source diagnostic omitted invocation attribution"
    filter_attribution "$WORKDIR/failure-$case_name-native.diag" \
        "$WORKDIR/failure-$case_name-native.attribution"
    filter_attribution "$WORKDIR/failure-$case_name-source.diag" \
        "$WORKDIR/failure-$case_name-source.attribution"
    cmp "$WORKDIR/failure-$case_name-native.attribution" \
        "$WORKDIR/failure-$case_name-source.attribution" >/dev/null ||
        fail "$case_name native/source source attribution differs"
    cmp "$WORKDIR/failure-$case_name-native.out" \
        "$WORKDIR/failure-$case_name-source.out" >/dev/null ||
        fail "$case_name native/source stdout differ"

    cp "$SUCCESS_SOURCE" "$CONSUMER/src/main.tl"
    unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true
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
    decls=$8
    grep -F "dependency-tlci-verification|phase=finished|requests=-1|entries=3" \
        "$file" |
        grep -F "|surface-enabled=$enabled|surface-fragments=3|surface-hits=$hits|surface-fallbacks=$fallbacks|" \
        | grep -F "|surface-decls=$decls|surface-macro-skipped=$macro_skipped|surface-typecheck-skipped=$typecheck_skipped" \
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
    (define (value) : i64 4)
    (define (ordered-value) : i64 (value))))

;; The first invocation must learn this unsupported registration shell; the
;; second must use the mapping-generation terminal shell cache.
(defmacro (unsupported [value : Expr]) : Expr
  (match value
    [(comptime.Expr.If condition _ _) condition]
    [_ value]))

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
(import stdlib.comptime)

(defmacro (adjust [value : Expr]) : Expr
  `(base.typed-add i64 (+ ,value 5)))

(defmacro (generated) : Decls
  `(begin
    (define (right-generated-first) : i64 2)
    (define (right-generated-middle) : i64
      (+ (right-generated-first) 2))
    (define (right-generated-value) : i64
      (+ (right-generated-middle) 2))))

(defmacro (authored-failure [T : type]) : Expr
  (match (type-kind T)
    ["i64" `0]
    [_ (comptime.comptime-error "surface-right authored diagnostic")]))

(defmacro (fuel-failure [T : type]) : Expr
  (match (type-kind T)
    ["i64" `0]
    [_
      (let
        [_patterns : comptime.PatternList
          (comptime.pattern-list-bindings "fuel" 100001)]
        `0)]))

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

(import left.src.lib as left)
(import right.src.lib as right)
(import (left.generated) as left-generated)
(import (left.generated) as left-generated-repeat)
(right.generated)
(right.generated)

(define (fill [out : (&mut out (__tl_dyn-array i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (+ (left.lane-add i 3) (right.lane-double i)))))

(define (main) : i64
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (begin
      (fill (&mut out) 4)
      (if (and
        (= (array-ref out 3) 12)
        (= (left.unsupported 7) 7)
        (= (left.unsupported 8) 8)
        (= (left-generated.value) 4)
        (= (left-generated-repeat.ordered-value) 4))
        (+
          (left.left-value (left.adjust 1))
          (right.right-value (right.adjust 1))
          (left.same 1)
          (right.same 1)
          (left-generated.value)
          (right-generated-value))
        1))))
EOF

cp "$CONSUMER/src/main.tl" "$SUCCESS_SOURCE"

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
assert_catalog_state trusted "$WORKDIR/native.err" 0 3
assert_surface_route trusted "$WORKDIR/native.err" 1 2 0 \
    "$TRUSTED_PREFIX_SKIPPED" "$TRUSTED_PREFIX_SKIPPED" 24
# The package build and its isolated doctest worker each load the dependency
# closure.  Profile rows are emitted by both contexts into this shared log.
assert_profile_eq dependency_tlci_catalog_hits 18 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_catalog_misses 0 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_load_failures 0 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_native_dispatches 15 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_native_expr_results 8 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_direct_expr_results 8 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_native_module_results 2 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_native_decls_results 4 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_parameter_name_lookups 0 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_interpreted_fallbacks 4 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_shell_learns 1 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_shell_cache_hits 3 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_direct_shell_env_folds 1 "$WORKDIR/native.err"
assert_macro_row trusted base.src.lib/typed-add 2 2 "$WORKDIR/native.err"
assert_macro_row trusted left.src.lib/adjust 1 1 "$WORKDIR/native.err"
assert_macro_row trusted left.src.lib/generated 0 1 "$WORKDIR/native.err"
assert_macro_row trusted left.src.lib/unsupported 1 2 "$WORKDIR/native.err"
assert_macro_row trusted right.src.lib/adjust 1 1 "$WORKDIR/native.err"
assert_macro_row trusted right.src.lib/generated 0 2 "$WORKDIR/native.err"
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
assert_catalog_state forced-source "$WORKDIR/source.err" 3 0
assert_surface_route forced-source "$WORKDIR/source.err" 0 0 \
    "$FORCED_SOURCE_FALLBACKS" 0 0 0
assert_profile_eq dependency_tlci_catalog_hits 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_catalog_misses 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_load_failures 18 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_native_dispatches 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_native_expr_results 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_native_module_results 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_native_decls_results 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_interpreted_fallbacks 18 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_shell_learns 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_shell_cache_hits 0 "$WORKDIR/source.err"
assert_macro_row forced-source base.src.lib/typed-add 2 2 "$WORKDIR/source.err"
assert_macro_row forced-source left.src.lib/adjust 1 1 "$WORKDIR/source.err"
assert_macro_row forced-source left.src.lib/generated 0 1 "$WORKDIR/source.err"
assert_macro_row forced-source left.src.lib/unsupported 1 2 "$WORKDIR/source.err"
assert_macro_row forced-source right.src.lib/adjust 1 1 "$WORKDIR/source.err"
assert_macro_row forced-source right.src.lib/generated 0 2 "$WORKDIR/source.err"
cmp "$NATIVE_ASM" "$CONSUMER_ASM" >/dev/null ||
    fail "trusted and forced-source diamond assembly differ"
run_consumer_90 forced-source
cmp "$WORKDIR/trusted.program.out" "$WORKDIR/forced-source.program.out" >/dev/null ||
    fail "trusted and forced-source consumer stdout differ"
cmp "$WORKDIR/trusted.program.err" "$WORKDIR/forced-source.program.err" >/dev/null ||
    fail "trusted and forced-source consumer stderr differ"

echo "[package-surface-tlci] authored dependency diagnostic differential"
run_failure_pair authored "surface-right authored diagnostic"
echo "[package-surface-tlci] dependency fuel diagnostic differential"
run_failure_pair fuel "compile-time evaluation limit exceeded"

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
assert_surface_route malformed "$WORKDIR/malformed.err" 0 0 1 0 0 0
cmp "$NATIVE_ASM" "$CONSUMER_ASM" >/dev/null ||
    fail "malformed fallback and trusted diamond assembly differ"
run_consumer_90 malformed
unset TYPELISP_DEPENDENCY_TLCI_VERIFY_SURFACE_REJECT_LAST || true

echo "[package-surface-tlci] diamond hydration, parity, and rollback passed"
