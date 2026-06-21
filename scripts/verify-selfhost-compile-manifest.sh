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
# commit surfaces as an access violation, exit 139).
# Windows still has tighter commit headroom during stage1-mode selfhost chunks;
# keep its default low enough that heavyweight compiler modules do not accumulate
# in one process while allowing Linux and explicit local overrides to go larger.
DEFAULT_BATCH_CHUNK_SIZE=16
if [ "$HOST_OS" = windows ]; then
    DEFAULT_BATCH_CHUNK_SIZE=2
fi
BATCH_CHUNK_SIZE=${TYPELISP_COMPILE_MANIFEST_BATCH_SIZE:-$DEFAULT_BATCH_CHUNK_SIZE}

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
MANIFEST_INPUT="$WORKDIR/compile-manifest.normalized.txt"
BATCH_INPUT="$WORKDIR/compile-batch.txt"
BATCH_CHUNK_DIR="$WORKDIR/compile-batch-chunks"
tr -d '\r' < "$MANIFEST" > "$MANIFEST_INPUT"

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

run_compile_batch() {
    batch_chunk_count=$(find "$BATCH_CHUNK_DIR" -type f -name 'compile-batch.*.txt' | wc -l | tr -d ' ')
    if [ "$batch_chunk_count" -eq 0 ]; then
        fail "batch compile manifest has no chunks"
    fi

    echo "[selfhost-compile] batch compile manifest ($batch_chunk_count chunk(s), size $BATCH_CHUNK_SIZE)"
    batch_chunk_index=0
    for batch_chunk in "$BATCH_CHUNK_DIR"/compile-batch.*.txt; do
        [ -f "$batch_chunk" ] || fail "batch compile manifest chunk is missing: $batch_chunk"
        batch_chunk_index=$((batch_chunk_index + 1))
        batch_label="batch compile manifest chunk $batch_chunk_index/$batch_chunk_count"
        batch_out="$batch_chunk.out"
        batch_err="$batch_chunk.err"
        echo "[selfhost-compile] $batch_label"
        set +e
        run_with_heartbeat_capture \
            "$batch_label" \
            "$batch_out" \
            "$batch_err" \
            "$COMPILER" compile --batch "$batch_chunk" --target linux-x86_64 --stdlib-root "$ROOT/stdlib"
        code=$?
        set -e
        if [ "$code" -ne 0 ]; then
            echo "stdout:" >&2
            sed 's/^/  /' "$batch_out" >&2
            echo "stderr:" >&2
            sed 's/^/  /' "$batch_err" >&2
            fail "$batch_label exited $code in $EXPECTATION_MODE mode"
        fi
    done
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
