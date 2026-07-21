#!/usr/bin/env sh
set -eu

# measure-result-import-cost.sh - paired #3903 generated result import cost.
#
# This is a diagnostic harness, not a CI gate. It measures one compiler binary
# compiling scratch copies of the selfhost CLI source:
#   base:          src/*.tl unchanged
#   format_tokens: src/format_tokens.tl imports unused (result.result i64 FormatSourceError)
#   lex:           src/lex.tl imports unused (result.result i64 String)
#   compiler_ctfe: src/compiler_ctfe.tl imports unused (result.result (Tuple i64 i64) (Box CompilerDiagnostic))
#
# The scratch sources live under target/ by default and tracked src/*.tl files
# are never edited. Use this before and after generated-result import
# throughput work for #3903/#3215.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

RUNS=${TYPELISP_RESULT_IMPORT_RUNS:-1}
WORKDIR=${TYPELISP_RESULT_IMPORT_OUT:-target/result-import-cost}
OPT_LEVEL=${TYPELISP_RESULT_IMPORT_OPT_LEVEL:-1}
RUN_PROFILE=${TYPELISP_RESULT_IMPORT_PROFILE:-0}
PROFILE_ONLY=0
PREPARE_ONLY=0
SEED_ARG=
VARIANTS="format_tokens lex compiler_ctfe"

usage() {
    cat <<'EOF'
usage: scripts/measure-result-import-cost.sh [options] [typelisp-compiler]

Options:
  --runs N           Cachegrind runs for each source variant (default: 1)
  --output DIR       Output root (default: target/result-import-cost)
  --opt-level N      Self-compile opt level 0, 1, or 2 (default: 1)
  --profile          Also build a compile-profile CLI and print phase/counter deltas
  --profile-only     Run only the compile-profile phase comparison
  --prepare-only     Create scratch source trees, then exit
  -h, --help         Show this help

Environment:
  TYPELISP_BIN                    Compiler when no argument is given
  TYPELISP_RESULT_IMPORT_RUNS     Default --runs
  TYPELISP_RESULT_IMPORT_OUT      Default --output
  TYPELISP_RESULT_IMPORT_OPT_LEVEL
                                    Default --opt-level
  TYPELISP_RESULT_IMPORT_PROFILE  Set to 1 to enable --profile by default
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --runs)
            [ "$#" -ge 2 ] || {
                echo "missing value for --runs" >&2
                exit 2
            }
            RUNS=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || {
                echo "missing value for --output" >&2
                exit 2
            }
            WORKDIR=$2
            shift 2
            ;;
        --opt-level)
            [ "$#" -ge 2 ] || {
                echo "missing value for --opt-level" >&2
                exit 2
            }
            OPT_LEVEL=$2
            shift 2
            ;;
        --profile)
            RUN_PROFILE=1
            shift
            ;;
        --profile-only)
            RUN_PROFILE=1
            PROFILE_ONLY=1
            shift
            ;;
        --prepare-only)
            PREPARE_ONLY=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$SEED_ARG" ]; then
                echo "only one typelisp compiler may be provided" >&2
                exit 2
            fi
            SEED_ARG=$1
            shift
            ;;
    esac
done

case "$RUNS" in
    "" | *[!0-9]* | 0)
        echo "--runs must be a positive integer: $RUNS" >&2
        exit 2
        ;;
esac

case "$OPT_LEVEL" in
    0 | 1 | 2) ;;
    *)
        echo "--opt-level must be 0, 1, or 2: $OPT_LEVEL" >&2
        exit 2
        ;;
esac

case "$RUN_PROFILE" in
    0 | 1) ;;
    *)
        echo "TYPELISP_RESULT_IMPORT_PROFILE must be 0 or 1: $RUN_PROFILE" >&2
        exit 2
        ;;
esac

case "$WORKDIR" in
    "" | / | . | ..)
        echo "unsafe --output path: $WORKDIR" >&2
        exit 2
        ;;
esac

