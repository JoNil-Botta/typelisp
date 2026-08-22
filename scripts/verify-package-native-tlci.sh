#!/usr/bin/env sh
set -eu

# Execute package dependency Expr/Module/Decls macros from their admitted TLCI
# catalog, then force the same compiler job through source CTFE and require
# identical assembly/runtime behavior. A generated producer/consumer/runner
# graph then changes one macro result, deliberately rebuilds only the consumer
# against the stale producer image, and verifies source fallback, native rebuild,
# registry replacement, and deterministic restoration. The supplied compiler
# must carry compile-profile and dependency-tlci-verification.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

# Target-conditioned prefix declarations change how much source work the
# hydrated dependency surface bypasses.
case "$NL_HOST_OS" in
    windows) TRUSTED_PREFIX_SKIPPED=223 ;;
    *) TRUSTED_PREFIX_SKIPPED=218 ;;
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
    echo "package native tlci compiler is not executable: $COMPILER" >&2
    exit 1
}

PRODUCER="$ROOT/tests/spmd/package_callable"
CONSUMER="$ROOT/tests/spmd/package_consumer"
PRODUCER_TARGET="$PRODUCER/target/release"
CONSUMER_TARGET="$CONSUMER/target/release"
PRODUCER_TLCI="$PRODUCER_TARGET/spmd_fixture.tlci"
CONSUMER_ASM="$CONSUMER_TARGET/spmd_consumer.s"
CONSUMER_BIN="$CONSUMER_TARGET/spmd_consumer$NL_BIN_EXT"
WORKDIR="$ROOT/target/package-native-tlci/$NL_HOST_OS"
NATIVE_OUT="$WORKDIR/native.out"
NATIVE_ERR="$WORKDIR/native.err"
SOURCE_OUT="$WORKDIR/source.out"
SOURCE_ERR="$WORKDIR/source.err"
INSPECT_OUT="$WORKDIR/inspect.out"
NATIVE_ASM="$WORKDIR/spmd_consumer.native.s"
TRANSITION="$WORKDIR/transition"
TRANSITION_PRODUCER="$TRANSITION/producer"
TRANSITION_CONSUMER="$TRANSITION/consumer"
TRANSITION_RUNNER="$TRANSITION/runner"
TRANSITION_SOURCE="$TRANSITION_PRODUCER/src/lib.tl"
TRANSITION_MANIFEST="$TRANSITION_PRODUCER/typelisp.pkg"
TRANSITION_TLCI="$TRANSITION_PRODUCER/target/release/rebuild_fixture.tlci"
TRANSITION_CONSUMER_ASM="$TRANSITION_CONSUMER/target/release/rebuild_consumer.s"
TRANSITION_RUNNER_MANIFEST="$TRANSITION_RUNNER/typelisp.pkg"
TRANSITION_BIN="$TRANSITION_RUNNER/target/release/rebuild_runner$NL_BIN_EXT"
TRANSITION_HARNESS="$ROOT/tests/tlci/package_dependency_transition.tl"
OLD_SOURCE="$TRANSITION/producer.old.tl"
NEW_SOURCE="$TRANSITION/producer.new.tl"
OLD_IMAGE="$TRANSITION/rebuild_fixture.old.tlci"
NEW_IMAGE="$TRANSITION/rebuild_fixture.new.tlci"
STALE_CONSUMER_ASM="$TRANSITION/rebuild_consumer.stale.s"
TRANSITION_EVIDENCE="$TRANSITION/evidence.txt"

fail() {
    echo "[package-native-tlci] $*" >&2
    exit 1
}

# Windows package emission may profile package lowering and side-assembly
# regeneration as separate jobs. Validate the first job that exercised a route;
# an expected-zero metric still fails if any job records a nonzero value.
profile_first_nonzero() {
    phase=$1
    file=$2
    awk -F '|' -v wanted="typecheck.macro.$phase" \
        '$1 == "compile-profile" && $2 == wanted && $3 != 0 && !found { \
            value = $3; found = 1 \
         } \
         END { print value + 0 }' "$file"
}

assert_profile_eq() {
    phase=$1
    wanted=$2
    file=$3
    actual=$(profile_first_nonzero "$phase" "$file")
    [ "$actual" -eq "$wanted" ] ||
        fail "$phase is $actual, expected $wanted"
}

