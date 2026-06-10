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

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # No-Rust fallback for local development: fetch the published
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

for root in selfhost stdlib tools tests/integration tests/inline examples; do
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

echo "[inline-tests] check ($discovered_file_count file(s), one process per file)"
# #2357: type-check one file per compiler process instead of one batched process
# over the whole corpus. A single batched process accumulates the per-file working
# set and peaks ~2.3GB across the corpus -- right at the memory ceiling of the CI
# runner, which dies there with a VM-level SIGTERM (job exit 143) even though it
# fits locally. The heaviest single file (build_cli_core/test_cli_core, which pull
# in the whole compiler) peaks ~1.16GB, so a fresh process per file roughly halves
# the peak and stays well under the ceiling. Output is concatenated in discovery
# order so the per-file "typecheck passed: N" count lines parsed below are
# identical to the old batched output.
: > "$batch_check_stdout"
: > "$batch_check_stderr"
batch_check_status=0
_chunk_list="$WORKDIR/check.chunk.list"
_chunk_stdout="$WORKDIR/check.chunk.stdout"
_chunk_stderr="$WORKDIR/check.chunk.stderr"
while IFS= read -r _chunk_src; do
    [ -n "$_chunk_src" ] || continue
    printf '%s\n' "$_chunk_src" > "$_chunk_list"
    if run_with_retry "$_chunk_stdout" "$_chunk_stderr" \
        "${VERIFY_INLINE_TESTS_ATTEMPTS:-6}" \
        "$COMPILER" test --check --batch "$_chunk_list" --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib"; then
        cat "$_chunk_stdout" >> "$batch_check_stdout"
        cat "$_chunk_stderr" >> "$batch_check_stderr"
    else
        batch_check_status=$?
        cat "$_chunk_stdout" >> "$batch_check_stdout"
        cat "$_chunk_stderr" >> "$batch_check_stderr"
        break
    fi
done < "$DISCOVERED"
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
