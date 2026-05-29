#!/usr/bin/env sh
set -eu

# verify-safety-corpus.sh - no-Rust safe-code contract corpus (#1102).
#
# The manifest pairs small TypeLisp fixtures with check/run expectations for the
# SPEC.md "Safe code: no undefined behavior" table.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-retry.sh"

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
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
    [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe"
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

MANIFEST=${TYPELISP_SAFETY_MANIFEST:-tests/safety/manifest.txt}
if [ ! -f "$MANIFEST" ]; then
    echo "safety corpus manifest does not exist: $MANIFEST" >&2
    exit 1
fi

WORKDIR=${TYPELISP_SAFETY_WORKDIR:-target/safety-corpus-verify}
ATTEMPTS=${VERIFY_SAFETY_CORPUS_ATTEMPTS:-6}
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
NORMALIZED_MANIFEST="$WORKDIR/manifest.normalized"
tr -d '\r' < "$MANIFEST" > "$NORMALIZED_MANIFEST"

BUILD_TARGET=linux-x86_64
CHECK_BIN="$WORKDIR/selfhost-check"
if [ "$HOST_OS" = windows ]; then
    BUILD_TARGET=windows-x86_64
    CHECK_BIN="$WORKDIR/selfhost-check.exe"
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

build_selfhost_checker() {
    out="$WORKDIR/selfhost-check.build.out"
    err="$WORKDIR/selfhost-check.build.err"
    run_case "$out" "$err" 0 \
        "$COMPILER" build selfhost/check.tl \
        --target "$BUILD_TARGET" \
        --stdlib-root "$ROOT/stdlib" \
        -o "$CHECK_BIN"
    if [ "$code" -ne 0 ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$out" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$err" >&2 || true
        fail "selfhost/check.tl build failed with exit $code"
    fi
}

safe_name() {
    printf '%s' "$1" | sed 's#[/\\:]#_#g'
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
            run_case "$out" "$err" 0 "$CHECK_BIN" "$source" --stdlib-root "$ROOT/stdlib"
            [ "$code" -eq 0 ] || fail "$case_id expected check success, got $code"
            assert_empty "$err" || fail "$case_id expected empty check stderr"
            ;;
        check-fail)
            echo "[safety-corpus] check-fail $case_id"
            run_case "$out" "$err" - "$CHECK_BIN" "$source" --stdlib-root "$ROOT/stdlib"
            [ "$code" -ne 0 ] || fail "$case_id expected check failure"
            [ "$stderr_contains" != "-" ] || fail "$case_id check-fail missing stderr expectation"
            assert_contains "$err" "$stderr_contains" || fail "$case_id stderr did not match expectation"
            ;;
        run-exit)
            echo "[safety-corpus] run-exit $case_id"
            run_case "$out" "$err" "$expected_code" "$COMPILER" run "$source" --stdlib-root "$ROOT/stdlib"
            [ "$code" -eq "$expected_code" ] || fail "$case_id expected run exit $expected_code, got $code"
            assert_empty "$err" || fail "$case_id expected empty stderr"
            ;;
        run-trap)
            echo "[safety-corpus] run-trap $case_id"
            run_case "$out" "$err" "$expected_code" "$COMPILER" run "$source" --stdlib-root "$ROOT/stdlib"
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
