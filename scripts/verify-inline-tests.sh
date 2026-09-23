#!/usr/bin/env sh
set -eu

# verify-inline-tests.sh - auto-discover and run inline TypeLisp tests.
# refs #947

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-ci-timing.sh"
. "$ROOT/scripts/lib-linux-memory-limit.sh"
BOUNDED_POOL_LABEL=inline-tests
. "$ROOT/scripts/lib-bounded-pool.sh"

usage() {
    cat <<'EOF'
usage: scripts/verify-inline-tests.sh [--self-test-chunks]

--self-test-chunks runs only the chunk accounting self-test: fabricated chunk
results that must pass, and mutations of them that must fail. Every ordinary
run performs it first.
EOF
}

SELF_TEST_ONLY=0
case "${1:-}" in
    "") ;;
    --self-test-chunks) SELF_TEST_ONLY=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

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

# The discovered sources run as contiguous chunks in a bounded pool
# (scripts/lib-bounded-pool.sh): TYPELISP_INLINE_TEST_WORKERS `typelisp test
# --batch` processes at once (1-3, default 2), each under an enforced memory cap
# and timeout (a user cgroup on Linux, a Job Object on Windows). A batch shares
# nothing between its sources, because #4820 resets the driver for each one, so
# a chunk costs only its own process start. Contiguous chunks concatenate back
# into the discovered order, so the checks below read one combined stream
# exactly as they read the single batch before (#7995).
INLINE_TEST_WORKERS=${TYPELISP_INLINE_TEST_WORKERS:-2}
case "$INLINE_TEST_WORKERS" in
    1 | 2 | 3) ;;
    *)
        echo "invalid TYPELISP_INLINE_TEST_WORKERS: $INLINE_TEST_WORKERS (expected 1-3)" >&2
        exit 2
        ;;
esac
INLINE_TEST_CHUNK_FILES=12
INLINE_TEST_CHUNK_CAP_MIB=6144
INLINE_TEST_POOL_BUDGET_MIB=$((INLINE_TEST_WORKERS * INLINE_TEST_CHUNK_CAP_MIB))
INLINE_TEST_JOB_TIMEOUT_SECONDS=1800
INLINE_TEST_PEAK_BYTES=0
INLINE_TEST_PEAK_JOB=

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

# Write `<dir>/chunk-NNN.list` files of at most INLINE_TEST_CHUNK_FILES
# consecutive sources and the pool queue (`chunk-NNN|<cap MiB>`) naming them in
# order.
inline_test_plan_chunks() {
    _plan_sources=$1
    _plan_dir=$2
    _plan_queue=$3
    : > "$_plan_queue"
    awk -v size="$INLINE_TEST_CHUNK_FILES" -v dir="$_plan_dir" \
        -v cap="$INLINE_TEST_CHUNK_CAP_MIB" -v queue="$_plan_queue" '
        {
            job = sprintf("chunk-%03d", int((NR - 1) / size) + 1)
            if (job != last) {
                if (last != "") close(dir "/" last ".list")
                print job "|" cap >> queue
                last = job
            }
            print > (dir "/" job ".list")
        }
    ' "$_plan_sources"
}

