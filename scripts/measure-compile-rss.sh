#!/usr/bin/env sh
set -eu

# measure-compile-rss.sh - heavy compile peak-RSS harness (#4220).
#
# This script intentionally measures OS max RSS around real compiler
# invocations. It complements compile-profile allocator counters; it does not
# replace or mutate existing benchmark/profile outputs.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat <<'EOF'
usage: scripts/measure-compile-rss.sh [options] [typelisp-bin]

Options:
  --mode <single|manifest-chunk|manifest-full|heavy-batch|all>
                                      Workload(s) to run (default all).
  --input <file.tl>                   Single compile input (default src/doc_test.tl).
  --chunk-id <NNNN|N>                 Manifest chunk to run (default 0002).
  --manifest <path>                   Compile manifest (default src/compile_manifest.txt).
  --batch-size <N>                    Manifest chunk size (default 16; do not shrink for #3863).
  --target <target>                   Compile target (default linux-x86_64).
  --time-bin <path>                   GNU time binary (default /usr/bin/time).
  -h, --help                          Show this help.

Environment:
  TYPELISP_BIN                        Compiler when no argument is given.
  TYPELISP_COMPILE_RSS_OUT            Output root (default target/compile-rss).
  TYPELISP_COMPILE_RSS_MODE           Default --mode.
  TYPELISP_COMPILE_RSS_INPUT          Default --input.
  TYPELISP_COMPILE_RSS_CHUNK_ID       Default --chunk-id.
  TYPELISP_COMPILE_RSS_MANIFEST       Default --manifest.
  TYPELISP_COMPILE_RSS_BATCH_SIZE     Default --batch-size.
  TYPELISP_COMPILE_RSS_TARGET         Default --target.
  TYPELISP_COMPILE_RSS_TIME_BIN       Default --time-bin.

Outputs:
  target/compile-rss/measurements.tsv
  target/compile-rss/batch-profile.tsv
  target/compile-rss/**/{stdout,stderr,time,argv}.*
EOF
}

fail() {
    echo "[compile-rss] $*" >&2
    exit 1
}

show_logs() {
    stdout=$1
    stderr=$2
    if [ -s "$stdout" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
    fi
    if [ -s "$stderr" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
    fi
}

now_ms() {
    value=$(date +%s%3N 2>/dev/null || true)
    case "$value" in
        *[!0-9]* | "") ;;
        *) printf '%s\n' "$value"; return 0 ;;
    esac
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
}

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *) ;;
esac

MODE=${TYPELISP_COMPILE_RSS_MODE:-all}
INPUT=${TYPELISP_COMPILE_RSS_INPUT:-src/doc_test.tl}
CHUNK_ID=${TYPELISP_COMPILE_RSS_CHUNK_ID:-0002}
MANIFEST=${TYPELISP_COMPILE_RSS_MANIFEST:-src/compile_manifest.txt}
BATCH_SIZE=${TYPELISP_COMPILE_RSS_BATCH_SIZE:-16}
TARGET=${TYPELISP_COMPILE_RSS_TARGET:-linux-x86_64}
TIME_BIN=${TYPELISP_COMPILE_RSS_TIME_BIN:-/usr/bin/time}
WORKDIR=${TYPELISP_COMPILE_RSS_OUT:-"$ROOT/target/compile-rss"}
COMPILER=${TYPELISP_BIN:-}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --mode)
            [ "$#" -ge 2 ] || fail "--mode requires a value"
            MODE=$2
            shift 2
            ;;
        --input)
            [ "$#" -ge 2 ] || fail "--input requires a value"
            INPUT=$2
            shift 2
            ;;
        --chunk-id)
            [ "$#" -ge 2 ] || fail "--chunk-id requires a value"
            CHUNK_ID=$2
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || fail "--manifest requires a value"
            MANIFEST=$2
            shift 2
            ;;
        --batch-size)
            [ "$#" -ge 2 ] || fail "--batch-size requires a value"
            BATCH_SIZE=$2
            shift 2
            ;;
        --target)
            [ "$#" -ge 2 ] || fail "--target requires a value"
            TARGET=$2
            shift 2
            ;;
        --time-bin)
            [ "$#" -ge 2 ] || fail "--time-bin requires a value"
            TIME_BIN=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            fail "unknown option: $1"
            ;;
        *)
            [ -z "$COMPILER" ] || fail "unexpected extra argument: $1"
            COMPILER=$1
            shift
            ;;
    esac
done

if [ "$#" -gt 0 ]; then
    [ -z "$COMPILER" ] || fail "unexpected extra argument: $1"
    COMPILER=$1
    shift
