#!/usr/bin/env sh
set -eu

# check-build-invariance.sh - opt1-built vs opt2-built compiler output gate.
#
# A correct compiler's emitted assembly depends on the source, target, backend
# mode, and requested optimization level. It must not depend on whether the
# compiler binary itself was built at opt1 or opt2. CI supplies a converged
# opt2-built stage4; this gate builds one opt1 compiler from current source and
# compares their emitted assembly over a fixed Linux corpus.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-ci-timing.sh"
. "$ROOT/scripts/lib-build-invariance-batch.sh"
. "$ROOT/scripts/lib-ci-compiler-artifact.sh"

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-build-invariance.sh

Requires TYPELISP_BIN to point at CI's converged Linux opt2-built stage4
compiler. Builds one opt1 compiler from src/main.tl, then compares emitted
assembly for a fixed corpus. The same fresh opt1 compiler must also compile
the complete codegen smoke and build backend-tests at opt2 within 8 GiB.

The four selfhost compiles whose wall time CI budgets run alone. Every other
compile and the backend-tests build run in a pool of
TYPELISP_BUILD_INVARIANCE_WORKERS processes (1-3, default 2), each under a
kernel-enforced memory cap, with at most 12288 MiB of caps running at once.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ "$#" -ne 0 ]; then
    usage
    exit 2
fi

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "build-invariance check is Linux-only" >&2
        exit 1
        ;;
esac

if [ -z "${TYPELISP_BIN:-}" ]; then
    echo "check-build-invariance requires TYPELISP_BIN" >&2
    exit 2
fi

COMPILER=$TYPELISP_BIN
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
if [ "$NL_HOST_OS" != linux ]; then
    echo "build-invariance check is Linux-only" >&2
    exit 1
fi
configure_toolchain

# `compile --batch` runs entries serially and tears down per-entry compiler
# state before advancing. A 64-entry ceiling amortizes process startup while
# keeping each process bounded; smaller values remain available for local
# memory probes, but the gate never accepts an unbounded whole-corpus batch.
# Whole-compiler selfhost and smoke sources dominate their process, so keep
# those as singleton batches instead of carrying an already-large process
# high-water mark into another compile.
BATCH_CHUNK_MAX=64
BATCH_CHUNK_SIZE=${TYPELISP_BUILD_INVARIANCE_BATCH_SIZE:-$BATCH_CHUNK_MAX}
case "$BATCH_CHUNK_SIZE" in
    "" | *[!0-9]*)
        echo "invalid build-invariance batch size: $BATCH_CHUNK_SIZE" >&2
        exit 2
        ;;
esac
if [ "$BATCH_CHUNK_SIZE" -lt 1 ] || [ "$BATCH_CHUNK_SIZE" -gt "$BATCH_CHUNK_MAX" ]; then
    echo "build-invariance batch size must be between 1 and $BATCH_CHUNK_MAX: $BATCH_CHUNK_SIZE" >&2
    exit 2
fi

# The producers' chunks are independent processes, so they run in a worker pool.
# Concurrency is bounded by enforcement rather than by what a host tolerates:
# every pooled job runs under a kernel-enforced cap with swap disabled, and a
# job starts only while the caps of all running jobs fit the pool budget. The
# budget leaves a 16 GiB runner a quarter of its memory for everything outside
# the pool. The complete backend-tests build and both producers' complete
# codegen smoke keep the 8 GiB cap, so no two of them overlap; every other
# chunk gets 4 GiB, half as much again as the largest measured peak
# (src/TESTING.md records the measurements).
POOL_WORKERS_MAX=3
POOL_WORKERS=${TYPELISP_BUILD_INVARIANCE_WORKERS:-2}
case "$POOL_WORKERS" in
    "" | *[!0-9]*)
        echo "invalid build-invariance worker count: $POOL_WORKERS" >&2
        exit 2
        ;;
esac
if [ "$POOL_WORKERS" -lt 1 ] || [ "$POOL_WORKERS" -gt "$POOL_WORKERS_MAX" ]; then
    echo "build-invariance worker count must be between 1 and $POOL_WORKERS_MAX: $POOL_WORKERS" >&2
    exit 2
fi
POOL_BUDGET_MIB=12288
POOL_FULL_CAP_MIB=8192
POOL_CHUNK_CAP_MIB=4096
POOL_JOB_TIMEOUT_SECONDS=600

WORKDIR="$ROOT/target/build-invariance"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
CHUNK_METRICS="$WORKDIR/chunk-metrics.tsv"
: > "$CHUNK_METRICS"

HANDOFF_PATH_FILE=""
if [ "${TYPELISP_BUILD_INVARIANCE_OPT1_REFERENCE_PATH_FILE+x}" = x ]; then
    HANDOFF_PATH_FILE=$TYPELISP_BUILD_INVARIANCE_OPT1_REFERENCE_PATH_FILE
    if [ -z "$HANDOFF_PATH_FILE" ]; then
        echo "build-invariance opt1 reference path file is empty" >&2
        exit 2
    fi
    case "$HANDOFF_PATH_FILE" in
        /*) ;;
        *) HANDOFF_PATH_FILE="$ROOT/$HANDOFF_PATH_FILE" ;;
    esac
    rm -f "$HANDOFF_PATH_FILE"
fi

print_log_pair() {
    label=$1
    stdout=$2
    stderr=$3
    echo "[$label] stdout:" >&2
    sed 's/^/  /' "$stdout" >&2 || true
    echo "[$label] stderr:" >&2
    sed 's/^/  /' "$stderr" >&2 || true
}

print_asm_fingerprint() {
    label=$1
    file=$2
    bytes=$(wc -c < "$file" | tr -d ' ')
    lines=$(wc -l < "$file" | tr -d ' ')
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(sha256sum "$file" | sed 's/[[:space:]].*//')
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(shasum -a 256 "$file" | sed 's/[[:space:]].*//')
    else
        hash=unavailable
    fi
    echo "[build-invariance]   $label sha256=$hash bytes=$bytes lines=$lines path=$file" >&2
}

