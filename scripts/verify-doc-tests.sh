#!/usr/bin/env sh
set -eu

# verify-doc-tests.sh - auto-discover documented TypeLisp sources and run one
# batched `typelisp doc --test --batch` process with the built compiler from
# TYPELISP_BIN.
# In CI, TYPELISP_BIN is the command-tier compiler selected by the
# caller. Seed fallback is only a compatibility path for older artifacts and
# cannot verify future stdlib borrowed-`str` doctests.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Each `typelisp` invocation runs exactly once: a crash is a real compiler bug,
# not a flake — do not retry it (see the no-retry policy in scripts/ci-verify.sh).

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "doc test verification is unsupported on this host" >&2
        exit 1
        ;;
esac

. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_require_compiler
BOUNDED_POOL_LABEL=doc-tests
. "$ROOT/scripts/lib-bounded-pool.sh"

DOC_TEST_WORKERS=${TYPELISP_DOC_TEST_WORKERS:-4}
case "$DOC_TEST_WORKERS" in
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8) ;;
    *)
        echo "invalid TYPELISP_DOC_TEST_WORKERS: $DOC_TEST_WORKERS (expected 1-8)" >&2
        exit 2
        ;;
esac

WORKDIR="$ROOT/target/doc-test-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

CANDIDATES="$WORKDIR/candidates.txt"
DISCOVERED="$WORKDIR/discovered.txt"
: > "$CANDIDATES"
: > "$DISCOVERED"

# `docs` carries the getting-started guide, whose whole value is that every
# example in it compiles; leaving it out of this sweep would let it rot.
for root in stdlib src examples tests docs; do
    if [ -d "$root" ]; then
        find "$root" \
            -type f \
            -name '*.tl' \
            ! -path '*/target/*' \
            ! -path '*/.typelisp-doctest/*'
    fi
done | sort > "$CANDIDATES"

safe_name() {
    printf '%s' "$1" | sed 's#[/\\:]#_#g'
}