fi
[ "$#" -eq 0 ] || fail "unexpected extra argument: $1"

case "$MODE" in
    single | manifest-chunk | manifest-full | heavy-batch | all) ;;
    *) fail "--mode must be single, manifest-chunk, manifest-full, heavy-batch, or all" ;;
esac

case "$BATCH_SIZE" in
    "" | *[!0-9]*) fail "--batch-size must be a positive integer" ;;
esac
[ "$BATCH_SIZE" -gt 0 ] || fail "--batch-size must be a positive integer"

case "$CHUNK_ID" in
    "" | *[!0-9]*) fail "--chunk-id must be numeric" ;;
esac
CHUNK_NUMBER=$(printf '%s\n' "$CHUNK_ID" | sed 's/^0*//')
[ -n "$CHUNK_NUMBER" ] || CHUNK_NUMBER=0
CHUNK_ID_PADDED=$(printf '%04d' "$CHUNK_NUMBER")

# With no explicit compiler, build an opt2 stage2 from the seed (unless
# TYPELISP_IR_SELF_STAGE2=0) so max-RSS numbers reflect the same
# register-allocated self-hosted compiler CI measures, not the older seed.
SELF_STAGE2=${TYPELISP_IR_SELF_STAGE2:-1}
BUILD_STAGE2_FROM_SEED=0
if [ -z "$COMPILER" ]; then
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    [ "$SELF_STAGE2" = 1 ] && BUILD_STAGE2_FROM_SEED=1
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || fail "typelisp compiler is not executable: $COMPILER"

if [ ! -x "$TIME_BIN" ]; then
    fail "GNU time is required for max RSS but is not executable: $TIME_BIN"
fi
if ! "$TIME_BIN" -v -o /dev/null true >/dev/null 2>&1; then
    fail "GNU time with -v support is required for max RSS: $TIME_BIN"
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

if [ "$BUILD_STAGE2_FROM_SEED" -eq 1 ]; then
    echo "[compile-rss] building opt2 stage2 from seed to match the CI self-compile compiler" >&2
    echo "[compile-rss]   (set TYPELISP_IR_SELF_STAGE2=0 to measure the raw seed instead)" >&2
    build_selfhost_stage2 "$ROOT" "$COMPILER" "$WORKDIR/stage2-compiler" || exit 1
    COMPILER=$(selfhost_stage2_path "$WORKDIR/stage2-compiler")
    [ -x "$COMPILER" ] || fail "stage2 compiler not executable after build: $COMPILER"
fi

MEASUREMENTS="$WORKDIR/measurements.tsv"
printf 'workload\tinput\tchunk_id\tchunk_ordinal\tchunk_count\tbatch_size\tentry_count\texit_code\telapsed_ms\tmax_rss_kb\tstdout\tstderr\ttime_log\targv_log\n' > "$MEASUREMENTS"
PROFILE_MEASUREMENTS="$WORKDIR/batch-profile.tsv"
printf 'workload\tentry_ordinal\tmarker\telapsed_ms\talloc_delta_bytes\tlive_delta_bytes\tpeak_live_delta_bytes\tlive_bytes\tentry0_baseline_delta_bytes\tmax_rss_kb\n' > "$PROFILE_MEASUREMENTS"

parse_max_rss_kb() {
    time_log=$1
    awk -F: '
        /Maximum resident set size/ {
            value = $2
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            print value
        }
    ' "$time_log" | tail -n 1
}

record_argv() {
    argv_log=$1
    shift
    {
        echo "# argv, one argument per line"
        for arg do
            printf '%s\n' "$arg"
        done
    } > "$argv_log"
}

run_measured() {
    workload=$1
    input_label=$2
    chunk_id=$3
    chunk_ordinal=$4
    chunk_count=$5
    batch_size=$6
    entry_count=$7
    outdir=$8
    shift 8

    mkdir -p "$outdir"
    stdout="$outdir/stdout.log"
    stderr="$outdir/stderr.log"
    time_log="$outdir/time.log"
    argv_log="$outdir/argv.log"
    record_argv "$argv_log" "$@"

    echo "[compile-rss] $workload"
    start=$(now_ms)
    set +e
    "$TIME_BIN" -v -o "$time_log" "$@" > "$stdout" 2> "$stderr"
    code=$?
    set -e
    end=$(now_ms)
    elapsed=$((end - start))
    max_rss=$(parse_max_rss_kb "$time_log")
    [ -n "$max_rss" ] || fail "could not parse max RSS from $time_log"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$workload" \
        "$input_label" \
        "$chunk_id" \
        "$chunk_ordinal" \
        "$chunk_count" \
        "$batch_size" \
        "$entry_count" \
        "$code" \
        "$elapsed" \
        "$max_rss" \
        "$stdout" \
        "$stderr" \
        "$time_log" \
        "$argv_log" >> "$MEASUREMENTS"

    echo "[compile-rss] $workload exit=$code elapsed_ms=$elapsed max_rss_kb=$max_rss"
    if [ "$code" -ne 0 ]; then
        show_logs "$stdout" "$stderr"
        fail "$workload exited $code"
    fi
    awk -F'|' -v workload="$workload" -v rss="$max_rss" '
        $1 == "compile-batch-profile" && $2 ~ /^[0-9]+$/ {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                workload, $2, $3, $4, $5, $6, $7, $8, $9, rss
        }
    ' "$stderr" >> "$PROFILE_MEASUREMENTS"
}

