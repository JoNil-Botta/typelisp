#!/usr/bin/env sh
set -eu

# verify-selfhost-compile-manifest.sh - selfhost assembly compile manifest.
#
# The manifest lists TypeLisp sources whose generated assembly used to be
# checked by Rust *_compile.rs harnesses. This runner compiles each entry with an
# already-built TypeLisp compiler, then checks the generated assembly for the
# expected main-label policy and text markers.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-ci-timing.sh"
. "$ROOT/scripts/lib-bounded-pool.sh"
BOUNDED_POOL_LABEL=selfhost-compile

# --self-test-pool runs only the chunk pool self-test (a fake compiler, no
# manifest); every ordinary run also runs it before compiling the manifest.
SELF_TEST_POOL=0
case "${1:-}" in
    "") ;;
    --self-test-pool)
        SELF_TEST_POOL=1
        shift
        ;;
    *)
        echo "usage: scripts/verify-selfhost-compile-manifest.sh [--self-test-pool]" >&2
        exit 2
        ;;
esac
if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-selfhost-compile-manifest.sh [--self-test-pool]" >&2
    exit 2
fi

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *) ;;
esac

MANIFEST=${TYPELISP_COMPILE_MANIFEST:-src/compile_manifest.txt}
WORKDIR=${TYPELISP_COMPILE_MANIFEST_WORKDIR:-target/selfhost-compile-manifest}
EXPECTATION_MODE=${TYPELISP_COMPILE_MANIFEST_EXPECTATION_MODE:-stage0}
# #2357: the batch driver scopes each entry's compile in its own arena region
# (compile-cli-run-batch-entries), so a chunk's peak memory is the heaviest
# single compile (~2.8GB for the whole-compiler drivers), not the sum of all
# entries. Without that scoping a 16-case chunk accumulated 9.7GB and
# SIGSEGV'd the Windows CI runner (freestanding runtime: a failed memory
# commit surfaces as an access violation, exit 139). Linux keeps the 16-case
# stress chunk; Windows CI runners have tighter commit headroom, so split the
# same manifest coverage into smaller default chunks unless explicitly
# overridden. As the compiler grows, two heavy entries in one Windows batch can
# trip the freestanding allocator after the first compile has emitted assembly,
# so keep the default at one manifest entry per process on Windows. Linux keeps
# the 16-entry stress size: allocation-owner snapshots and absolute batch live
# baselines make cross-entry retention diagnosable and enforce that repeated
# entries return to a bounded steady state.
if [ -n "${TYPELISP_COMPILE_MANIFEST_BATCH_SIZE:-}" ]; then
    BATCH_CHUNK_SIZE=$TYPELISP_COMPILE_MANIFEST_BATCH_SIZE
elif [ "$HOST_OS" = windows ]; then
    BATCH_CHUNK_SIZE=1
else
    BATCH_CHUNK_SIZE=16
fi

case "$EXPECTATION_MODE" in
    stage0 | stage1) ;;
    *)
        echo "unknown compile manifest expectation mode: $EXPECTATION_MODE" >&2
        exit 1
        ;;
esac

case "$BATCH_CHUNK_SIZE" in
    "" | *[!0-9]*)
        echo "invalid compile manifest batch size: $BATCH_CHUNK_SIZE" >&2
        exit 1
        ;;
esac
if [ "$BATCH_CHUNK_SIZE" -lt 1 ]; then
    echo "invalid compile manifest batch size: $BATCH_CHUNK_SIZE" >&2
    exit 1
fi

# Chunks compile in a bounded pool (scripts/lib-bounded-pool.sh):
# TYPELISP_COMPILE_MANIFEST_WORKERS compiler processes at once (1-3, default
# 2), each under an enforced memory cap and timeout (a user cgroup on Linux, a
# Job Object on Windows), so at most workers x cap MiB of caps run
# concurrently. A chunk's peak is its heaviest entry's (see above): main.tl,
# the largest, peaked at 1,753 MiB on Linux (#7998), so the cap leaves over 2x
# headroom while two capped chunks stay within half of a 16 GB hosted runner.
MANIFEST_POOL_WORKERS=${TYPELISP_COMPILE_MANIFEST_WORKERS:-2}
case "$MANIFEST_POOL_WORKERS" in
    1 | 2 | 3) ;;
    *)
        echo "invalid TYPELISP_COMPILE_MANIFEST_WORKERS: $MANIFEST_POOL_WORKERS (expected 1-3)" >&2
        exit 2
        ;;
esac
MANIFEST_POOL_CHUNK_CAP_MIB=4096
MANIFEST_POOL_JOB_TIMEOUT_SECONDS=900
# Internal: only the pool self-test turns enforcement off, on Windows, where
# the Job Object wrapper cannot launch its shell-script compiler.
MANIFEST_POOL_ENFORCE_CAPS=1
MANIFEST_POOL_DIR=
MANIFEST_POOL_PEAK_BYTES=0
MANIFEST_POOL_PEAK_LABEL=