fail() {
    echo "[result-import-cost] $*" >&2
    exit 1
}

preserve_missing_final_newline() {
    original_file=$1
    transformed_file=$2
    original_bytes=$(wc -c < "$original_file" | tr -d '[:space:]')
    [ "$original_bytes" -gt 0 ] || return 0

    original_last_byte=$(tail -c 1 "$original_file" |
        od -An -t x1 | tr -d '[:space:]')
    [ "$original_last_byte" != 0a ] || return 0

    transformed_bytes=$(wc -c < "$transformed_file" | tr -d '[:space:]')
    [ "$transformed_bytes" -gt 0 ] || return 1
    without_final_newline="$transformed_file.no-final-newline"
    if ! head -c $((transformed_bytes - 1)) "$transformed_file" > "$without_final_newline"; then
        rm -f "$without_final_newline"
        return 1
    fi
    mv "$without_final_newline" "$transformed_file"
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

copy_src_tree() {
    dst=$1
    mkdir -p "$dst"
    for src_file in src/*.tl; do
        [ -f "$src_file" ] || continue
        cp "$src_file" "$dst/"
    done
}

insert_after_last_import() {
    file=$1
    line=$2
    tmp_file=$file.tmp
    awk -v line="$line" '
        /^\(import / && inserted == 0 {
            pending = pending $0 "\n"
            next
        }
        pending != "" && inserted == 0 {
            printf "%s", pending
            print line
            pending = ""
            inserted = 1
        }
        { print }
        END {
            if (pending != "") {
                printf "%s", pending
                if (inserted == 0) {
                    print line
                    inserted = 1
                }
            }
            if (inserted == 0) {
                print line
            }
        }
    ' "$file" > "$tmp_file"
    preserve_missing_final_newline "$file" "$tmp_file" || {
        rm -f "$tmp_file"
        fail "could not preserve final newline state for $file"
    }
    mv "$tmp_file" "$file"
}

ensure_import_after_last_import() {
    file=$1
    line=$2
    if grep -F -x -- "$line" "$file" >/dev/null 2>&1; then
        return
    fi
    insert_after_last_import "$file" "$line"
}

insert_after_exact_line() {
    file=$1
    anchor=$2
    line=$3
    tmp_file=$file.tmp
    awk -v anchor="$anchor" -v line="$line" '
        {
            print
            if ($0 == anchor && inserted == 0) {
                print line
                inserted = 1
            }
        }
        END {
            if (inserted == 0) {
                exit 1
            }
        }
    ' "$file" > "$tmp_file" || {
        rm -f "$tmp_file"
        fail "anchor not found in $file: $anchor"
    }
    preserve_missing_final_newline "$file" "$tmp_file" || {
        rm -f "$tmp_file"
        fail "could not preserve final newline state for $file"
    }
    mv "$tmp_file" "$file"
}

prepare_variant() {
    name=$1
    dst="$WORKDIR/$name/src"
    copy_src_tree "$dst"
    case "$name" in
        format_tokens)
            file="$dst/format_tokens.tl"
            ensure_import_after_last_import "$file" "(import stdlib.result)"
            insert_after_exact_line \
                "$file" \
                "  (span FormatSourceSpan))" \
                "(import (result.result i64 FormatSourceError) as result_fmt_i64_unused)"
            ;;
        lex)
            file="$dst/lex.tl"
            ensure_import_after_last_import "$file" "(import stdlib.result)"
            insert_after_last_import "$file" "(import (result.result i64 String) as result_lex_i64_unused)"
            ;;
        compiler_ctfe)
            file="$dst/compiler_ctfe.tl"
            ensure_import_after_last_import "$file" "(import stdlib.result)"
            insert_after_last_import \
                "$file" \
                "(import (result.result (Tuple i64 i64) (Box CompilerDiagnostic)) as result_ctfe_i64_arg_unused)"
            ;;
        *)
            fail "unknown variant: $name"
            ;;
    esac
}

variant_source() {
    case "$1" in
        format_tokens) printf '%s\n' "src/format_tokens.tl" ;;
        lex) printf '%s\n' "src/lex.tl" ;;
        compiler_ctfe) printf '%s\n' "src/compiler_ctfe.tl" ;;
        *) fail "unknown variant: $1" ;;
    esac
}

variant_import() {
    case "$1" in
        format_tokens) printf '%s\n' "(result.result i64 FormatSourceError)" ;;
        lex) printf '%s\n' "(result.result i64 String)" ;;
        compiler_ctfe) printf '%s\n' "(result.result (Tuple i64 i64) (Box CompilerDiagnostic))" ;;
        *) fail "unknown variant: $1" ;;
    esac
}

variant_import_line() {
    case "$1" in
        format_tokens)
            printf '%s\n' "(import (result.result i64 FormatSourceError) as result_fmt_i64_unused)"
            ;;
        lex)
            printf '%s\n' "(import (result.result i64 String) as result_lex_i64_unused)"
            ;;
        compiler_ctfe)
            printf '%s\n' "(import (result.result (Tuple i64 i64) (Box CompilerDiagnostic)) as result_ctfe_i64_arg_unused)"
            ;;
        *) fail "unknown variant: $1" ;;
    esac
}

count_exact_line() {
    count_file=$1
    count_line=$2
    awk -v line="$count_line" '
        $0 == line { count = count + 1 }
        END { print count + 0 }
    ' "$count_file"
}

first_exact_line() {
    first_file=$1
    first_line=$2
    awk -v line="$first_line" '
        $0 == line {
            print NR
            exit
        }
    ' "$first_file"
}

first_line_containing() {
    containing_file=$1
    containing_text=$2
    awk -v text="$containing_text" '
        index($0, text) != 0 {
            print NR
            exit
        }
    ' "$containing_file"
}

show_prepared_difference() {
    expected=$1
    actual=$2
    if command -v diff >/dev/null 2>&1; then
        diff -u "$expected" "$actual" | sed -n '1,200p' >&2 || true
    else
        cmp -l "$expected" "$actual" | sed -n '1,80p' >&2 || true
    fi
}

filter_prepared_injections() {
    source_file=$1
    output_file=$2
    stdlib_import=$3
    drop_stdlib_import=$4
    synthetic_import=$5
    awk \
        -v stdlib_import="$stdlib_import" \
        -v drop_stdlib_import="$drop_stdlib_import" \
        -v synthetic_import="$synthetic_import" '
        $0 == synthetic_import {
            synthetic_count = synthetic_count + 1
            next
        }
        drop_stdlib_import == 1 && $0 == stdlib_import {
            stdlib_count = stdlib_count + 1
            next
        }
        { print }
        END {
            if (synthetic_count != 1) {
                exit 1
            }
            if (drop_stdlib_import == 1 && stdlib_count != 1) {
                exit 1
            }
        }
    ' "$source_file" > "$output_file" || return 1
    preserve_missing_final_newline "$source_file" "$output_file"
}

verify_compiler_ctfe_import_order() {
    base_file=$1
    variant_file=$2
    ctfe_import=$(awk '
        /^\(import \(result[.]result .* as result_ctfe_i64_arg\)$/ {
            print
            exit
        }
    ' "$base_file")
    [ -n "$ctfe_import" ] || fail "compiler_ctfe base source has no result_ctfe_i64_arg import"
    ctfe_import_line=$(first_exact_line "$variant_file" "$ctfe_import")
    ctfe_first_use=$(first_line_containing "$variant_file" "result_ctfe_i64_arg.")
    [ -n "$ctfe_import_line" ] || fail "compiler_ctfe variant lost result_ctfe_i64_arg import"
    [ -n "$ctfe_first_use" ] || fail "compiler_ctfe variant has no result_ctfe_i64_arg qualified use"
    if [ "$ctfe_import_line" -ge "$ctfe_first_use" ]; then
        fail "compiler_ctfe variant moved result_ctfe_i64_arg import after its first qualified use"
    fi
}

verify_prepared_variant() {
    name=$1
    source=$(variant_source "$name")
    source_name=${source##*/}
    base_dir="$WORKDIR/base/src"
    variant_dir="$WORKDIR/$name/src"
    base_file="$base_dir/$source_name"
    variant_file="$variant_dir/$source_name"
    stdlib_import="(import stdlib.result)"
    synthetic_import=$(variant_import_line "$name")

    [ -f "$base_file" ] || fail "base source is missing $source"
    [ -f "$variant_file" ] || fail "$name source is missing $source"
    base_stdlib_count=$(count_exact_line "$base_file" "$stdlib_import")
    variant_stdlib_count=$(count_exact_line "$variant_file" "$stdlib_import")
    base_synthetic_count=$(count_exact_line "$base_file" "$synthetic_import")
    variant_synthetic_count=$(count_exact_line "$variant_file" "$synthetic_import")
    drop_stdlib_import=0

    [ "$base_synthetic_count" -eq 0 ] || fail "base $source already contains the synthetic $name import"
    [ "$variant_synthetic_count" -eq 1 ] || fail "$name must contain exactly one synthetic import"

    if [ "$base_stdlib_count" -eq 0 ]; then
        [ "$variant_stdlib_count" -eq 1 ] || fail "$name must add exactly one stdlib.result import"
        drop_stdlib_import=1
    elif [ "$variant_stdlib_count" -ne "$base_stdlib_count" ]; then
        fail "$name changed the number of stdlib.result imports"
    fi

    for base_candidate in "$base_dir"/*.tl; do
        [ -f "$base_candidate" ] || continue
        candidate_name=${base_candidate##*/}
        variant_candidate="$variant_dir/$candidate_name"
        [ -f "$variant_candidate" ] || fail "$name is missing copied source $candidate_name"
        if [ "$candidate_name" != "$source_name" ] && ! cmp -s "$base_candidate" "$variant_candidate"; then
            echo "[result-import-cost] unexpected $name change in $candidate_name" >&2
            show_prepared_difference "$base_candidate" "$variant_candidate"
            fail "$name changed a source outside $source"
        fi
    done
    for variant_candidate in "$variant_dir"/*.tl; do
        [ -f "$variant_candidate" ] || continue
        candidate_name=${variant_candidate##*/}
        [ -f "$base_dir/$candidate_name" ] || fail "$name added unexpected source $candidate_name"
    done

    filtered="$WORKDIR/logs/$name.source-without-injections.tl"
    if ! filter_prepared_injections \
        "$variant_file" \
        "$filtered" \
        "$stdlib_import" \
        "$drop_stdlib_import" \
        "$synthetic_import"; then
        fail "$name did not contain exactly the expected injected imports"
    fi
    if ! cmp -s "$base_file" "$filtered"; then
        echo "[result-import-cost] prepared $name differs from base beyond injected imports" >&2
        show_prepared_difference "$base_file" "$filtered"
        fail "$name source preparation changed existing declarations"
    fi

    if [ "$name" = compiler_ctfe ]; then
        verify_compiler_ctfe_import_order "$base_file" "$variant_file"
    fi
}

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/logs"
copy_src_tree "$WORKDIR/base/src"
for variant in $VARIANTS; do
    prepare_variant "$variant"
    verify_prepared_variant "$variant"