manifest_path() {
    path=$1
    case "$path" in
        /* | [A-Za-z]:[/\\]*) printf '%s\n' "$path" ;;
        *) printf '%s/%s\n' "$ROOT" "$path" ;;
    esac
}

compiler_batch_path() {
    path=$1
    if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
    else
        printf '%s\n' "$path"
    fi
}

prepare_manifest_chunks() {
    manifest_abs=$(manifest_path "$MANIFEST")
    [ -f "$manifest_abs" ] || fail "compile manifest does not exist: $manifest_abs"

    manifest_dir="$WORKDIR/manifest"
    normalized="$manifest_dir/compile-manifest.normalized.txt"
    batch_input="$manifest_dir/compile-batch.txt"
    chunk_dir="$manifest_dir/compile-batch-chunks"
    rm -rf "$manifest_dir"
    mkdir -p "$chunk_dir"
    tr -d '\r' < "$manifest_abs" > "$normalized"
    : > "$batch_input"

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
                prep_case_dir="$manifest_dir/$prep_case_id"
                rm -rf "$prep_case_dir"
                mkdir -p "$prep_case_dir"
                if [ "$prep_case_mode" = "stage" ]; then
                    cp "$prep_case_source" "$prep_case_dir/$(basename "$prep_case_source")"
                fi
                prep_requires_stage0_mode=
                ;;
            requires-stage0-symbol) ;;
            requires-stage0-mode)
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
                if [ -n "$prep_requires_stage0_mode" ]; then
                    echo "[compile-rss] keeping stage0-only manifest case $prep_case_id: $prep_requires_stage0_mode" >&2
                fi
                if [ "$prep_case_mode" = "stage" ]; then
                    prep_compile_source="$prep_case_dir/$(basename "$prep_case_source")"
                else
                    prep_compile_source="$ROOT/$prep_case_source"
                fi
                printf '%s|%s\n' \
                    "$(compiler_batch_path "$prep_compile_source")" \
                    "$(compiler_batch_path "$prep_case_dir/$prep_case_id.s")" >> "$batch_input"
                prep_case_id=
                ;;
            *)
                fail "unknown manifest directive: $kind"
                ;;
        esac
    done < "$normalized"

    [ -z "$prep_case_id" ] || fail "manifest ended before case $prep_case_id had an end directive"

    awk -v outdir="$chunk_dir" -v size="$BATCH_SIZE" '
        {
            chunk = int((NR - 1) / size)
            path = sprintf("%s/compile-batch.%04d.txt", outdir, chunk)
            print $0 >> path
            if (NR % size == 0) {
                close(path)
            }
        }
    ' "$batch_input"
}

run_single() {
    input_abs=$(manifest_path "$INPUT")
    [ -f "$input_abs" ] || fail "single compile input does not exist: $input_abs"
    run_measured \
        single \
        "$INPUT" \
        - \
        - \
        - \
        - \
        1 \
        "$WORKDIR/single" \
        "$COMPILER" compile "$INPUT" \
            -o "$WORKDIR/single/doc-test.s" \
            --target "$TARGET" \
            --stdlib-root "$ROOT/stdlib" \
            --stdlib-root "$ROOT/src"
}

run_manifest_chunk() {
    prepare_manifest_chunks
    chunk_dir="$WORKDIR/manifest/compile-batch-chunks"
    chunk_file="$chunk_dir/compile-batch.$CHUNK_ID_PADDED.txt"
    [ -f "$chunk_file" ] || fail "manifest chunk does not exist: $chunk_file"
    chunk_count=$(find "$chunk_dir" -type f -name 'compile-batch.*.txt' | wc -l | tr -d ' ')
    entry_count=$(wc -l < "$chunk_file" | tr -d ' ')
    chunk_ordinal=$((CHUNK_NUMBER + 1))
    run_measured \
        manifest-chunk \
        "$chunk_file" \
        "$CHUNK_ID_PADDED" \
        "$chunk_ordinal" \
        "$chunk_count" \
        "$BATCH_SIZE" \
        "$entry_count" \
        "$WORKDIR/manifest/chunk-$CHUNK_ID_PADDED" \
        "$COMPILER" compile --batch "$chunk_file" \
            --target "$TARGET" \
            --cfg selfhost-compile-manifest \
            --stdlib-root "$ROOT/stdlib"
}

verify_batch_single_parity() {
    list=$1
    label=$2
    cfg_name=${3:-}
    parity_dir="$WORKDIR/$label/single-parity"
    rm -rf "$parity_dir"
    mkdir -p "$parity_dir"
    ordinal=0
    while IFS='|' read -r input output; do
        [ -n "$input" ] || continue
        single="$parity_dir/$(printf '%04d' "$ordinal").s"
        if [ -n "$cfg_name" ]; then
            "$COMPILER" compile "$input" -o "$single" \
                --target "$TARGET" \
                --cfg "$cfg_name" \
                --stdlib-root "$ROOT/stdlib" \
                --stdlib-root "$ROOT/src" \
                > "$parity_dir/$(printf '%04d' "$ordinal").stdout" \
                2> "$parity_dir/$(printf '%04d' "$ordinal").stderr" ||
                fail "$label one-entry compile failed at ordinal $ordinal"
        else
            "$COMPILER" compile "$input" -o "$single" \
                --target "$TARGET" \
                --stdlib-root "$ROOT/stdlib" \
                --stdlib-root "$ROOT/src" \
                > "$parity_dir/$(printf '%04d' "$ordinal").stdout" \
                2> "$parity_dir/$(printf '%04d' "$ordinal").stderr" ||
                fail "$label one-entry compile failed at ordinal $ordinal"
        fi
        cmp "$output" "$single" >/dev/null ||
            fail "$label batch assembly differs from one-entry output at ordinal $ordinal"
        ordinal=$((ordinal + 1))
    done < "$list"
    echo "[compile-rss] $label batch/single assembly parity passed for $ordinal entries"
}

run_manifest_full() {
    prepare_manifest_chunks
    batch_input="$WORKDIR/manifest/compile-batch.txt"
    entry_count=$(wc -l < "$batch_input" | tr -d ' ')
    run_measured \
        manifest-full \
        "$batch_input" \
        all \
        1 \
        1 \
        "$entry_count" \
        "$entry_count" \
        "$WORKDIR/manifest/full" \
        "$COMPILER" compile --batch "$batch_input" \
            --target "$TARGET" \
            --cfg selfhost-compile-manifest \
            --stdlib-root "$ROOT/stdlib"
    verify_batch_single_parity \
        "$batch_input" \
        "manifest/full" \
        selfhost-compile-manifest
}

run_heavy_batch() {
    heavy_dir="$WORKDIR/heavy"
    heavy_list="$heavy_dir/compile-batch.txt"
    rm -rf "$heavy_dir"
    mkdir -p "$heavy_dir/outputs"
    : > "$heavy_list"
    while IFS='|' read -r case_id source; do
        [ -n "$case_id" ] || continue
        printf '%s|%s\n' \
            "$(compiler_batch_path "$ROOT/$source")" \
            "$(compiler_batch_path "$heavy_dir/outputs/$case_id.s")" >> "$heavy_list"
    done <<EOF
$(scripts/measure-heavy-closure-profile.sh --list)
EOF
    entry_count=$(wc -l < "$heavy_list" | tr -d ' ')
    [ "$entry_count" -gt 0 ] || fail "heavy batch source list is empty"
    run_measured \
        heavy-batch \
        "$heavy_list" \
        - \
        - \
        - \
        "$entry_count" \
        "$entry_count" \
        "$heavy_dir/run" \
        "$COMPILER" compile --batch "$heavy_list" \
            --target "$TARGET" \
            --stdlib-root "$ROOT/stdlib" \
            --stdlib-root "$ROOT/src"
    verify_batch_single_parity "$heavy_list" "heavy"
}

case "$MODE" in
    single)
        run_single
        ;;
    manifest-chunk)
        run_manifest_chunk
        ;;
    manifest-full)
        run_manifest_full
        ;;
    heavy-batch)
        run_heavy_batch
        ;;
    all)
        run_single
        run_manifest_chunk
        ;;
esac

echo "[compile-rss] wrote $MEASUREMENTS"
