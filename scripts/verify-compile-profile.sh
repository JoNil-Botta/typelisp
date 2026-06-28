#!/usr/bin/env sh
set -eu

# verify-compile-profile.sh - smoke compile-profile detail output.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/compile-profile-verify/$NL_HOST_OS"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

PROFILE_ASM="$WORKDIR/typelisp-profile.s"
PROFILE_OBJ="$WORKDIR/typelisp-profile.$NL_OBJ_EXT"
PROFILE_BIN="$WORKDIR/typelisp-profile$NL_BIN_EXT"
BUILD_STDOUT="$WORKDIR/profile-build.stdout"
BUILD_STDERR="$WORKDIR/profile-build.stderr"
CHECK_STDOUT="$WORKDIR/profile-check.stdout"
CHECK_STDERR="$WORKDIR/profile-check.stderr"
VECTOR_STDOUT="$WORKDIR/profile-vector.stdout"
VECTOR_STDERR="$WORKDIR/profile-vector.stderr"
REPLAY_STDOUT="$WORKDIR/profile-generated-replay.stdout"
REPLAY_STDERR="$WORKDIR/profile-generated-replay.stderr"
LAYOUT_STDOUT="$WORKDIR/profile-layout.stdout"
LAYOUT_STDERR="$WORKDIR/profile-layout.stderr"
OPT_ASM="$WORKDIR/profile-opt.s"
OPT_STDOUT="$WORKDIR/profile-opt.stdout"
OPT_STDERR="$WORKDIR/profile-opt.stderr"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

show_failure_logs() {
    _stdout=$1
    _stderr=$2
    echo "stdout:" >&2
    sed 's/^/  /' "$_stdout" >&2 || true
    echo "stderr:" >&2
    sed 's/^/  /' "$_stderr" >&2 || true
}

assert_contains_in() {
    _file=$1
    _text=$2
    _stdout=$3
    _stderr=$4
    if ! grep -F -- "$_text" "$_file" >/dev/null; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "missing expected profile text: $_text"
    fi
}

assert_contains() {
    assert_contains_in "$1" "$2" "$CHECK_STDOUT" "$CHECK_STDERR"
}

assert_not_contains_in() {
    _file=$1
    _text=$2
    _stdout=$3
    _stderr=$4
    if grep -F -- "$_text" "$_file" >/dev/null; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "unexpected profile text: $_text"
    fi
}

assert_not_contains() {
    assert_not_contains_in "$1" "$2" "$CHECK_STDOUT" "$CHECK_STDERR"
}

assert_line_count_in() {
    _file=$1
    _text=$2
    _want=$3
    _stdout=$4
    _stderr=$5
    _got=$(grep -F -- "$_text" "$_file" | wc -l | tr -d '[:space:]')
    if [ "$_got" != "$_want" ]; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "expected $_want profile rows for: $_text; got $_got"
    fi
}

assert_layout_row() {
    assert_contains_in \
        "$LAYOUT_STDERR" \
        "compile-profile|typecheck.layout.$1|" \
        "$LAYOUT_STDOUT" \
        "$LAYOUT_STDERR"
}

assert_opt_escape_row() {
    assert_contains_in \
        "$OPT_STDERR" \
        "compile-profile-detail|optimize.escape.$1|" \
        "$OPT_STDOUT" \
        "$OPT_STDERR"
}

assert_lower_row() {
    assert_contains_in \
        "$OPT_STDERR" \
        "compile-profile|lower.$1|" \
        "$OPT_STDOUT" \
        "$OPT_STDERR"
}

echo "[compile-profile] compile profile-enabled CLI"
if ! "$COMPILER" compile src/main.tl \
    -o "$PROFILE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --cfg compile-profile \
    > "$BUILD_STDOUT" 2> "$BUILD_STDERR"; then
    show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "profile-enabled CLI compile failed"
fi

echo "[compile-profile] link profile-enabled CLI"
if ! assemble_and_link compile-profile-cli "$PROFILE_ASM" "$PROFILE_OBJ" "$PROFILE_BIN" \
    >> "$BUILD_STDOUT" 2>> "$BUILD_STDERR"; then
    show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "profile-enabled CLI link failed"
fi

echo "[compile-profile] check macro detail fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_macro_detail.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$CHECK_STDOUT" 2> "$CHECK_STDERR"; then
    show_failure_logs "$CHECK_STDOUT" "$CHECK_STDERR"
    fail "profiled fixture check failed"
fi

assert_contains "$CHECK_STDERR" "compile-profile-detail|typecheck.macro_expand|"
assert_contains "$CHECK_STDERR" "stdlib.str_cat/str-cat arity=2 calls=1"
assert_contains "$CHECK_STDERR" "stdlib.str_cat/str-cat arity=6 calls=1"
assert_not_contains "$CHECK_STDERR" "stdlib.str_cat/str-cat-pack"
assert_contains "$CHECK_STDERR" "stdlib.core_macros/and arity=3"
assert_contains "$CHECK_STDERR" "stdlib.core_macros/or arity=2"
assert_contains "$CHECK_STDERR" "stdlib.core_macros/cond arity=4"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.binds|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.lookups|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.cache_builds|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.marker_scans|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.module_local_hits|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.module_local_misses|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.generated_fingerprint_cache_hits|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.generated_fingerprint_cache_misses|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.reinfer.move.call_func|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.reinfer.borrow.call_arg.calls|"

