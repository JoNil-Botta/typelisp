#!/usr/bin/env sh
set -eu

# The ordinary compiler excludes optional debug template renderers. Build a
# current-tree test-enabled emitter before selecting compiler-arena-debug in
# the native fixture; passing the cfg to an ordinary emitter is insufficient.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain
COMPILER=${TYPELISP_BIN:?compiler arena debug requires TYPELISP_BIN}
WORKDIR="$ROOT/target/compiler-arena-debug/$HOST_OS"
mkdir -p "$WORKDIR"
SUPPORT="$WORKDIR/emitter$BIN_EXT"
FIXTURE="$WORKDIR/fixture$BIN_EXT"
# native_target_cfg_args emits only fixed, whitespace-free flag tokens.
# shellcheck disable=SC2046
"$COMPILER" compile src/main.tl -o "$WORKDIR/emitter.s"     --target "$BOOTSTRAP_TARGET" $(native_target_cfg_args) --cfg test     --stdlib-root stdlib --stdlib-root src --opt-level 1
assemble_and_link arena-debug-emitter "$WORKDIR/emitter.s"     "$WORKDIR/emitter.$OBJ_EXT" "$SUPPORT"
# shellcheck disable=SC2046
"$SUPPORT" compile tests/integration/compiler_arena_debug.tl     -o "$WORKDIR/fixture.s" --target "$BOOTSTRAP_TARGET"     $(native_target_cfg_args) --cfg compiler-arena-debug     --stdlib-root stdlib --stdlib-root src --opt-level 1
assemble_and_link arena-debug-fixture "$WORKDIR/fixture.s"     "$WORKDIR/fixture.$OBJ_EXT" "$FIXTURE"

check_operation() {
    operation=$1
    expected=$2
    diagnostic=$3
    status=0
    "$FIXTURE" "$operation" > "$WORKDIR/$operation.stdout"         2> "$WORKDIR/$operation.stderr" || status=$?
    [ "$status" -eq "$expected" ] || fail "arena debug $operation: exit $status, expected $expected"
    [ ! -s "$WORKDIR/$operation.stdout" ] || fail "arena debug $operation: unexpected stdout"
    if [ -n "$diagnostic" ]; then
        printf '%s\n' "$diagnostic" > "$WORKDIR/$operation.expected"
    else
        : > "$WORKDIR/$operation.expected"
    fi
    cmp "$WORKDIR/$operation.expected" "$WORKDIR/$operation.stderr" || fail "arena debug $operation: stderr mismatch"
}
for operation in allowed unprotected-reset retire retire-grown; do
    check_operation "$operation" 42 ""
done
for operation in reset-mark reset-all overflow-reset implicit-reset; do
    check_operation "$operation" 134 "tl: never-reset arena reset"
done
check_operation destroy 134 "tl: never-reset arena destroy"
check_operation pool-install 134 "tl: never-reset arena pool install"
for operation in invalid-null invalid-address invalid-atomic retire-unprotected retire-invalid-address; do
    check_operation "$operation" 134 "tl: invalid never-reset arena protection"
done
echo "compiler arena debug native matrix passed (15 cases, $HOST_OS)"
