#!/usr/bin/env sh
set -eu

# Exercise dependency native macros and frontend surfaces with three direct,
# dependency-free packages. Exact route counters, physical
# defining-catalog rows, repeated generated identities, a terminal shell, and
# bounded failure twins make this a non-vacuous native/source differential. One
# malformed surface must still disable the complete hydrated set rather than
# leave a mixed prefix.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

# Target-conditioned prefix declarations change the skip totals. Windows builds
# dependency nodes serially in one process, which still changes prefix skip
# totals. All three library nodes are dependency-free, however, so
# forced-source fallback happens only for the root consumer on both hosts.
case "$NL_HOST_OS" in
    windows)
        TRUSTED_PREFIX_SKIPPED=239
        FAILURE_PREFIX_SKIPPED=224
        FORCED_SOURCE_FALLBACKS=1
        ;;
    *)
        TRUSTED_PREFIX_SKIPPED=234
        FAILURE_PREFIX_SKIPPED=219
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
RIGHT_TLI="$RIGHT/target/release/surface_right.tli"
NATIVE_ASM="$WORKDIR/surface_consumer.native.s"
SUCCESS_SOURCE="$WORKDIR/surface_consumer.success.tl"
INTERLEAVED_ASM="$WORKDIR/surface_consumer.interleaved.s"

GATE_FAIL_PREFIX='[package-surface-tlci] '
. "$ROOT/scripts/lib-gate.sh"

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
    package_count=${4:-3}
    awk -F '|' -v wanted_phase="phase=$phase" -v wanted_field="$field" \
        -v requests="requests=$package_count" -v entries="entries=$package_count" '
        $1 == "dependency-tlci-verification" && $2 == wanted_phase &&
            $3 == requests && $4 == entries {
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
    package_count=${5:-3}
    grep -F "dependency-tlci-verification|phase=prepared|requests=$package_count|entries=$package_count|" \
        "$file" |
        grep -F "|unavailable=$unavailable|metadata=0|code=$code|" >/dev/null ||
        fail "$label dependency catalog census mismatch"
    code_bytes=$(verification_field prepared code-bytes "$file" "$package_count")
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
    expected_code=$3
    failure_source="$WORKDIR/failure-$case_name.tl"
    write_failure_source "$case_name" "$failure_source"
    cp "$failure_source" "$CONSUMER/src/main.tl"

    unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true
    rm -rf "$CONSUMER/target"
    set +e
    "$COMPILER" build --release \
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
    assert_tli_route "$case_name native" \
        "$WORKDIR/failure-$case_name-native.err" 1 3 1 1 0
    assert_macro_row "$case_name native" \
        right.src.lib/$case_name-failure 1 1 \
        "$WORKDIR/failure-$case_name-native.err"

    TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
    export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE
    rm -rf "$CONSUMER/target"
    set +e
    "$COMPILER" build --release \
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
    assert_tli_route "$case_name source" \
        "$WORKDIR/failure-$case_name-source.err" 0 0 0 0 1
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
    grep -F "error[$expected_code]:" "$WORKDIR/failure-$case_name-native.diag" >/dev/null ||
        fail "$case_name native diagnostic has wrong cause code"
    grep -F "error[$expected_code]:" "$WORKDIR/failure-$case_name-source.diag" >/dev/null ||
        fail "$case_name source diagnostic has wrong cause code"
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

runtime_surface_field() {
    field=$1
    file=$2
    awk -F '|' -v wanted="$field" '
        { sub(/\r$/, "") }
        $1 == "dependency-tlci-verification" && $2 == "phase=runtime-finished" &&
            $3 == "requests=-1" && $4 == "entries=3" {
            for (i = 5; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == wanted) {
                    print pair[2]
                    exit
                }
            }
        }
    ' "$file"
}