# Account for one finished chunk, in queue order, and append its streams to the
# combined output. A chunk that left no status, was stopped by its cap or
# timeout, failed, or whose own aggregate does not match its list fails the gate.
inline_test_settle_chunk() {
    _settle_job=$1
    _settle_dir=$2
    _settle_combined_stdout=$3
    _settle_combined_stderr=$4
    _settle_list="$_settle_dir/$_settle_job.list"
    _settle_stdout="$_settle_dir/$_settle_job.stdout"
    _settle_stderr="$_settle_dir/$_settle_job.stderr"
    _settle_status="$_settle_dir/$_settle_job.status"
    _settle_report="$_settle_dir/$_settle_job.memory"
    if [ ! -s "$_settle_status" ] || [ ! -s "$_settle_list" ]; then
        echo "inline test $_settle_job left no status" >&2
        exit 1
    fi
    _settle_reason=$(sed -n 's/^reason=//p' "$_settle_report" 2>/dev/null || true)
    case "$_settle_reason" in
        success | command-failure) ;;
        *)
            echo "inline test $_settle_job was stopped by its bound" \
                "(reason=${_settle_reason:-missing-report}," \
                "cap $INLINE_TEST_CHUNK_CAP_MIB MiB," \
                "timeout $INLINE_TEST_JOB_TIMEOUT_SECONDS s)" >&2
            show_streams "$_settle_stdout" "$_settle_stderr"
            exit 1
            ;;
    esac
    _settle_peak=$(sed -n 's/^peak_memory_bytes=//p' "$_settle_report")
    case "$_settle_peak" in
        '' | *[!0-9]*)
            echo "inline test $_settle_job memory report has no peak" >&2
            exit 1
            ;;
    esac
    if [ "$_settle_peak" -gt "$INLINE_TEST_PEAK_BYTES" ]; then
        INLINE_TEST_PEAK_BYTES=$_settle_peak
        INLINE_TEST_PEAK_JOB=$_settle_job
    fi
    if [ "$(cat "$_settle_status")" != 0 ]; then
        echo "inline test batch execution failed in $_settle_job" >&2
        show_streams "$_settle_stdout" "$_settle_stderr"
        exit 1
    fi
    _settle_files=$(wc -l < "$_settle_list" | tr -d ' ')
    _settle_tests=$(sed -n 's/^TypeLisp test file: .* (\([0-9][0-9]*\) test(s))$/\1/p' \
        "$_settle_stdout" | tr -d '\r' | awk '{ total += $1 } END { print total + 0 }')
    if ! grep -qF \
        "TypeLisp test batch passed: $_settle_tests test(s) in $_settle_files file(s)" \
        "$_settle_stdout"; then
        echo "inline test $_settle_job did not report the expected aggregate" \
            "($_settle_tests test(s) in $_settle_files file(s))" >&2
        show_streams "$_settle_stdout" "$_settle_stderr"
        exit 1
    fi
    cat "$_settle_stdout" >> "$_settle_combined_stdout"
    cat "$_settle_stderr" >> "$_settle_combined_stderr"
}

# The checks the single batch always had, over the combined chunk streams: one
# count line and one success summary per discovered source, the discovered order
# exactly, and no source that ran zero tests. The order check is also the
# partition proof: every discovered source ran in exactly one chunk.
inline_test_check_combined() {
    _check_discovered=$1
    _check_stdout=$2
    _check_stderr=$3
    _check_counts=$4
    _check_paths=$5
    _check_files=$(wc -l < "$_check_discovered" | tr -d ' ')
    sed -n 's/^TypeLisp test file: .* (\([0-9][0-9]*\) test(s))$/\1/p' "$_check_stdout" \
        | tr -d '\r' > "$_check_counts"
    sed -n 's/^TypeLisp test file: \(.*\) ([0-9][0-9]* test(s))$/\1/p' "$_check_stdout" \
        | tr -d '\r' > "$_check_paths"
    _check_count_lines=$(wc -l < "$_check_counts" | tr -d ' ')
    if [ "$_check_count_lines" -ne "$_check_files" ]; then
        echo "inline test execution reported $_check_count_lines count line(s), expected $_check_files" >&2
        show_streams "$_check_stdout" "$_check_stderr"
        exit 1
    fi
    if ! cmp -s "$_check_discovered" "$_check_paths"; then
        echo "inline test execution did not preserve discovered source order" >&2
        show_streams "$_check_stdout" "$_check_stderr"
        exit 1
    fi
    if grep -q '^0$' "$_check_counts"; then
        echo "inline test execution reported zero tests for a discovered source" >&2
        show_streams "$_check_stdout" "$_check_stderr"
        exit 1
    fi
    _check_success=$(grep -c '^TypeLisp tests: .* passed; 0 failed; .* ignored; .* slow-skipped; .* total$' "$_check_stderr" || true)
    if [ "$_check_success" -ne "$_check_files" ]; then
        echo "inline test execution reported $_check_success success summary line(s), expected $_check_files" >&2
        show_streams "$_check_stdout" "$_check_stderr"
        exit 1
    fi
}