done

VARIANTS_TSV="$WORKDIR/variants.tsv"
{
    printf 'case\tsource\tinjected_import\n'
    printf 'base\t-\t-\n'
    for variant in $VARIANTS; do
        printf '%s\t%s\t%s\n' "$variant" "$(variant_source "$variant")" "$(variant_import "$variant")"
    done
} > "$VARIANTS_TSV"

if [ "$PREPARE_ONLY" -eq 1 ]; then
    echo "[result-import-cost] prepared base source: $WORKDIR/base/src/main.tl"
    for variant in $VARIANTS; do
        echo "[result-import-cost] prepared $variant source: $WORKDIR/$variant/src/main.tl"
    done
    echo "[result-import-cost] variants: $VARIANTS_TSV"
    cat "$VARIANTS_TSV"
    exit 0
fi

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

if [ -n "$SEED_ARG" ]; then
    COMPILER=$SEED_ARG
elif [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

[ -x "$COMPILER" ] || fail "typelisp compiler is not executable: $COMPILER"

compile_args() {
    srcdir=$1
    asm=$2
    printf '%s\n' \
        compile "$srcdir/main.tl" \
        -o "$asm" \
        --target "$NL_BOOTSTRAP_TARGET"
    native_target_cfg_args
    printf '%s\n' \
        --stdlib-root stdlib \
        --stdlib-root "$srcdir" \
        --opt-level "$OPT_LEVEL"
}

cachegrind_ir() {
    awk '
        /^events:/ {
            ir_col = 0
            for (i = 2; i <= NF; i++) {
                if ($i == "Ir") {
                    ir_col = i - 1
                }
            }
        }
        /^summary:/ && ir_col > 0 {
            value = $(ir_col + 1)
            gsub(/,/, "", value)
            print value
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$1"
}

RUNS_TSV="$WORKDIR/runs.tsv"
printf 'case\trun\tir_count\texit_status\n' > "$RUNS_TSV"

run_cachegrind_case() {
    name=$1
    srcdir=$2
    run=$3
    asm="$WORKDIR/$name/main.opt$OPT_LEVEL.s"
    cgout="$WORKDIR/logs/$name-$run.cachegrind.out"
    stdout="$WORKDIR/logs/$name-$run.stdout"
    stderr="$WORKDIR/logs/$name-$run.stderr"
    mkdir -p "$WORKDIR/$name"

    echo "[result-import-cost] cachegrind $name run $run"
    set +e
    env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C "$VALGRIND" \
        --quiet --tool=cachegrind --cachegrind-out-file="$cgout" \
        "$COMPILER" $(compile_args "$srcdir" "$asm") \
        > "$stdout" 2> "$stderr"
    status=$?
    set -e

    if [ "$status" -ne 0 ]; then
        show_logs "$stdout" "$stderr"
        fail "$name run $run exited $status"
    fi
    [ -s "$asm" ] || fail "$name run $run did not write assembly: $asm"
    [ -s "$cgout" ] || fail "$name run $run did not write cachegrind output"

    ir=$(cachegrind_ir "$cgout") || fail "could not parse Ir from $cgout"
    case "$ir" in
        "" | *[!0-9]*) fail "parsed non-numeric Ir for $name run $run: $ir" ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$run" "$ir" "$status" >> "$RUNS_TSV"
    LAST_IR=$ir
}

measure_case() {
    name=$1
    srcdir=$2
    first=
    min=
    max=
    run=1
    while [ "$run" -le "$RUNS" ]; do
        run_cachegrind_case "$name" "$srcdir" "$run"
        if [ -z "$first" ]; then
            first=$LAST_IR
            min=$LAST_IR
            max=$LAST_IR
        else
            if [ "$LAST_IR" -lt "$min" ]; then min=$LAST_IR; fi
            if [ "$LAST_IR" -gt "$max" ]; then max=$LAST_IR; fi
        fi
        run=$((run + 1))
    done
    if [ "$min" != "$max" ]; then
        fail "$name Ir was not stable across $RUNS runs: min=$min max=$max"
    fi
    LAST_CASE_IR=$first
}

signed_delta() {
    value=$1
    if [ "$value" -gt 0 ]; then
        printf '+%s' "$value"
    else
        printf '%s' "$value"
    fi
}

pct_delta() {
    base=$1
    delta=$2
    awk -v base="$base" -v delta="$delta" 'BEGIN {
        if (base == 0) {
            print "n/a"
        } else {
            printf "%+.6f%%\n", (delta * 100.0) / base
        }
    }'
}