compile_stage() {
    opt_level=$1
    stage_label=$2
    compiler=$3
    asm=$4
    stdout=$5
    stderr=$6

    echo "[build-invariance] opt$opt_level $stage_label: compile src/main.tl"
    if ! ci_timing_run "compiler-opt$opt_level" compile \
        run_with_heartbeat_capture \
        "build-invariance opt$opt_level $stage_label" \
        "$stdout" \
        "$stderr" \
        "$compiler" compile src/main.tl \
        -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --backend-mode scalar \
        --opt-level "$opt_level" \
        --stdlib-root stdlib \
        --stdlib-root src; then
        print_log_pair "build-invariance opt$opt_level $stage_label compile failed" "$stdout" "$stderr"
        exit 1
    fi
    if [ ! -s "$asm" ]; then
        print_log_pair "build-invariance opt$opt_level $stage_label compile output" "$stdout" "$stderr"
        echo "[build-invariance] empty assembly: $asm" >&2
        exit 1
    fi
}

build_opt1_compiler() {
    outdir="$WORKDIR/opt1"
    mkdir -p "$outdir"

    opt1_asm="$outdir/opt1.s"
    opt1_obj="$outdir/opt1.$NL_OBJ_EXT"
    opt1_bin="$outdir/opt1$NL_BIN_EXT"

    compile_stage 1 "stage4-to-opt1" "$COMPILER" "$opt1_asm" "$outdir/opt1.stdout" "$outdir/opt1.stderr"
    ci_timing_run compiler-opt1 assemble-link \
        assemble_and_link "build-invariance opt1 compiler" "$opt1_asm" "$opt1_obj" "$opt1_bin"

    if [ ! -x "$opt1_bin" ]; then
        chmod +x "$opt1_bin" 2>/dev/null || true
    fi
    if [ ! -x "$opt1_bin" ]; then
        echo "[build-invariance] opt1 compiler is not executable: $opt1_bin" >&2
        exit 1
    fi
}

check_backend_memory_report() {
    if ! awk -F= -v expected_limit="$(($2 * 1048576))" '
        $1 == "schema_version" { schema = $2 }
        $1 == "host" { host = $2 }
        $1 == "backend" { backend = $2 }
        $1 == "reason" { reason = $2 }
        $1 == "exit_code" { code = $2; have_code = 1 }
        $1 == "limit_bytes" { limit = $2 }
        $1 == "peak_memory_bytes" { peak = $2 }
        END {
            exit !(schema == 1 && host == "linux" &&
                backend == "systemd-user-cgroup" &&
                reason == "success" && have_code && code == 0 &&
                limit == expected_limit && peak ~ /^[0-9]+$/ &&
                peak + 0 > 0 && peak + 0 < limit + 0)
        }
    ' "$1"; then
        echo "[build-invariance] backend memory report lacks successful enforced headroom: $1" >&2
        exit 1
    fi
}

check_backend_memory() {
    memory_dir="$WORKDIR/backend-memory"
    mkdir -p "$memory_dir"
    echo "[build-invariance] complete backend fixtures: enforced $POOL_FULL_CAP_MIB MiB process-tree cap"
    if ! ci_timing_run backend-memory backend-tests \
        run_with_heartbeat_capture \
        "bounded opt2 backend-tests build" \
        "$memory_dir/backend-tests.stdout" "$memory_dir/backend-tests.stderr" \
        env TYPELISP_LINUX_MEMORY_LIMIT_BACKEND=systemd-user-cgroup \
        "$ROOT/scripts/run-memory-bounded.sh" \
        --limit-mib "$POOL_FULL_CAP_MIB" --report "$memory_dir/backend-tests.memory" \
        --timeout-seconds "$POOL_JOB_TIMEOUT_SECONDS" -- \
        "$OPT1_COMPILER" build src/compiler_backend_tests.tl \
        -o "$memory_dir/backend-tests" --target linux-x86_64 --opt-level 2 \
        --stdlib-root stdlib --stdlib-root src; then
        print_log_pair "bounded backend-tests build failed" \
            "$memory_dir/backend-tests.stdout" "$memory_dir/backend-tests.stderr"
        exit 1
    fi
    check_backend_memory_report "$memory_dir/backend-tests.memory" "$POOL_FULL_CAP_MIB"
    if [ ! -s "$memory_dir/backend-tests" ] || \
       [ ! -s "$memory_dir/backend-tests.memory" ]; then
        echo "[build-invariance] backend memory gate did not publish complete outputs/reports" >&2
        exit 1
    fi
    cat "$memory_dir/backend-tests.memory"
}

write_corpus() {
    corpus_file=$1
    {
        printf '%s\n' "selfhost_main_opt1|src/main.tl|1"
        printf '%s\n' "selfhost_main_opt2|src/main.tl|2"
        awk -F'|' '
            /^[[:space:]]*#/ { next }
            NF < 2 { next }
            $1 == "" || $2 == "" { next }
            {
                print "integration_" $1 "|" $2 "|2"
            }
        ' tests/integration/native-linux.manifest
    } > "$corpus_file"
}