assert_tli_route() {
    label=$1
    file=$2
    active=$3
    bundles=$4
    hydrated_bundles=$5
    hits=$6
    force_source=$7
    package_count=${8:-3}
    runtime="dependency-tlci-verification|phase=runtime-finished|requests=-1|entries=$package_count|"
    [ "$(grep -Fc "$runtime" "$file")" -eq 1 ] ||
        fail "$label dependency runtime observation is missing or duplicated"
    if [ "$force_source" = "1" ]; then
        if ! grep -F "$runtime" "$file" |
            grep -F "|tli-package-bundles=$bundles|tli-hydrated-package-bundles=$hydrated_bundles|" |
            grep -F "|tli-package-hits=$hits|tli-force-source=$force_source" \
                >/dev/null; then
            grep -F "$runtime" "$file" >&2 || true
            fail "$label dependency TLI route mismatch"
        fi
    else
        if ! grep -F "$runtime" "$file" |
            grep -F "|tli-active=$active|tli-package-bundles=$bundles|tli-hydrated-package-bundles=$hydrated_bundles|" |
            grep -F "|tli-package-hits=$hits|tli-force-source=$force_source" \
                >/dev/null; then
            grep -F "$runtime" "$file" >&2 || true
            fail "$label dependency TLI route mismatch"
        fi
    fi
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
  (kind "lib"))
EOF
cat > "$LEFT/src/lib.tl" <<'EOF'
(module left.src.lib)

(defmacro (adjust [value : Expr]) : Expr
  `(+ ,value 3))

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
  (kind "lib"))
EOF
cat > "$RIGHT/src/lib.tl" <<'EOF'
(module right.src.lib)

(import stdlib.comptime)

(defmacro (adjust [value : Expr]) : Expr
  `(+ ,value 5))

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
    (base "../base")
    (left "../left")
    (right "../right")))
EOF
cat > "$CONSUMER/src/main.tl" <<'EOF'
(module consumer.src.main)

(import base.src.lib as base)
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
          (left.left-value (base.typed-add i64 (left.adjust 1)))
          (right.right-value (base.typed-add i64 (right.adjust 1)))
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

echo "[package-surface-tlci] trusted direct dependency set"
if ! "$COMPILER" build --release \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$WORKDIR/native.out" 2> "$WORKDIR/native.err"; then
    cat "$WORKDIR/native.out" >&2
    cat "$WORKDIR/native.err" >&2
    fail "trusted direct dependency build failed"
fi
[ -s "$CONSUMER_ASM" ] || fail "trusted consumer assembly is missing"
[ -x "$CONSUMER_BIN" ] || fail "trusted consumer executable is missing"
[ -s "$RIGHT_TLCI" ] || fail "right dependency TLCI is missing"
[ -s "$RIGHT_TLI" ] || fail "right dependency TLI is missing"
assert_catalog_state trusted "$WORKDIR/native.err" 0 3
assert_tli_route trusted "$WORKDIR/native.err" 1 3 3 3 0
# The runtime is prepared once, including its side assembly. One preparation
# has nine catalog lookups, eight native dispatches (including the first shell
# probe), and two interpreted shell calls with one learned-cache hit. Exact
# per-macro rows and native/source runtime/diagnostic parity remain checked.
assert_profile_eq dependency_tlci_catalog_hits 9 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_catalog_misses 0 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_load_failures 0 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_native_dispatches 8 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_native_expr_results 4 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_direct_expr_results 4 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_native_module_results 1 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_native_decls_results 2 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_parameter_name_lookups 0 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_interpreted_fallbacks 2 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_shell_learns 1 "$WORKDIR/native.err"
assert_profile_eq dependency_tlci_shell_cache_hits 1 "$WORKDIR/native.err"
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
if grep -F "_tl_surface_left_src_lib_left_src_lib_same:" "$CONSUMER_ASM" >/dev/null; then
    fail "trusted consumer unexpectedly compiled left.same body inline"
fi
run_consumer_90 trusted

case "$CONSUMER/target" in
    "$WORKDIR"/consumer/target) ;;
    *) fail "refusing unsafe consumer target cleanup" ;;
esac
rm -rf "$CONSUMER/target"
TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE

echo "[package-surface-tlci] forced-source direct dependency set"
if ! "$COMPILER" build --release \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$WORKDIR/source.out" 2> "$WORKDIR/source.err"; then
    cat "$WORKDIR/source.out" >&2
    cat "$WORKDIR/source.err" >&2
    fail "forced-source direct dependency build failed"
