#!/usr/bin/env sh
set -eu

# verify-doc-tests.sh - auto-discover documented TypeLisp sources and run
# `typelisp doc --test` for each one. This intentionally uses a built compiler
# from TYPELISP_BIN so CI can run it without relying on the Rust test harness.
# In no-Rust lanes, TYPELISP_BIN is the command-tier compiler selected by the
# caller. Seed fallback is only a compatibility path for older artifacts and
# cannot verify future stdlib borrowed-`str` doctests.
# refs #946

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Retry transient Windows segfaults (#1204) around each `typelisp` invocation.
. "$ROOT/scripts/lib-retry.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "doc test verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # No-Rust fallback for local development: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/doc-test-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

CANDIDATES="$WORKDIR/candidates.txt"
DISCOVERED="$WORKDIR/discovered.txt"
: > "$CANDIDATES"
: > "$DISCOVERED"

for root in stdlib selfhost examples tests; do
    if [ -d "$root" ]; then
        find "$root" \
            -type f \
            -name '*.tl' \
            ! -path '*/target/*' \
            ! -path '*/.typelisp-doctest/*'
    fi
done | sort > "$CANDIDATES"

has_public_docs_or_fences() {
    grep -Eq '^[[:space:]]*(;#|;:)|```[[:space:]]*(typelisp|tl)([[:space:]]|$)' "$1"
}

has_runnable_doctest() {
    grep -Eq '```[[:space:]]*(typelisp|tl)[[:space:]]+run([[:space:]]|$)' "$1"
}

safe_name() {
    printf '%s' "$1" | sed 's#[/\\:]#_#g'
}

# Extract a staged-primitive directive `;; requires-stage0-symbol: <name>` from a
# source file (first match), else empty. Repository doctests run through the
# published seed compiler on some no-Rust lanes, so documented files that import
# a newly staged runtime primitive need the same narrow skip used by manifests.
staged_symbol_for() {
    sed -n 's/^;;[[:space:]]*requires-stage0-symbol:[[:space:]]*\([^[:space:]][^[:space:]]*\).*/\1/p' "$1" | head -n 1
}

should_skip_staged() {
    _symbols=$1
    _stderr=$2
    [ -n "$_symbols" ] || return 1
    for _symbol in $(printf '%s\n' "$_symbols" | tr ',' ' '); do
        grep -qF "$_symbol" "$_stderr" && return 0
    done
    return 1
}

runnable_count=0
while IFS= read -r source; do
    [ -n "$source" ] || continue
    if has_public_docs_or_fences "$source"; then
        printf '%s\n' "$source" >> "$DISCOVERED"
        if has_runnable_doctest "$source"; then
            runnable_count=$((runnable_count + 1))
        fi
    fi
done < "$CANDIDATES"

if [ ! -s "$DISCOVERED" ]; then
    echo "doc test verification found no documented TypeLisp files" >&2
    exit 1
fi
if [ "$runnable_count" -eq 0 ]; then
    echo "doc test verification found no runnable doctest files" >&2
    exit 1
fi

count=0
skipped=0
while IFS= read -r source; do
    [ -n "$source" ] || continue
    count=$((count + 1))
    case_name=$(safe_name "$source")
    stdout="$WORKDIR/$case_name.stdout"
    stderr="$WORKDIR/$case_name.stderr"
    requires_symbol=$(staged_symbol_for "$source")

    echo "[doc-tests] $source"
    # Default 6 (not 3): some stdlib doc-tests (text_buf.tl, hash.tl) hit the
    # #1204 Windows segfault often enough that 3 attempts can all crash
    # (observed on PR #1225), so the crash-retry needs more headroom.
    if ! run_with_retry "$stdout" "$stderr" "${VERIFY_DOC_TESTS_ATTEMPTS:-6}" \
        "$COMPILER" doc --test "$source" --stdlib-root "$ROOT/stdlib"; then
        if should_skip_staged "$requires_symbol" "$stderr"; then
            echo "[doc-tests] SKIP $source (awaiting no-Rust compiler support for '$requires_symbol')"
            skipped=$((skipped + 1))
            continue
        fi
        echo "doc test verification failed for $source (after retries)" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
    if [ -n "$requires_symbol" ]; then
        echo "[doc-tests] NOTE: $source passed with staged symbol marker '$requires_symbol'; drop the marker once published stage0 carries it" >&2
    fi

    if ! grep -q '^Doc tests passed:' "$stdout"; then
        echo "doc test verification failed for $source: missing success summary" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
    fi
done < "$DISCOVERED"

echo "doc test verification passed for $count file(s), including $runnable_count runnable doctest file(s)"
if [ "$skipped" -gt 0 ]; then
    echo "doc test verification skipped $skipped staged-symbol file(s)"
fi
