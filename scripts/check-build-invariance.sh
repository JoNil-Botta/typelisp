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

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-build-invariance.sh

Requires TYPELISP_BIN to point at CI's converged Linux opt2-built stage4
compiler. Builds one opt1 compiler from src/main.tl, then compares emitted
assembly for a fixed corpus.
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
# Whole-compiler smoke sources dominate their process, so keep those as
# singleton batches instead of carrying an already-large process high-water
# mark into another compile.
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
        function heavy(source) {
            return source ~ /^src\/tests\/compiler_[^/]*\.tl$/
        }
        function finish_chunk() {
            if (chunk_entries > 0) {
                close(entries_path)
                close(cases_path)
                chunk_index += 1
                chunk_entries = 0
            }
        }
        function start_chunk() {
            suffix = sprintf("%04d", chunk_index)
            entries_path = chunk_dir "/entries." suffix ".txt"
            cases_path = chunk_dir "/cases." suffix ".txt"
        }
        $1 != "" {
            if (heavy($2) && chunk_entries > 0) {
                finish_chunk()
            }
            if (chunk_entries == 0) {
                start_chunk()
            }
            print $3 "|" $4 >> entries_path
            print $0 >> cases_path
            chunk_entries += 1
            if (heavy($2) || chunk_entries >= chunk_size) {
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

run_batch_chunk() {
    batch_compiler_label=$1
    batch_compiler=$2
    batch_opt_level=$3
    batch_chunk_path=$4
    batch_case_chunk=$5
    batch_id=$6
    batch_entries=$7
    batch_label="build-invariance $batch_compiler_label opt$batch_opt_level chunk $batch_id ($batch_entries case(s), serial)"

    batch_stdout="${batch_chunk_path%.txt}.stdout"
    batch_stderr="${batch_chunk_path%.txt}.stderr"
    batch_started=$(date +%s%3N)
    echo "[build-invariance] $batch_label"
    if ! ci_timing_run "$batch_compiler_label:opt$batch_opt_level:chunk$batch_id" compile \
        run_with_heartbeat_capture \
        "$batch_label" \
        "$batch_stdout" \
        "$batch_stderr" \
        "$batch_compiler" compile --batch "$batch_chunk_path" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --backend-mode scalar \
        --opt-level "$batch_opt_level" \
        --stdlib-root stdlib \
        --stdlib-root src; then
        print_log_pair "$batch_label failed" "$batch_stdout" "$batch_stderr"
        echo "[build-invariance] $batch_label cases:" >&2
        print_batch_cases "$batch_case_chunk"
        exit 1
    fi
    verify_batch_outputs "$batch_compiler_label" "$batch_case_chunk" "$batch_stdout" "$batch_stderr"
    batch_finished=$(date +%s%3N)
    batch_elapsed_ms=$((batch_finished - batch_started))
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$batch_elapsed_ms" "$batch_compiler_label" "$batch_opt_level" "$batch_id" "$batch_entries" >> "$CHUNK_METRICS"
    echo "[build-invariance] $batch_label elapsed_ms=$batch_elapsed_ms"
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

run_batched_comparison() {
    left_batches="$WORKDIR/batches/opt1-built"
    right_batches="$WORKDIR/batches/opt2-built"
    left_chunk_count=$(find "$left_batches" -type f -name 'entries.*.txt' | wc -l | tr -d ' ')
    right_chunk_count=$(find "$right_batches" -type f -name 'entries.*.txt' | wc -l | tr -d ' ')
    if [ "$left_chunk_count" -eq 0 ] || [ "$left_chunk_count" -ne "$right_chunk_count" ]; then
        echo "[build-invariance] comparison compiler batch counts differ: opt1-built=$left_chunk_count opt2-built=$right_chunk_count" >&2
        exit 1
    fi

    BATCH_CASE_COUNT=0
    batch_index=0
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
            if [ "$left_entries" -ne "$right_entries" ] || [ "$left_entries" -ne "$left_case_count" ] || [ "$left_entries" -ne "$right_case_count" ]; then
                echo "[build-invariance] malformed paired opt$opt_level batch chunk $chunk_id" >&2
                exit 1
            fi

            batch_index=$((batch_index + 1))
            run_batch_chunk "opt1-built" "$OPT1_COMPILER" "$opt_level" "$left_chunk" "$left_cases" "$batch_index/$left_chunk_count" "$left_entries"
            run_batch_chunk "opt2-built" "$OPT2_STAGE4" "$opt_level" "$right_chunk" "$right_cases" "$batch_index/$left_chunk_count" "$right_entries"
            compare_batch_cases "$left_cases" "$LEFT_DIR" "$RIGHT_DIR"
        done
    done

    if [ "$batch_index" -ne "$left_chunk_count" ]; then
        echo "[build-invariance] ran $batch_index chunks, expected $left_chunk_count" >&2
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
}

echo "[build-invariance] incoming opt2-built stage4 compiler: $COMPILER"
construction_start=$(date +%s)
build_opt1_compiler
OPT1_COMPILER="$WORKDIR/opt1/opt1$NL_BIN_EXT"
OPT2_STAGE4="$COMPILER"
construction_end=$(date +%s)
construction_seconds=$((construction_end - construction_start))
echo "[build-invariance] compiler construction: ${construction_seconds}s"

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
run_batched_comparison
batch_comparison_end=$(date +%s)
sentinel_start=$batch_comparison_end
run_batch_sentinels "opt1-built" "$OPT1_COMPILER"
run_batch_sentinels "opt2-built" "$OPT2_STAGE4"
sentinel_end=$(date +%s)
corpus_end=$(date +%s)
corpus_seconds=$((corpus_end - corpus_start))

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