MANIFEST_INPUT="$WORKDIR/compile-manifest.normalized.txt"
BATCH_INPUT="$WORKDIR/compile-batch.txt"
BATCH_CHUNK_DIR="$WORKDIR/compile-batch-chunks"
COMPILER=
if [ "$SELF_TEST_POOL" -eq 0 ]; then
    if [ -n "${TYPELISP_BIN:-}" ]; then
        COMPILER=$TYPELISP_BIN
    else
        # Local-development fallback: fetch the published
        # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
        . "$ROOT/scripts/lib-stage0.sh"
        COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    fi

    if [ ! -f "$COMPILER" ]; then
        echo "typelisp compiler does not exist: $COMPILER" >&2
        exit 1
    fi

    if [ ! -f "$MANIFEST" ]; then
        echo "compile manifest does not exist: $MANIFEST" >&2
        exit 1
    fi

    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    tr -d '\r' < "$MANIFEST" > "$MANIFEST_INPUT"
fi

check_selfhost_manifest_sync() {
    expected="$WORKDIR/expected-selfhost-sources.txt"
    actual="$WORKDIR/actual-selfhost-sources.txt"

    awk -F'|' '
        $1 == "case" && $3 ~ /^src\/[^/]+\.tl$/ { print $3 }
        $1 == "decision" && $2 ~ /^src\/[^/]+\.tl$/ { print $2 }
    ' "$MANIFEST_INPUT" | sort -u > "$expected"

    find src -maxdepth 1 -type f -name '*.tl' | sort > "$actual"

    if ! cmp -s "$expected" "$actual"; then
        echo "selfhost compile manifest is out of date" >&2
        echo "expected manifest decisions:" >&2
        sed 's/^/  /' "$expected" >&2
        echo "actual top-level selfhost sources:" >&2
        sed 's/^/  /' "$actual" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$expected" "$actual" >&2 || true
        fi
        exit 1
    fi
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_with_heartbeat_capture() {
    heartbeat_label=$1
    heartbeat_stdout=$2
    heartbeat_stderr=$3
    shift 3

    "$@" > "$heartbeat_stdout" 2> "$heartbeat_stderr" &
    heartbeat_cmd_pid=$!
    (
        while kill -0 "$heartbeat_cmd_pid" 2>/dev/null; do
            sleep "${TYPELISP_COMPILE_MANIFEST_HEARTBEAT_SECONDS:-30}"
            if kill -0 "$heartbeat_cmd_pid" 2>/dev/null; then
                echo "[selfhost-compile] ${heartbeat_label} still running"
            fi
        done
    ) &
    heartbeat_pid=$!

    heartbeat_status=0
    wait "$heartbeat_cmd_pid" || heartbeat_status=$?
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
    return "$heartbeat_status"
}

compiler_batch_path() {
    path=$1
    if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
    else
        printf '%s\n' "$path"
    fi
}

contains_text() {
    needle=$1
    [ "$compiled" -eq 2 ] && return
    if ! grep -F -- "$needle" "$asm_path" >/dev/null; then
        if expectation_contains_text "$needle"; then
            return
        fi
        fail "$case_id assembly is missing expected text [$needle] in $EXPECTATION_MODE mode (assembly: $asm_path)"
    fi
}

not_contains_text() {
    needle=$1
    [ "$compiled" -eq 2 ] && return
    if grep -F -- "$needle" "$asm_path" >/dev/null; then
        fail "$case_id assembly contains forbidden text [$needle] in $EXPECTATION_MODE mode (assembly: $asm_path)"
    fi
    if expectation_contains_text "$needle"; then
        fail "$case_id assembly contains forbidden qualified text for [$needle] in $EXPECTATION_MODE mode (assembly: $asm_path)"
    fi
}

count_at_least() {
    needle=$1
    min=$2
    [ "$compiled" -eq 2 ] && return
    count=$(grep -F -- "$needle" "$asm_path" | wc -l | tr -d ' ')
    if [ "$count" -lt "$min" ]; then
        count=$(expectation_count_text "$needle")
    fi
    if [ "$count" -lt "$min" ]; then
        fail "$case_id assembly has $count occurrence(s) of [$needle] in $EXPECTATION_MODE mode, expected at least $min (assembly: $asm_path)"
    fi
}

expectation_symbol_regex() {
    needle=$1
    case "$needle" in
        match_nested)
            printf '_match_\n'
            return 0
            ;;
        .L_tl_*:)
            symbol=${needle#.L_tl_}
            symbol=${symbol%:}
            printf '(_tl__u2eL_tl_%s|_tl_%s|\\.L_tl_%s)\n' "$symbol" "$symbol" "$symbol"
            return 0
            ;;
        .L_tl_*)
            symbol=${needle#.L_tl_}
            printf '(_tl__u2eL_tl_%s|_tl_%s|\\.L_tl_%s)\n' "$symbol" "$symbol" "$symbol"
            return 0
            ;;
        _tl_*:)
            symbol=${needle#_tl_}
            symbol=${symbol%:}
            printf '^(_tl_([[:alnum:]_]+_u2etl_colon_colon|[[:alnum:]_]+_)?|tl_)%s:$\n' "$symbol"
            return 0
            ;;
        _tl_*)
            symbol=${needle#_tl_}
            printf '(_tl_([[:alnum:]_]+_u2etl_colon_colon|[[:alnum:]_]+_)?|tl_)%s([^[:alnum:]_]|$)\n' "$symbol"
            return 0
            ;;
        call\ _tl_*)
            symbol=${needle#call _tl_}
            printf 'call[[:space:]]+(_tl_([[:alnum:]_]+_u2etl_colon_colon|[[:alnum:]_]+_)?|tl_)%s([^[:alnum:]_]|$)\n' "$symbol"
            return 0
            ;;
        call\ .L_tl_*)
            symbol=${needle#call .L_tl_}
            printf 'call[[:space:]]+(_tl__u2eL_tl_%s|_tl_%s|\\.L_tl_%s)\n' "$symbol" "$symbol" "$symbol"
            return 0
            ;;
    esac
    return 1
}

