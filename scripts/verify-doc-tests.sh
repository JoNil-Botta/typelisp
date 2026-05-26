#!/usr/bin/env sh
set -eu

# verify-doc-tests.sh - auto-discover documented TypeLisp sources and run
# `typelisp doc --test` for each one. This intentionally uses a built compiler
# from TYPELISP_BIN so CI can run it without relying on the Rust test harness.
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
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
    [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe"
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
    grep -Eq '^[[:space:]]*;;;|```[[:space:]]*(typelisp|tl)([[:space:]]|$)' "$1"
}

safe_name() {
    printf '%s' "$1" | sed 's#[/\\:]#_#g'
}

while IFS= read -r source; do
    [ -n "$source" ] || continue
    if has_public_docs_or_fences "$source"; then
        printf '%s\n' "$source" >> "$DISCOVERED"
    fi
done < "$CANDIDATES"

if [ ! -s "$DISCOVERED" ]; then
    echo "doc test verification found no documented TypeLisp files" >&2
    exit 1
fi

count=0
while IFS= read -r source; do
    [ -n "$source" ] || continue
    count=$((count + 1))
    case_name=$(safe_name "$source")
    stdout="$WORKDIR/$case_name.stdout"
    stderr="$WORKDIR/$case_name.stderr"

    echo "[doc-tests] $source"
    if ! run_with_retry "$stdout" "$stderr" "${VERIFY_DOC_TESTS_ATTEMPTS:-5}" \
        "$COMPILER" doc --test "$source" --stdlib-root "$ROOT/stdlib"; then
        echo "doc test verification failed for $source (after retries)" >&2
        echo "stdout:" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$stderr" >&2 || true
        exit 1
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

echo "doc test verification passed for $count file(s)"