write_batch_chunks() {
    chunk_records=$1
    chunk_dir=$2

    rm -rf "$chunk_dir"
    mkdir -p "$chunk_dir"
    awk -F'|' -v chunk_dir="$chunk_dir" -v chunk_size="$BATCH_CHUNK_SIZE" '
        function singleton(name, source) {
            return name ~ /^selfhost_main_/ || source ~ /^src\/tests\/compiler_[^/]*\.tl$/
        }
        function finish_chunk() {
            if (chunk_entries > 0) {
                close(cases_path)
                chunk_index += 1
                chunk_entries = 0
            }
        }
        function start_chunk() {
            suffix = sprintf("%04d", chunk_index)
            cases_path = chunk_dir "/cases." suffix ".txt"
        }
        $1 != "" {
            if (singleton($1, $2) && chunk_entries > 0) {
                finish_chunk()
            }
            if (chunk_entries == 0) {
                start_chunk()
            }
            print $0 >> cases_path
            chunk_entries += 1
            if (singleton($1, $2) || chunk_entries >= chunk_size) {
                finish_chunk()
            }
        }
        END {
            finish_chunk()
        }
    ' "$chunk_records"
}

prepare_compile_batches() {
    compiler_label=$1
    output_dir=$2
    batch_root="$WORKDIR/batches/$compiler_label"
    all_cases="$batch_root/cases.txt"

    rm -rf "$batch_root"
    mkdir -p "$batch_root/opt1" "$batch_root/opt2"
    prepared_count=0
    while IFS='|' read -r name source opt_level; do
        [ -n "$name" ] || continue
        if [ ! -f "$source" ]; then
            echo "[build-invariance] corpus source not found for $name: $source" >&2
            exit 1
        fi
        case "$opt_level" in
            1 | 2) ;;
            *)
                echo "[build-invariance] invalid opt level for $name: $opt_level" >&2
                exit 1
                ;;
        esac

        out="$output_dir/$name.s"
        compile_source=$source
        if [ "$name" = integration_sym_i64_env ]; then
            input_dir="$WORKDIR/inputs/$name/sym_i64_env"
            rm -rf "$input_dir"
            mkdir -p "$input_dir"
            cp "$source" "$input_dir/sym_i64_env.tl"
            cp src/sym_i64_env.tl "$input_dir/sym_i64_env_core.tl"
            compile_source="$input_dir/sym_i64_env.tl"
        fi
        record="$name|$source|$compile_source|$out|$opt_level"
        printf '%s\n' "$record"
        prepared_count=$((prepared_count + 1))
    done < "$CORPUS" > "$all_cases"

    if [ "$prepared_count" -ne "$CORPUS_CASE_COUNT" ]; then
        echo "[build-invariance] $compiler_label prepared $prepared_count cases, expected $CORPUS_CASE_COUNT" >&2
        exit 1
    fi

    awk -F'|' '$5 == 1' "$all_cases" > "$batch_root/opt1/cases.txt"
    awk -F'|' '$5 == 2' "$all_cases" > "$batch_root/opt2/cases.txt"

    for opt_level in 1 2; do
        opt_dir="$batch_root/opt$opt_level"
        cases="$opt_dir/cases.txt"
        [ -s "$cases" ] || continue
        chunks="$opt_dir/chunks"
        write_batch_chunks "$cases" "$chunks"
        for case_chunk in "$chunks"/cases.*.txt; do
            chunk_suffix=${case_chunk##*/cases.}
            build_invariance_plan_chunk "$case_chunk" \
                "$chunks/entries.$chunk_suffix" \
                "$chunks/aliases.$chunk_suffix" "$opt_level" "$output_dir"
        done
        entry_chunk_count=$(find "$chunks" -type f -name 'entries.*.txt' | wc -l | tr -d ' ')
        case_chunk_count=$(find "$chunks" -type f -name 'cases.*.txt' | wc -l | tr -d ' ')
        if [ "$entry_chunk_count" -eq 0 ] || [ "$entry_chunk_count" -ne "$case_chunk_count" ]; then
            echo "[build-invariance] malformed $compiler_label opt$opt_level batch chunks" >&2
            exit 1
        fi
    done
}

print_batch_cases() {
    print_case_chunk=$1
    while IFS='|' read -r print_name print_source print_compile_source print_out print_opt_level; do
        [ -n "$print_name" ] || continue
        echo "[build-invariance]   $print_name opt$print_opt_level source=$print_source batch-input=$print_compile_source" >&2
    done < "$print_case_chunk"
}

verify_batch_outputs() {
    verify_compiler_label=$1
    verify_case_chunk=$2
    verify_stdout=$3
    verify_stderr=$4
    while IFS='|' read -r verify_name verify_source verify_compile_source verify_out verify_opt_level; do
        [ -n "$verify_name" ] || continue
        if [ ! -s "$verify_out" ]; then
            print_log_pair "build-invariance $verify_compiler_label missing output for $verify_name" "$verify_stdout" "$verify_stderr"
            echo "[build-invariance] missing assembly for $verify_name (source $verify_source): $verify_out" >&2
            exit 1
        fi
    done < "$verify_case_chunk"
}

chunk_is_timed_selfhost() {
    [ "$(wc -l < "$1" | tr -d ' ')" -eq 1 ] || return 1
    case "$(awk -F'|' 'NR == 1 { print $1; exit }' "$1")" in
        selfhost_main_opt1 | selfhost_main_opt2) return 0 ;;
    esac
    return 1
}