fi
assert_catalog_state forced-source "$WORKDIR/source.err" 3 0
assert_tli_route forced-source "$WORKDIR/source.err" 0 0 0 0 1
assert_profile_eq dependency_tlci_catalog_hits 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_catalog_misses 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_load_failures 9 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_native_dispatches 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_native_expr_results 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_native_module_results 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_native_decls_results 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_interpreted_fallbacks 9 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_shell_learns 0 "$WORKDIR/source.err"
assert_profile_eq dependency_tlci_shell_cache_hits 0 "$WORKDIR/source.err"
assert_macro_row forced-source base.src.lib/typed-add 2 2 "$WORKDIR/source.err"
assert_macro_row forced-source left.src.lib/adjust 1 1 "$WORKDIR/source.err"
assert_macro_row forced-source left.src.lib/generated 0 1 "$WORKDIR/source.err"
assert_macro_row forced-source left.src.lib/unsupported 1 2 "$WORKDIR/source.err"
assert_macro_row forced-source right.src.lib/adjust 1 1 "$WORKDIR/source.err"
assert_macro_row forced-source right.src.lib/generated 0 2 "$WORKDIR/source.err"
run_consumer_90 forced-source
cmp "$WORKDIR/trusted.program.out" "$WORKDIR/forced-source.program.out" >/dev/null ||
    fail "trusted and forced-source consumer stdout differ"
cmp "$WORKDIR/trusted.program.err" "$WORKDIR/forced-source.program.err" >/dev/null ||
    fail "trusted and forced-source consumer stderr differ"

echo "[package-surface-tlci] authored dependency diagnostic differential"
run_failure_pair authored "surface-right authored diagnostic" E0505
echo "[package-surface-tlci] dependency fuel diagnostic differential"
run_failure_pair fuel "compile-time evaluation limit exceeded" E0507

echo "[package-surface-tlci] interleaved source + TLI dependency hydration"
cat > "$CONSUMER/src/main.tl" <<'EOF'
(module consumer.src.main)

(import stdlib.string)

(define prefix-offset : i64 (+ (string.string-length "abc") 7))

(import base.src.lib as base)
(import left.src.lib as left)
(import right.src.lib as right)

(define (main) : i64
  (+
    prefix-offset
    (left.left-value (base.typed-add i64 (left.adjust 1)))
    (right.right-value (base.typed-add i64 (right.adjust 1)))
    (left.same 1)
    (right.same 1)))
EOF
unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true
rm -rf "$CONSUMER/target"
if ! "$COMPILER" build --release \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$WORKDIR/interleaved.out" 2> "$WORKDIR/interleaved.err"; then
    cat "$WORKDIR/interleaved.out" >&2
    cat "$WORKDIR/interleaved.err" >&2
    fail "interleaved source build failed"
fi
assert_tli_route interleaved "$WORKDIR/interleaved.err" 1 3 3 3 0
cp "$CONSUMER_ASM" "$INTERLEAVED_ASM"
run_consumer_90 interleaved
rm -rf "$CONSUMER/target"
TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE
if ! "$COMPILER" build --release \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$WORKDIR/interleaved-source.out" \
    2> "$WORKDIR/interleaved-source.err"; then
    cat "$WORKDIR/interleaved-source.out" >&2
    cat "$WORKDIR/interleaved-source.err" >&2
    fail "interleaved forced-source build failed"
fi
assert_tli_route interleaved-source "$WORKDIR/interleaved-source.err" 0 0 0 0 1
run_consumer_90 interleaved-source
cp "$SUCCESS_SOURCE" "$CONSUMER/src/main.tl"

unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true
rm -rf "$CONSUMER/target"

echo "[package-surface-tlci] corrupted .tli fail-closed rejection"
# `check` prebuilds the dev dependency interfaces; `test --list` then reads
# them without a dependency build, so a corrupt .tli must be rejected (and
# left in place), never silently rebuilt.
cp "$CONSUMER/src/main.tl" "$WORKDIR/consumer-main.bak"
cat >> "$CONSUMER/src/main.tl" <<'EOF'
(import stdlib.test)
(test right-surface (test.assert-i64-eq (right.same 1) (right.same 1) "right surface"))
EOF
"$COMPILER" check \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" > "$WORKDIR/malformed-prebuild.out" 2> "$WORKDIR/malformed-prebuild.err" ||
    fail "check before .tli corruption failed: $(cat "$WORKDIR/malformed-prebuild.err")"