# Fabricated chunk results for the accounting above: a well-formed set must
# pass, and each single mutation of it must fail.
inline_test_self_test_fixture() {
    _fixture_dir=$1
    rm -rf "$_fixture_dir"
    mkdir -p "$_fixture_dir"
    printf '%s\n' a.tl b.tl c.tl > "$_fixture_dir/discovered.txt"
    _fixture_saved_size=$INLINE_TEST_CHUNK_FILES
    INLINE_TEST_CHUNK_FILES=2
    inline_test_plan_chunks "$_fixture_dir/discovered.txt" "$_fixture_dir" "$_fixture_dir/queue"
    INLINE_TEST_CHUNK_FILES=$_fixture_saved_size
    for _fixture_job in chunk-001 chunk-002; do
        : > "$_fixture_dir/$_fixture_job.stdout"
        : > "$_fixture_dir/$_fixture_job.stderr"
        _fixture_tests=0
        _fixture_files=0
        while IFS= read -r _fixture_source; do
            printf 'TypeLisp test file: %s (2 test(s))\n' "$_fixture_source" \
                >> "$_fixture_dir/$_fixture_job.stdout"
            printf 'TypeLisp tests: 2 passed; 0 failed; 0 ignored; 0 slow-skipped; 2 total\n' \
                >> "$_fixture_dir/$_fixture_job.stderr"
            _fixture_tests=$((_fixture_tests + 2))
            _fixture_files=$((_fixture_files + 1))
        done < "$_fixture_dir/$_fixture_job.list"
        printf 'TypeLisp test batch passed: %s test(s) in %s file(s)\n' \
            "$_fixture_tests" "$_fixture_files" >> "$_fixture_dir/$_fixture_job.stdout"
        printf '0\n' > "$_fixture_dir/$_fixture_job.status"
        printf 'reason=success\npeak_memory_bytes=1048576\n' > "$_fixture_dir/$_fixture_job.memory"
    done
}

inline_test_self_test_settle_all() {
    _all_dir=$1
    : > "$_all_dir/combined.stdout"
    : > "$_all_dir/combined.stderr"
    while IFS='|' read -r _all_job _all_cap; do
        inline_test_settle_chunk "$_all_job" "$_all_dir" \
            "$_all_dir/combined.stdout" "$_all_dir/combined.stderr"
    done < "$_all_dir/queue"
    inline_test_check_combined "$_all_dir/discovered.txt" \
        "$_all_dir/combined.stdout" "$_all_dir/combined.stderr" \
        "$_all_dir/counts" "$_all_dir/paths"
}

inline_test_self_test_expect_failure() {
    _expect_name=$1
    _expect_dir=$2
    if ( inline_test_self_test_settle_all "$_expect_dir" ) > "$_expect_dir/out" 2>&1; then
        echo "inline test chunk self-test: $_expect_name was accepted" >&2
        exit 1
    fi
}

