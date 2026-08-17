#!/usr/bin/env sh
set -eu

# Execute package dependency Expr/Module/Decls macros from their admitted TLCI
# catalog, then force the same compiler job through source CTFE and require
# identical assembly/runtime behavior. The supplied compiler must carry
# compile-profile and dependency-tlci-verification.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

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

fail() {
    echo "[package-native-tlci] $*" >&2
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

case "$WORKDIR" in
    "$ROOT"/target/package-native-tlci/*) ;;
    *) fail "refusing unsafe workdir: $WORKDIR" ;;
esac
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

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
assert_profile_eq dependency_tlci_native_dispatches 0 "$SOURCE_ERR"
assert_profile_eq dependency_tlci_load_failures 6 "$SOURCE_ERR"
assert_profile_eq dependency_tlci_interpreted_fallbacks 6 "$SOURCE_ERR"

cmp "$NATIVE_ASM" "$CONSUMER_ASM" >/dev/null ||
    fail "native and forced-source consumer assembly differ"
run_consumer_42 source

echo "[package-native-tlci] Expr/Module/Decls native route and source parity passed"