RIGHT_DEV_TLI="$RIGHT/target/dev/surface_right.tli"
[ -s "$RIGHT_DEV_TLI" ] || fail "check did not prebuild $RIGHT_DEV_TLI"
cp "$RIGHT_DEV_TLI" "$WORKDIR/surface_right.dev.tli.bak"
printf 'CORRUPT' > "$RIGHT_DEV_TLI"
set +e
"$COMPILER" test --list \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" > "$WORKDIR/malformed.out" 2> "$WORKDIR/malformed.err"
malformed_status=$?
set -e
[ "$malformed_status" -ne 0 ] || fail "consumer accepted a corrupt dependency .tli"
# The compiler reports native paths: on Windows that is the mixed `D:/...`
# form, not the MSYS `/d/...` spelling this shell uses for `$RIGHT_DEV_TLI`.
RIGHT_DEV_TLI_DIAG=$RIGHT_DEV_TLI
if [ "$NL_HOST_OS" = windows ]; then
    RIGHT_DEV_TLI_DIAG=$(cygpath -m "$RIGHT_DEV_TLI")
fi
grep -F "package tli: $RIGHT_DEV_TLI_DIAG:" "$WORKDIR/malformed.err" >/dev/null ||
    fail "corrupt dependency .tli rejection did not name the interface: $(cat "$WORKDIR/malformed.err")"
[ "$(cat "$RIGHT_DEV_TLI")" = CORRUPT ] || fail "corrupt dependency .tli was overwritten"
cp "$WORKDIR/surface_right.dev.tli.bak" "$RIGHT_DEV_TLI"
cp "$WORKDIR/consumer-main.bak" "$CONSUMER/src/main.tl"

echo "[package-surface-tlci] #9755 v7 and v11 under TYPELISP_DEPENDENCY_TLCI_VERIFY=1"
V7_NP="$WORKDIR/v7/np"
V7_NC="$WORKDIR/v7/nc"
V11_NP="$WORKDIR/v11/np"
V11_NC="$WORKDIR/v11/nc"
mkdir -p "$V7_NP/src" "$V7_NC/src" "$V11_NP/src" "$V11_NC/src"
cat > "$V7_NP/typelisp.pkg" <<'EOF'
(package (name "np") (version "0.1.0") (kind "lib") (entry "src/lib.tl"))
EOF
cat > "$V7_NP/src/lib.tl" <<'EOF'
(import stdlib.comptime)
(define same : i64 42)
(defmacro (t) : Expr `same)
(define via : i64 (t))
EOF
cat > "$V7_NC/typelisp.pkg" <<'EOF'
(package (name "nc") (version "0.1.0") (kind "bin") (entry "src/main.tl")
  (dependencies (np "../np")))
EOF
cat > "$V7_NC/src/main.tl" <<'EOF'
(import np.src.lib as np)
(define (main) : i64 9)
EOF
cat > "$V11_NP/typelisp.pkg" <<'EOF'
(package (name "np11") (version "0.1.0") (kind "lib") (entry "src/lib.tl"))
EOF
cat > "$V11_NP/src/lib.tl" <<'EOF'
(import stdlib.comptime)
(defstruct Own (v i64))
(define same : i64 42)
(defmacro (gen [X : type]) : Module
  (let [h (comptime.module-hook (type-nominal-module X) "same")]
    `(begin (module generated.gm) (import stdlib.comptime)
       (defmacro (peek [e : Expr]) : Expr
         (match e [(comptime.Expr.Var i) (comptime.expr-string i)] [_ (comptime.expr-int 1)]))
       (defmacro (show) : Expr (comptime.expr-call (comptime.expr-var "peek") (comptime.expr-list-cons (quote ,h) (comptime.expr-list-empty))))
       (define (f) : i64 1))))
(import (gen Own) as g)
EOF
cat > "$V11_NC/typelisp.pkg" <<'EOF'
(package (name "nc11") (version "0.1.0") (kind "bin") (entry "src/main.tl")
  (dependencies (np "../np")))
