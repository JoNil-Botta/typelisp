#!/usr/bin/env sh
set -eu

# verify-inline-tests.sh - auto-discover and run inline TypeLisp tests.
# refs #947

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-ci-timing.sh"

# Each `typelisp` invocation runs exactly once: a crash is a real compiler bug,
# not a flake — do not retry it (see the no-retry policy in scripts/ci-verify.sh).

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
batch_run_stdout="$WORKDIR/run.batch.stdout"
batch_run_stderr="$WORKDIR/run.batch.stderr"
run_counts="$WORKDIR/run.counts.txt"
run_paths="$WORKDIR/run.paths.txt"

echo "[inline-tests] run ($discovered_file_count file(s), one isolated batch process)"
# #4820: execution batches keep every source inside its own destroyable scratch
# arena with a full driver reset, preserving the old one-process-per-file
# semantics without paying process/bootstrap overhead for every source.
if ci_timing_run all batch-run \
    "$COMPILER" test --batch "$DISCOVERED" --target "$HOST_TARGET" \
    --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" \
    > "$batch_run_stdout" 2> "$batch_run_stderr"; then
    batch_run_status=0
else
    batch_run_status=$?
fi
if [ "$batch_run_status" -ne 0 ]; then
    echo "inline test batch execution failed" >&2
    show_streams "$batch_run_stdout" "$batch_run_stderr"
    exit 1
fi

sed -n 's/^TypeLisp test file: .* (\([0-9][0-9]*\) test(s))$/\1/p' "$batch_run_stdout" \
    | tr -d '\r' > "$run_counts"
sed -n 's/^TypeLisp test file: \(.*\) ([0-9][0-9]* test(s))$/\1/p' "$batch_run_stdout" \
    | tr -d '\r' > "$run_paths"
run_count_lines=$(wc -l < "$run_counts" | tr -d ' ')
if [ "$run_count_lines" -ne "$discovered_file_count" ]; then
    echo "inline test execution batch reported $run_count_lines count line(s), expected $discovered_file_count" >&2
    show_streams "$batch_run_stdout" "$batch_run_stderr"
    exit 1
fi
if ! cmp -s "$DISCOVERED" "$run_paths"; then
    echo "inline test execution batch did not preserve discovered source order" >&2
    show_streams "$batch_run_stdout" "$batch_run_stderr"
    exit 1
fi
if grep -q '^0$' "$run_counts"; then
    echo "inline test execution batch reported zero tests for a discovered source" >&2
    show_streams "$batch_run_stdout" "$batch_run_stderr"
    exit 1
fi

success_count=$(grep -c '^TypeLisp tests passed: ' "$batch_run_stderr" || true)
if [ "$success_count" -ne "$discovered_file_count" ]; then
    echo "inline test execution batch reported $success_count success summary line(s), expected $discovered_file_count" >&2
    show_streams "$batch_run_stdout" "$batch_run_stderr"
    exit 1
fi

test_count=$(awk '{ total += $1 } END { print total + 0 }' "$run_counts")
expected_summary="TypeLisp test batch passed: $test_count test(s) in $discovered_file_count file(s)"
if ! grep -qF "$expected_summary" "$batch_run_stdout"; then
    echo "inline test execution batch did not report the expected aggregate" >&2
    show_streams "$batch_run_stdout" "$batch_run_stderr"
    exit 1
fi

echo "inline test verification passed for $test_count test(s) in $discovered_file_count file(s)"
