#!/usr/bin/env sh
set -eu

# verify-result-import-harness.sh - source-integrity and equivalent-Module checks
# for scripts/measure-result-import-cost.sh. The measurement harness injects
# generated result imports into scratch selfhost trees; this verifier ensures
# that it changes nothing else and that an equivalent user-defined Module macro
# typechecks the measured source in every prepared case.

usage() {
    echo "usage: $0 [typelisp-compiler]" >&2
}

compiler_arg=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            if [ -n "$compiler_arg" ]; then
                usage
                exit 2
            fi
            compiler_arg=$1
            ;;
    esac
    shift
done

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORKDIR=${TYPELISP_RESULT_IMPORT_VERIFY_DIR:-target/verify-result-import-harness}
case "$WORKDIR" in
    "" | / | . | ..)
        echo "unsafe verification output path: $WORKDIR" >&2
        exit 2
        ;;
esac
case "$WORKDIR" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) WORKDIR="$ROOT/$WORKDIR" ;;
esac

if [ -n "$compiler_arg" ]; then
    COMPILER=$compiler_arg
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

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

fail() {
    echo "[result-import-harness] $*" >&2
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

PREPARED="$WORKDIR/prepared"
ORDINARY_STDLIB="$WORKDIR/ordinary-stdlib"
ORDINARY_ROOT="$WORKDIR/ordinary"
CHECK_CWD="$WORKDIR/check-cwd"
LOG_DIR="$WORKDIR/logs"

rm -rf "$WORKDIR"
mkdir -p "$ORDINARY_STDLIB" "$ORDINARY_ROOT" "$CHECK_CWD" "$LOG_DIR"

# The preparation command itself checks every variant against the base source
# after removing only the documented injected imports.
scripts/measure-result-import-cost.sh --prepare-only --output "$PREPARED"

# Make an equivalent macro with a different module and name, then rewrite the
# scratch trees to use it. Both macros use the generic transformer/catalog path;
# this keeps a differential guard against behavior depending on public Result
# spellings.
if ! awk '
    $0 == "(defmacro (result [T : type] [E : type]) : Module" {
        print "(defmacro (generic-result [T : type] [E : type]) : Module"
        renamed = renamed + 1
        next
    }
    index($0, "\"stdlib.result.generated.\"") != 0 {
        sub(/stdlib[.]result[.]generated[.]/, "stdlib.generic_result.generated.")
        print
        reprefixed = reprefixed + 1
        next
    }
    { print }
    END {
        if (renamed != 1 || reprefixed != 1) {
            exit 1
        }
    }
' stdlib/result.tl > "$ORDINARY_STDLIB/generic_result.tl"; then
    fail "could not create the ordinary Module test macro"
fi

rewrite_for_ordinary_module() {
    source_dir=$1
    destination_dir=$2
    mkdir -p "$destination_dir"
    for source_file in "$source_dir"/*.tl; do
        [ -f "$source_file" ] || continue
        source_name=${source_file##*/}
        case "$source_name" in
            format_tokens.tl | lex.tl | compiler_ctfe.tl)
                awk '
                    $0 == "(import stdlib.result)" {
                        print "(import generic_result)"
                        next
                    }
                    /^\(import \(result / {
                        sub(/^\(import \(result /, "(import (generic_result.generic-result ")
                    }
                    { print }
                ' "$source_file" > "$destination_dir/$source_name"
                ;;
            *) cp "$source_file" "$destination_dir/$source_name" ;;
        esac
    done

    for measured_source in format_tokens.tl lex.tl compiler_ctfe.tl; do
        measured_file="$destination_dir/$measured_source"
        if grep -E '^\(import stdlib\.result\)$|^\(import \(result ' "$measured_file" >/dev/null 2>&1; then
            fail "$measured_source still contains a stdlib.result import"
        fi
        if ! grep -E '^\(import generic_result\)$' "$measured_file" >/dev/null 2>&1; then
            fail "$measured_source did not import generic_result"
        fi
        if ! grep -E '^\(import \(generic_result\.generic-result ' "$measured_file" >/dev/null 2>&1; then
            fail "$measured_source did not instantiate generic-result"
        fi
    done
}

check_prepared_source() {
    name=$1
    measured_source=$2
    source_dir="$PREPARED/$name/src"
    ordinary_source="$ORDINARY_ROOT/$name/src"
    source_file="$ordinary_source/$measured_source"
    log_name=${measured_source%.tl}
    stdout="$LOG_DIR/$name-$log_name.stdout"
    stderr="$LOG_DIR/$name-$log_name.stderr"
    [ -f "$source_dir/$measured_source" ] || fail "prepared $name tree has no $measured_source"

    echo "[result-import-harness] equivalent Module check $name $measured_source"
    check_status=0
    if [ "$measured_source" = compiler_ctfe.tl ]; then
        ir_file="$LOG_DIR/$name-$log_name.ir"
        (
            cd "$CHECK_CWD"
            "$COMPILER" compile "$source_file" \
                --emit-ir \
                -o "$ir_file" \
                --opt-level 0 \
                --stdlib-root "$ROOT/stdlib" \
                --stdlib-root "$ORDINARY_STDLIB" \
                --stdlib-root "$ordinary_source" \
                --cfg selfhost-compile-manifest
        ) > "$stdout" 2> "$stderr" || check_status=$?
        if [ "$check_status" -eq 0 ] && [ ! -s "$ir_file" ]; then
            check_status=1
        fi
    else
        (
            cd "$CHECK_CWD"
            "$COMPILER" check "$source_file" \
                --stdlib-root "$ROOT/stdlib" \
                --stdlib-root "$ORDINARY_STDLIB" \
                --stdlib-root "$ordinary_source"
        ) > "$stdout" 2> "$stderr" || check_status=$?
    fi
    if [ "$check_status" -ne 0 ]; then
        show_logs "$stdout" "$stderr"
        fail "equivalent Module typecheck failed for prepared $name $measured_source"
    fi
}

prepare_ordinary_tree() {
    name=$1
    rewrite_for_ordinary_module "$PREPARED/$name/src" "$ORDINARY_ROOT/$name/src"
}

prepare_ordinary_tree base
for measured_source in format_tokens.tl lex.tl compiler_ctfe.tl; do
    check_prepared_source base "$measured_source"
done
for variant in format_tokens lex compiler_ctfe; do
    prepare_ordinary_tree "$variant"
    check_prepared_source "$variant" "$variant.tl"
done

echo "[result-import-harness] prepared source integrity and equivalent Module checks passed"