expectation_contains_text() {
    needle=$1
    if regex=$(expectation_symbol_regex "$needle"); then
        grep -E -- "$regex" "$asm_path" >/dev/null && return 0
    fi
    if [ "$EXPECTATION_MODE" = stage1 ]; then
        stage1_compact_contains_text "$needle"
        return $?
    fi
    return 1
}

expectation_count_text() {
    needle=$1
    if regex=$(expectation_symbol_regex "$needle"); then
        count=$(grep -E -- "$regex" "$asm_path" | wc -l | tr -d ' ')
        if [ "$count" -gt 0 ]; then
            printf '%s\n' "$count"
            return
        fi
    fi
    if [ "$EXPECTATION_MODE" = stage1 ]; then
        stage1_compact_count_text "$needle"
        return
    fi
    printf '0\n'
}

stage1_compact_readable_symbol() {
    needle=$1
    case "$needle" in
        .L_tl_*:)
            symbol=${needle%:}
            symbol=${symbol#.}
            printf '_tl__u2e%s\n' "$symbol"
            return 0
            ;;
        .L_tl_*)
            symbol=${needle#.}
            printf '_tl__u2e%s\n' "$symbol"
            return 0
            ;;
        _tl_*:)
            symbol=${needle#_tl_}
            symbol=${symbol%:}
            case "$symbol" in
                *_u2etl_colon_colon*) symbol=${symbol##*_u2etl_colon_colon} ;;
            esac
            printf '_tl_%s\n' "$symbol"
            return 0
            ;;
        _tl_*)
            symbol=${needle#_tl_}
            case "$symbol" in
                *_u2etl_colon_colon*) symbol=${symbol##*_u2etl_colon_colon} ;;
            esac
            printf '_tl_%s\n' "$symbol"
            return 0
            ;;
        call\ _tl_*)
            symbol=${needle#call _tl_}
            case "$symbol" in
                *_u2etl_colon_colon*) symbol=${symbol##*_u2etl_colon_colon} ;;
            esac
            printf '_tl_%s\n' "$symbol"
            return 0
            ;;
        call\ .L_tl_*)
            symbol=${needle#call }
            symbol=${symbol#.}
            printf '_tl__u2e%s\n' "$symbol"
            return 0
            ;;
        *:)
            symbol=${needle%:}
            printf '_tl_%s\n' "$symbol"
            return 0
            ;;
    esac
    return 1
}

stage1_compact_symbols_for() {
    readable=$1
    awk -v readable="$readable" '
        $1 == "#" && $2 == "typelisp-symbol" && $4 == readable { print $3 }
        $1 == "#t" && $3 == readable { print $2 }
    ' "$asm_path"
}

stage1_compact_contains_text() {
    needle=$1
    readable=$(stage1_compact_readable_symbol "$needle") || return 1
    for compact in $(stage1_compact_symbols_for "$readable"); do
        case "$needle" in
            .L_tl_*:)
                grep -F -- "$compact:" "$asm_path" >/dev/null && return 0
                ;;
            _tl_*:)
                grep -F -- "$compact:" "$asm_path" >/dev/null && return 0
                ;;
            call\ .L_tl_*)
                grep -E -- "call[[:space:]]+$compact([^[:alnum:]_]|$)" "$asm_path" >/dev/null && return 0
                ;;
            call\ _tl_*)
                grep -E -- "call[[:space:]]+$compact([^[:alnum:]_]|$)" "$asm_path" >/dev/null && return 0
                ;;
            .L_tl_*)
                grep -E -- "$compact([^[:alnum:]_]|$)" "$asm_path" >/dev/null && return 0
                ;;
            _tl_*)
                grep -E -- "$compact([^[:alnum:]_]|$)" "$asm_path" >/dev/null && return 0
                ;;
            *:)
                grep -F -- "$compact:" "$asm_path" >/dev/null && return 0
                ;;
        esac
    done
    return 1
}

stage1_compact_count_text() {
    needle=$1
    readable=$(stage1_compact_readable_symbol "$needle") || {
        printf '0\n'
        return
    }
    total=0
    for compact in $(stage1_compact_symbols_for "$readable"); do
        case "$needle" in
            .L_tl_*:)
                count=$(grep -F -- "$compact:" "$asm_path" | wc -l | tr -d ' ')
                ;;
            _tl_*:)
                count=$(grep -F -- "$compact:" "$asm_path" | wc -l | tr -d ' ')
                ;;
            call\ .L_tl_*)
                count=$(grep -E -- "call[[:space:]]+$compact([^[:alnum:]_]|$)" "$asm_path" | wc -l | tr -d ' ')
                ;;
            call\ _tl_*)
                count=$(grep -E -- "call[[:space:]]+$compact([^[:alnum:]_]|$)" "$asm_path" | wc -l | tr -d ' ')
                ;;
            .L_tl_*)
                count=$(grep -E -- "$compact([^[:alnum:]_]|$)" "$asm_path" | wc -l | tr -d ' ')
                ;;
            _tl_*)
                count=$(grep -E -- "$compact([^[:alnum:]_]|$)" "$asm_path" | wc -l | tr -d ' ')
                ;;
            *:)
                count=$(grep -F -- "$compact:" "$asm_path" | wc -l | tr -d ' ')
                ;;
            *)
                count=0
                ;;
        esac
        total=$((total + count))
    done
    printf '%s\n' "$total"
}