if [ "$PROFILE_ONLY" -eq 0 ]; then
    IR_AVAILABLE=1
    case "$(uname -s)" in
        Linux*) ;;
        *)
            echo "[result-import-cost] instruction-count measurement is Linux-only; use WSL or --profile-only"
            IR_AVAILABLE=0
            ;;
    esac
    if [ "$IR_AVAILABLE" -eq 1 ] && ! command -v valgrind >/dev/null 2>&1; then
        echo "[result-import-cost] valgrind not found; skipping instruction-count measurement"
        IR_AVAILABLE=0
    fi

    if [ "$IR_AVAILABLE" -eq 1 ]; then
        VALGRIND=$(command -v valgrind)
        SUMMARY_TSV="$WORKDIR/summary.tsv"

        echo "[result-import-cost] compiler: $COMPILER"
        echo "[result-import-cost] output: $WORKDIR"
        echo "[result-import-cost] runs per case: $RUNS"
        measure_case base "$WORKDIR/base/src"
        BASE_IR=$LAST_CASE_IR
        {
            printf 'case\tsource\tinjected_import\tir_count\tdelta\tdelta_pct\n'
            printf 'base\t-\t-\t%s\t0\t+0.000000%%\n' "$BASE_IR"
        } > "$SUMMARY_TSV"
        for variant in $VARIANTS; do
            measure_case "$variant" "$WORKDIR/$variant/src"
            case_ir=$LAST_CASE_IR
            delta=$((case_ir - BASE_IR))
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$variant" \
                "$(variant_source "$variant")" \
                "$(variant_import "$variant")" \
                "$case_ir" \
                "$(signed_delta "$delta")" \
                "$(pct_delta "$BASE_IR" "$delta")" \
                >> "$SUMMARY_TSV"
        done
        echo "[result-import-cost] instruction summary: $SUMMARY_TSV"
        cat "$SUMMARY_TSV"
    elif [ "$RUN_PROFILE" -eq 0 ]; then
        exit 0
    fi
