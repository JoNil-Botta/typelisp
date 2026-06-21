#!/usr/bin/env sh
set -eu

# verify-safety-corpus.sh - safe-code contract corpus (#1102).
#
# The manifest pairs small TypeLisp fixtures with check/run expectations for the
# SPEC.md "Safe code: no undefined behavior" table.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-retry.sh"
. "$ROOT/scripts/lib-linux-entry.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "safety corpus verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Local-development fallback: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
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

if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || {
        echo "missing assembler: as" >&2
        exit 1
    }
    command -v ld >/dev/null 2>&1 || {
        echo "missing linker: ld" >&2
        exit 1
    }
else
    command -v clang >/dev/null 2>&1 || {
        echo "missing assembler: clang" >&2
        exit 1
    }
    command -v lld-link >/dev/null 2>&1 || {
        echo "missing linker: lld-link" >&2
        exit 1
    }
fi

MANIFEST=${TYPELISP_SAFETY_MANIFEST:-tests/safety/manifest.txt}
if [ ! -f "$MANIFEST" ]; then
    echo "safety corpus manifest does not exist: $MANIFEST" >&2
    exit 1
fi

WORKDIR=${TYPELISP_SAFETY_WORKDIR:-target/safety-corpus-verify}
# Single attempt by default: a #1204 crash from a corpus case is a real compiler
# memory-safety bug, not a transient to retry away (see scripts/lib-retry.sh).
# ATTEMPTS>1 is an opt-in local override only.
ATTEMPTS=${VERIFY_SAFETY_CORPUS_ATTEMPTS:-1}
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
NORMALIZED_MANIFEST="$WORKDIR/manifest.normalized"
tr -d '\r' < "$MANIFEST" > "$NORMALIZED_MANIFEST"

BUILD_TARGET=linux-x86_64
CHECK_BIN="$WORKDIR/selfhost-check"
TARGET_CFG_ARGS="--cfg linux --cfg unix --cfg target-linux --cfg os-linux"
if [ "$HOST_OS" = windows ]; then
    BUILD_TARGET=windows-x86_64
    CHECK_BIN="$WORKDIR/selfhost-check.exe"
    TARGET_CFG_ARGS="--cfg windows --cfg target-windows --cfg os-windows"
fi

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    file=$1
    needle=$2
    if ! grep -F -- "$needle" "$file" >/dev/null; then
        echo "expected substring: $needle" >&2
        echo "actual output:" >&2
        sed 's/^/  /' "$file" >&2 || true
        return 1
    fi
}

assert_empty() {
    file=$1
    if [ -s "$file" ]; then
        echo "expected empty output, got:" >&2
        sed 's/^/  /' "$file" >&2 || true
        return 1
    fi
}

run_case() {
    out=$1
    err=$2
    expected_terminal_code=$3
    shift 3
    attempt=0
    while :; do
        attempt=$((attempt + 1))
        set +e
        "$@" > "$out" 2> "$err"
        code=$?
        set -e
        if [ "$expected_terminal_code" != "-" ] && [ "$code" -eq "$expected_terminal_code" ]; then
            break
        fi
        if is_crash_code "$code" && [ "$attempt" -lt "$ATTEMPTS" ]; then
            echo "  retry ($attempt/$ATTEMPTS): safety corpus crash exit $code - likely transient (#1204)" >&2
        else
            break
        fi
    done
}

# Assemble (clang) + link (lld-link) a Windows .s into an .exe. The compile-only
# bootstrapped stage1 has no `build` host action, so the corpus drives the Windows
# toolchain by hand (mirrors verify-integration.sh's assemble_link_windows).
assemble_link_windows() {
    _asm=$1
    _obj=$2
    _bin=$3
    _label=$4
    _out=$5
    _err=$6
    if ! clang --target=x86_64-pc-windows-msvc -c "$_asm" -o "$_obj" >> "$_out" 2>> "$_err"; then
        show_stream_if_nonempty stderr "$_err"
        fail "$_label assemble failed"
    fi
    if ! lld-link -NOLOGO "$(cygpath -aw "$_obj")" "-OUT:$(cygpath -aw "$_bin")" \
        -SUBSYSTEM:CONSOLE -STACK:268435456 -ENTRY:_tl_start -NODEFAULTLIB kernel32.lib \
        >> "$_out" 2>> "$_err"; then
        show_stream_if_nonempty stderr "$_err"
        fail "$_label link failed"
    fi
}