prepare_compile_batch() {
    : > "$BATCH_INPUT"
    rm -rf "$BATCH_CHUNK_DIR"
    mkdir -p "$BATCH_CHUNK_DIR"
    prep_case_id=
    prep_case_source=
    prep_case_mode=
    prep_case_dir=
    prep_requires_stage0_mode=

    while IFS='|' read -r kind a b c d e; do
        case "$kind" in
            ""|\#*) ;;
            decision) ;;
            case)
                prep_case_id=$a
                prep_case_source=$b
                prep_output_mode=$c
                prep_main_policy=$d
                prep_case_mode=$e
                [ "$prep_output_mode" = "assembly" ] || fail "$prep_case_id has unsupported output mode: $prep_output_mode"
                [ "$prep_case_mode" = "direct" ] || [ "$prep_case_mode" = "stage" ] || fail "$prep_case_id has unknown mode: $prep_case_mode"
                prep_case_dir="$WORKDIR/$prep_case_id"
                rm -rf "$prep_case_dir"
                mkdir -p "$prep_case_dir"
                if [ "$prep_case_mode" = "stage" ]; then
                    cp "$prep_case_source" "$prep_case_dir/$(basename "$prep_case_source")"
                fi
                prep_requires_stage0_mode=
                ;;
            requires-stage0-symbol)
                [ -n "$prep_case_id" ] || fail "requires-stage0-symbol appears before a case"
                ;;
            requires-stage0-mode)
                [ -n "$prep_case_id" ] || fail "requires-stage0-mode appears before a case"
                prep_requires_stage0_mode=$a
                ;;
            copy)
                [ -n "$prep_case_id" ] || fail "copy appears before a case"
                [ "$prep_case_mode" = "stage" ] || fail "$prep_case_id copy is only valid for staged cases"
                mkdir -p "$(dirname -- "$prep_case_dir/$b")"
                cp "$a" "$prep_case_dir/$b"
                ;;
            contains | not-contains | count-at-least) ;;
            lint-root)
                [ -n "$prep_case_id" ] || fail "lint-root appears before a case"
                [ -n "$a" ] || fail "$prep_case_id has an empty lint-root"
                ;;
            end)
                [ -n "$prep_case_id" ] || fail "end appears before a case"
                if [ "$EXPECTATION_MODE" = stage1 ] && [ -n "$prep_requires_stage0_mode" ]; then
                    fail "$prep_case_id declares a stage1 blocker in fail-closed CI: $prep_requires_stage0_mode"
                fi
                if [ "$prep_case_mode" = "stage" ]; then
                    prep_compile_source="$prep_case_dir/$(basename "$prep_case_source")"
                else
                    prep_compile_source="$ROOT/$prep_case_source"
                fi
                printf '%s|%s\n' \
                    "$(compiler_batch_path "$prep_compile_source")" \
                    "$(compiler_batch_path "$prep_case_dir/$prep_case_id.s")" >> "$BATCH_INPUT"
                prep_case_id=
                ;;
            *)
                fail "unknown manifest directive: $kind"
                ;;
        esac
    done < "$MANIFEST_INPUT"

    if [ -n "$prep_case_id" ]; then
        fail "manifest ended before case $prep_case_id had an end directive"
    fi

    split_compile_batch
}

# Split BATCH_INPUT into BATCH_CHUNK_SIZE-entry chunk files, numbered from 0.
split_compile_batch() {
    awk -v outdir="$BATCH_CHUNK_DIR" -v size="$BATCH_CHUNK_SIZE" '
        {
            chunk = int((NR - 1) / size)
            path = sprintf("%s/compile-batch.%04d.txt", outdir, chunk)
            print $0 >> path
            if (NR % size == 0) {
                close(path)
            }
        }
    ' "$BATCH_INPUT"
}

# Compile one chunk inside a pool worker. It touches no shared state: it leaves
# the compiler's status and, when CAP_MIB is set, the memory report of its
# bounded run in the chunk's own files, which manifest_settle_chunk reads back
# in chunk order.
manifest_compile_chunk() {
    _chunk=$1
    _chunk_index=$2
    _chunk_count=$3
    _chunk_cap=$4
    _chunk_label="batch compile manifest chunk $_chunk_index/$_chunk_count"
    rm -f "$_chunk.status" "$_chunk.memory"
    echo "[selfhost-compile] $_chunk_label"
    set -- "$COMPILER" compile --batch "$_chunk" --target linux-x86_64 \
        --cfg selfhost-compile-manifest \
        --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src"
    if [ -n "$_chunk_cap" ]; then
        set -- "$ROOT/scripts/run-memory-bounded.sh" \
            --limit-mib "$_chunk_cap" --report "$_chunk.memory" \
            --timeout-seconds "$MANIFEST_POOL_JOB_TIMEOUT_SECONDS" -- "$@"
    fi
    set +e
    ci_timing_run "chunk-$_chunk_index" compile \
        run_with_heartbeat_capture "$_chunk_label" \
        "$_chunk.out" "$_chunk.err" "$@"
    _chunk_rc=$?
    set -e
    printf '%s\n' "$_chunk_rc" > "$_chunk.status"
}