fi

profile_value() {
    file=$1
    phase=$2
    column=$3
    awk -F'|' -v phase="$phase" -v column="$column" '
        $1 == "compile-profile" && $2 == phase {
            value = $column
            found = 1
        }
        END {
            if (!found) {
                print 0
            } else {
                print value
            }
        }
    ' "$file"
}

append_profile_delta() {
    variant=$1
    phase=$2
    base_file=$3
    variant_file=$4
    base_ms=$(profile_value "$base_file" "$phase" 3)
    variant_ms=$(profile_value "$variant_file" "$phase" 3)
    base_alloc=$(profile_value "$base_file" "$phase" 4)
    variant_alloc=$(profile_value "$variant_file" "$phase" 4)
    ms_delta=$((variant_ms - base_ms))
    alloc_delta=$((variant_alloc - base_alloc))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$variant" \
        "$phase" \
        "$base_ms" \
        "$variant_ms" \
        "$(signed_delta "$ms_delta")" \
        "$base_alloc" \
        "$variant_alloc" \
        "$(signed_delta "$alloc_delta")" \
        >> "$PROFILE_SUMMARY"
}

append_counter_delta() {
    variant=$1
    phase=$2
    base_file=$3
    variant_file=$4
    base_value=$(profile_value "$base_file" "$phase" 3)
    variant_value=$(profile_value "$variant_file" "$phase" 3)
    value_delta=$((variant_value - base_value))
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$variant" \
        "$phase" \
        "$base_value" \
        "$variant_value" \
        "$(signed_delta "$value_delta")" \
        >> "$COUNTER_SUMMARY"
}

