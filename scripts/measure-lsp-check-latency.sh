#!/usr/bin/env sh
set -eu

# measure-lsp-check-latency.sh - exercise interactive LSP tl/check latency.
#
# This intentionally uses a single persistent `typelisp lsp` process.  Each
# document begins invalid, receives an unchanged tl/check, is edited to valid
# source, then receives another tl/check.  The request timers therefore cover
# the normal LSP queue after didOpen/didChange, while the unchanged request
# demonstrates the document-result cache. scripts/lib-lsp-client.sh describes
# the client and its clock.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-gate.sh"
. "$ROOT/scripts/lib-lsp-client.sh"
gate_compiler

# MSYS can execute a Windows .exe even when its POSIX executable bit is not
# represented in the checkout.  Keep the ordinary executable check for other
# paths while accepting a regular file for that host case.
if [ ! -x "$COMPILER" ] && [ ! -f "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi
lsp_require_clock

WORKDIR=${TYPELISP_LSP_CHECK_WORKDIR:-target/lsp-check-latency}
SMALL_LINES=${TYPELISP_LSP_CHECK_SMALL_LINES:-500}
LARGE_LINES=${TYPELISP_LSP_CHECK_LARGE_LINES:-6000}

case "$SMALL_LINES" in
    ''|*[!0-9]*)
        echo "LSP benchmark line counts must be positive integers" >&2
        exit 1
        ;;
esac
case "$LARGE_LINES" in
    ''|*[!0-9]*)
        echo "LSP benchmark line counts must be positive integers" >&2
        exit 1
        ;;
esac
if [ "$SMALL_LINES" -le 2 ] || [ "$LARGE_LINES" -le 2 ]; then
    echo "LSP benchmark line counts must be greater than 2" >&2
    exit 1
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# write_source LABEL LINES FILE: a stdlib import and LINES - 2 definitions.
write_source() {
    awk -v label="$1" -v count="$2" 'BEGIN {
        print "(import stdlib.string)"
        print ""
        for (i = 1; i < count - 1; i++) printf "(define benchmark_%s_%d : i64 %d)\n", label, i, i
    }' > "$3"
}

# open_document URI TEXT-FILE
open_document() {
    {
        printf '{"textDocument":{"uri":"%s","languageId":"typelisp","version":1,"text":' "$1"
        lsp_json_string_file "$2"
        printf '}}'
    } > "$WORKDIR/params.json"
    lsp_notify_file textDocument/didOpen "$WORKDIR/params.json"
}

# change_document URI TEXT-FILE
change_document() {
    {
        printf '{"textDocument":{"uri":"%s","version":2},"contentChanges":[{"text":' "$1"
        lsp_json_string_file "$2"
        printf '}]}'
    } > "$WORKDIR/params.json"
    lsp_notify_file textDocument/didChange "$WORKDIR/params.json"
}

# check URI EXPECTED-SUCCESS: a timed tl/check; sets LSP_ELAPSED_NS.
check() {
    lsp_request tl/check "{\"textDocument\":{\"uri\":\"$1\"}}"
    _success=$(lsp_result_text | LC_ALL=C awk '{
        if (match($0, /^\{"success":(true|false)/)) print substr($0, 12, RLENGTH - 11)
        else if (match($0, /[{,]"success":(true|false)/)) print substr($0, RSTART + 11, RLENGTH - 11)
        else print "missing"
    }')
    [ "$_success" = "$2" ] ||
        fail "tl/check expected success=$2, got $(cat "$WORKDIR/response.json")"
}

# run_case LABEL LINES: print "<lines> <invalid-ns> <unchanged-ns> <edited-ns>".
run_case() {
    _path=$WORKDIR/$1.tl
    write_source "$1" "$2" "$_path"
    cp "$_path" "$WORKDIR/invalid.txt"
    printf '(\n' >> "$WORKDIR/invalid.txt"
    _uri=$(lsp_uri "$_path")
    open_document "$_uri" "$WORKDIR/invalid.txt"
    check "$_uri" false
    _invalid=$LSP_ELAPSED_NS
    check "$_uri" false
    _unchanged=$LSP_ELAPSED_NS
    change_document "$_uri" "$_path"
    check "$_uri" true
    printf '%s %s %s %s\n' "$2" "$_invalid" "$_unchanged" "$LSP_ELAPSED_NS" >> "$WORKDIR/results.txt"
}

lsp_start "$WORKDIR" "$COMPILER" lsp --stdlib-root "$ROOT/stdlib" --prefix-cache-stats
lsp_request initialize '{"capabilities":{}}'

# Seed the shared import path so subsequent edited documents can expose the
# compiler's existing prefix-cache counters at shutdown.
printf '(import stdlib.string)\n(define warmup : i64 1)\n' > "$WORKDIR/warmup.tl"
warmup_uri=$(lsp_uri "$WORKDIR/warmup.tl")
open_document "$warmup_uri" "$WORKDIR/warmup.tl"
check "$warmup_uri" true

: > "$WORKDIR/results.txt"
run_case generated-500-lines "$SMALL_LINES"
run_case generated-6000-lines "$LARGE_LINES"
lsp_close

stats=$(awk '/^typecheck-prefix-cache\|lsp\|/ { print; exit }' "$WORKDIR/lsp.stderr")
[ -n "$stats" ] ||
    fail "LSP did not emit the requested prefix-cache stats; see $WORKDIR/lsp.stderr"

echo "[lsp-check] persistent_server=1 scenarios=2"
awk '{
    target = ($1 <= 500) ? 500 : 3000
    edited = $4 / 1e6
    printf "[lsp-check] lines=%d invalid_check_ms=%.3f unchanged_check_ms=%.3f edited_check_ms=%.3f edited_target_ms=%d comparison=%s\n",
        $1, $2 / 1e6, $3 / 1e6, edited, target, (edited < target) ? "within" : "over"
}' "$WORKDIR/results.txt"
echo "[lsp-check] $stats"
echo "[lsp-check] unchanged_check is served from the per-document result cache"
echo "[lsp-check] targets are informational local baselines, not pass/fail gates"