echo "[compile-profile] check named vector Decls macro fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_named_vector_decls.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$VECTOR_STDOUT" 2> "$VECTOR_STDERR"; then
    show_failure_logs "$VECTOR_STDOUT" "$VECTOR_STDERR"
    fail "profiled vector fixture check failed"
fi

assert_contains_in \
    "$VECTOR_STDERR" \
    "compile-profile-detail|typecheck.macro_expand|" \
    "$VECTOR_STDOUT" \
    "$VECTOR_STDERR"
assert_contains_in \
    "$VECTOR_STDERR" \
    "stdlib.vector/vector-family arity=3 calls=2" \
    "$VECTOR_STDOUT" \
    "$VECTOR_STDERR"

echo "[compile-profile] check generated module replay lazy fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_generated_replay_lazy.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$REPLAY_STDOUT" 2> "$REPLAY_STDERR"; then
    show_failure_logs "$REPLAY_STDOUT" "$REPLAY_STDERR"
    fail "profiled generated replay fixture check failed"
fi

assert_contains_in \
    "$REPLAY_STDERR" \
    "compile-profile-detail|typecheck.macro_expand|" \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
assert_contains_in \
    "$REPLAY_STDERR" \
    "compile-profile|typecheck.macro.generated_compare_passes|0|0|0|0" \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
assert_contains_in \
    "$REPLAY_STDERR" \
    "compile-profile|typecheck.macro.generated_fingerprint_cache_hits|0|0|0|0" \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
assert_contains_in \
    "$REPLAY_STDERR" \
    "compile-profile|typecheck.macro.generated_fingerprint_cache_misses|0|0|0|0" \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
assert_line_count_in \
    "$REPLAY_STDERR" \
    "profile-replay-user arity=1 calls=1" \
    2 \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
assert_line_count_in \
    "$REPLAY_STDERR" \
    "profile-replay-nested arity=2 calls=1" \
    2 \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"

echo "[compile-profile] check layout/spec counter fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_layout_spec.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$LAYOUT_STDOUT" 2> "$LAYOUT_STDERR"; then
    show_failure_logs "$LAYOUT_STDOUT" "$LAYOUT_STDERR"
    fail "profiled layout/spec fixture check failed"
fi

assert_layout_row "repr_c_field_builds"
assert_layout_row "repr_c_field_visits"
assert_layout_row "inline_field_builds"
assert_layout_row "inline_field_visits"
assert_layout_row "inline_payload_builds"
assert_layout_row "inline_payload_visits"
assert_layout_row "inline_variant_builds"
assert_layout_row "inline_variant_visits"
assert_layout_row "stdlib_field_spec_builds"
assert_layout_row "stdlib_field_spec_visits"
assert_layout_row "stdlib_variant_spec_builds"
assert_layout_row "stdlib_variant_spec_visits"
assert_layout_row "cache_hits"
assert_layout_row "cache_misses"
assert_layout_row "cache_bypasses"

echo "[compile-profile] compile optimizer escape fixture"
if ! "$PROFILE_BIN" compile tests/integration/compile_profile_optimizer_escape.tl \
    -o "$OPT_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root . \
    --stdlib-root stdlib \
    --opt-level 1 \
    > "$OPT_STDOUT" 2> "$OPT_STDERR"; then
    show_failure_logs "$OPT_STDOUT" "$OPT_STDERR"
    fail "profiled optimized fixture compile failed"
fi

assert_contains_in \
    "$OPT_STDERR" \
    "compile-profile|optimize.functions|" \
    "$OPT_STDOUT" \
    "$OPT_STDERR"
assert_opt_escape_row "body"
assert_opt_escape_row "compact"
assert_opt_escape_row "clone"
assert_opt_escape_row "restore"
assert_contains_in "$OPT_STDERR" "|1|main" "$OPT_STDOUT" "$OPT_STDERR"
assert_lower_row "ast_expr_pool.macro_expand.len"
assert_lower_row "ast_expr_pool.macro_expand.capacity"
assert_lower_row "ast_type_pool.macro_expand.len"
assert_lower_row "ast_type_pool.macro_expand.capacity"
assert_lower_row "ast_expr_pool.typecheck.len"
assert_lower_row "ast_expr_pool.typecheck.capacity"
assert_lower_row "ast_type_pool.typecheck.len"
assert_lower_row "ast_type_pool.typecheck.capacity"
assert_lower_row "ast_expr_pool.pre_decls.len"
assert_lower_row "ast_expr_pool.pre_decls.capacity"
assert_lower_row "ast_type_pool.pre_decls.len"
assert_lower_row "ast_type_pool.pre_decls.capacity"
assert_lower_row "checked_program.pre_decls.decls"
assert_lower_row "checked_program.pre_decls.functions"
assert_lower_row "ir.after_decls.functions"
assert_lower_row "ir.after_decls.blocks"
assert_lower_row "ir.after_decls.instructions"
assert_lower_row "ir_arena.after_decls.active"

echo "[compile-profile] ok"