chunk_is_complete_codegen_smoke() {
    [ "$(wc -l < "$1" | tr -d ' ')" -eq 1 ] &&
        [ "$(awk -F'|' 'NR == 1 { print $3; exit }' "$1")" = src/tests/compiler_codegen_smoke_suite.tl ]
}

run_batch_chunk() {
    batch_compiler_label=$1
    batch_compiler=$2
    batch_opt_level=$3
    batch_chunk_path=$4
    batch_case_chunk=$5
    batch_id=$6
    batch_entries=$7
    # Empty for the selfhost compiles that run alone; a pooled chunk passes the
    # cap its queue record reserved.
    batch_cap_mib=$8
    batch_logical_cases=$(wc -l < "$batch_case_chunk" | tr -d ' ')
    batch_label="build-invariance $batch_compiler_label opt$batch_opt_level chunk $batch_id ($batch_entries compile(s), $batch_logical_cases case(s), serial)"

    # Rebuild the plan from the authoritative logical records. An altered,
    # omitted or cross-producer entry/alias cannot silently remove coverage.
    batch_output_dir="$WORKDIR/compare/$batch_compiler_label"
    batch_aliases="$(dirname "$batch_chunk_path")/aliases.${batch_chunk_path##*/entries.}"
    build_invariance_require_plan "$batch_case_chunk" \
        "$batch_chunk_path" "$batch_aliases" \
        "$batch_opt_level" "$batch_output_dir"
    while IFS='|' read -r fresh_name fresh_source fresh_input fresh_out fresh_opt; do
        if [ -e "$fresh_out" ] || [ -L "$fresh_out" ]; then
            echo "[build-invariance] output exists before compile: $fresh_out" >&2
            exit 1
        fi
    done < "$batch_case_chunk"

    batch_stdout="${batch_chunk_path%.txt}.stdout"
    batch_stderr="${batch_chunk_path%.txt}.stderr"
    batch_timing_label="$batch_compiler_label:opt$batch_opt_level:chunk$batch_id"
    if [ "$batch_entries" -eq 1 ]; then
        batch_single_name=$(awk -F'|' 'NR == 1 { print $1; exit }' "$batch_case_chunk")
        case "$batch_single_name" in
            selfhost_main_opt1 | selfhost_main_opt2)
                # Preserve the timing-budget contract and self-build ratio rows
                # while compiling the selfhost cases through singleton batches.
                batch_timing_label="$batch_compiler_label:$batch_single_name"
                ;;
        esac
    fi
    batch_started=$(date +%s%3N)
    echo "[build-invariance] $batch_label"
    set -- "$batch_compiler" compile --batch "$batch_chunk_path" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --backend-mode scalar \
        --opt-level "$batch_opt_level" \
        --stdlib-root stdlib --stdlib-root src
    batch_memory_report=
    batch_peak_bytes=0
    if [ -n "$batch_cap_mib" ]; then
        batch_suffix=${batch_chunk_path##*/entries.}
        batch_memory_report="$WORKDIR/backend-memory/$batch_compiler_label.opt$batch_opt_level.chunk${batch_suffix%.txt}.memory"
        if [ "$batch_compiler_label" = opt1-built ] && chunk_is_complete_codegen_smoke "$batch_case_chunk"; then
            # This existing singleton already compiles the complete stress
            # corpus with the opt1-built compiler. Its report is the ownership
            # regression's evidence; it is not compiled a second time.
            batch_memory_report="$WORKDIR/backend-memory/codegen-smoke.memory"
            batch_stdout="$WORKDIR/backend-memory/codegen-smoke.stdout"
            batch_stderr="$WORKDIR/backend-memory/codegen-smoke.stderr"
        fi
        if [ -e "$batch_memory_report" ] || [ -L "$batch_memory_report" ]; then
            echo "[build-invariance] memory report exists before compile: $batch_memory_report" >&2
            exit 1
        fi
        set -- env TYPELISP_LINUX_MEMORY_LIMIT_BACKEND=systemd-user-cgroup \
            "$ROOT/scripts/run-memory-bounded.sh" \
            --limit-mib "$batch_cap_mib" --report "$batch_memory_report" \
            --timeout-seconds "$POOL_JOB_TIMEOUT_SECONDS" -- "$@"
    fi
    if ! ci_timing_run "$batch_timing_label" compile \
        run_with_heartbeat_capture \
        "$batch_label" \
        "$batch_stdout" \
        "$batch_stderr" \
        "$@"; then
        print_log_pair "$batch_label failed" "$batch_stdout" "$batch_stderr"
        echo "[build-invariance] $batch_label cases:" >&2
        print_batch_cases "$batch_case_chunk"
        exit 1
    fi
    if [ -n "$batch_memory_report" ]; then
        check_backend_memory_report "$batch_memory_report" "$batch_cap_mib"
        batch_peak_bytes=$(sed -n 's/^peak_memory_bytes=//p' "$batch_memory_report")
        if [ "$batch_memory_report" = "$WORKDIR/backend-memory/codegen-smoke.memory" ]; then
            cat "$batch_memory_report"
        fi
    fi
    build_invariance_copy_aliases "$batch_aliases"
    verify_batch_outputs "$batch_compiler_label" "$batch_case_chunk" "$batch_stdout" "$batch_stderr"
    batch_finished=$(date +%s%3N)
    batch_elapsed_ms=$((batch_finished - batch_started))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$batch_elapsed_ms" "$batch_compiler_label" "$batch_opt_level" "$batch_id" "$batch_logical_cases" "$batch_peak_bytes" >> "$CHUNK_METRICS"
    echo "[build-invariance] $batch_label elapsed_ms=$batch_elapsed_ms peak_memory_bytes=$batch_peak_bytes"
}