build_selfhost_checker() {
    out="$WORKDIR/selfhost-check.build.out"
    err="$WORKDIR/selfhost-check.build.err"
    if [ "$HOST_OS" = windows ]; then
        asm="$WORKDIR/selfhost-check.s"
        obj="$WORKDIR/selfhost-check.obj"
        run_case "$out" "$err" 0 \
            "$COMPILER" compile src/main.tl \
            --target "$BUILD_TARGET" \
            $TARGET_CFG_ARGS \
            --stdlib-root stdlib \
            -o "$asm"
        if [ "$code" -ne 0 ]; then
            echo "stdout:" >&2
            sed 's/^/  /' "$out" >&2 || true
            echo "stderr:" >&2
            sed 's/^/  /' "$err" >&2 || true
            fail "src/main.tl compile failed with exit $code"
        fi
        assemble_link_windows "$asm" "$obj" "$CHECK_BIN" "src/main.tl" "$out" "$err"
    else
        # The compile-only bootstrapped stage1 has `compile`/`check` but not the
        # `build` host action, so assemble + link the checker by hand (mirrors
        # build_case_program's Linux path).
        asm="$WORKDIR/selfhost-check.s"
        obj="$WORKDIR/selfhost-check.o"
        run_case "$out" "$err" 0 \
            "$COMPILER" compile src/main.tl \
            --target "$BUILD_TARGET" \
            $TARGET_CFG_ARGS \
            --stdlib-root stdlib \
            -o "$asm"
        if [ "$code" -ne 0 ]; then
            echo "stdout:" >&2
            sed 's/^/  /' "$out" >&2 || true
            echo "stderr:" >&2
            sed 's/^/  /' "$err" >&2 || true
            fail "src/main.tl compile failed with exit $code"
        fi
        if ! as "$asm" -o "$obj" >> "$out" 2>> "$err"; then
            show_stream_if_nonempty stderr "$err"
            fail "src/main.tl assemble failed"
        fi
        if ! ld "$obj" -o "$CHECK_BIN" -static -e "$(linux_entry_symbol_for_asm "$asm")" \
            >> "$out" 2>> "$err"; then
            show_stream_if_nonempty stderr "$err"
            fail "src/main.tl link failed"
        fi
    fi
}

safe_name() {
    printf '%s' "$1" | sed 's#[/\\:]#_#g'
}

show_stream_if_nonempty() {
    label=$1
    file=$2
    if [ -s "$file" ]; then
        echo "$label:" >&2
        sed 's/^/  /' "$file" >&2 || true
    fi
}