EOF
cat > "$V11_NC/src/main.tl" <<'EOF'
(import np.src.lib as np)
(define (main) : i64 9)
EOF
for pair in "v7:$V7_NC" "v11:$V11_NC"; do
    tag=${pair%%:*}
    pkg=${pair#*:}
    "$COMPILER" check --manifest-path "$pkg/typelisp.pkg" --target "$NL_BOOTSTRAP_TARGET" \
        > "$WORKDIR/$tag-check.out" 2> "$WORKDIR/$tag-check.err" ||
        fail "#9755 $tag check failed"
    "$COMPILER" build --release --manifest-path "$pkg/typelisp.pkg" --target "$NL_BOOTSTRAP_TARGET" --opt-level 0 \
        > "$WORKDIR/$tag-build.out" 2> "$WORKDIR/$tag-build.err" ||
        fail "#9755 $tag build failed"
    set +e
    "$COMPILER" run --release --manifest-path "$pkg/typelisp.pkg" --target "$NL_BOOTSTRAP_TARGET" --opt-level 0 \
        > "$WORKDIR/$tag-run.out" 2> "$WORKDIR/$tag-run.err"
    run_status=$?
    set -e
    [ "$run_status" -eq 9 ] || fail "#9755 $tag run exited $run_status, expected 9"
done

echo "[package-surface-tlci] opaque aggregate source and image visibility"
cat >> "$RIGHT/src/lib.tl" <<'EOF'

(defstruct Whole (:opaque) (whole-secret i64))
(defstruct Mixed (visible i64) (mixed-secret i64 (:opaque)))
(defstruct BorrowedMixed
  (:lifetimes a)
  (visible i64)
  (borrowed-secret (& a i64) (:opaque)))

(defmacro (opacity-first-name [T : type]) : Expr
  (comptime.expr-string (struct-field-name T 0)))

(defmacro (opacity-second-name [T : type]) : Expr
  (comptime.expr-string (struct-field-name T 1)))

(defmacro (opacity-count [T : type]) : Expr
  (if (= (struct-field-count (reference-element-type T)) 2)
    `1
    `0))

(define (make-mixed) : Mixed (Mixed 9 42))
(define (make-borrowed-mixed [value : (& a i64)]) : (BorrowedMixed a)
  (BorrowedMixed 7 value))
(define (read-mixed [value : Mixed]) : i64 value.mixed-secret)
(define (read-whole [value : (& Whole)]) : i64 value.whole-secret)
EOF
for route in native source; do
    if [ "$route" = source ]; then
        TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
        export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE
    else
        unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true
    fi
    for opacity_case in public opaque-field opaque-constructor opaque-pattern \
        opaque-lifetime-constructor opaque-lifetime-pattern opaque-type opaque-name opaque-count; do
        case "$opacity_case" in
            public) extra='' ;;
            opaque-field)
                extra='(define (probe [m : right.Mixed]) : i64 (unsafe m.mixed-secret))' ;;
            opaque-constructor)
                extra='(define (probe) : right.Mixed (unsafe (right.Mixed 1 2)))' ;;
            opaque-pattern)
                extra='(define (probe [m : right.Mixed]) : i64
  (match m [(right.Mixed visible _) visible]))' ;;
            opaque-lifetime-constructor)
                extra='(define (probe [value : (& a i64)]) : (right.BorrowedMixed a)
  (right.BorrowedMixed 1 value))' ;;
            opaque-lifetime-pattern)
                extra='(define (probe [m : (right.BorrowedMixed a)]) : i64
  (match m [(fields visible) visible]))' ;;
            opaque-type)
                extra='(define (probe [w : (& right.Whole)]) : i64 (unsafe w.whole-secret))' ;;
            opaque-name)
                extra='(define (probe) : String (right.opacity-second-name right.Mixed))' ;;
            opaque-count)
                extra='(define (probe) : i64 (right.opacity-count (& a right.Whole)))' ;;
        esac
        cat > "$CONSUMER/src/main.tl" <<EOF
(module right.src.lib.consumer)
(import right.src.lib as right)
(import stdlib.string)

(defstruct Local (:opaque) (local-visible i64) (local-secret i64))

$extra
(define (main) : i64
  (let
    [value : right.Mixed (right.make-mixed)]
    [number : i64 42]
    [borrowed (right.make-borrowed-mixed (& number))]
    (if (and
        (= borrowed.visible 7)
        (string.eq (right.opacity-second-name Local) "local-secret")
        (string.eq (right.opacity-first-name right.Mixed) "visible"))
      (+ (right.adjust value.visible)
        (right.read-mixed value)
        (right.opacity-count (& a Local)))
      0)))
