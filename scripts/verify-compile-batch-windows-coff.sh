#!/usr/bin/env sh
set -eu

# verify-compile-batch-windows-coff.sh - One-lowering Windows COFF-or-assembly
# batch contract, deterministic plan, and native object link/run smoke.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

COMPILER=${TYPELISP_BIN:-}
if [ -z "$COMPILER" ]; then
    echo "Windows COFF batch verifier requires TYPELISP_BIN" >&2
    exit 1
fi
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

fail() {
    echo "$*" >&2
    exit 1
}

assert_contains() {
    file=$1
    needle=$2
    if ! grep -qF "$needle" "$file"; then
        echo "expected '$needle' in $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    fi
}

assert_empty() {
    file=$1
    [ ! -s "$file" ] || {
        echo "expected empty file: $file" >&2
        sed 's/^/  /' "$file" >&2 || true
        exit 1
    }
}

HOST_OS=linux
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    Linux*) HOST_OS=linux ;;
    *) fail "unsupported host: $(uname -s)" ;;
esac

WORKDIR="target/verify-compile-batch-windows-coff"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

DIRECT_SOURCE="tests/integration/f64_negation.tl"
FALLBACK_SOURCE="tests/integration/aggregate_globals.tl"
DIRECT_OBJECT="$WORKDIR/direct.obj"
DIRECT_ASSEMBLY="$WORKDIR/direct.s"
FALLBACK_OBJECT="$WORKDIR/fallback.obj"
FALLBACK_ASSEMBLY="$WORKDIR/fallback.s"
FORCED_OBJECT="$WORKDIR/forced.obj"
FORCED_ASSEMBLY="$WORKDIR/forced.s"
RESULT_PLAN="$WORKDIR/results.plan"
BATCH_LIST="$WORKDIR/artifacts.list"

printf '%s|%s|%s\n' \
    "$DIRECT_SOURCE" "$DIRECT_OBJECT" "$DIRECT_ASSEMBLY" > "$BATCH_LIST"
printf '%s|%s|%s|force-assembly\n' \
    "$FALLBACK_SOURCE" "$FORCED_OBJECT" "$FORCED_ASSEMBLY" >> "$BATCH_LIST"
printf '%s|%s|%s\n' \
    "$FALLBACK_SOURCE" "$FALLBACK_OBJECT" "$FALLBACK_ASSEMBLY" >> "$BATCH_LIST"

echo "[compile-batch-windows-coff] object, fallback, and forced assembly"
if ! TYPELISP_WINDOWS_CLANG=__typelisp_unexpected_batch_assembler__.exe \
    "$COMPILER" compile --batch "$BATCH_LIST" \
    --windows-coff-plan "$RESULT_PLAN" \
    --target windows-x86_64 \
    --stdlib-root stdlib \
    > "$WORKDIR/batch.stdout" 2> "$WORKDIR/batch.stderr"; then
    sed 's/^/  /' "$WORKDIR/batch.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/batch.stderr" >&2 || true
    fail "Windows COFF batch compile failed"
fi
assert_empty "$WORKDIR/batch.stderr"

EXPECTED_PLAN="$WORKDIR/expected.plan"
printf '%s|coff-object|%s|none\n' \
    "$DIRECT_SOURCE" "$DIRECT_OBJECT" > "$EXPECTED_PLAN"
printf '%s|assembly|%s|forced-assembly\n' \
    "$FALLBACK_SOURCE" "$FORCED_ASSEMBLY" >> "$EXPECTED_PLAN"
printf '%s|assembly|%s|unsupported-coff-image\n' \
    "$FALLBACK_SOURCE" "$FALLBACK_ASSEMBLY" >> "$EXPECTED_PLAN"
cmp "$EXPECTED_PLAN" "$RESULT_PLAN" ||
    fail "Windows COFF batch result plan was not deterministic"

[ -s "$DIRECT_OBJECT" ] || fail "direct row did not write a COFF object"
[ ! -e "$DIRECT_ASSEMBLY" ] || fail "direct row unexpectedly wrote assembly"
[ ! -e "$FALLBACK_OBJECT" ] || fail "fallback row unexpectedly wrote an object"
[ -s "$FALLBACK_ASSEMBLY" ] || fail "fallback row did not write assembly"
[ ! -e "$FORCED_OBJECT" ] || fail "forced row unexpectedly wrote an object"
[ -s "$FORCED_ASSEMBLY" ] || fail "forced row did not write assembly"

LEGACY_ASSEMBLY="$WORKDIR/legacy.s"
LEGACY_LIST="$WORKDIR/legacy.list"
printf '%s|%s\n' "$FALLBACK_SOURCE" "$LEGACY_ASSEMBLY" > "$LEGACY_LIST"
if ! "$COMPILER" compile --batch "$LEGACY_LIST" \
    --target windows-x86_64 \
    --stdlib-root stdlib \
    > "$WORKDIR/legacy.stdout" 2> "$WORKDIR/legacy.stderr"; then
    sed 's/^/  /' "$WORKDIR/legacy.stdout" >&2 || true
    sed 's/^/  /' "$WORKDIR/legacy.stderr" >&2 || true
    fail "legacy Windows assembly batch compile failed"
