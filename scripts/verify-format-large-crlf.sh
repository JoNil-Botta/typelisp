#!/usr/bin/env sh
set -eu

# Exercise the whole-file `fmt --check` diff produced when canonical LF source
# arrives with CRLF endings. The old immutable-string accumulator retained
# quadratic intermediate output; a 20,000-line hunk crossed many GiB while
# the growable render buffer stays comfortably below this gate's 1 GiB Linux
# process-tree limit. Windows runs the same deterministic structural probe
# without asserting a host-specific memory number.
# refs #6498, #6193.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "large CRLF formatter verification is unsupported on this host" >&2
        exit 1
        ;;
esac

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
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR=target/format-large-crlf-verify
LF_FIXTURE="$WORKDIR/large-lf.tl"
CRLF_FIXTURE="$WORKDIR/large-crlf.tl"
LF_STDOUT="$WORKDIR/lf.stdout"
LF_STDERR="$WORKDIR/lf.stderr"
CRLF_STDOUT="$WORKDIR/crlf.stdout"
CRLF_STDERR="$WORKDIR/crlf.stderr"
LINE_COUNT=20000
DECL_COUNT=10000
LINUX_LIMIT_BYTES=1073741824

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "large CRLF formatter verification failed: $*" >&2
    exit 1
}

show_stream() {
    _stream_label=$1
    _stream_file=$2
    [ -s "$_stream_file" ] || return 0
    _stream_lines=$(wc -l < "$_stream_file" | tr -d ' ')
    echo "$_stream_label:" >&2
    if [ "$_stream_lines" -le 160 ]; then
        sed 's/^/  /' "$_stream_file" >&2 || true
    else
        sed -n '1,80{s/^/  /;p;}' "$_stream_file" >&2 || true
        echo "  ... $((_stream_lines - 160)) line(s) omitted ..." >&2
        tail -n 80 "$_stream_file" | sed 's/^/  /' >&2 || true
    fi
}

show_streams() {
    show_stream stdout "$1"
    show_stream stderr "$2"
}

# Flat constant declarations are cheap to parse and stable under formatting.
# Unique lines make the first/last diff markers useful completeness checks.
awk -v count="$DECL_COUNT" 'BEGIN {
    for (i = 1; i <= count; i++) {
        if (i > 1) printf "\n"
        printf "(define fmt-crlf-value-%05d : i64\n  %d)", i, i
    }
}' > "$LF_FIXTURE"

awk '{
    if (NR > 1) printf "\r\n"
    printf "%s", $0
}' "$LF_FIXTURE" > "$CRLF_FIXTURE"

if cmp -s "$LF_FIXTURE" "$CRLF_FIXTURE"; then
    fail "derived CRLF fixture is byte-identical to LF input"
fi
lf_lines=$(awk 'END { print NR + 0 }' "$LF_FIXTURE")
crlf_lines=$(awk 'END { print NR + 0 }' "$CRLF_FIXTURE")
if [ "$lf_lines" -ne "$LINE_COUNT" ] || [ "$crlf_lines" -ne "$LINE_COUNT" ]; then
    fail "generated fixture line counts changed (LF=$lf_lines, CRLF=$crlf_lines)"
fi

if ! "$COMPILER" fmt --check "$LF_FIXTURE" > "$LF_STDOUT" 2> "$LF_STDERR"; then
    show_streams "$LF_STDOUT" "$LF_STDERR"
    fail "generated LF source is not already canonical"
fi
if [ -s "$LF_STDOUT" ] || [ -s "$LF_STDERR" ]; then
    show_streams "$LF_STDOUT" "$LF_STDERR"
    fail "canonical LF check produced output"
fi

set +e
if [ "$HOST_OS" = linux ]; then
    . "$ROOT/scripts/lib-linux-memory-limit.sh"
    linux_memory_limit_run "$LINUX_LIMIT_BYTES" \
        "$COMPILER" fmt --check "$CRLF_FIXTURE" \
        > "$CRLF_STDOUT" 2> "$CRLF_STDERR"
    status=$?
else
    "$COMPILER" fmt --check "$CRLF_FIXTURE" \
        > "$CRLF_STDOUT" 2> "$CRLF_STDERR"
    status=$?
fi
set -e

if [ "$status" -ne 1 ]; then
    show_streams "$CRLF_STDOUT" "$CRLF_STDERR"
    fail "CRLF fmt --check exited $status, expected 1"
fi
if [ -s "$CRLF_STDOUT" ]; then
    show_streams "$CRLF_STDOUT" "$CRLF_STDERR"
    fail "CRLF fmt --check unexpectedly wrote stdout"
fi

grep -qF "fmt: would reformat $CRLF_FIXTURE" "$CRLF_STDERR" \
    || fail "missing would-reformat diagnostic"
grep -qF -- "--- a/$CRLF_FIXTURE" "$CRLF_STDERR" \
    || fail "missing stable old-file header"
grep -qF -- "+++ b/$CRLF_FIXTURE" "$CRLF_STDERR" \
    || fail "missing stable new-file header"
grep -qF "@@ -1,20000 +1,20000 @@" "$CRLF_STDERR" \
    || fail "whole-file hunk header changed"
grep -qF -- "-(define fmt-crlf-value-00001 : i64" "$CRLF_STDERR" \
    || fail "missing first removed CRLF line"
grep -qF -- "-(define fmt-crlf-value-10000 : i64" "$CRLF_STDERR" \
    || fail "missing last removed CRLF line"
grep -qF -- "+(define fmt-crlf-value-00001 : i64" "$CRLF_STDERR" \
    || fail "missing first canonical LF line"
grep -qF -- "+(define fmt-crlf-value-10000 : i64" "$CRLF_STDERR" \
    || fail "missing last canonical LF line"
grep -qF -- "   10000)" "$CRLF_STDERR" \
    || fail "missing final unchanged context line"

if [ "$HOST_OS" = linux ]; then
    echo "large CRLF formatter verification passed ($LINE_COUNT lines, $LINUX_MEMORY_LIMIT_BACKEND, 1 GiB limit)"
else
    echo "large CRLF formatter verification passed ($LINE_COUNT lines, structural Windows probe)"
fi