EOF
        rm -rf "$CONSUMER/target"
        log="$WORKDIR/opacity-$opacity_case-$route"
        status=0
        "$COMPILER" build --release --manifest-path "$CONSUMER/typelisp.pkg" \
            --target "$NL_BOOTSTRAP_TARGET" --opt-level 0 \
            > "$log.out" 2> "$log.err" || status=$?
        if [ "$opacity_case" = public ]; then
            [ "$status" -eq 0 ] || fail "$route public opaque aggregate members failed"
            if [ "$route" = native ]; then
                assert_tli_route opacity-native "$log.err" 1 3 1 1 0
                assert_macro_row opacity-native right.src.lib/adjust 1 1 "$log.err"
                assert_macro_row opacity-native right.src.lib/opacity-first-name 1 1 "$log.err"
                assert_macro_row opacity-native right.src.lib/opacity-second-name 1 1 "$log.err"
                assert_macro_row opacity-native right.src.lib/opacity-count 1 1 "$log.err"
                assert_profile_eq dependency_tlci_native_dispatches 4 "$log.err"
            else
                assert_tli_route opacity-source "$log.err" 0 0 0 0 1
            fi
            status=0
            "$CONSUMER_BIN" > "$log.program.out" 2> "$log.program.err" || status=$?
            [ "$status" -eq 57 ] || fail "$route opacity control exited $status, expected 57"
        else
            [ "$status" -ne 0 ] || fail "$route $opacity_case unexpectedly built"
            grep -F 'error[E0221]:' "$log.err" > "$log.diag" ||
                fail "$route $opacity_case did not report E0221"
            case "$opacity_case" in
                opaque-*constructor | opaque-*pattern)
                    grep -F 'with an opaque field outside its module family' "$log.diag" >/dev/null ||
                        fail "$route $opacity_case did not report field opacity" ;;
            esac
            if [ "$route" = native ]; then
                case "$opacity_case" in
                    opaque-name)
                        assert_macro_row "$opacity_case" right.src.lib/opacity-second-name 1 1 "$log.err" ;;
                    opaque-count)
                        assert_macro_row "$opacity_case" right.src.lib/opacity-count 1 1 "$log.err" ;;
                esac
                assert_catalog_state "$opacity_case" "$log.err" 0 3
                assert_tli_route "$opacity_case" "$log.err" 1 3 1 1 0
            else
                cmp "$WORKDIR/opacity-$opacity_case-native.diag" "$log.diag" ||
                    fail "$opacity_case native/source diagnostics differ"
            fi
        fi
    done
done
unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true

echo "[package-surface-tlci] #9083 lifetime-bearing public package exports"
VIEWS="$WORKDIR/views"
VIEW_APP="$WORKDIR/view-app"
VIEW_APP_BIN="$VIEW_APP/target/release/view_app$NL_BIN_EXT"
mkdir -p "$VIEWS/src" "$VIEW_APP/src"

cat > "$VIEWS/typelisp.pkg" <<'EOF'
(package
  (name "views")
  (version "1.0.0")
  (kind "lib"))
EOF
cat > "$VIEWS/src/lib.tl" <<'EOF'
(defstruct View (:lifetimes a) (value (& a i64)))
(defstruct Nested (:lifetimes item) (view (View item)))
(defstruct Plain (value i64))

(define (make-view [x : (& a i64)]) : (View a) (View x))
(define (read-view [view : (View a)]) : i64 (deref view.value))
(define (make-nested [x : (& a i64)]) : (Nested a) (Nested (make-view x)))
(define (make-plain [value : i64]) : Plain (Plain value))

(defmacro (through-interface [value : Expr]) : Expr value)
EOF

cat > "$VIEW_APP/typelisp.pkg" <<'EOF'
(package
  (name "view_app")
  (version "1.0.0")
  (kind "bin")
  (dependencies (views "../views")))
EOF
cat > "$WORKDIR/view-app.tl" <<'EOF'
(import views.src.lib as dep)