compare_case() {
    name=$1
    left=$2
    right=$3

    if [ "$name" = selfhost_main_opt2 ]; then
        left_rbp=$(grep -cF "(,%rbp,1)" "$left" || true)
        right_rbp=$(grep -cF "(,%rbp,1)" "$right" || true)
        echo "[build-invariance] selfhost opt2 '(,%rbp,1)' count: opt1-built=$left_rbp opt2-built=$right_rbp"
    fi

    if ! ci_timing_run "$name" compare cmp -s "$left" "$right"; then
        echo "[build-invariance] BUILD-INVARIANCE MISMATCH: $name" >&2
        print_asm_fingerprint "opt1-built compiler output" "$left"
        print_asm_fingerprint "opt2-built compiler output" "$right"
        if [ "$name" = selfhost_main_opt2 ]; then
            echo "[build-invariance] '(,%rbp,1)' counts: opt1-built=$left_rbp opt2-built=$right_rbp" >&2
        fi
        if command -v diff >/dev/null 2>&1; then
            diff -u "$left" "$right" | sed -n '1,160p' >&2 || true
        else
            cmp -l "$left" "$right" | sed -n '1,80p' >&2 || true
        fi
        exit 1
    fi
}

compare_batch_cases() {
    compare_case_chunk=$1
    compare_left_dir=$2
    compare_right_dir=$3

    while IFS='|' read -r compare_name compare_source compare_compile_source compare_out compare_opt_level; do
        [ -n "$compare_name" ] || continue
        compare_case "$compare_name" "$compare_left_dir/$compare_name.s" "$compare_right_dir/$compare_name.s"
        BATCH_CASE_COUNT=$((BATCH_CASE_COUNT + 1))
    done < "$compare_case_chunk"
}

case_record_field() {
    record_field_records=$1
    record_field_name=$2
    record_field_number=$3
    awk -F'|' -v wanted_name="$record_field_name" -v field="$record_field_number" '
        $1 == wanted_name {
            print $field
            exit
        }
    ' "$record_field_records"
}

run_batch_sentinel() {
    sentinel_compiler_label=$1
    sentinel_compiler=$2
    sentinel_name=$3
    records="$WORKDIR/batches/$sentinel_compiler_label/cases.txt"
    compile_source=$(case_record_field "$records" "$sentinel_name" 3)
    batch_output=$(case_record_field "$records" "$sentinel_name" 4)
    opt_level=$(case_record_field "$records" "$sentinel_name" 5)

    if [ -z "$compile_source" ] || [ -z "$batch_output" ] || [ -z "$opt_level" ]; then
        echo "[build-invariance] missing batch sentinel case: $sentinel_name" >&2
        exit 1
    fi

    sentinel_dir="$WORKDIR/sentinels/$sentinel_compiler_label"
    standalone_output="$sentinel_dir/$sentinel_name.standalone.s"
    stdout="$standalone_output.stdout"
    stderr="$standalone_output.stderr"
    mkdir -p "$sentinel_dir"
    echo "[build-invariance] $sentinel_compiler_label standalone sentinel $sentinel_name opt$opt_level"
    if ! run_with_heartbeat_capture \
        "build-invariance $sentinel_compiler_label standalone sentinel $sentinel_name opt$opt_level" \
        "$stdout" \
        "$stderr" \
        "$sentinel_compiler" compile "$compile_source" \
        -o "$standalone_output" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --backend-mode scalar \
        --opt-level "$opt_level" \
        --stdlib-root stdlib \
        --stdlib-root src; then
        print_log_pair "build-invariance $sentinel_compiler_label standalone sentinel $sentinel_name failed" "$stdout" "$stderr"
        exit 1
    fi
    if [ ! -s "$standalone_output" ]; then
        print_log_pair "build-invariance $sentinel_compiler_label standalone sentinel $sentinel_name output" "$stdout" "$stderr"
        echo "[build-invariance] empty standalone sentinel assembly for $sentinel_name: $standalone_output" >&2
        exit 1
    fi
    if ! cmp -s "$batch_output" "$standalone_output"; then
        echo "[build-invariance] BATCH-STANDALONE MISMATCH: $sentinel_compiler_label $sentinel_name" >&2
        print_asm_fingerprint "batch output" "$batch_output"
        print_asm_fingerprint "standalone output" "$standalone_output"
        if command -v diff >/dev/null 2>&1; then
            diff -u "$batch_output" "$standalone_output" | sed -n '1,160p' >&2 || true
        else
            cmp -l "$batch_output" "$standalone_output" | sed -n '1,80p' >&2 || true
        fi
        exit 1
    fi
}

run_batch_sentinels() {
    sentinel_compiler_label=$1
    sentinel_compiler=$2
    # Cover an ordinary imported source and the only staged-input case on each
    # compiler side. Both occur inside non-trivial chunks, so comparing them
    # with standalone outputs catches state or cache leakage without weakening
    # the ordinary opt1-vs-opt2 byte comparisons.
    for sentinel_name in integration_aggregate_globals integration_sym_i64_env; do
        run_batch_sentinel "$sentinel_compiler_label" "$sentinel_compiler" "$sentinel_name"
    done
}

