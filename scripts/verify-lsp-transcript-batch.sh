#!/usr/bin/env sh
set -eu

# Exercise the file-bounded LSP transcript manifest contract without running
# the full public-tools corpus.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || {
    echo "LSP transcript-batch compiler is not executable: $COMPILER" >&2
    exit 1
}

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *) echo "LSP transcript-batch verifier is unsupported on this host" >&2; exit 1 ;;
esac

compiler_path() {
    if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m -a -l "$1"
    else
        printf '%s' "$1"
    fi
}

WORKDIR="$ROOT/target/lsp-transcript-batch-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
HEADER=typelisp-lsp-transcript-batch-v1
EMPTY_INPUT="$WORKDIR/empty.in"
TRUNCATED_INPUT="$WORKDIR/truncated.in"
: > "$EMPTY_INPUT"
printf 'Content-Length: 5\r\n\r\n{}' > "$TRUNCATED_INPUT"

run_manifest() {
    "$COMPILER" lsp --transcript-batch "$(compiler_path "$1")" \
        --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src"
}

expect_manifest_failure() {
    label=$1
    manifest=$2
    needle=$3
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    if run_manifest "$manifest" > "$stdout" 2> "$stderr"; then
        echo "LSP transcript-batch $label unexpectedly succeeded" >&2
        exit 1
    fi
    grep -F "$needle" "$stderr" >/dev/null || {
        echo "LSP transcript-batch $label did not report: $needle" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    }
}

EMPTY_MANIFEST="$WORKDIR/empty.tsv"
printf '%s\n' "$HEADER" > "$EMPTY_MANIFEST"
expect_manifest_failure empty "$EMPTY_MANIFEST" "manifest has no entries"

MISSING_MANIFEST="$WORKDIR/missing.tsv"
printf '%s\n' "$HEADER" > "$MISSING_MANIFEST"
printf 'missing\t%s\t%s\t%s\t%s\n' \
    "$(compiler_path "$WORKDIR/absent.in")" \
    "$(compiler_path "$WORKDIR/missing.out")" \
    "$(compiler_path "$WORKDIR/missing.err")" \
    "$(compiler_path "$WORKDIR/missing.status")" >> "$MISSING_MANIFEST"
expect_manifest_failure missing-input "$MISSING_MANIFEST" "input does not exist"

DUPLICATE_MANIFEST="$WORKDIR/duplicate.tsv"
printf '%s\n' "$HEADER" > "$DUPLICATE_MANIFEST"
for suffix in a b; do
    printf 'duplicate\t%s\t%s\t%s\t%s\n' \
        "$(compiler_path "$EMPTY_INPUT")" \
        "$(compiler_path "$WORKDIR/duplicate-$suffix.out")" \
        "$(compiler_path "$WORKDIR/duplicate-$suffix.err")" \
        "$(compiler_path "$WORKDIR/duplicate-$suffix.status")" >> "$DUPLICATE_MANIFEST"
done
expect_manifest_failure duplicate-id "$DUPLICATE_MANIFEST" "duplicate transcript batch case id"

DUPLICATE_RESULT_MANIFEST="$WORKDIR/duplicate-result.tsv"
shared_result=$(compiler_path "$WORKDIR/shared.result")
printf '%s\n' "$HEADER" > "$DUPLICATE_RESULT_MANIFEST"
printf 'duplicate-result\t%s\t%s\t%s\t%s\n' \
    "$(compiler_path "$EMPTY_INPUT")" "$shared_result" "$shared_result" \
    "$(compiler_path "$WORKDIR/duplicate-result.status")" >> "$DUPLICATE_RESULT_MANIFEST"
expect_manifest_failure duplicate-result "$DUPLICATE_RESULT_MANIFEST" "duplicate transcript batch result path"

MALFORMED_MANIFEST="$WORKDIR/malformed.tsv"
printf '%s\nmalformed\tonly-two-fields\n' "$HEADER" > "$MALFORMED_MANIFEST"
expect_manifest_failure malformed "$MALFORMED_MANIFEST" "expected five tab-separated fields"