runnable_count=$(awk -v discovered="$DISCOVERED" '
    {
        path = $0
        if (path == "") next
        has_doc = 0
        has_run = 0
        while ((rc = (getline line < path)) > 0) {
            if (!has_doc && line ~ /^[[:space:]]*(;#|;:)|```[[:space:]]*(typelisp|tl)([[:space:]]|$)/) {
                has_doc = 1
            }
            if (!has_run && line ~ /```[[:space:]]*(typelisp|tl)[[:space:]]+run([[:space:]]|$)/) {
                has_run = 1
                has_doc = 1
                break
            }
        }
        close(path)
        if (rc < 0) exit 1
        if (has_doc) print path >> discovered
        if (has_run) runnable++
    }
    END { print runnable + 0 }
' "$CANDIDATES")

if [ ! -s "$DISCOVERED" ]; then
    echo "doc test verification found no documented TypeLisp files" >&2
    exit 1
fi
if [ "$runnable_count" -eq 0 ]; then
    echo "doc test verification found no runnable doctest files" >&2
    exit 1
fi

run_doc_tests_per_file() {
    _probe_list=$1
    _probe_count=0
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        _probe_count=$((_probe_count + 1))
        case_name=$(safe_name "$source")
        stdout="$WORKDIR/$case_name.stdout"
        stderr="$WORKDIR/$case_name.stderr"

        echo "[doc-tests] $source"
        if ! "$COMPILER" doc --test "$source" --stdlib-root "$ROOT/stdlib" \
            > "$stdout" 2> "$stderr"; then
            echo "doc test verification failed for $source" >&2
            echo "stdout:" >&2
            sed 's/^/  /' "$stdout" >&2 || true
            echo "stderr:" >&2
            sed 's/^/  /' "$stderr" >&2 || true
            exit 1
        fi

        if ! grep -q '^Doc tests passed:' "$stdout"; then
            echo "doc test verification failed for $source: missing success summary" >&2
            echo "stdout:" >&2
            sed 's/^/  /' "$stdout" >&2 || true
            echo "stderr:" >&2
            sed 's/^/  /' "$stderr" >&2 || true
            exit 1
        fi
    done < "$_probe_list"
}

count=$(wc -l < "$DISCOVERED" | tr -d ' ')
CHUNK_COUNT=$DOC_TEST_WORKERS
if [ "$CHUNK_COUNT" -gt "$count" ]; then
    CHUNK_COUNT=$count
fi

CHUNK_DIR="$WORKDIR/chunks"
POOL_DIR="$WORKDIR/pool"
POOL_QUEUE="$WORKDIR/pool.queue"
mkdir -p "$CHUNK_DIR"
: > "$POOL_QUEUE"

# Distribute discovered files round-robin across chunks so heavy directories
# (docs, src, stdlib, tests) and runnable doctests balance evenly.
awk -v outdir="$CHUNK_DIR" -v nchunks="$CHUNK_COUNT" '
    {
        idx = ((NR - 1) % nchunks) + 1
        path = sprintf("%s/chunk-%02d.list", outdir, idx)
        print $0 >> path
    }
' "$DISCOVERED"

chunk_idx=0
assigned_total=0
while [ "$chunk_idx" -lt "$CHUNK_COUNT" ]; do
    chunk_idx=$((chunk_idx + 1))
    chunk_id=$(printf 'chunk-%02d' "$chunk_idx")
    chunk_list="$CHUNK_DIR/$chunk_id.list"
    [ -s "$chunk_list" ] || {
        echo "doc test verification chunk $chunk_id is missing or empty" >&2
        exit 1
    }
    chunk_files=$(wc -l < "$chunk_list" | tr -d ' ')
    assigned_total=$((assigned_total + chunk_files))
    printf '%s|1\n' "$chunk_id" >> "$POOL_QUEUE"
done
if [ "$assigned_total" -ne "$count" ]; then
    echo "doc test verification chunk partition mismatch: $assigned_total vs $count" >&2
    exit 1
fi

bounded_pool_run_job() {
    _job=$1
    _chunk_list="$CHUNK_DIR/$_job.list"
    _chunk_out="$CHUNK_DIR/$_job.stdout"
    _chunk_err="$CHUNK_DIR/$_job.stderr"
    _chunk_status="$CHUNK_DIR/$_job.status"
    _rc=0
    "$COMPILER" doc --test --batch "$_chunk_list" --stdlib-root "$ROOT/stdlib" \
        > "$_chunk_out" 2> "$_chunk_err" || _rc=$?
    printf '%s\n' "$_rc" > "$_chunk_status"
    # Return 0 so every chunk completes and parent reports/probes in deterministic order.
    return 0
}

echo "[doc-tests] batch $count file(s) across $CHUNK_COUNT chunk(s) with $DOC_TEST_WORKERS worker(s)"
bounded_pool_init "$POOL_DIR" "$DOC_TEST_WORKERS" "$POOL_QUEUE" || exit 1
bounded_pool_start "$POOL_DIR" "$DOC_TEST_WORKERS"
bounded_pool_join "$POOL_DIR" || exit 1

total_summaries=0
total_examples=0
chunk_idx=0
while [ "$chunk_idx" -lt "$CHUNK_COUNT" ]; do
    chunk_idx=$((chunk_idx + 1))
    chunk_id=$(printf 'chunk-%02d' "$chunk_idx")
    chunk_list="$CHUNK_DIR/$chunk_id.list"
    chunk_out="$CHUNK_DIR/$chunk_id.stdout"
    chunk_err="$CHUNK_DIR/$chunk_id.stderr"
    chunk_status_file="$CHUNK_DIR/$chunk_id.status"
    chunk_files=$(wc -l < "$chunk_list" | tr -d ' ')

    if [ ! -f "$chunk_status_file" ]; then
        echo "doc test verification failed: chunk $chunk_id left no exit status" >&2
        exit 1
    fi
    read -r chunk_rc < "$chunk_status_file"
    if [ "$chunk_rc" -ne 0 ]; then
        echo "[doc-tests] batched $chunk_id failed (exit $chunk_rc); probing its $chunk_files file(s) one by one" >&2
        run_doc_tests_per_file "$chunk_list"
        # The probe exits on the first file that fails alone. Reaching here means
        # every file passes alone, so the failure is batch-only, such as state one
        # file's examples leave behind for the next (#8580). The probe only locates
        # failures; it must not turn a batch failure into a pass.
        echo "doc test verification failed: batched $chunk_id failed, but every file passes on its own (a batch-only failure)" >&2
        echo "batched stdout:" >&2
        sed 's/^/  /' "$chunk_out" >&2 || true
        echo "batched stderr:" >&2
        sed 's/^/  /' "$chunk_err" >&2 || true
        exit 1
    fi

    chunk_counts=$(awk '
        /^Doc tests passed: [0-9]+ example\(s\)$/ {
            summaries++
            examples += $4 + 0
        }
        END { printf "%d %d\n", summaries + 0, examples + 0 }
    ' "$chunk_out")
    chunk_summaries=${chunk_counts%% *}
    chunk_examples=${chunk_counts##* }
    if [ "$chunk_summaries" -ne "$chunk_files" ]; then
        echo "doc test verification failed for batched $chunk_id: expected $chunk_files success summaries, saw $chunk_summaries" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$chunk_out" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$chunk_err" >&2 || true
        exit 1
    fi
    total_summaries=$((total_summaries + chunk_summaries))
    total_examples=$((total_examples + chunk_examples))
done

if [ "$total_summaries" -ne "$count" ]; then
    echo "doc test verification failed: expected $count total success summaries, saw $total_summaries" >&2
    exit 1
fi

echo "doc test verification passed for $count file(s) ($total_examples example(s)), including $runnable_count runnable doctest file(s)"