pool_job_cap_mib() {
    if chunk_is_complete_codegen_smoke "$1"; then
        printf '%s\n' "$POOL_FULL_CAP_MIB"
    else
        printf '%s\n' "$POOL_CHUNK_CAP_MIB"
    fi
}

# The worker pool's job callback; see lib-build-invariance-batch.sh.
build_invariance_pool_run_job() {
    pool_job=$1
    pool_job_cap=$2
    # One private file per job keeps concurrent writers apart; the gate merges
    # them in queue order, so the published rows do not depend on scheduling.
    CHUNK_METRICS="$POOL_DIR/metrics/$pool_job.tsv"
    if ci_timing_enabled; then
        TYPELISP_CI_TIMING_FILE="$POOL_DIR/timing/$pool_job.tsv"
    fi
    if [ "$pool_job" = backend-tests ]; then
        check_backend_memory
        return 0
    fi
    pool_job_fields=$(awk -F'|' -v job="$pool_job" '
        $1 == job { print; found += 1 }
        END { exit found != 1 }
    ' "$POOL_JOBS") || {
        echo "[build-invariance] pool job has no chunk record: $pool_job" >&2
        exit 1
    }
    pool_job_ifs=$IFS
    IFS='|'
    # shellcheck disable=SC2086
    set -- $pool_job_fields
    IFS=$pool_job_ifs
    case "$2" in
        opt1-built) pool_job_compiler=$OPT1_COMPILER ;;
        opt2-built) pool_job_compiler=$OPT2_STAGE4 ;;
        *)
            echo "[build-invariance] pool job names no producer: $pool_job" >&2
            exit 1
            ;;
    esac
    pool_job_chunks="$WORKDIR/batches/$2/opt$3/chunks"
    run_batch_chunk "$2" "$pool_job_compiler" "$3" \
        "$pool_job_chunks/entries.$4.txt" "$pool_job_chunks/cases.$4.txt" \
        "$5" "$6" "$pool_job_cap"
}

# Publish the jobs' private rows in queue order. A passing gate requires every
# job's rows; a failing one still publishes what ran, for the timing artifact.
pool_merge_rows() {
    while IFS='|' read -r merge_job merge_cap; do
        for merge_kind in metrics timing; do
            merge_rows="$POOL_DIR/$merge_kind/$merge_job.tsv"
            case "$merge_kind" in
                metrics)
                    [ "$merge_job" != backend-tests ] || continue
                    merge_target=$CHUNK_METRICS
                    ;;
                timing)
                    ci_timing_enabled || continue
                    merge_target=$TYPELISP_CI_TIMING_FILE
                    ;;
            esac
            if [ -s "$merge_rows" ]; then
                cat "$merge_rows" >> "$merge_target"
            elif [ "$1" = required ]; then
                echo "[build-invariance] pool job published no $merge_kind rows: $merge_job" >&2
                exit 1
            fi
        done
    done < "$POOL_QUEUE"
}

# The gate's own failure must not leave compiles running behind it. Running
# jobs finish (each is bounded by its timeout); no further job starts.
pool_main_exit() {
    pool_main_status=$1
    if [ "$POOL_ACTIVE" -eq 1 ]; then
        POOL_ACTIVE=0
        echo "[build-invariance] stopping the worker pool after its running jobs" >&2
        build_invariance_pool_stop "$POOL_DIR"
        pool_merge_rows available
    fi
    exit "$pool_main_status"
}