# Account for one compiled chunk in the parent, in chunk order. A failing
# compile fails the gate with the chunk's output, as the serial loop did; a
# chunk stopped by its memory cap or timeout, or one that left no status, is a
# resource regression and fails the gate too.
manifest_settle_chunk() {
    _chunk=$1
    _chunk_index=$2
    _chunk_count=$3
    _chunk_cap=$4
    _chunk_label="batch compile manifest chunk $_chunk_index/$_chunk_count"
    if [ ! -s "$_chunk.status" ]; then
        fail "$_chunk_label left no compile status"
    fi
    _chunk_rc=$(cat "$_chunk.status")
    if [ -n "$_chunk_cap" ]; then
        _chunk_reason=$(sed -n 's/^reason=//p' "$_chunk.memory" 2>/dev/null || true)
        case "$_chunk_reason" in
            success | command-failure) ;;
            *)
                echo "stderr:" >&2
                sed 's/^/  /' "$_chunk.err" >&2 || true
                fail "$_chunk_label was stopped by its bound" \
                    "(reason=${_chunk_reason:-missing-report}, cap $_chunk_cap MiB," \
                    "timeout $MANIFEST_POOL_JOB_TIMEOUT_SECONDS s)"
                ;;
        esac
        _chunk_peak=$(sed -n 's/^peak_memory_bytes=//p' "$_chunk.memory")
        case "$_chunk_peak" in
            '' | *[!0-9]*) fail "$_chunk_label memory report has no peak" ;;
        esac
        if [ "$_chunk_peak" -gt "$MANIFEST_POOL_PEAK_BYTES" ]; then
            MANIFEST_POOL_PEAK_BYTES=$_chunk_peak
            MANIFEST_POOL_PEAK_LABEL="chunk-$_chunk_index"
        fi
    fi
    if [ "$_chunk_rc" -ne 0 ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$_chunk.out" >&2
        echo "stderr:" >&2
        sed 's/^/  /' "$_chunk.err" >&2
        fail "$_chunk_label exited $_chunk_rc in $EXPECTATION_MODE mode"
    fi
}

# The chunk file of pool job `chunk-N` (N counts from 1, the file suffix from 0).
manifest_chunk_path() {
    printf '%s/compile-batch.%04d.txt\n' "$BATCH_CHUNK_DIR" "$(($1 - 1))"
}

# The pool's job callback (see lib-bounded-pool.sh). Timing rows go to a
# private file per job; manifest_merge_pool_timing publishes them in queue
# order, so the rows do not depend on scheduling.
bounded_pool_run_job() {
    _pool_job=$1
    _pool_cap=$2
    [ "$MANIFEST_POOL_ENFORCE_CAPS" -eq 1 ] || _pool_cap=
    case "$_pool_job" in
        chunk-[1-9]*) ;;
        *)
            echo "[selfhost-compile] pool job names no chunk: $_pool_job" >&2
            return 1
            ;;
    esac
    _pool_index=${_pool_job#chunk-}
    if ci_timing_enabled; then
        TYPELISP_CI_TIMING_FILE="$MANIFEST_POOL_DIR/timing/$_pool_job.tsv"
    fi
    manifest_compile_chunk "$(manifest_chunk_path "$_pool_index")" \
        "$_pool_index" "$batch_chunk_count" "$_pool_cap"
}

# Publish the jobs' private timing rows in queue order. A passing pool requires
# a row from every job; a failing one still publishes what ran.
manifest_merge_pool_timing() {
    ci_timing_enabled || return 0
    while IFS='|' read -r _merge_job _merge_cap; do
        _merge_rows="$MANIFEST_POOL_DIR/timing/$_merge_job.tsv"
        if [ -s "$_merge_rows" ]; then
            cat "$_merge_rows" >> "$TYPELISP_CI_TIMING_FILE"
        elif [ "$1" = required ]; then
            fail "batch compile manifest pool job published no timing row: $_merge_job"
        fi
    done < "$MANIFEST_POOL_DIR/queue"
}

