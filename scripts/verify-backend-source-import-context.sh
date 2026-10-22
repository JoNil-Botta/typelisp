#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-native-link.sh"
gate_compiler
gate_compiler_absolute
gate_require_compiler
native_link_detect_host
configure_toolchain
WORK=${TYPELISP_BACKEND_IMPORT_WORK:-"$ROOT/target/exp/backend-source-import-context"}
mkdir -p "$WORK"
DRIVER="$WORK/oracle$NL_BIN_EXT"
"$COMPILER" build tools/backend-source-import-oracle/main.tl \
    --stdlib-root stdlib --stdlib-root src --opt-level 2 -o "$DRIVER"
checks=0

run_expected() {
    _run_name=$1
    _run_binary=$2
    _run_status=0
    "$_run_binary" > "$WORK/$_run_name.stdout" 2> "$WORK/$_run_name.stderr" || _run_status=$?
    if [ "$_run_status" -ne 42 ]; then
        cat "$WORK/$_run_name.stdout" "$WORK/$_run_name.stderr" >&2
        fail "$_run_name returned $_run_status, expected 42"
    fi
    [ ! -s "$WORK/$_run_name.stdout" ] && [ ! -s "$WORK/$_run_name.stderr" ] ||
        fail "$_run_name produced unexpected output"
    checks=$((checks + 1))
}

check_assembly() {
    _asm_name=$1
    _asm_source=$2
    "$DRIVER" "$NL_HOST_OS" asm "$_asm_source" "$WORK/$_asm_name.s"
    assemble_and_link "$_asm_name" "$WORK/$_asm_name.s" \
        "$WORK/$_asm_name.$NL_OBJ_EXT" "$WORK/$_asm_name$NL_BIN_EXT"
    run_expected "$_asm_name" "$WORK/$_asm_name$NL_BIN_EXT"
}

check_cli() {
    _cli_name=$1
    _cli_source=$2
    "$COMPILER" build "$_cli_source" --target "$NL_BOOTSTRAP_TARGET" \
        --stdlib-root stdlib --stdlib-root src --opt-level 0 -o "$WORK/$_cli_name$NL_BIN_EXT"
    run_expected "$_cli_name" "$WORK/$_cli_name$NL_BIN_EXT"
}

for fixture in payload aliases wildcard; do
    source="tests/fixtures/backend_source_import_$fixture.tl"
    check_assembly "$fixture-asm" "$source"
    "$DRIVER" "$NL_HOST_OS" object "$source" "$WORK/$fixture-object.$NL_OBJ_EXT"
    link_native_object "$fixture-object" "$WORK/$fixture-object.$NL_OBJ_EXT" \
        "$WORK/$fixture-object$NL_BIN_EXT"
    run_expected "$fixture-object" "$WORK/$fixture-object$NL_BIN_EXT"
    check_cli "$fixture-cli" "$source"
done

# Raw source-helper images do not certify complete runtime bodies (#8317).
# Keep the allocation fixture's assembly/CLI behaviour and positive exclusion.
source=tests/fixtures/backend_source_import_str_cat.tl
check_assembly str-cat-asm "$source"
check_cli str-cat-cli "$source"
status=0
"$DRIVER" "$NL_HOST_OS" admission "$source" "$WORK/unused" \
    > "$WORK/str-cat-admission.stdout" 2> "$WORK/str-cat-admission.stderr" || status=$?
[ "$status" -eq 2 ] || fail "allocation object was not explicitly excluded: $status"
printf 'unsupported-object-semantics\n' > "$WORK/str-cat-admission.expected"
cmp "$WORK/str-cat-admission.expected" "$WORK/str-cat-admission.stdout"
[ ! -s "$WORK/str-cat-admission.stderr" ] || fail "allocation exclusion produced unexpected stderr"
checks=$((checks + 1))
[ "$checks" -eq 12 ] || fail "expected all 12 route checks, got $checks"
printf 'Backend source imports: %s route checks passed on %s\n' "$checks" "$NL_HOST_OS"