run_batched_comparison() {
    left_batches="$WORKDIR/batches/opt1-built"
    right_batches="$WORKDIR/batches/opt2-built"
    build_invariance_require_coverage "$CORPUS" "$left_batches"
    build_invariance_require_coverage "$CORPUS" "$right_batches"
    left_chunk_count=$(find "$left_batches" -type f -name 'entries.*.txt' | wc -l | tr -d ' ')
    right_chunk_count=$(find "$right_batches" -type f -name 'entries.*.txt' | wc -l | tr -d ' ')
    if [ "$left_chunk_count" -eq 0 ] || [ "$left_chunk_count" -ne "$right_chunk_count" ]; then
        echo "[build-invariance] comparison compiler batch counts differ: opt1-built=$left_chunk_count opt2-built=$right_chunk_count" >&2
        exit 1
    fi

    POOL_QUEUE="$WORKDIR/pool-queue.txt"
    POOL_JOBS="$WORKDIR/pool-jobs.txt"
    POOL_PAIRS="$WORKDIR/pool-pairs.txt"
    printf 'backend-tests|%s\n' "$POOL_FULL_CAP_MIB" > "$POOL_QUEUE"
    : > "$POOL_JOBS"
    : > "$POOL_PAIRS"

    BATCH_CASE_COUNT=0
    batch_index=0
    exclusive_selfhost_count=0
    for opt_level in 1 2; do
        left_chunk_dir="$left_batches/opt$opt_level/chunks"
        right_chunk_dir="$right_batches/opt$opt_level/chunks"
        [ -d "$left_chunk_dir" ] || continue
        for left_chunk in "$left_chunk_dir"/entries.*.txt; do
            [ -f "$left_chunk" ] || continue
            chunk_id=$(basename "$left_chunk" | sed -e 's/^entries\.//' -e 's/\.txt$//')
            right_chunk="$right_chunk_dir/entries.$chunk_id.txt"
            left_cases="$left_chunk_dir/cases.$chunk_id.txt"
            right_cases="$right_chunk_dir/cases.$chunk_id.txt"
            if [ ! -f "$right_chunk" ] || [ ! -f "$left_cases" ] || [ ! -f "$right_cases" ]; then
                echo "[build-invariance] missing paired opt$opt_level batch chunk $chunk_id" >&2
                exit 1
            fi
            left_entries=$(wc -l < "$left_chunk" | tr -d ' ')
            right_entries=$(wc -l < "$right_chunk" | tr -d ' ')
            left_case_count=$(wc -l < "$left_cases" | tr -d ' ')
            right_case_count=$(wc -l < "$right_cases" | tr -d ' ')
            if [ "$left_entries" -eq 0 ] || [ "$left_entries" -ne "$right_entries" ] || [ "$left_case_count" -ne "$right_case_count" ]; then
                echo "[build-invariance] malformed paired opt$opt_level batch chunk $chunk_id" >&2
                exit 1
            fi

            batch_index=$((batch_index + 1))
            if chunk_is_timed_selfhost "$left_cases"; then
                # CI budgets the wall time of these four compiles, so they run
                # alone, before the pool starts, exactly as they always have.
                run_batch_chunk "opt1-built" "$OPT1_COMPILER" "$opt_level" "$left_chunk" "$left_cases" "$batch_index/$left_chunk_count" "$left_entries" ""
                run_batch_chunk "opt2-built" "$OPT2_STAGE4" "$opt_level" "$right_chunk" "$right_cases" "$batch_index/$left_chunk_count" "$right_entries" ""
                compare_batch_cases "$left_cases" "$LEFT_DIR" "$RIGHT_DIR"
                exclusive_selfhost_count=$((exclusive_selfhost_count + 1))
                continue
            fi
            left_job="opt1-built.opt$opt_level.$chunk_id"
            right_job="opt2-built.opt$opt_level.$chunk_id"
            printf '%s|%s\n' "$left_job" "$(pool_job_cap_mib "$left_cases")" >> "$POOL_QUEUE"
            printf '%s|%s\n' "$right_job" "$(pool_job_cap_mib "$right_cases")" >> "$POOL_QUEUE"
            printf '%s|opt1-built|%s|%s|%s|%s\n' "$left_job" "$opt_level" "$chunk_id" "$batch_index/$left_chunk_count" "$left_entries" >> "$POOL_JOBS"
            printf '%s|opt2-built|%s|%s|%s|%s\n' "$right_job" "$opt_level" "$chunk_id" "$batch_index/$left_chunk_count" "$right_entries" >> "$POOL_JOBS"
            printf '%s|%s|%s\n' "$left_job" "$right_job" "$left_cases" >> "$POOL_PAIRS"
        done
    done
    if [ "$exclusive_selfhost_count" -ne 2 ]; then
        echo "[build-invariance] expected the opt1 and opt2 selfhost chunks to run alone, got $exclusive_selfhost_count" >&2
        exit 1
    fi

    POOL_DIR="$WORKDIR/pool"
    build_invariance_pool_init "$POOL_DIR" "$POOL_BUDGET_MIB" "$POOL_QUEUE"
    mkdir -p "$POOL_DIR/metrics" "$POOL_DIR/timing" "$WORKDIR/backend-memory"
    pool_job_count=$(wc -l < "$POOL_QUEUE" | tr -d ' ')
    echo "[build-invariance] worker pool: $pool_job_count job(s), $POOL_WORKERS worker(s), $POOL_BUDGET_MIB MiB of enforced caps at once"
    pool_started=$(date +%s%3N)
    POOL_ACTIVE=1
    build_invariance_pool_start "$POOL_DIR" "$POOL_WORKERS"

    # Compare each chunk as soon as both producers have emitted it, so a
    # mismatch stops the gate without waiting for the rest of the corpus.
    while IFS='|' read -r pair_left_job pair_right_job pair_cases; do
        build_invariance_pool_wait_for "$POOL_DIR" "$pair_left_job" "$pair_right_job" || exit 1
        compare_batch_cases "$pair_cases" "$LEFT_DIR" "$RIGHT_DIR"
    done < "$POOL_PAIRS"
    build_invariance_pool_wait_for "$POOL_DIR" backend-tests || exit 1
    build_invariance_pool_join "$POOL_DIR" || exit 1
    POOL_ACTIVE=0
    pool_finished=$(date +%s%3N)

    pool_merge_rows required
    pool_serial_ms=$(awk -F '\t' '$6 + 0 > 0 { total += $1 } END { print total + 0 }' "$CHUNK_METRICS")
    echo "[build-invariance] worker pool: $((pool_finished - pool_started))ms wall for ${pool_serial_ms}ms of chunk compiles plus the backend-tests build"

    for required_report in backend-tests codegen-smoke; do
        if [ ! -s "$WORKDIR/backend-memory/$required_report.memory" ]; then
            echo "[build-invariance] missing complete-fixture memory report: $required_report" >&2
            exit 1
        fi
    done
    if [ "$batch_index" -ne "$left_chunk_count" ]; then
        echo "[build-invariance] planned $batch_index chunks, expected $left_chunk_count" >&2
        exit 1
    fi
    if [ "$BATCH_CASE_COUNT" -ne "$CORPUS_CASE_COUNT" ]; then
        echo "[build-invariance] compared $BATCH_CASE_COUNT cases, expected $CORPUS_CASE_COUNT" >&2
        exit 1
    fi
}

