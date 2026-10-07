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

# Linux's private TLS word must also work with the debug renderer enabled in
# this emitter. Ordinary compilers deliberately omit that renderer.
if [ "$HOST_OS" = linux ]; then
    for variant in debug combined; do
        for opt in 0 1 2; do
            asm="$WORKDIR/thread-word-$variant-opt$opt.s"
            binary="$WORKDIR/thread-word-$variant-opt$opt"
            set -- --cfg compiler-arena-debug
            if [ "$variant" = combined ]; then
                set -- "$@" --cfg compile-profile --backtrace
            fi
            "$SUPPORT" compile tests/integration/thread_local_word.tl \
                --stdlib-root stdlib --stdlib-root src --opt-level "$opt" \
                "$@" -o "$asm"
            grep -F '.L_tl_arena_debug_roots:' "$asm" >/dev/null ||
                fail "TLS $variant opt$opt omitted arena debug storage"
            grep -F 'tl_arena_debug_assert_pool_install:' "$asm" >/dev/null ||
                fail "TLS $variant opt$opt omitted the debug renderer"
            if [ "$variant" = combined ]; then
                grep -F 'tl_profile_alloc_total_bytes:' "$asm" >/dev/null ||
                    fail "TLS combined opt$opt omitted profile storage"
                grep -F 'tl_backtrace_stack_low:' "$asm" >/dev/null ||
                    fail "TLS combined opt$opt omitted backtrace TLS"
            fi
            assemble_and_link "TLS $variant opt$opt" "$asm" \
                "$WORKDIR/thread-word-$variant-opt$opt.$OBJ_EXT" "$binary"
            status=0
            "$binary" > "$binary.stdout" 2> "$binary.stderr" || status=$?
            [ "$status" -eq 42 ] || fail "TLS $variant opt$opt: exit $status"
            [ ! -s "$binary.stdout" ] && [ ! -s "$binary.stderr" ] ||
                fail "TLS $variant opt$opt: unexpected output"
        done
    done
    echo "Linux thread word debug/profile/backtrace matrix passed (6 cases)"
fi