run_profile_compile() {
    name=$1
    srcdir=$2
    asm="$WORKDIR/profile/$name-main.opt$OPT_LEVEL.s"
    stdout="$WORKDIR/profile/$name.stdout"
    stderr="$WORKDIR/profile/$name.stderr"
    mkdir -p "$WORKDIR/profile"
    echo "[result-import-cost] profile $name"
    if ! "$PROFILE_BIN" $(compile_args "$srcdir" "$asm") > "$stdout" 2> "$stderr"; then
        show_logs "$stdout" "$stderr"
        fail "profile compile failed for $name"
    fi
    grep '^compile-profile|' "$stderr" > "$WORKDIR/profile/$name.profile.tsv" || {
        show_logs "$stdout" "$stderr"
        fail "profile compile emitted no compile-profile rows for $name"
    }
    grep '^compile-profile-detail|typecheck.macro_expand|' "$stderr" \
        > "$WORKDIR/profile/$name.macro-detail.tsv" || true
}

if [ "$RUN_PROFILE" -eq 1 ]; then
    mkdir -p "$WORKDIR/profile"
    PROFILE_ASM="$WORKDIR/profile/typelisp-profile.s"
    PROFILE_OBJ="$WORKDIR/profile/typelisp-profile.$NL_OBJ_EXT"
    PROFILE_BIN="$WORKDIR/profile/typelisp-profile$NL_BIN_EXT"
    PROFILE_BUILD_STDOUT="$WORKDIR/profile/profile-build.stdout"
    PROFILE_BUILD_STDERR="$WORKDIR/profile/profile-build.stderr"

    echo "[result-import-cost] build compile-profile CLI"
    if ! "$COMPILER" compile src/main.tl \
        -o "$PROFILE_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root src \
        --opt-level "$OPT_LEVEL" \
        --cfg compile-profile \
        > "$PROFILE_BUILD_STDOUT" 2> "$PROFILE_BUILD_STDERR"; then
        show_logs "$PROFILE_BUILD_STDOUT" "$PROFILE_BUILD_STDERR"
        fail "profile-enabled CLI compile failed"
    fi
    if ! assemble_and_link result-import-profile "$PROFILE_ASM" "$PROFILE_OBJ" "$PROFILE_BIN" \
        >> "$PROFILE_BUILD_STDOUT" 2>> "$PROFILE_BUILD_STDERR"; then
        show_logs "$PROFILE_BUILD_STDOUT" "$PROFILE_BUILD_STDERR"
        fail "profile-enabled CLI link failed"
    fi

    run_profile_compile base "$WORKDIR/base/src"
    for variant in $VARIANTS; do
        run_profile_compile "$variant" "$WORKDIR/$variant/src"
    done

    PROFILE_SUMMARY="$WORKDIR/profile-summary.tsv"
    printf 'case\tphase\tbase_ms\tcase_ms\tdelta_ms\tbase_alloc_bytes\tcase_alloc_bytes\tdelta_alloc_bytes\n' > "$PROFILE_SUMMARY"
    for variant in $VARIANTS; do
        variant_profile="$WORKDIR/profile/$variant.profile.tsv"
        append_profile_delta "$variant" load "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" typecheck.macro_setup "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" typecheck.macro_walk "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" lower.macro_expand "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" lower.specialize "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" lower.prune "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" lower "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" optimize "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" optimize.functions "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" backend "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" backend.functions "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_profile_delta "$variant" total "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
    done

    COUNTER_SUMMARY="$WORKDIR/profile-counter-summary.tsv"
    printf 'case\tcounter\tbase_value\tcase_value\tdelta\n' > "$COUNTER_SUMMARY"
    for variant in $VARIANTS; do
        variant_profile="$WORKDIR/profile/$variant.profile.tsv"
        append_counter_delta "$variant" typecheck.macro.generated_module_materializations "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
        append_counter_delta "$variant" typecheck.macro.generated_module_memo_hits "$WORKDIR/profile/base.profile.tsv" "$variant_profile"
    done

    echo "[result-import-cost] profile summary: $PROFILE_SUMMARY"
    cat "$PROFILE_SUMMARY"
    echo "[result-import-cost] profile counter summary: $COUNTER_SUMMARY"
    cat "$COUNTER_SUMMARY"
    echo "[result-import-cost] macro detail rows: $WORKDIR/profile/*.macro-detail.tsv"
fi