run_consumer_42() {
    label=$1
    set +e
    "$CONSUMER_BIN" > "$WORKDIR/$label.program.out" \
        2> "$WORKDIR/$label.program.err"
    status=$?
    set -e
    [ "$status" -eq 42 ] || fail "$label consumer exited $status, expected 42"
    [ ! -s "$WORKDIR/$label.program.out" ] || fail "$label consumer wrote stdout"
    [ ! -s "$WORKDIR/$label.program.err" ] || fail "$label consumer wrote stderr"
}

run_transition_value() {
    label=$1
    wanted=$2
    set +e
    "$TRANSITION_BIN" > "$TRANSITION/$label.program.out" \
        2> "$TRANSITION/$label.program.err"
    status=$?
    set -e
    [ "$status" -eq "$wanted" ] ||
        fail "$label transition consumer exited $status, expected $wanted"
    [ ! -s "$TRANSITION/$label.program.out" ] ||
        fail "$label transition consumer wrote stdout"
    [ ! -s "$TRANSITION/$label.program.err" ] ||
        fail "$label transition consumer wrote stderr"
}

inspect_field() {
    field=$1
    file=$2
    awk -F ': ' -v wanted="$field" '$1 == wanted { print $2; exit }' "$file"
}

case "$WORKDIR" in
    "$ROOT"/target/package-native-tlci/*) ;;
    *) fail "refusing unsafe workdir: $WORKDIR" ;;
esac
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

mkdir -p \
    "$TRANSITION_PRODUCER/src" \
    "$TRANSITION_CONSUMER/src" \
    "$TRANSITION_RUNNER/src"
cat > "$TRANSITION_MANIFEST" <<'EOF'
(package
  (name "rebuild_fixture")
  (version "1.0.0")
  (kind "lib"))
EOF
cat > "$OLD_SOURCE" <<'EOF'
(module fixture.src.lib)

(defmacro (package-answer) : i64
  `42)
EOF
cat > "$NEW_SOURCE" <<'EOF'
(module fixture.src.lib)

(defmacro (package-answer) : i64
  `43)
EOF
cp "$OLD_SOURCE" "$TRANSITION_SOURCE"
cat > "$TRANSITION_CONSUMER/typelisp.pkg" <<'EOF'
(package
  (name "rebuild_consumer")
  (version "1.0.0")
  (kind "lib")
  (dependencies
    (fixture "../producer")))
EOF
cat > "$TRANSITION_CONSUMER/src/lib.tl" <<'EOF'
(module consumer.src.lib)

(import fixture.src.lib as fixture)

(define (answer) : i64
  (fixture.package-answer))
EOF
cat > "$TRANSITION_RUNNER_MANIFEST" <<'EOF'
(package
  (name "rebuild_runner")
  (version "1.0.0")
  (kind "bin")
  (dependencies
    (consumer "../consumer")))
EOF
cat > "$TRANSITION_RUNNER/src/main.tl" <<'EOF'
(module rebuild_runner)

(import consumer.src.lib as consumer)

(define (main) : i64
  (consumer.answer))
EOF

for target in "$PRODUCER/target" "$CONSUMER/target"; do
    case "$target" in
        "$ROOT"/tests/spmd/package_callable/target | \
        "$ROOT"/tests/spmd/package_consumer/target) ;;
        *) fail "refusing unsafe package target cleanup: $target" ;;
    esac
    rm -rf "$target"
done

TYPELISP_DEPENDENCY_TLCI_VERIFY=1
export TYPELISP_DEPENDENCY_TLCI_VERIFY
unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true

echo "[package-native-tlci] trusted native dependency build"
if ! "$COMPILER" build \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$NATIVE_OUT" 2> "$NATIVE_ERR"; then
    cat "$NATIVE_OUT" >&2
    cat "$NATIVE_ERR" >&2
    fail "trusted native dependency build failed"
fi
[ -s "$PRODUCER_TLCI" ] || fail "producer TLCI is missing"
[ -s "$CONSUMER_ASM" ] || fail "consumer assembly is missing"
[ -x "$CONSUMER_BIN" ] || fail "consumer executable is missing"
grep -F "dependency-tlci-verification|phase=prepared|requests=1|entries=1" \
    "$NATIVE_ERR" | grep -F "|metadata=0|code=1|" >/dev/null ||
    fail "consumer did not admit one code-bearing dependency catalog"
grep -F "dependency-tlci-verification|phase=finished|requests=-1|entries=1" \
    "$NATIVE_ERR" |
    grep -F "|surface-enabled=1|surface-fragments=1|surface-hits=1|surface-fallbacks=0|surface-decls=20|surface-macro-skipped=$TRUSTED_PREFIX_SKIPPED|surface-typecheck-skipped=$TRUSTED_PREFIX_SKIPPED" \
    >/dev/null || fail "trusted dependency frontend surface route mismatch"

assert_profile_eq dependency_tlci_catalog_hits 6 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_catalog_misses 0 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_load_failures 0 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_native_dispatches 5 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_native_expr_results 2 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_direct_expr_results 2 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_native_module_results 1 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_native_decls_results 1 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_parameter_name_lookups 0 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_interpreted_fallbacks 2 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_shell_learns 1 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_shell_cache_hits 1 "$NATIVE_ERR"
assert_profile_eq dependency_tlci_direct_shell_env_folds 1 "$NATIVE_ERR"

if ! "$COMPILER" inspect "$PRODUCER_TLCI" > "$INSPECT_OUT" 2>/dev/null; then
    fail "producer TLCI inspect failed"
fi
grep -F "image-classification: code-bearing" "$INSPECT_OUT" >/dev/null ||
    fail "producer TLCI is not code-bearing"

cp "$CONSUMER_ASM" "$NATIVE_ASM"
run_consumer_42 native

case "$CONSUMER/target" in
    "$ROOT"/tests/spmd/package_consumer/target) ;;
    *) fail "refusing unsafe consumer target cleanup" ;;
esac
rm -rf "$CONSUMER/target"
TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE=1
export TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE

echo "[package-native-tlci] forced-source dependency build"
if ! "$COMPILER" build \
    --manifest-path "$CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$SOURCE_OUT" 2> "$SOURCE_ERR"; then
    cat "$SOURCE_OUT" >&2
    cat "$SOURCE_ERR" >&2
    fail "forced-source dependency build failed"
fi
grep -F "dependency-tlci-verification|phase=prepared|requests=1|entries=1" \
    "$SOURCE_ERR" | grep -F "|unavailable=1|metadata=0|code=0|" >/dev/null ||
    fail "forced-source control did not stay on the consumer job"
grep -F "dependency-tlci-verification|phase=finished|requests=-1|entries=1" \
    "$SOURCE_ERR" |
    grep -F "|surface-enabled=0|surface-fragments=1|surface-hits=0|surface-fallbacks=1|surface-decls=0|surface-macro-skipped=0|surface-typecheck-skipped=0" \
    >/dev/null || fail "forced-source dependency frontend route mismatch"
assert_profile_eq dependency_tlci_native_dispatches 0 "$SOURCE_ERR"
assert_profile_eq dependency_tlci_load_failures 6 "$SOURCE_ERR"
assert_profile_eq dependency_tlci_interpreted_fallbacks 6 "$SOURCE_ERR"

cmp "$NATIVE_ASM" "$CONSUMER_ASM" >/dev/null ||
    fail "native and forced-source consumer assembly differ"
run_consumer_42 source

unset TYPELISP_DEPENDENCY_TLCI_FORCE_SOURCE || true

echo "[package-native-tlci] initial transition dependency build"
if ! "$COMPILER" build \
    --manifest-path "$TRANSITION_RUNNER_MANIFEST" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$TRANSITION/old.out" 2> "$TRANSITION/old.err"; then
    cat "$TRANSITION/old.out" >&2
    cat "$TRANSITION/old.err" >&2
    fail "initial transition dependency build failed"
fi
[ -s "$TRANSITION_TLCI" ] || fail "initial transition TLCI is missing"
[ -x "$TRANSITION_BIN" ] || fail "initial transition executable is missing"
grep -F "dependency-tlci-verification|phase=prepared|requests=1|entries=1" \
    "$TRANSITION/old.err" | grep -F "|unavailable=0|metadata=0|code=1|" >/dev/null ||
    fail "initial transition dependency was not admitted as code-bearing"
assert_profile_eq dependency_tlci_catalog_hits 1 "$TRANSITION/old.err"
assert_profile_eq dependency_tlci_load_failures 0 "$TRANSITION/old.err"
assert_profile_eq dependency_tlci_native_dispatches 1 "$TRANSITION/old.err"
assert_profile_eq dependency_tlci_native_expr_results 1 "$TRANSITION/old.err"
assert_profile_eq dependency_tlci_direct_expr_results 1 "$TRANSITION/old.err"
assert_profile_eq dependency_tlci_interpreted_fallbacks 0 "$TRANSITION/old.err"
run_transition_value old 42

if ! "$COMPILER" inspect "$TRANSITION_TLCI" \
    > "$TRANSITION/old.inspect" 2>/dev/null; then
    fail "initial transition TLCI inspect failed"
fi
OLD_SOURCE_DIGEST=$(inspect_field source-set-digest "$TRANSITION/old.inspect")
OLD_CONTENT_HASH=$(inspect_field content-hash "$TRANSITION/old.inspect")
[ -n "$OLD_SOURCE_DIGEST" ] || fail "initial source-set digest is missing"
[ -n "$OLD_CONTENT_HASH" ] || fail "initial content hash is missing"
cp "$TRANSITION_TLCI" "$OLD_IMAGE"

cp "$NEW_SOURCE" "$TRANSITION_SOURCE"
echo "[package-native-tlci] stale transition dependency check"
if ! "$COMPILER" build --package-worker \
    --manifest-path "$TRANSITION_CONSUMER/typelisp.pkg" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --profile release \
    --opt-level 0 \
    > "$TRANSITION/stale.out" 2> "$TRANSITION/stale.err"; then
    cat "$TRANSITION/stale.out" >&2
    cat "$TRANSITION/stale.err" >&2
    fail "stale transition dependency check failed"
fi
[ -s "$TRANSITION_CONSUMER_ASM" ] ||
    fail "stale-source transition consumer assembly is missing"
grep -F "dependency-tlci-verification|phase=prepared|requests=1|entries=1" \
    "$TRANSITION/stale.err" | \
    grep -F "|unavailable=1|metadata=0|code=0|code-bytes=0|fixup-bytes=0|entry-bytes=0|import-bytes=0" \
        >/dev/null ||
    fail "stale transition dependency retained mapped code"
assert_profile_eq dependency_tlci_native_dispatches 0 "$TRANSITION/stale.err"
assert_profile_eq dependency_tlci_load_failures 1 "$TRANSITION/stale.err"
assert_profile_eq dependency_tlci_interpreted_fallbacks 1 "$TRANSITION/stale.err"
cp "$TRANSITION_CONSUMER_ASM" "$STALE_CONSUMER_ASM"

echo "[package-native-tlci] rebuilt transition dependency build"
if ! "$COMPILER" build \
    --manifest-path "$TRANSITION_RUNNER_MANIFEST" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$TRANSITION/new.out" 2> "$TRANSITION/new.err"; then
    cat "$TRANSITION/new.out" >&2
    cat "$TRANSITION/new.err" >&2
    fail "rebuilt transition dependency build failed"
fi
grep -F "dependency-tlci-verification|phase=prepared|requests=1|entries=1" \
    "$TRANSITION/new.err" | grep -F "|unavailable=0|metadata=0|code=1|" >/dev/null ||
    fail "rebuilt transition dependency was not admitted as code-bearing"
assert_profile_eq dependency_tlci_catalog_hits 1 "$TRANSITION/new.err"
assert_profile_eq dependency_tlci_load_failures 0 "$TRANSITION/new.err"
assert_profile_eq dependency_tlci_native_dispatches 1 "$TRANSITION/new.err"
assert_profile_eq dependency_tlci_native_expr_results 1 "$TRANSITION/new.err"
assert_profile_eq dependency_tlci_direct_expr_results 1 "$TRANSITION/new.err"
assert_profile_eq dependency_tlci_interpreted_fallbacks 0 "$TRANSITION/new.err"
grep -F "|fixture.src.lib/package-answer arity=0 calls=1" \
    "$TRANSITION/new.err" >/dev/null ||
    fail "rebuilt transition profile lacks its package-qualified macro call"
cmp "$STALE_CONSUMER_ASM" "$TRANSITION_CONSUMER_ASM" >/dev/null ||
    fail "stale-source and rebuilt-native consumer assembly differ"
run_transition_value new 43

if ! "$COMPILER" inspect "$TRANSITION_TLCI" \
    > "$TRANSITION/new.inspect" 2>/dev/null; then
    fail "rebuilt transition TLCI inspect failed"
fi
NEW_SOURCE_DIGEST=$(inspect_field source-set-digest "$TRANSITION/new.inspect")
NEW_CONTENT_HASH=$(inspect_field content-hash "$TRANSITION/new.inspect")
[ -n "$NEW_SOURCE_DIGEST" ] || fail "rebuilt source-set digest is missing"
[ -n "$NEW_CONTENT_HASH" ] || fail "rebuilt content hash is missing"
[ "$OLD_SOURCE_DIGEST" != "$NEW_SOURCE_DIGEST" ] ||
    fail "source change did not alter the source-set digest"
[ "$OLD_CONTENT_HASH" != "$NEW_CONTENT_HASH" ] ||
    fail "source change did not alter the image content hash"
cp "$TRANSITION_TLCI" "$NEW_IMAGE"

cp "$OLD_SOURCE" "$TRANSITION_SOURCE"
cp "$OLD_IMAGE" "$TRANSITION_TLCI"
echo "[package-native-tlci] same-process transition registry lifecycle"
if ! "$COMPILER" run "$TRANSITION_HARNESS" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --cfg embedded-stdlib-tlci \
    --stdlib-root stdlib \
    --stdlib-root src \
    -- "$TRANSITION_MANIFEST" "$TRANSITION_SOURCE" \
    "$OLD_SOURCE" "$NEW_SOURCE" "$TRANSITION_TLCI" \
    "$OLD_IMAGE" "$NEW_IMAGE" "fixture.src.lib/package-answer" \
    > "$TRANSITION/lifecycle.out" 2> "$TRANSITION/lifecycle.err"; then
    cat "$TRANSITION/lifecycle.out" >&2
    cat "$TRANSITION/lifecycle.err" >&2
    fail "same-process transition registry lifecycle failed"
fi
LIFECYCLE=$(grep -F \
    "package-tlci-transition|package=rebuild_fixture|classification=stale-source|stale-unavailable=1|stale-code-bytes=0|old-generation=1|stale-generation=2|rebuilt-generation=3|restored-generation=4|reused-generation=4" \
    "$TRANSITION/lifecycle.out" || true)
[ -n "$LIFECYCLE" ] || fail "same-process transition evidence is missing"

echo "[package-native-tlci] restored transition dependency build"
if ! "$COMPILER" build \
    --manifest-path "$TRANSITION_RUNNER_MANIFEST" \
    --target "$NL_BOOTSTRAP_TARGET" \
    --backend-mode scalar \
    --opt-level 0 > "$TRANSITION/restored.out" 2> "$TRANSITION/restored.err"; then
    cat "$TRANSITION/restored.out" >&2
    cat "$TRANSITION/restored.err" >&2
    fail "restored transition dependency build failed"
fi
run_transition_value restored 42
if ! "$COMPILER" inspect "$TRANSITION_TLCI" \
    > "$TRANSITION/restored.inspect" 2>/dev/null; then
    fail "restored transition TLCI inspect failed"
fi
RESTORED_SOURCE_DIGEST=$(inspect_field source-set-digest "$TRANSITION/restored.inspect")
RESTORED_CONTENT_HASH=$(inspect_field content-hash "$TRANSITION/restored.inspect")
[ "$RESTORED_SOURCE_DIGEST" = "$OLD_SOURCE_DIGEST" ] ||
    fail "restored source-set digest differs from the initial digest"
[ "$RESTORED_CONTENT_HASH" = "$OLD_CONTENT_HASH" ] ||
    fail "restored content hash differs from the initial hash"
cmp "$OLD_IMAGE" "$TRANSITION_TLCI" >/dev/null ||
    fail "restored transition image is not byte-identical to the initial image"

{
    echo "old-source-set-digest=$OLD_SOURCE_DIGEST"
    echo "new-source-set-digest=$NEW_SOURCE_DIGEST"
    echo "old-content-hash=$OLD_CONTENT_HASH"
    echo "new-content-hash=$NEW_CONTENT_HASH"
    echo "$LIFECYCLE"
} > "$TRANSITION_EVIDENCE"

echo "[package-native-tlci] Expr/Module/Decls parity and stale/rebuild lifecycle passed"
