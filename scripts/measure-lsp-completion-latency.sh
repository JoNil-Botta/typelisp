#!/usr/bin/env sh
set -eu

# Measure cold analysis separately from repeated completion over one retained
# document/workspace snapshot.  The hot loop alternates a deep lexical query
# and a large-workspace import query without edits, filesystem reads, or
# compiler reruns between requests. scripts/lib-lsp-client.sh describes the
# client and its clock.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-gate.sh"
. "$ROOT/scripts/lib-lsp-client.sh"
gate_compiler

if [ ! -x "$COMPILER" ] && [ ! -f "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi
lsp_require_clock

WORKDIR=${TYPELISP_LSP_COMPLETION_WORKDIR:-target/lsp-completion-latency}
REQUESTS=${TYPELISP_LSP_COMPLETION_REQUESTS:-100}
TOP_LEVEL=${TYPELISP_LSP_COMPLETION_TOP_LEVEL:-1000}
DEPTH=${TYPELISP_LSP_COMPLETION_DEPTH:-128}
MODULES=${TYPELISP_LSP_COMPLETION_MODULES:-128}

for value in "$REQUESTS" "$TOP_LEVEL" "$DEPTH" "$MODULES"; do
    case "$value" in
        ''|*[!0-9]*)
            echo "completion benchmark sizes must be positive integers" >&2
            exit 1
            ;;
    esac
    if [ "$value" -le 0 ]; then
        echo "completion benchmark sizes must be positive integers" >&2
        exit 1
    fi
done
if [ "$REQUESTS" -lt 100 ]; then
    echo "completion benchmark requires at least 100 repeated requests" >&2
    exit 1
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/bench"

i=0
while [ "$i" -lt "$MODULES" ]; do
    printf '(module bench.mod%d)\n(define module_value_%d : i64 %d)\n(define (module_function_%d [value : i64]) : i64 value)\n' \
        "$i" "$i" "$i" "$i" > "$WORKDIR/bench/mod$i.tl"
    i=$((i + 1))
done

# main.tl: the import line, TOP_LEVEL definitions, then one function whose
# body nests DEPTH lets; the deep query sits on the innermost reference.
awk -v top="$TOP_LEVEL" -v depth="$DEPTH" 'BEGIN {
    print "(module bench.main)"
    print "(import bench.mod0 as m0)"
    for (i = 0; i < top; i++) printf "(define benchmark_value_%d : i64 %d)\n", i, i
    body = "deep_" (depth - 1)
    for (i = depth - 1; i >= 0; i--) {
        initial = (i == 0) ? "root" : "deep_" (i - 1)
        body = "(let [deep_" i " : i64 " initial "] " body ")"
    }
    print "(define (deep [root : i64]) : i64 " body ")"
}' > "$WORKDIR/main.tl"
deep_line_number=$((TOP_LEVEL + 2))
# The cursor sits just after the `deep_` of the last `deep_<DEPTH-1>`.
deep_cursor=$(awk -v n="$((deep_line_number + 1))" -v name="deep_$((DEPTH - 1))" 'NR == n {
    s = $0; at = 0
    while ((i = index(s, name)) > 0) { at += i; s = substr(s, i + 1) }
    print at - 1 + length("deep_"); exit
}' "$WORKDIR/main.tl")
uri=$(lsp_uri "$WORKDIR/main.tl")
root_uri=$(lsp_uri "$WORKDIR")
deep_params="{\"textDocument\":{\"uri\":\"$uri\"},\"position\":{\"line\":$deep_line_number,\"character\":$deep_cursor}}"
import_params="{\"textDocument\":{\"uri\":\"$uri\"},\"position\":{\"line\":1,\"character\":15}}"