inline_test_self_test_chunks() {
    _self_dir="$ROOT/target/inline-test-verify-self-test"
    inline_test_self_test_fixture "$_self_dir"
    printf 'chunk-001|%s\nchunk-002|%s\n' "$INLINE_TEST_CHUNK_CAP_MIB" \
        "$INLINE_TEST_CHUNK_CAP_MIB" > "$_self_dir/expected-queue"
    if ! cmp -s "$_self_dir/queue" "$_self_dir/expected-queue" ||
        [ "$(cat "$_self_dir/chunk-001.list" "$_self_dir/chunk-002.list")" != "$(cat "$_self_dir/discovered.txt")" ]; then
        echo "inline test chunk self-test: the plan does not partition the sources in order" >&2
        exit 1
    fi
    if ! ( inline_test_self_test_settle_all "$_self_dir" ) > "$_self_dir/out" 2>&1; then
        echo "inline test chunk self-test: well-formed chunks were rejected" >&2
        sed 's/^/  /' "$_self_dir/out" >&2
        exit 1
    fi

    inline_test_self_test_fixture "$_self_dir"
    rm "$_self_dir/chunk-002.status"
    inline_test_self_test_expect_failure "a chunk without a status" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    printf '1\n' > "$_self_dir/chunk-001.status"
    inline_test_self_test_expect_failure "a failed chunk" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    printf 'reason=memory-limit\npeak_memory_bytes=1048576\n' > "$_self_dir/chunk-002.memory"
    inline_test_self_test_expect_failure "a chunk stopped by its cap" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    rm "$_self_dir/chunk-001.memory"
    inline_test_self_test_expect_failure "a chunk without a memory report" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    sed -i.bak 's/in 2 file(s)/in 1 file(s)/' "$_self_dir/chunk-001.stdout"
    inline_test_self_test_expect_failure "a chunk aggregate that disagrees with its list" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    printf 'z.tl\n' > "$_self_dir/chunk-002.list"
    sed -i.bak 's/c\.tl/z.tl/' "$_self_dir/chunk-002.stdout"
    inline_test_self_test_expect_failure "a chunk that ran a source outside the discovered list" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    printf 'chunk-002|%s\nchunk-001|%s\n' "$INLINE_TEST_CHUNK_CAP_MIB" \
        "$INLINE_TEST_CHUNK_CAP_MIB" > "$_self_dir/queue"
    inline_test_self_test_expect_failure "chunks settled out of order" "$_self_dir"

    inline_test_self_test_fixture "$_self_dir"
    sed -i.bak 's/ 0 failed;/ 1 failed;/' "$_self_dir/chunk-002.stderr"
    inline_test_self_test_expect_failure "a source whose tests did not all pass" "$_self_dir"

    rm -rf "$_self_dir"
    echo "[inline-tests] chunk accounting self-test passed"
}

inline_test_self_test_chunks
[ "$SELF_TEST_ONLY" -eq 0 ] || exit 0

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

# #5122: fixed-array `(init)` once expanded the profile-summary tables into
# thousands of initializer AST nodes and made this single inline test peak above
# 5 GiB. Keep a focused Linux hard-cap probe ahead of the aggregate batch so the
# regression fails deterministically without asking an uncapped runner to OOM.
#
# RLIMIT_AS is unsuitable here: the runtime reserves large virtual mappings,
# so `ulimit -v` can fail while RSS remains below 200 MiB. Prefer a cgroup-v2
# MemoryMax over the complete process tree. On Linux hosts without a usable
# user systemd manager, the helper falls back to a process-group aggregate-RSS
# watchdog with the same 1 GiB threshold.
if [ "$HOST_OS" = linux ]; then
    profile_summary_stdout="$WORKDIR/profile-summary.stdout"
    profile_summary_stderr="$WORKDIR/profile-summary.stderr"
    profile_summary_limit_bytes=1073741824
    linux_memory_limit_select_backend
    echo "[inline-tests] profile-summary memory cap (1 GiB resident/cgroup memory; $LINUX_MEMORY_LIMIT_BACKEND)"
    if linux_memory_limit_run "$profile_summary_limit_bytes" \
        "$COMPILER" test "$ROOT/src/compiler_profile_summary.tl" \
            --target "$HOST_TARGET" --stdlib-root "$ROOT/stdlib" \
            > "$profile_summary_stdout" 2> "$profile_summary_stderr"; then
        profile_summary_status=0
    else
        profile_summary_status=$?
    fi
    if [ "$profile_summary_status" -ne 0 ]; then
        echo "compiler_profile_summary inline test exceeded 1 GiB of resident/cgroup memory or failed" >&2
        show_streams "$profile_summary_stdout" "$profile_summary_stderr"
        exit 1
    fi
fi

run_stdout="$WORKDIR/run.batch.stdout"
run_stderr="$WORKDIR/run.batch.stderr"
run_counts="$WORKDIR/run.counts.txt"
run_paths="$WORKDIR/run.paths.txt"
INLINE_TEST_QUEUE="$WORKDIR/queue"
INLINE_TEST_POOL_DIR="$WORKDIR/pool"