VALID_MANIFEST="$WORKDIR/valid.tsv"
printf '%s\n' "$HEADER" > "$VALID_MANIFEST"
printf 'empty\t%s\t%s\t%s\t%s\n' \
    "$(compiler_path "$EMPTY_INPUT")" \
    "$(compiler_path "$WORKDIR/empty.out")" \
    "$(compiler_path "$WORKDIR/empty.err")" \
    "$(compiler_path "$WORKDIR/empty.status")" >> "$VALID_MANIFEST"
printf 'truncated\t%s\t%s\t%s\t%s\n' \
    "$(compiler_path "$TRUNCATED_INPUT")" \
    "$(compiler_path "$WORKDIR/truncated.out")" \
    "$(compiler_path "$WORKDIR/truncated.err")" \
    "$(compiler_path "$WORKDIR/truncated.status")" >> "$VALID_MANIFEST"
VALID_RESULTS="$WORKDIR/valid-results.tsv"
run_manifest "$VALID_MANIFEST" > "$VALID_RESULTS"
EXPECTED_RESULTS="$WORKDIR/expected-results.tsv"
printf 'lsp-transcript-batch-result\tempty\n' > "$EXPECTED_RESULTS"
printf 'lsp-transcript-batch-result\ttruncated\n' >> "$EXPECTED_RESULTS"
cmp -s "$EXPECTED_RESULTS" "$VALID_RESULTS" || {
    echo "valid transcript batch did not emit its exact ordered result rows" >&2
    diff -u "$EXPECTED_RESULTS" "$VALID_RESULTS" >&2 || true
    exit 1
}

result_rows_valid() {
    cmp -s "$EXPECTED_RESULTS" "$1"
}

MUTATED_RESULTS="$WORKDIR/mutated-results.tsv"
sed -n '1p' "$VALID_RESULTS" > "$MUTATED_RESULTS"
if result_rows_valid "$MUTATED_RESULTS"; then
    echo "missing transcript result row was not detected" >&2
    exit 1
fi
sed -n '1p;1p;2p' "$VALID_RESULTS" > "$MUTATED_RESULTS"
if result_rows_valid "$MUTATED_RESULTS"; then
    echo "duplicate transcript result row was not detected" >&2
    exit 1
fi
{
    sed -n '2p' "$VALID_RESULTS"
    sed -n '1p' "$VALID_RESULTS"
} > "$MUTATED_RESULTS"
if result_rows_valid "$MUTATED_RESULTS"; then
    echo "reordered transcript result rows were not detected" >&2
    exit 1
fi
cp "$VALID_RESULTS" "$MUTATED_RESULTS"
printf 'lsp-transcript-batch-result\textra\n' >> "$MUTATED_RESULTS"
if result_rows_valid "$MUTATED_RESULTS"; then
    echo "extra transcript result row was not detected" >&2
    exit 1
fi

[ "$(tr -d '\r\n' < "$WORKDIR/empty.status")" = 0 ] || {
    echo "empty transcript did not report status 0" >&2
    exit 1
}
[ "$(tr -d '\r\n' < "$WORKDIR/truncated.status")" = 1 ] || {
    echo "raw truncated transcript did not report status 1" >&2
    exit 1
}
grep -F 'lsp: truncated payload' "$WORKDIR/truncated.err" >/dev/null || {
    echo "raw truncated transcript lost its framing error" >&2
    exit 1
}

result_set_valid() {
    for case_id in empty truncated; do
        [ -f "$WORKDIR/$case_id.out" ] || return 1
        [ -f "$WORKDIR/$case_id.err" ] || return 1
        [ -f "$WORKDIR/$case_id.status" ] || return 1
        status=$(tr -d '\r\n' < "$WORKDIR/$case_id.status")
        case "$status" in
            '' | *[!0-9]*) return 1 ;;
        esac
    done
}

result_set_valid || {
    echo "valid transcript batch produced an incomplete result set" >&2
    exit 1
}
rm -f "$WORKDIR/empty.status"
if result_set_valid; then
    echo "missing transcript result was not detected" >&2
    exit 1
fi
printf 'not-a-status\n' > "$WORKDIR/empty.status"
if result_set_valid; then
    echo "malformed transcript status was not detected" >&2
    exit 1
fi

echo "LSP transcript batch manifest verification passed"
