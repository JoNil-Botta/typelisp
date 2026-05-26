#!/usr/bin/env sh
set -eu

# verify-inline-tests.sh - auto-discover and run inline TypeLisp tests.
# refs #947

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Retry transient Windows segfaults (#1204) around each `typelisp` invocation.
. "$ROOT/scripts/lib-retry.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "inline test verification is unsupported on this host" >&2
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

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/inline-test-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

CANDIDATES="$WORKDIR/candidates.txt"
DISCOVERED="$WORKDIR/discovered.txt"
: > "$CANDIDATES"
: > "$DISCOVERED"

for root in selfhost stdlib tests/integration tests/inline examples; do
    if [ -d "$root" ]; then
        find "$root" \
            -type f \
            -name '*.tl' \
            ! -path '*/target/*'
    fi
done | sort > "$CANDIDATES"

has_inline_test_item() {
    grep -Eq '^[[:space:]]*\(test([[:space:]]|\)|$)' "$1"
}

safe_name() {
    printf '%s' "$1" | sed 's#[/\\:]#_#g'
}

show_streams() {
    _stdout=$1
    _stderr=$2
    if [ -s "$_stdout" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$_stdout" >&2 || true
    fi
    if [ -s "$_stderr" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$_stderr" >&2 || true
    fi
}

# Extract a staged-primitive directive `;; requires-stage0-symbol: <name>` from a
# source file (first match), else empty. Such a file is skipped on the no-Rust
# gate when the fetched compiler does not yet provide <name> (#1114): introduce
# the primitive + a marked test in one PR, merge, let the published stage0
# republish, then drop the marker.
staged_symbol_for() {
    sed -n 's/^;;[[:space:]]*requires-stage0-symbol:[[:space:]]*\([^[:space:]][^[:space:]]*\).*/\1/p' "$1" | head -n 1
}

while IFS= read -r source; do
    [ -n "$source" ] || continue
    if has_inline_test_item "$source"; then
        printf '%s\n' "$source" >> "$DISCOVERED"
    fi
done < "$CANDIDATES"

if [ ! -s "$DISCOVERED" ]; then
    echo "inline test verification found no inline test-bearing TypeLisp files" >&2
    exit 1
fi

file_count=0
test_count=0
skipped=0
while IFS= read -r source; do
    [ -n "$source" ] || continue
    file_count=$((file_count + 1))
    case_name=$(safe_name "$source")
    check_stdout="$WORKDIR/$case_name.check.stdout"
    check_stderr="$WORKDIR/$case_name.check.stderr"
    run_stdout="$WORKDIR/$case_name.run.stdout"
    run_stderr="$WORKDIR/$case_name.run.stderr"
    requires_symbol=$(staged_symbol_for "$source")

    echo "[inline-tests] check $source"
    if run_with_retry "$check_stdout" "$check_stderr" \
        "${VERIFY_INLINE_TESTS_ATTEMPTS:-5}" \
        "$COMPILER" test --check "$source" --stdlib-root "$ROOT/stdlib"; then
        check_status=0
    else
        check_status=$?
    fi
    if [ "$check_status" -ne 0 ]; then
        if [ -n "$requires_symbol" ] && grep -qF "$requires_symbol" "$check_stderr"; then
            echo "[inline-tests] SKIP $source (awaiting stage0 republish of '$requires_symbol')"
            skipped=$((skipped + 1))
            continue
        fi
        echo "inline test typecheck failed for $source" >&2
        show_streams "$check_stdout" "$check_stderr"
        exit 1
    fi

    case_tests=$(sed -n 's/^TypeLisp test typecheck passed: \([0-9][0-9]*\) test(s)$/\1/p' "$check_stdout" | tr -d '\r')
    if [ -z "$case_tests" ]; then
        echo "inline test typecheck for $source did not report a test count" >&2
        show_streams "$check_stdout" "$check_stderr"
        exit 1
    fi
    if [ "$case_tests" -eq 0 ]; then
        echo "inline test discovery found $source, but typelisp test reported zero tests" >&2
        show_streams "$check_stdout" "$check_stderr"
        exit 1
    fi

    echo "[inline-tests] run $source ($case_tests test(s))"
    if run_with_retry "$run_stdout" "$run_stderr" \
        "${VERIFY_INLINE_TESTS_ATTEMPTS:-5}" \
        "$COMPILER" test "$source" --stdlib-root "$ROOT/stdlib"; then
        run_status=0
    else
        run_status=$?
    fi
    if [ "$run_status" -ne 0 ]; then
        if [ -n "$requires_symbol" ] && grep -qF "$requires_symbol" "$run_stderr"; then
            echo "[inline-tests] SKIP $source (awaiting stage0 republish of '$requires_symbol')"
            skipped=$((skipped + 1))
            continue
        fi
        echo "inline test execution failed for $source" >&2
        show_streams "$run_stdout" "$run_stderr"
        exit 1
    fi

    if ! grep -q '^TypeLisp tests passed: ' "$run_stderr"; then
        echo "inline test execution for $source did not report a success summary" >&2
        show_streams "$run_stdout" "$run_stderr"
        exit 1
    fi

    test_count=$((test_count + case_tests))
done < "$DISCOVERED"

if [ "$skipped" -gt 0 ]; then
    echo "inline test verification: $skipped file(s) skipped (staged primitive awaiting stage0 republish)"
fi

echo "inline test verification passed for $test_count test(s) in $file_count file(s)"
