#!/usr/bin/env sh
set -eu

# measure-unused-import-cost.sh - paired #3803 unused import measurement.
#
# This is a diagnostic harness, not a CI gate. It measures one compiler binary
# compiling two scratch copies of the selfhost CLI source:
#   base:        src/main.tl unchanged
#   with-import: src/main.tl plus `(import "format_doc.tl")`
#
# Use this before and after compiler-throughput work for #3803/#3857:
#
#   TYPELISP_BIN=target/stage2/typelisp \
#     scripts/attic/measure-unused-import-cost.sh --runs 1 --profile
#
# The scratch sources live under target/ by default and the tracked src/main.tl
# is never edited.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

RUNS=${TYPELISP_UNUSED_IMPORT_RUNS:-1}
WORKDIR=${TYPELISP_UNUSED_IMPORT_OUT:-target/unused-import-cost}
OPT_LEVEL=${TYPELISP_UNUSED_IMPORT_OPT_LEVEL:-1}
RUN_PROFILE=${TYPELISP_UNUSED_IMPORT_PROFILE:-0}
PROFILE_ONLY=0
PREPARE_ONLY=0
SEED_ARG=

usage() {
    cat <<'EOF'
usage: scripts/attic/measure-unused-import-cost.sh [options] [typelisp-compiler]

Options:
  --runs N           Cachegrind runs for each source variant (default: 1)
  --output DIR       Output root (default: target/unused-import-cost)
  --opt-level N      Self-compile opt level 0, 1, or 2 (default: 1)
  --profile          Also build a compile-profile CLI and print phase deltas
  --profile-only     Run only the compile-profile phase comparison
  --prepare-only     Create paired scratch source trees, then exit
  -h, --help         Show this help

Environment:
  TYPELISP_BIN                    Compiler when no argument is given
  TYPELISP_UNUSED_IMPORT_RUNS     Default --runs
  TYPELISP_UNUSED_IMPORT_OUT      Default --output
  TYPELISP_UNUSED_IMPORT_OPT_LEVEL
                                    Default --opt-level
  TYPELISP_UNUSED_IMPORT_PROFILE  Set to 1 to enable --profile by default
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
        echo "TYPELISP_UNUSED_IMPORT_PROFILE must be 0 or 1: $RUN_PROFILE" >&2
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
    echo "[unused-import-cost] $*" >&2
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

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/base/src" "$WORKDIR/with/src" "$WORKDIR/logs"

copy_src_tree() {
    dst=$1
    for src_file in src/*.tl; do
        [ -f "$src_file" ] || continue
        cp "$src_file" "$dst/"
    done
}

inject_unused_import() {
    main_file=$1
    tmp_file=$main_file.tmp
    awk '
        BEGIN { inserted = 0 }
        inserted == 0 && /^\(import / {
            print "(import \"format_doc.tl\")"
            inserted = 1
        }
        { print }
        END {
            if (inserted == 0) {
                print "(import \"format_doc.tl\")"
            }
        }
    ' "$main_file" > "$tmp_file"
    mv "$tmp_file" "$main_file"
}

copy_src_tree "$WORKDIR/base/src"
copy_src_tree "$WORKDIR/with/src"
inject_unused_import "$WORKDIR/with/src/main.tl"

if [ "$PREPARE_ONLY" -eq 1 ]; then
    echo "[unused-import-cost] prepared base source: $WORKDIR/base/src/main.tl"
    echo "[unused-import-cost] prepared with-import source: $WORKDIR/with/src/main.tl"
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

run_cachegrind_case() {
    name=$1
    srcdir=$2
    run=$3
    asm="$WORKDIR/$name/main.opt$OPT_LEVEL.s"
    cgout="$WORKDIR/logs/$name-$run.cachegrind.out"
    stdout="$WORKDIR/logs/$name-$run.stdout"
    stderr="$WORKDIR/logs/$name-$run.stderr"

    echo "[unused-import-cost] cachegrind $name run $run"
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
            echo "[unused-import-cost] instruction-count measurement is Linux-only; use WSL or --profile-only"
            IR_AVAILABLE=0
            ;;
    esac
    if [ "$IR_AVAILABLE" -eq 1 ] && ! command -v valgrind >/dev/null 2>&1; then
        echo "[unused-import-cost] valgrind not found; skipping instruction-count measurement"
        IR_AVAILABLE=0
    fi

    if [ "$IR_AVAILABLE" -eq 1 ]; then
        VALGRIND=$(command -v valgrind)

        echo "[unused-import-cost] compiler: $COMPILER"
        echo "[unused-import-cost] output: $WORKDIR"
        echo "[unused-import-cost] runs per case: $RUNS"
        measure_case base "$WORKDIR/base/src"
        BASE_IR=$LAST_CASE_IR
        measure_case with "$WORKDIR/with/src"
        WITH_IR=$LAST_CASE_IR
        IR_DELTA=$((WITH_IR - BASE_IR))
        {
            printf 'case\tir_count\n'
            printf 'base\t%s\n' "$BASE_IR"
            printf 'with-format-doc\t%s\n' "$WITH_IR"
            printf 'delta\t%s\n' "$(signed_delta "$IR_DELTA")"
            printf 'delta-pct\t%s\n' "$(pct_delta "$BASE_IR" "$IR_DELTA")"
        } > "$WORKDIR/summary.tsv"
        echo "[unused-import-cost] instruction summary: $WORKDIR/summary.tsv"
        cat "$WORKDIR/summary.tsv"
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
    phase=$1
    base_file=$2
    with_file=$3
    base_ms=$(profile_value "$base_file" "$phase" 3)
    with_ms=$(profile_value "$with_file" "$phase" 3)
    base_alloc=$(profile_value "$base_file" "$phase" 4)
    with_alloc=$(profile_value "$with_file" "$phase" 4)
    ms_delta=$((with_ms - base_ms))
    alloc_delta=$((with_alloc - base_alloc))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$phase" \
        "$base_ms" \
        "$with_ms" \
        "$(signed_delta "$ms_delta")" \
        "$base_alloc" \
        "$with_alloc" \
        "$(signed_delta "$alloc_delta")" \
        >> "$PROFILE_SUMMARY"
}

run_profile_compile() {
    name=$1
    srcdir=$2
    asm="$WORKDIR/profile/$name-main.opt$OPT_LEVEL.s"
    stdout="$WORKDIR/profile/$name.stdout"
    stderr="$WORKDIR/profile/$name.stderr"
    echo "[unused-import-cost] profile $name"
    if ! "$PROFILE_BIN" $(compile_args "$srcdir" "$asm") > "$stdout" 2> "$stderr"; then
        show_logs "$stdout" "$stderr"
        fail "profile compile failed for $name"
    fi
    grep '^compile-profile|' "$stderr" > "$WORKDIR/profile/$name.profile.tsv" || {
        show_logs "$stdout" "$stderr"
        fail "profile compile emitted no compile-profile rows for $name"
    }
}

if [ "$RUN_PROFILE" -eq 1 ]; then
    mkdir -p "$WORKDIR/profile"
    PROFILE_ASM="$WORKDIR/profile/typelisp-profile.s"
    PROFILE_OBJ="$WORKDIR/profile/typelisp-profile.$NL_OBJ_EXT"
    PROFILE_BIN="$WORKDIR/profile/typelisp-profile$NL_BIN_EXT"
    PROFILE_BUILD_STDOUT="$WORKDIR/profile/profile-build.stdout"
    PROFILE_BUILD_STDERR="$WORKDIR/profile/profile-build.stderr"

    echo "[unused-import-cost] build compile-profile CLI"
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
    if ! assemble_and_link unused-import-profile "$PROFILE_ASM" "$PROFILE_OBJ" "$PROFILE_BIN" \
        >> "$PROFILE_BUILD_STDOUT" 2>> "$PROFILE_BUILD_STDERR"; then
        show_logs "$PROFILE_BUILD_STDOUT" "$PROFILE_BUILD_STDERR"
        fail "profile-enabled CLI link failed"
    fi

    run_profile_compile base "$WORKDIR/base/src"
    run_profile_compile with "$WORKDIR/with/src"

    PROFILE_SUMMARY="$WORKDIR/profile-summary.tsv"
    printf 'phase\tbase_ms\twith_ms\tdelta_ms\tbase_alloc_bytes\twith_alloc_bytes\tdelta_alloc_bytes\n' > "$PROFILE_SUMMARY"
    append_profile_delta load "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"
    append_profile_delta lower.macro_expand "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"
    append_profile_delta lower.specialize "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"
    append_profile_delta lower.prune "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"
    append_profile_delta lower "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"
    append_profile_delta optimize "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"
    append_profile_delta optimize.functions "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"
    append_profile_delta backend "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"
    append_profile_delta backend.functions "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"
    append_profile_delta total "$WORKDIR/profile/base.profile.tsv" "$WORKDIR/profile/with.profile.tsv"

    echo "[unused-import-cost] profile summary: $PROFILE_SUMMARY"
    cat "$PROFILE_SUMMARY"
fi