# completion_count: the number of items in the last completion response, a
# bare list or a CompletionList (each CompletionItem has exactly one "label").
completion_count() {
    lsp_result_text | LC_ALL=C awk '{
        if ($0 !~ /^(\[|\{)/) { print "invalid"; exit }
        if ($0 ~ /^\{/ && $0 !~ /"items":\[/) { print "invalid"; exit }
        print gsub(/"label":/, "&")
    }'
}

if [ "${TYPELISP_LSP_COMPLETION_CACHEGRIND:-}" = 1 ]; then
    lsp_start "$WORKDIR" valgrind --tool=cachegrind --quiet \
        "--cachegrind-out-file=$WORKDIR/cachegrind.out" -- \
        "$COMPILER" lsp --stdlib-root "$ROOT/stdlib"
else
    lsp_start "$WORKDIR" "$COMPILER" lsp --stdlib-root "$ROOT/stdlib"
fi
lsp_request initialize "{\"rootUri\":\"$root_uri\",\"capabilities\":{}}"
{
    printf '{"textDocument":{"uri":"%s","languageId":"typelisp","version":1,"text":' "$uri"
    lsp_json_string_file "$WORKDIR/main.tl"
    printf '}}'
} > "$WORKDIR/params.json"
opened=$(date +%s%N)
lsp_notify_file textDocument/didOpen "$WORKDIR/params.json"
lsp_request textDocument/completion "$deep_params"
cold_total_ns=$((LSP_HEADER_NS - opened))
cold_request_ns=$LSP_ELAPSED_NS
cold_candidates=$(completion_count)
case "$cold_candidates" in
    '' | *[!0-9]*) fail "unexpected completion result: $(cat "$WORKDIR/response.json")" ;;
esac

rss_before=$(lsp_rss_bytes)
: > "$WORKDIR/timings.txt"
: > "$WORKDIR/candidates.txt"
i=0
while [ "$i" -lt "$REQUESTS" ]; do
    if [ $((i % 2)) -eq 0 ]; then
        lsp_request textDocument/completion "$deep_params"
    else
        lsp_request textDocument/completion "$import_params"
    fi
    count=$(completion_count)
    case "$count" in
        '' | *[!0-9]*) fail "unexpected completion result: $(cat "$WORKDIR/response.json")" ;;
    esac
    echo "$LSP_ELAPSED_NS" >> "$WORKDIR/timings.txt"
    echo "$count" >> "$WORKDIR/candidates.txt"
    i=$((i + 1))
done
rss_after=$(lsp_rss_bytes)
lsp_close

retained=unavailable
if [ "$rss_before" != unavailable ] && [ "$rss_after" != unavailable ]; then
    retained=$((rss_after - rss_before))
fi
instruction_count=unavailable
if [ "${TYPELISP_LSP_COMPLETION_CACHEGRIND:-}" = 1 ] && [ -f "$WORKDIR/cachegrind.out" ]; then
    instruction_count=$(awk '$1 == "summary:" && $2 != "" { print $2; found = 1; exit }
        END { if (!found) print "unavailable" }' "$WORKDIR/cachegrind.out")
fi
set -- $(lsp_stats "$WORKDIR/timings.txt")
p50=$2 p95=$3 max=$4
set -- $(sort -n "$WORKDIR/candidates.txt" | sed -n '1p;$p')

echo "[lsp-completion] cold_total_ms=$(lsp_ms "$cold_total_ns") cold_request_ms=$(lsp_ms "$cold_request_ns") cold_candidates=$cold_candidates"
echo "[lsp-completion] requests=$REQUESTS p50_ms=$p50 p95_ms=$p95 max_ms=$max candidate_min=$1 candidate_max=$2"
echo "[lsp-completion] rss_before_bytes=$rss_before rss_after_bytes=$rss_after retained_rss_delta_bytes=$retained"
echo "[lsp-completion] top_level=$TOP_LEVEL lexical_depth=$DEPTH workspace_modules=$MODULES compiler_reruns_in_hot_loop=0 filesystem_reads_in_hot_loop=0"
echo "[lsp-completion] dynamic_instructions=$instruction_count"