run_compile_batch() {
    batch_chunk_count=$(find "$BATCH_CHUNK_DIR" -type f -name 'compile-batch.*.txt' | wc -l | tr -d ' ')
    if [ "$batch_chunk_count" -eq 0 ]; then
        fail "batch compile manifest has no chunks"
    fi
    _pool_budget=$((MANIFEST_POOL_WORKERS * MANIFEST_POOL_CHUNK_CAP_MIB))
    echo "[selfhost-compile] batch compile manifest ($batch_chunk_count chunk(s), size $BATCH_CHUNK_SIZE)"
    echo "[selfhost-compile] batch pool: $MANIFEST_POOL_WORKERS worker(s), $_pool_budget MiB of enforced caps at once"
    MANIFEST_POOL_DIR="$WORKDIR/compile-batch-pool"
    _pool_queue="$WORKDIR/compile-batch-pool.queue"
    : > "$_pool_queue"
    _queue_index=0
    for batch_chunk in "$BATCH_CHUNK_DIR"/compile-batch.*.txt; do
        [ -f "$batch_chunk" ] || fail "batch compile manifest chunk is missing: $batch_chunk"
        _queue_index=$((_queue_index + 1))
        [ "$batch_chunk" = "$(manifest_chunk_path "$_queue_index")" ] ||
            fail "batch compile manifest chunks are not numbered contiguously: $batch_chunk"
        printf 'chunk-%s|%s\n' "$_queue_index" "$MANIFEST_POOL_CHUNK_CAP_MIB" >> "$_pool_queue"
    done
    bounded_pool_init "$MANIFEST_POOL_DIR" "$_pool_budget" "$_pool_queue" ||
        fail "batch compile manifest pool could not start"
    mkdir -p "$MANIFEST_POOL_DIR/timing"
    ci_timing_set_now_ms
    _pool_started=$CI_TIMING_NOW_MS
    bounded_pool_start "$MANIFEST_POOL_DIR" "$MANIFEST_POOL_WORKERS"
    if ! bounded_pool_join "$MANIFEST_POOL_DIR"; then
        manifest_merge_pool_timing available
        fail "batch compile manifest pool did not complete every chunk"
    fi
    ci_timing_set_now_ms
    _pool_wall_ms=$((CI_TIMING_NOW_MS - _pool_started))
    manifest_merge_pool_timing required
    _settle_index=0
    while IFS='|' read -r _settle_job _settle_cap; do
        _settle_index=$((_settle_index + 1))
        [ "$MANIFEST_POOL_ENFORCE_CAPS" -eq 1 ] || _settle_cap=
        manifest_settle_chunk "$(manifest_chunk_path "$_settle_index")" \
            "$_settle_index" "$batch_chunk_count" "$_settle_cap"
    done < "$_pool_queue"
    if [ -n "$MANIFEST_POOL_PEAK_LABEL" ]; then
        echo "[selfhost-compile] batch pool compiled $batch_chunk_count chunk(s) in $_pool_wall_ms ms;" \
            "largest chunk peak $((MANIFEST_POOL_PEAK_BYTES / 1048576)) MiB ($MANIFEST_POOL_PEAK_LABEL)"
    else
        echo "[selfhost-compile] batch pool compiled $batch_chunk_count chunk(s) in $_pool_wall_ms ms"
    fi
}

main_label_count() {
    awk 'BEGIN { count = 0 } /^main:$/ { count += 1 } END { print count }' "$asm_path"
}

stage1_entry_label_count() {
    awk 'BEGIN { count = 0 } /^_tl_start:$/ { count += 1 } END { print count }' "$asm_path"
}

ensure_compiled() {
    if [ "$compiled" -ne 0 ]; then
        return
    fi

    asm_path="$case_dir/$case_id.s"
    if [ ! -f "$asm_path" ]; then
        fail "$case_id batch compile did not produce assembly: $asm_path"
    fi

    if grep -F -- "# TODO" "$asm_path" >/dev/null; then
        fail "$case_id assembly still contains # TODO"
    fi

    main_count=$(main_label_count)
    stage1_entry_count=0
    if [ "$EXPECTATION_MODE" = stage1 ]; then
        stage1_entry_count=$(stage1_entry_label_count)
    fi
    case "$main_policy" in
        exactly-one)
            if [ "$main_count" -eq 0 ] && [ "$EXPECTATION_MODE" = stage1 ]; then
                if [ "$stage1_entry_count" -ne 1 ]; then
                    fail "$case_id expected exactly one stage1 _tl_start: entry fallback, found $stage1_entry_count"
                fi
            elif [ "$main_count" -ne 1 ]; then
                fail "$case_id expected exactly one main: label, found $main_count"
            fi
            ;;
        present)
            if [ "$main_count" -eq 0 ] && [ "$EXPECTATION_MODE" = stage1 ]; then
                if [ "$stage1_entry_count" -lt 1 ]; then
                    fail "$case_id expected a main: label or stage1 _tl_start: entry fallback"
                fi
            elif [ "$main_count" -lt 1 ]; then
                fail "$case_id expected a main: label"
            fi
            ;;
        none)
            if [ "$main_count" -ne 0 ]; then
                fail "$case_id expected no main: label, found $main_count"
            fi
            ;;
        skip) ;;
        *)
            fail "$case_id has unknown main policy: $main_policy"
            ;;
    esac

    compiled=1
}

# Pool self-test (#7998): drive run_compile_batch with a fake compiler and pin
# what the pooled route must keep from the serial one. Every job runs; timing
# rows are published in chunk order even when chunks finish out of order; a
# failing chunk fails the gate with its label and stderr while the other chunks
# still compile; and, where caps are enforced, a chunk past its timeout fails
# the gate instead of passing.
manifest_pool_self_test_fail() {
    echo "FAIL: compile manifest pool self-test: $*" >&2
    exit 1
}