(define (consume [x : (& caller i64)]) : i64
  (let
    [view : (dep.View caller) (dep.make-view x)]
    [nested : (dep.Nested caller) (dep.make-nested x)]
    [plain : dep.Plain (dep.make-plain (dep.read-view view))]
    (if (= plain.value (dep.read-view nested.view)) plain.value 1)))

(define (main) : i64
  (let [x : i64 (dep.through-interface 42)] (consume (& x))))
EOF

build_view_app() {
    rm -rf "$VIEW_APP/target"
    "$COMPILER" build --release --manifest-path "$VIEW_APP/typelisp.pkg" \
        --target "$NL_BOOTSTRAP_TARGET" --backend-mode scalar --opt-level "$1" \
        > "$2.out" 2> "$2.err"
}

for opt in 0 1 2; do
    for route in native native-cached source; do
        if [ "$route" = source ]; then
            export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
        else
            unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true
        fi
        cp "$WORKDIR/view-app.tl" "$VIEW_APP/src/main.tl"
        log="$WORKDIR/view-app-opt$opt-$route"
        if ! build_view_app "$opt" "$log"; then
            cat "$log.out" "$log.err" >&2
            fail "#9083 opt$opt $route build failed"
        fi
        if [ "$route" = source ]; then
            assert_catalog_state "$route" "$log.err" 1 0 1
            assert_tli_route "$route" "$log.err" 0 0 0 0 1 1
            assert_profile_eq dependency_tlci_interpreted_fallbacks 1 "$log.err"
            assert_profile_eq dependency_tlci_native_dispatches 0 "$log.err"
        else
            assert_catalog_state "$route" "$log.err" 0 1 1
            assert_tli_route "$route" "$log.err" 1 1 1 1 0 1
            assert_profile_eq dependency_tlci_native_dispatches 1 "$log.err"
            if [ "$route" = native-cached ]; then
                grep -F 'Fresh ' "$log.out" | grep -F 'views.tlci' >/dev/null ||
                    fail "#9083 opt$opt cached build did not reuse the dependency TLCI"
            fi
        fi
        status=0
        "$VIEW_APP_BIN" > "$log.program.out" 2> "$log.program.err" || status=$?
        [ "$status" -eq 42 ] || fail "#9083 opt$opt $route exited $status, expected 42"
    done
done

for route in native source; do
    if [ "$route" = source ]; then
        export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
    else
        unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true
    fi
    for lifetime_case in arity plain-arity unknown escape; do
        case "$lifetime_case" in
            arity)
                invalid='(define (invalid [x : (& a i64)] [y : (& b i64)]) : (dep.View a b)
  (dep.make-view x))'
                expected='error[E0202]: typecheck: nominal lifetime argument arity mismatch' ;;
            plain-arity)
                invalid='(define (invalid [x : (& a i64)]) : (dep.Plain a)
  (dep.make-plain (deref x)))'
                expected='error[E0202]: typecheck: nominal lifetime argument arity mismatch' ;;
            unknown)
                invalid='(define (invalid [x : (& a i64)]) : i64
  (let [view : (dep.View missing) (dep.make-view x)] (dep.read-view view)))'
                expected='source lifetime `a` does not outlive required lifetime `missing`' ;;
            escape)
                invalid='(define (invalid [x : (& a i64)]) : (dep.View a)
  (let [local : i64 (deref x)] (dep.make-view (& local))))'
                expected='error[E0205]: typecheck: reference value would escape lexical scope' ;;
        esac
        cp "$WORKDIR/view-app.tl" "$VIEW_APP/src/main.tl"
        printf '\n%s\n' "$invalid" >> "$VIEW_APP/src/main.tl"
        log="$WORKDIR/view-app-$lifetime_case-$route"
        if build_view_app 0 "$log"; then
            fail "#9083 $route $lifetime_case unexpectedly built"
        fi
        grep -F "$expected" "$log.err" >/dev/null || {
            cat "$log.err" >&2
            fail "#9083 $route $lifetime_case omitted the expected diagnostic"
        }
        if [ "$route" = source ]; then
            assert_tli_route "$route" "$log.err" 0 0 0 0 1 1
        else
            assert_tli_route "$route" "$log.err" 1 1 1 1 0 1
        fi
    done
done
unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true

echo "[package-surface-tlci] direct TLI hydration, lifetime and opacity parity, and #9755 passed"