fi
assert_empty "$WORKDIR/legacy.stderr"
cmp "$LEGACY_ASSEMBLY" "$FORCED_ASSEMBLY" ||
    fail "forced assembly differs from the legacy batch output"
cmp "$LEGACY_ASSEMBLY" "$FALLBACK_ASSEMBLY" ||
    fail "automatic fallback assembly differs from the legacy batch output"

MALFORMED_LIST="$WORKDIR/malformed.list"
MALFORMED_PLAN="$WORKDIR/malformed.plan"
printf '%s|%s\n' "$DIRECT_SOURCE" "$WORKDIR/malformed.obj" > "$MALFORMED_LIST"
printf 'stale plan must not survive\n' > "$MALFORMED_PLAN"
if "$COMPILER" compile --batch "$MALFORMED_LIST" \
    --windows-coff-plan "$MALFORMED_PLAN" \
    --target windows-x86_64 \
    --stdlib-root stdlib \
    > "$WORKDIR/malformed.stdout" 2> "$WORKDIR/malformed.stderr"; then
    fail "malformed Windows COFF batch unexpectedly succeeded"
fi
assert_contains "$WORKDIR/malformed.stderr" \
    "compile: malformed --batch line 1: missing assembly path"
[ ! -e "$MALFORMED_PLAN" ] ||
    fail "malformed Windows COFF batch wrote a result plan"

BAD_SOURCE="$WORKDIR/bad.tl"
cat > "$BAD_SOURCE" <<'EOF'
(define (main) : i64
  "not an integer")
EOF
FAILURE_LIST="$WORKDIR/failure.list"
FAILURE_PLAN="$WORKDIR/failure.plan"
SENTINEL_OBJECT="$WORKDIR/sentinel.obj"
SENTINEL_ASSEMBLY="$WORKDIR/sentinel.s"
printf 'stale plan must not survive\n' > "$FAILURE_PLAN"
printf '%s|%s|%s\n' \
    "$BAD_SOURCE" "$WORKDIR/bad.obj" "$WORKDIR/bad.s" > "$FAILURE_LIST"
printf '%s|%s|%s\n' \
    "$DIRECT_SOURCE" "$SENTINEL_OBJECT" "$SENTINEL_ASSEMBLY" >> "$FAILURE_LIST"
if "$COMPILER" compile --batch "$FAILURE_LIST" \
    --windows-coff-plan "$FAILURE_PLAN" \
    --target windows-x86_64 \
    --stdlib-root stdlib \
    > "$WORKDIR/failure.stdout" 2> "$WORKDIR/failure.stderr"; then
    fail "compile-error Windows COFF batch unexpectedly succeeded"
fi
assert_contains "$WORKDIR/failure.stderr" \
    "typecheck: return type mismatch: expected i64, found String"
assert_contains "$WORKDIR/failure.stderr" \
    "compile: batch source failed: $BAD_SOURCE"
[ ! -e "$FAILURE_PLAN" ] ||
    fail "failed Windows COFF batch wrote a result plan"
[ ! -e "$SENTINEL_OBJECT" ] ||
    fail "failed Windows COFF batch compiled the sentinel object"
[ ! -e "$SENTINEL_ASSEMBLY" ] ||
    fail "failed Windows COFF batch compiled the sentinel assembly"

if "$COMPILER" compile --batch "$BATCH_LIST" \
    --windows-coff-plan "$WORKDIR/linux-target.plan" \
    --target linux-x86_64 \
    > "$WORKDIR/linux-target.stdout" 2> "$WORKDIR/linux-target.stderr"; then
    fail "Windows COFF batch accepted a Linux target"
fi
assert_contains "$WORKDIR/linux-target.stderr" \
    "compile: --windows-coff-plan requires --target windows-x86_64"

if [ "$HOST_OS" = windows ]; then
    LINKER=
    if command -v lld-link >/dev/null 2>&1; then
        LINKER=$(command -v lld-link)
    elif command -v lld-link.exe >/dev/null 2>&1; then
        LINKER=$(command -v lld-link.exe)
    fi
    [ -n "$LINKER" ] || fail "missing Windows COFF linker: lld-link"

    DIRECT_EXE="$WORKDIR/direct.exe"
    DIRECT_OBJECT_WIN=$(cygpath -aw "$DIRECT_OBJECT")
    DIRECT_EXE_WIN=$(cygpath -aw "$DIRECT_EXE")
    echo "[compile-batch-windows-coff] link and run direct object without clang"
    MSYS2_ARG_CONV_EXCL='*' "$LINKER" \
        /NOLOGO \
        "$DIRECT_OBJECT_WIN" \
        "/OUT:$DIRECT_EXE_WIN" \
        /SUBSYSTEM:CONSOLE \
        /ENTRY:_tl_start \
        /NODEFAULTLIB \
        /DYNAMICBASE:NO \
        /STACK:268435456 \
        kernel32.lib

    set +e
    "$DIRECT_EXE" > "$WORKDIR/direct.stdout" 2> "$WORKDIR/direct.stderr"
    direct_status=$?
    set -e
    [ "$direct_status" -eq 42 ] ||
        fail "direct batch object executable expected exit 42, got $direct_status"
    assert_empty "$WORKDIR/direct.stdout"
    assert_empty "$WORKDIR/direct.stderr"
fi

echo "Windows COFF batch verifier passed"