# Run one scenario: NAME CHUNK_SIZE SOURCE... in its own directory, recording
# the gate's exit status, stdout and stderr there.
manifest_pool_self_test_run() {
    _st_name=$1
    BATCH_CHUNK_SIZE=$2
    shift 2
    WORKDIR="$MANIFEST_POOL_SELF_TEST_ROOT/$_st_name"
    BATCH_INPUT="$WORKDIR/compile-batch.txt"
    BATCH_CHUNK_DIR="$WORKDIR/compile-batch-chunks"
    mkdir -p "$BATCH_CHUNK_DIR"
    : > "$BATCH_INPUT"
    for _st_source in "$@"; do
        printf '%s|%s\n' "$WORKDIR/$_st_source.tl" "$WORKDIR/$_st_source.s" >> "$BATCH_INPUT"
    done
    split_compile_batch
    TYPELISP_CI_TIMING=1
    TYPELISP_CI_TIMING_FILE="$WORKDIR/timing.tsv"
    TYPELISP_CI_TIMING_HOST=$HOST_OS
    TYPELISP_CI_TIMING_GATE=selfhost-compile-manifest-pool-self-test
    export TYPELISP_CI_TIMING TYPELISP_CI_TIMING_FILE TYPELISP_CI_TIMING_HOST TYPELISP_CI_TIMING_GATE
    : > "$TYPELISP_CI_TIMING_FILE"
    MANIFEST_SELF_TEST_LOG="$WORKDIR/finished.log"
    export MANIFEST_SELF_TEST_LOG
    : > "$MANIFEST_SELF_TEST_LOG"
    _st_status=0
    ( run_compile_batch ) > "$WORKDIR/stdout" 2> "$WORKDIR/stderr" || _st_status=$?
    printf '%s\n' "$_st_status" > "$WORKDIR/status"
}

manifest_pool_self_test_expect() {
    _st_dir="$MANIFEST_POOL_SELF_TEST_ROOT/$1"
    _st_want=$2
    _st_got=$(cat "$_st_dir/status")
    if [ "$_st_want" = pass ] && [ "$_st_got" -ne 0 ]; then
        sed 's/^/  /' "$_st_dir/stderr" >&2
        manifest_pool_self_test_fail "$1 exited $_st_got, expected success"
    fi
    if [ "$_st_want" = fail ] && [ "$_st_got" -eq 0 ]; then
        manifest_pool_self_test_fail "$1 passed, expected the gate to fail"
    fi
}

manifest_pool_self_test_stderr_has() {
    grep -F -- "$2" "$MANIFEST_POOL_SELF_TEST_ROOT/$1/stderr" >/dev/null ||
        manifest_pool_self_test_fail "$1 stderr lacks: $2"
}

manifest_pool_self_test() {
    MANIFEST_POOL_SELF_TEST_ROOT="$ROOT/target/selfhost-compile-manifest-pool-self-test"
    rm -rf "$MANIFEST_POOL_SELF_TEST_ROOT"
    mkdir -p "$MANIFEST_POOL_SELF_TEST_ROOT"
    # The fake compiler writes each entry's output, sleeps 3 s for a source
    # named `pause*`, 30 s for `stall*`, fails `broken*`, and logs its chunk
    # list once it finishes.
    COMPILER="$MANIFEST_POOL_SELF_TEST_ROOT/fake-typelisp"
    cat > "$COMPILER" <<'FAKE'
#!/usr/bin/env sh
if [ "${1:-}" != compile ] || [ "${2:-}" != --batch ]; then
    echo "fake compiler: unexpected arguments: $*" >&2
    exit 2
fi
while IFS='|' read -r source output; do
    case "${source##*/}" in
        pause*) sleep 3 ;;
        stall*) sleep 30 ;;
    esac
    case "${source##*/}" in
        broken*)
            echo "fake compile failed: $source" >&2
            exit 7
            ;;
    esac
    printf 'main:\n' > "$output"