print_top_chunks() {
    echo "[build-invariance] top 5 compile chunks by elapsed time:"
    sort -t "$(printf '\t')" -k1,1nr -k2,2 -k3,3n -k4,4 "$CHUNK_METRICS" |
        sed -n '1,5p' |
        awk -F '\t' '{
            printf "[build-invariance]   %sms %s opt%s chunk %s (%s case(s), serial)\n", $1, $2, $3, $4, $5
        }'
    echo "[build-invariance] top 5 pooled chunks by peak memory:"
    sort -t "$(printf '\t')" -k6,6nr -k2,2 -k3,3n -k4,4 "$CHUNK_METRICS" |
        sed -n '1,5p' |
        awk -F '\t' '{
            printf "[build-invariance]   %d MiB %s opt%s chunk %s (%s case(s))\n", $6 / 1048576, $2, $3, $4, $5
        }'
}

echo "[build-invariance] incoming opt2-built stage4 compiler: $COMPILER"
SOURCE_INPUTS=src,stdlib,tests,scripts/check-build-invariance.sh,scripts/lib-build-invariance-batch.sh,scripts/lib-native-link.sh
SOURCE_DIGEST=$(ci_compiler_artifact_source_set_digest "$ROOT" "$SOURCE_INPUTS")
COMPILER_DIGEST=$(ci_compiler_artifact_sha256_file "$COMPILER")
construction_start=$(date +%s)
build_opt1_compiler
OPT1_COMPILER="$WORKDIR/opt1/opt1$NL_BIN_EXT"
OPT2_STAGE4="$COMPILER"
OPT1_DIGEST=$(ci_compiler_artifact_sha256_file "$OPT1_COMPILER")
construction_end=$(date +%s)
construction_seconds=$((construction_end - construction_start))
echo "[build-invariance] compiler construction: ${construction_seconds}s"

# The ownership regression reuses the compiler just built above: the pool runs
# the complete backend-tests build and the complete codegen smoke at opt2 under
# the fail-closed 8 GiB wrapper. No extra compiler build or reduced stress
# corpus is needed.

CORPUS="$WORKDIR/corpus.txt"
LEFT_DIR="$WORKDIR/compare/opt1-built"
RIGHT_DIR="$WORKDIR/compare/opt2-built"
write_corpus "$CORPUS"
rm -rf "$LEFT_DIR" "$RIGHT_DIR"
mkdir -p "$LEFT_DIR" "$RIGHT_DIR"

corpus_start=$(date +%s)
CORPUS_CASE_COUNT=$(awk -F'|' 'NF >= 3 && $1 != "" { count += 1 } END { print count + 0 }' "$CORPUS")
if [ "$CORPUS_CASE_COUNT" -eq 0 ]; then
    echo "[build-invariance] corpus is empty" >&2
    exit 1
fi
echo "[build-invariance] corpus: $CORPUS_CASE_COUNT case(s), serial batch size $BATCH_CHUNK_SIZE (maximum $BATCH_CHUNK_MAX)"
batch_setup_start=$(date +%s)
prepare_compile_batches "opt1-built" "$LEFT_DIR"
prepare_compile_batches "opt2-built" "$RIGHT_DIR"
batch_setup_end=$(date +%s)
batch_comparison_start=$batch_setup_end
POOL_ACTIVE=0
trap 'pool_main_exit $?' EXIT
# A signal takes the same path, so an interrupted gate also stops its workers.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
run_batched_comparison
batch_comparison_end=$(date +%s)
sentinel_start=$batch_comparison_end
run_batch_sentinels "opt1-built" "$OPT1_COMPILER"
run_batch_sentinels "opt2-built" "$OPT2_STAGE4"
sentinel_end=$(date +%s)
corpus_end=$(date +%s)
corpus_seconds=$((corpus_end - corpus_start))

if [ "$SOURCE_DIGEST" != "$(ci_compiler_artifact_source_set_digest "$ROOT" "$SOURCE_INPUTS")" ] ||
    [ "$COMPILER_DIGEST" != "$(ci_compiler_artifact_sha256_file "$COMPILER")" ] ||
    [ "$OPT1_DIGEST" != "$(ci_compiler_artifact_sha256_file "$OPT1_COMPILER")" ]; then
    echo "[build-invariance] source or compiler changed during comparison" >&2
    exit 1
fi

echo "[build-invariance] batch setup: $((batch_setup_end - batch_setup_start))s"
echo "[build-invariance] batched comparison: $((batch_comparison_end - batch_comparison_start))s"
echo "[build-invariance] standalone sentinels: $((sentinel_end - sentinel_start))s"
echo "[build-invariance] corpus comparison: ${corpus_seconds}s"
print_top_chunks
echo "build-invariance check passed for $BATCH_CASE_COUNT case(s)"

if [ -n "$HANDOFF_PATH_FILE" ]; then
    handoff_reference="$RIGHT_DIR/selfhost_main_opt1.s"
    if [ ! -s "$handoff_reference" ]; then
        echo "build-invariance validated opt1 reference is missing or empty: $handoff_reference" >&2
        exit 1
    fi
    handoff_dir=$(dirname "$HANDOFF_PATH_FILE")
    mkdir -p "$handoff_dir"
    handoff_tmp="$HANDOFF_PATH_FILE.tmp.$$"
    printf '%s\n' "$handoff_reference" > "$handoff_tmp"
    mv "$handoff_tmp" "$HANDOFF_PATH_FILE"
    echo "[build-invariance] published validated opt1 reference: $handoff_reference"
fi
