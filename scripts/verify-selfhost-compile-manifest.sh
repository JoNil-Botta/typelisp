#!/usr/bin/env sh
set -eu

# verify-selfhost-compile-manifest.sh - no-Rust assembly compile manifest.
#
# The manifest lists TypeLisp sources whose generated assembly used to be
# checked by Rust *_compile.rs harnesses. This runner compiles each entry with an
# already-built TypeLisp compiler, then checks the generated assembly for the
# expected main-label policy and text markers.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

MANIFEST=${TYPELISP_COMPILE_MANIFEST:-selfhost/compile_manifest.txt}
WORKDIR=${TYPELISP_COMPILE_MANIFEST_WORKDIR:-target/selfhost-compile-manifest}

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Fallback only for local development; CI should pass a fetched stage0
    # compiler through TYPELISP_BIN until #793/#795 remove Rust stage0.
    cargo build --quiet
    COMPILER="$ROOT/target/debug/typelisp"
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
tr -d '\r' < "$MANIFEST" > "$MANIFEST_INPUT"

check_selfhost_manifest_sync() {
    expected="$WORKDIR/expected-selfhost-sources.txt"
    actual="$WORKDIR/actual-selfhost-sources.txt"

    awk -F'|' '
        $1 == "case" && $3 ~ /^selfhost\/[^/]+\.tl$/ { print $3 }
        $1 == "decision" && $2 ~ /^selfhost\/[^/]+\.tl$/ { print $2 }
    ' "$MANIFEST_INPUT" | sort -u > "$expected"

    find selfhost -maxdepth 1 -type f -name '*.tl' | sort > "$actual"

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

contains_text() {
    needle=$1
    [ "$compiled" -eq 2 ] && return
    if ! grep -F -- "$needle" "$asm_path" >/dev/null; then
        fail "$case_id assembly is missing expected text [$needle]"
    fi
}

not_contains_text() {
    needle=$1
    [ "$compiled" -eq 2 ] && return
    if grep -F -- "$needle" "$asm_path" >/dev/null; then
        fail "$case_id assembly contains forbidden text [$needle]"
    fi
}

count_at_least() {
    needle=$1
    min=$2
    [ "$compiled" -eq 2 ] && return
    count=$(grep -F -- "$needle" "$asm_path" | wc -l | tr -d ' ')
    if [ "$count" -lt "$min" ]; then
        fail "$case_id assembly has $count occurrence(s) of [$needle], expected at least $min"
    fi
}

staged_symbol_matches() {
    symbols=$1
    err_path=$2
    [ -n "$symbols" ] || return 1
    for symbol in $(printf '%s\n' "$symbols" | tr ',' ' '); do
        grep -qF "$symbol" "$err_path" && return 0
    done
    return 1
}

main_label_count() {
    awk 'BEGIN { count = 0 } /^main:$/ { count += 1 } END { print count }' "$asm_path"
}

ensure_compiled() {
    if [ "$compiled" -ne 0 ]; then
        return
    fi

    asm_path="$case_dir/$case_id.s"
    out_path="$case_dir/$case_id.out"
    err_path="$case_dir/$case_id.err"

    if [ "$case_mode" = "stage" ]; then
        compile_source="$case_dir/$(basename "$case_source")"
    else
        compile_source="$ROOT/$case_source"
    fi

    echo "[selfhost-compile] $case_id ($case_source)"
    set +e
    "$COMPILER" compile "$compile_source" --stdlib-root "$ROOT/stdlib" -o "$asm_path" > "$out_path" 2> "$err_path"
    code=$?
    set -e
    if [ "$code" -ne 0 ]; then
        if staged_symbol_matches "$case_requires_symbol" "$err_path"; then
            echo "[selfhost-compile] SKIP $case_id (awaiting no-Rust compiler support for '$case_requires_symbol')"
            skipped=$((skipped + 1))
            compiled=2
            return
        fi
        echo "stdout:" >&2
        sed 's/^/  /' "$out_path" >&2
        echo "stderr:" >&2
        sed 's/^/  /' "$err_path" >&2
        fail "$case_id compile exited $code"
    fi

    if grep -F -- "# TODO" "$asm_path" >/dev/null; then
        fail "$case_id assembly still contains # TODO"
    fi

    main_count=$(main_label_count)
    case "$main_policy" in
        exactly-one)
            if [ "$main_count" -ne 1 ]; then
                fail "$case_id expected exactly one main: label, found $main_count"
            fi
            ;;
        present)
            if [ "$main_count" -lt 1 ]; then
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

case_id=
case_source=
case_mode=
main_policy=
case_dir=
compiled=1
case_count=0
skipped=0

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
            rm -rf "$case_dir"
            mkdir -p "$case_dir"
            if [ "$case_mode" = "stage" ]; then
                cp "$case_source" "$case_dir/$(basename "$case_source")"
            fi
            asm_path=
            compiled=0
            case_requires_symbol=
            case_count=$((case_count + 1))
            ;;
        requires-stage0-symbol)
            [ -n "$case_id" ] || fail "requires-stage0-symbol appears before a case"
            case_requires_symbol=$a
            ;;
        copy)
            [ -n "$case_id" ] || fail "copy appears before a case"
            [ "$case_mode" = "stage" ] || fail "$case_id copy is only valid for staged cases"
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

echo "selfhost compile manifest passed: $case_count case(s)"
if [ "$skipped" -ne 0 ]; then
    echo "selfhost compile manifest: $skipped case(s) skipped (staged primitive awaiting no-Rust compiler support)"
fi