done < "$3"
printf '%s\n' "${3##*/}" >> "$MANIFEST_SELF_TEST_LOG"
FAKE
    chmod +x "$COMPILER"
    EXPECTATION_MODE=stage1
    # Windows' Job Object wrapper cannot launch a shell script; the pool and its
    # settlement still run, only the cap and timeout are not enforced there.
    [ "$HOST_OS" != windows ] || MANIFEST_POOL_ENFORCE_CAPS=0

    # Two workers, three chunks. Chunk 1 pauses, so chunk 2 finishes first;
    # the published rows must still be chunk-1, chunk-2, chunk-3.
    MANIFEST_POOL_WORKERS=2
    manifest_pool_self_test_run order 2 pause-a b c d e
    manifest_pool_self_test_expect order pass
    for _st_output in pause-a b c d e; do
        [ -s "$MANIFEST_POOL_SELF_TEST_ROOT/order/$_st_output.s" ] ||
            manifest_pool_self_test_fail "order did not compile $_st_output"
    done
    [ "$(head -n 1 "$MANIFEST_POOL_SELF_TEST_ROOT/order/finished.log")" = compile-batch.0001.txt ] ||
        manifest_pool_self_test_fail "order: chunk 2 did not finish before chunk 1, so the scenario proves nothing"
    [ "$(awk -F '\t' '{ printf "%s ", $2 }' "$MANIFEST_POOL_SELF_TEST_ROOT/order/timing.tsv")" = "chunk-1 chunk-2 chunk-3 " ] ||
        manifest_pool_self_test_fail "order: timing rows are not one per chunk in chunk order"

    # One worker is the serial route.
    MANIFEST_POOL_WORKERS=1
    manifest_pool_self_test_run serial 2 a b c
    manifest_pool_self_test_expect serial pass
    [ "$(wc -l < "$MANIFEST_POOL_SELF_TEST_ROOT/serial/timing.tsv" | tr -d ' ')" -eq 2 ] ||
        manifest_pool_self_test_fail "serial: expected 2 timing rows"

    # A failing chunk fails the gate with its label and the compiler's stderr;
    # the chunks after it still ran.
    MANIFEST_POOL_WORKERS=2
    manifest_pool_self_test_run broken 1 a broken-b c
    manifest_pool_self_test_expect broken fail
    manifest_pool_self_test_stderr_has broken "batch compile manifest chunk 2/3 exited 7 in stage1 mode"
    manifest_pool_self_test_stderr_has broken "fake compile failed:"
    [ -s "$MANIFEST_POOL_SELF_TEST_ROOT/broken/c.s" ] ||
        manifest_pool_self_test_fail "broken: the chunk after the failing one did not compile"

    # A chunk past its timeout is a bound stop, not a pass.
    if [ "$MANIFEST_POOL_ENFORCE_CAPS" -eq 1 ]; then
        MANIFEST_POOL_JOB_TIMEOUT_SECONDS=2
        manifest_pool_self_test_run stall 1 a stall-b
        manifest_pool_self_test_expect stall fail
        manifest_pool_self_test_stderr_has stall "batch compile manifest chunk 2/2 was stopped by its bound (reason=timeout"
        MANIFEST_POOL_JOB_TIMEOUT_SECONDS=900
    fi

    # The worker count is validated before anything runs.
    for _st_workers in 0 4 x; do
        _st_status=0
        TYPELISP_COMPILE_MANIFEST_WORKERS=$_st_workers sh "$ROOT/scripts/verify-selfhost-compile-manifest.sh" \
            --self-test-pool > /dev/null 2>&1 || _st_status=$?
        [ "$_st_status" -eq 2 ] ||
            manifest_pool_self_test_fail "TYPELISP_COMPILE_MANIFEST_WORKERS=$_st_workers exited $_st_status, expected 2"
    done
    echo "[selfhost-compile] pool self-test passed"
}

( manifest_pool_self_test )
if [ "$SELF_TEST_POOL" -eq 1 ]; then
    exit 0
fi

check_selfhost_manifest_sync
prepare_compile_batch
run_compile_batch

case_id=
case_source=
case_mode=
main_policy=
case_dir=
compiled=1
case_count=0
case_requires_stage0_mode=

while IFS='|' read -r kind a b c d e; do
    case "$kind" in
        ""|\#*) ;;
        decision) ;;
        case)
            case_id=$a
            case_source=$b
            output_mode=$c
            main_policy=$d
            case_mode=$e
            [ "$output_mode" = "assembly" ] || fail "$case_id has unsupported output mode: $output_mode"
            [ "$case_mode" = "direct" ] || [ "$case_mode" = "stage" ] || fail "$case_id has unknown mode: $case_mode"
            case_dir="$WORKDIR/$case_id"
            mkdir -p "$case_dir"
            asm_path=
            compiled=0
            case_requires_symbol=
            case_requires_stage0_mode=
            case_count=$((case_count + 1))
            ;;
        requires-stage0-symbol)
            [ -n "$case_id" ] || fail "requires-stage0-symbol appears before a case"
            case_requires_symbol=$a
            ;;
        requires-stage0-mode)
            [ -n "$case_id" ] || fail "requires-stage0-mode appears before a case"
            case_requires_stage0_mode=$a
            ;;
        copy)
            [ -n "$case_id" ] || fail "copy appears before a case"
            [ "$case_mode" = "stage" ] || fail "$case_id copy is only valid for staged cases"
            mkdir -p "$(dirname -- "$case_dir/$b")"
            cp "$a" "$case_dir/$b"
            ;;
        contains)
            [ -n "$case_id" ] || fail "contains appears before a case"
            ensure_compiled
            contains_text "$a"
            ;;
        lint-root)
            [ -n "$case_id" ] || fail "lint-root appears before a case"
            [ -n "$a" ] || fail "$case_id has an empty lint-root"
            ;;
        not-contains)
            [ -n "$case_id" ] || fail "not-contains appears before a case"
            ensure_compiled
            not_contains_text "$a"
            ;;
        count-at-least)
            [ -n "$case_id" ] || fail "count-at-least appears before a case"
            ensure_compiled
            count_at_least "$a" "$b"
            ;;
        end)
            [ -n "$case_id" ] || fail "end appears before a case"
            ensure_compiled
            case_id=
            ;;
        *)
            fail "unknown manifest directive: $kind"
            ;;
    esac
done < "$MANIFEST_INPUT"

if [ -n "$case_id" ]; then
    fail "manifest ended before case $case_id had an end directive"
fi

echo "selfhost compile manifest passed: $case_count case(s) ($EXPECTATION_MODE mode)"