build_case_program() {
    case_id=$1
    case_name=$2
    source=$3
    case_dir="$WORKDIR/$case_name"
    mkdir -p "$case_dir"
    build_out="$case_dir/build.out"
    build_err="$case_dir/build.err"

    if [ "$HOST_OS" = windows ]; then
        case_source="$case_dir/$(basename "$source")"
        cp "$source" "$case_source"
        asm="$case_dir/$case_name.s"
        obj="$case_dir/$case_name.obj"
        program="$case_dir/$case_name.exe"
        run_case "$build_out" "$build_err" 0 \
            "$COMPILER" compile "$case_source" \
            --target "$BUILD_TARGET" \
            $TARGET_CFG_ARGS \
            --stdlib-root "$ROOT/stdlib" \
            -o "$asm"
        if [ "$code" -ne 0 ]; then
            show_stream_if_nonempty stdout "$build_out"
            show_stream_if_nonempty stderr "$build_err"
            fail "$case_id compile failed with exit $code"
        fi
        assemble_link_windows "$asm" "$obj" "$program" "$case_id" "$build_out" "$build_err"
    else
        asm="$case_dir/$case_name.s"
        obj="$case_dir/$case_name.o"
        program="$case_dir/$case_name"
        run_case "$build_out" "$build_err" 0 \
            "$COMPILER" compile "$source" \
            --target "$BUILD_TARGET" \
            $TARGET_CFG_ARGS \
            --stdlib-root "$ROOT/stdlib" \
            -o "$asm"
        if [ "$code" -ne 0 ]; then
            show_stream_if_nonempty stdout "$build_out"
            show_stream_if_nonempty stderr "$build_err"
            fail "$case_id compile failed with exit $code"
        fi
        if ! as "$asm" -o "$obj" >> "$build_out" 2>> "$build_err"; then
            show_stream_if_nonempty stdout "$build_out"
            show_stream_if_nonempty stderr "$build_err"
            fail "$case_id assemble failed"
        fi
        if ! ld "$obj" -o "$program" -static -e "$(linux_entry_symbol_for_asm "$asm")" \
            >> "$build_out" 2>> "$build_err"; then
            show_stream_if_nonempty stdout "$build_out"
            show_stream_if_nonempty stderr "$build_err"
            fail "$case_id link failed"
        fi
    fi
}

run_program_case() {
    case_id=$1
    case_name=$2
    source=$3
    out=$4
    err=$5
    expected_code=$6
    build_case_program "$case_id" "$case_name" "$source"
    run_case "$out" "$err" "$expected_code" "$program"
}

build_selfhost_checker

checked=0
while IFS='|' read -r case_id mode source expected_code stderr_contains; do
    case "$case_id" in
        "" | \#*) continue ;;
    esac
    [ -n "$mode" ] || fail "$case_id missing mode"
    [ -n "$source" ] || fail "$case_id missing source"
    [ -f "$source" ] || fail "$case_id source does not exist: $source"

    checked=$((checked + 1))
    case_name=$(safe_name "$case_id")
    out="$WORKDIR/$case_name.out"
    err="$WORKDIR/$case_name.err"

    case "$mode" in
        check-ok)
            echo "[safety-corpus] check-ok $case_id"
            run_case "$out" "$err" 0 "$CHECK_BIN" check "$source" --stdlib-root "$ROOT/stdlib"
            [ "$code" -eq 0 ] || fail "$case_id expected check success, got $code"
            assert_empty "$err" || fail "$case_id expected empty check stderr"
            ;;
        check-fail)
            echo "[safety-corpus] check-fail $case_id"
            run_case "$out" "$err" - "$CHECK_BIN" check "$source" --stdlib-root "$ROOT/stdlib"
            [ "$code" -ne 0 ] || fail "$case_id expected check failure"
            [ "$stderr_contains" != "-" ] || fail "$case_id check-fail missing stderr expectation"
            assert_contains "$err" "$stderr_contains" || fail "$case_id stderr did not match expectation"
            ;;
        run-exit)
            echo "[safety-corpus] run-exit $case_id"
            run_program_case "$case_id" "$case_name" "$source" "$out" "$err" "$expected_code"
            [ "$code" -eq "$expected_code" ] || fail "$case_id expected run exit $expected_code, got $code"
            assert_empty "$err" || fail "$case_id expected empty stderr"
            ;;
        run-trap)
            echo "[safety-corpus] run-trap $case_id"
            run_program_case "$case_id" "$case_name" "$source" "$out" "$err" "$expected_code"
            [ "$code" -eq "$expected_code" ] || fail "$case_id expected trap exit $expected_code, got $code"
            [ "$stderr_contains" != "-" ] || fail "$case_id run-trap missing stderr expectation"
            assert_contains "$err" "$stderr_contains" || fail "$case_id trap stderr did not match expectation"
            ;;
        *)
            fail "$case_id has unknown safety corpus mode: $mode"
            ;;
    esac
done < "$NORMALIZED_MANIFEST"

echo "safety corpus verification passed for $checked case(s)"