# The pool's job callback (see lib-bounded-pool.sh). A job is one chunk; its
# list is `$WORKDIR/<job>.list`. The job records the batch's status rather than
# failing, so the parent reports the first failing chunk, in queue order, with
# its streams. Its timing rows go to a private file merged in queue order below.
bounded_pool_run_job() {
    _pool_job=$1
    _pool_cap=$2
    if ci_timing_enabled; then
        TYPELISP_CI_TIMING_FILE="$INLINE_TEST_POOL_DIR/timing/$_pool_job.tsv"
    fi
    _pool_rc=0
    ci_timing_run "$_pool_job" batch-run \
        "$ROOT/scripts/run-memory-bounded.sh" \
        --limit-mib "$_pool_cap" --report "$WORKDIR/$_pool_job.memory" \
        --timeout-seconds "$INLINE_TEST_JOB_TIMEOUT_SECONDS" -- \
        "$COMPILER" test --batch "$WORKDIR/$_pool_job.list" --target "$HOST_TARGET" \
        --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" \
        > "$WORKDIR/$_pool_job.stdout" 2> "$WORKDIR/$_pool_job.stderr" ||
        _pool_rc=$?
    printf '%s\n' "$_pool_rc" > "$WORKDIR/$_pool_job.status"
}

# Publish the jobs' private timing rows in queue order. A passing pool requires
# a row from every job; a failing one still publishes what ran.
inline_test_merge_pool_timing() {
    ci_timing_enabled || return 0
    while IFS='|' read -r _merge_job _merge_cap; do
        _merge_rows="$INLINE_TEST_POOL_DIR/timing/$_merge_job.tsv"
        if [ -s "$_merge_rows" ]; then
            cat "$_merge_rows" >> "$TYPELISP_CI_TIMING_FILE"
        elif [ "$1" = required ]; then
            echo "inline test pool job published no timing row: $_merge_job" >&2
            exit 1
        fi
    done < "$INLINE_TEST_QUEUE"
}

inline_test_plan_chunks "$DISCOVERED" "$WORKDIR" "$INLINE_TEST_QUEUE"
chunk_count=$(wc -l < "$INLINE_TEST_QUEUE" | tr -d ' ')
bounded_pool_init "$INLINE_TEST_POOL_DIR" "$INLINE_TEST_POOL_BUDGET_MIB" \
    "$INLINE_TEST_QUEUE" || exit 1
mkdir -p "$INLINE_TEST_POOL_DIR/timing"

echo "[inline-tests] run ($discovered_file_count file(s) in $chunk_count chunk(s)" \
    "of up to $INLINE_TEST_CHUNK_FILES, $INLINE_TEST_WORKERS worker(s)," \
    "$INLINE_TEST_POOL_BUDGET_MIB MiB of enforced caps at once)"
# #4820: execution batches keep every source inside its own destroyable scratch
# arena with a full driver reset, preserving the old one-process-per-file
# semantics without paying process/bootstrap overhead for every source.
ci_timing_set_now_ms
pool_started=$CI_TIMING_NOW_MS
bounded_pool_start "$INLINE_TEST_POOL_DIR" "$INLINE_TEST_WORKERS"
if ! bounded_pool_join "$INLINE_TEST_POOL_DIR"; then
    inline_test_merge_pool_timing available
    echo "inline test chunk pool did not complete every chunk" >&2
    exit 1
fi
ci_timing_set_now_ms
pool_wall_ms=$((CI_TIMING_NOW_MS - pool_started))
inline_test_merge_pool_timing required

: > "$run_stdout"
: > "$run_stderr"
while IFS='|' read -r settle_job settle_cap; do
    inline_test_settle_chunk "$settle_job" "$WORKDIR" "$run_stdout" "$run_stderr"
done < "$INLINE_TEST_QUEUE"
inline_test_check_combined "$DISCOVERED" "$run_stdout" "$run_stderr" \
    "$run_counts" "$run_paths"

test_count=$(awk '{ total += $1 } END { print total + 0 }' "$run_counts")
echo "[inline-tests] $chunk_count chunk(s) in $pool_wall_ms ms;" \
    "peak $((INLINE_TEST_PEAK_BYTES / 1048576)) MiB ($INLINE_TEST_PEAK_JOB)" \
    "of a $INLINE_TEST_CHUNK_CAP_MIB MiB cap"
echo "inline test verification passed for $test_count test(s) in $discovered_file_count file(s)"
