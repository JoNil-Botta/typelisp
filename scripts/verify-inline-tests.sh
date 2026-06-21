#!/usr/bin/env sh
set -eu

# verify-inline-tests.sh - auto-discover and run inline TypeLisp tests.
# refs #947

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Retry transient Windows segfaults (#1204) around each `typelisp` invocation.
. "$ROOT/scripts/lib-retry.sh"

HOST_OS=linux
HOST_TARGET=linux-x86_64
case "$(uname -s)" in
    Linux*)
        HOST_OS=linux
        HOST_TARGET=linux-x86_64
        ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        HOST_TARGET=windows-x86_64
        ;;
    *)
        echo "inline test verification is unsupported on this host" >&2
        exit 1
        ;;
esac

PATH_SEP=:
[ "$HOST_OS" = windows ] && PATH_SEP=';'
unset TYPELISP_STDLIB_TEST_MISSING_854
export TYPELISP_STDLIB_TEST_EMPTY=
export TYPELISP_STDLIB_TEST_VALUE=env-value-854
export TYPELISP_STDLIB_TEST_PATH="one${PATH_SEP}two${PATH_SEP}three"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Local-development fallback: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
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

for root in src stdlib tools tests/integration tests/inline examples; do
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

discovered_file_count=$(wc -l < "$DISCOVERED" | tr -d ' ')
batch_check_stdout="$WORKDIR/check.batch.stdout"
batch_check_stderr="$WORKDIR/check.batch.stderr"
check_counts="$WORKDIR/check.counts.txt"
: > "$batch_check_stdout"
: > "$batch_check_stderr"

batch_size=${VERIFY_INLINE_TESTS_BATCH_SIZE:-0}
case "$batch_size" in
    '' | *[!0-9]*)
        echo "invalid VERIFY_INLINE_TESTS_BATCH_SIZE: $batch_size" >&2
        exit 1
        ;;
esac
if [ "$HOST_OS" = windows ] && [ "$batch_size" -eq 0 ]; then
    # Windows CI has less practical headroom for the single large inline-test
    # batch. Keep exercising `test --check --batch`, but do it in bounded
    # chunks so coverage is preserved without relying on a single peak.
    batch_size=16
fi

run_check_batch() {
    _list=$1
    _label=$2
    _stdout=$3
    _stderr=$4
    echo "[inline-tests] check $_label"
    if run_with_retry "$_stdout" "$_stderr" \
        "${VERIFY_INLINE_TESTS_ATTEMPTS:-6}" \
        "$COMPILER" test --check --batch "$_list" --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"; then
        return 0
    fi
    return $?
}

batch_check_status=0
if [ "$batch_size" -gt 0 ] && [ "$discovered_file_count" -gt "$batch_size" ]; then
    chunk_index=1
    chunk_line_count=0
    chunk_path="$WORKDIR/check.chunk.$chunk_index.txt"
    : > "$chunk_path"

    run_current_chunk() {
        chunk_stdout="$WORKDIR/check.chunk.$chunk_index.stdout"
        chunk_stderr="$WORKDIR/check.chunk.$chunk_index.stderr"
        if run_check_batch "$chunk_path" "chunk $chunk_index ($chunk_line_count file(s))" "$chunk_stdout" "$chunk_stderr"; then
            chunk_status=0
        else
            chunk_status=$?
        fi
        cat "$chunk_stdout" >> "$batch_check_stdout" || true
        cat "$chunk_stderr" >> "$batch_check_stderr" || true
        if [ "$chunk_status" -ne 0 ]; then
            batch_check_status=$chunk_status
            return 1
        fi
        chunk_index=$((chunk_index + 1))
        chunk_line_count=0
        chunk_path="$WORKDIR/check.chunk.$chunk_index.txt"
        : > "$chunk_path"
        return 0
    }

    while IFS= read -r source; do
        [ -n "$source" ] || continue
        printf '%s\n' "$source" >> "$chunk_path"
        chunk_line_count=$((chunk_line_count + 1))
        if [ "$chunk_line_count" -ge "$batch_size" ]; then
            run_current_chunk || break
        fi
    done < "$DISCOVERED"
    if [ "$batch_check_status" -eq 0 ] && [ "$chunk_line_count" -gt 0 ]; then
        run_current_chunk || true
    fi
else
    # #2609: `test --check --batch` scopes each entry in its own compiler arena
    # and resets per-file compiler state between entries, matching compile
    # --batch. Keep the default verifier batched so CI exercises that
    # bounded-memory path.
    if run_check_batch "$DISCOVERED" "($discovered_file_count file(s), one batch process)" "$batch_check_stdout" "$batch_check_stderr"; then
        batch_check_status=0
    else
        batch_check_status=$?
    fi
fi
if [ "$batch_check_status" -ne 0 ]; then
    echo "inline test batch typecheck failed" >&2
    show_streams "$batch_check_stdout" "$batch_check_stderr"
    exit 1
fi

sed -n 's/^TypeLisp test typecheck passed: \([0-9][0-9]*\) test(s)$/\1/p' "$batch_check_stdout" \
    | tr -d '\r' > "$check_counts"
check_count_lines=$(wc -l < "$check_counts" | tr -d ' ')
if [ "$check_count_lines" -ne "$discovered_file_count" ]; then
    echo "inline test batch typecheck reported $check_count_lines count line(s), expected $discovered_file_count" >&2
    show_streams "$batch_check_stdout" "$batch_check_stderr"
    exit 1
fi

file_count=0
test_count=0
exec 3< "$check_counts"
while IFS= read -r source; do
    [ -n "$source" ] || continue
    file_count=$((file_count + 1))
    case_name=$(safe_name "$source")
    run_stdout="$WORKDIR/$case_name.run.stdout"
    run_stderr="$WORKDIR/$case_name.run.stderr"

    if ! IFS= read -r case_tests <&3; then
        echo "inline test batch typecheck did not report a count for $source" >&2
        show_streams "$batch_check_stdout" "$batch_check_stderr"
        exit 1
    fi
    if [ -z "$case_tests" ]; then
        echo "inline test typecheck for $source did not report a test count" >&2
        show_streams "$batch_check_stdout" "$batch_check_stderr"
        exit 1
    fi
    if [ "$case_tests" -eq 0 ]; then
        echo "inline test discovery found $source, but typelisp test reported zero tests" >&2
        show_streams "$batch_check_stdout" "$batch_check_stderr"
        exit 1
    fi

    echo "[inline-tests] run $source ($case_tests test(s))"
    if run_with_retry "$run_stdout" "$run_stderr" \
        "${VERIFY_INLINE_TESTS_ATTEMPTS:-6}" \
        "$COMPILER" test "$source" --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"; then
        run_status=0
    else
        run_status=$?
    fi
    if [ "$run_status" -ne 0 ]; then
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
exec 3<&-

echo "inline test verification passed for $test_count test(s) in $file_count file(s)"
