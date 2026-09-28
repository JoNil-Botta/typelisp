#!/usr/bin/env sh
set -eu

# Measure one cold open/check/full-token response and repeated full-token reads
# over the retained document semantic snapshot. The benchmark source defaults
# to the compiler's largest typechecking module and is never modified.
# scripts/lib-lsp-client.sh describes the client and its clock.

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

REQUESTS=${TYPELISP_LSP_SEMANTIC_TOKEN_REQUESTS:-100}
SOURCE=${TYPELISP_LSP_SEMANTIC_TOKEN_SOURCE:-src/compiler_typecheck_core.tl}
WORKDIR=${TYPELISP_LSP_SEMANTIC_TOKEN_WORKDIR:-target/lsp-semantic-tokens-latency}

case "$REQUESTS" in
    ''|*[!0-9]*)
        echo "semantic-token request count must be a positive integer" >&2
        exit 1
        ;;
esac
if [ "$REQUESTS" -lt 100 ]; then
    echo "semantic-token benchmark requires at least 100 repeated requests" >&2
    exit 1
fi
if [ ! -f "$SOURCE" ]; then
    echo "semantic-token benchmark source does not exist: $SOURCE" >&2
    exit 1
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

uri=$(lsp_uri "$SOURCE")
source_abs=$(CDPATH= cd -- "$(dirname -- "$SOURCE")" && pwd)/$(basename -- "$SOURCE")
source_rel=${source_abs#"$ROOT/"}
params="{\"textDocument\":{\"uri\":\"$uri\"}}"

# token_data FILE: write the last response's "data" array text to FILE.
token_data() {
    lsp_result_text | LC_ALL=C awk '{
        if (!match($0, /"data":\[[-0-9,]*\]/)) exit 1
        print substr($0, RSTART + 8, RLENGTH - 9)
    }' > "$1"
}

lsp_start "$WORKDIR" "$COMPILER" lsp --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src"
lsp_request initialize "{\"rootUri\":\"$(lsp_uri "$ROOT")\",\"capabilities\":{}}"
rss_before_open=$(lsp_rss_bytes)
{
    printf '{"textDocument":{"uri":"%s","languageId":"typelisp","version":1,"text":' "$uri"
    lsp_json_string_file "$SOURCE"
    printf '}}'
} > "$WORKDIR/params.json"
opened=$(date +%s%N)
lsp_notify_file textDocument/didOpen "$WORKDIR/params.json"
lsp_request textDocument/semanticTokens/full "$params"
cold_request_ns=$LSP_ELAPSED_NS
cold_open_and_request_ns=$((LSP_HEADER_NS - opened))
token_data "$WORKDIR/baseline.txt" ||
    fail "unexpected semantic-token result: $(head -c 2000 "$WORKDIR/response.json")"
encoded_integers=$(tr ',' '\n' < "$WORKDIR/baseline.txt" | grep -c .) || :
[ $((encoded_integers % 5)) -eq 0 ] ||
    fail "semantic-token data length is not divisible by five"
result_bytes=$(lsp_result_text | tr -d '\n' | wc -c)
rss_after_cold=$(lsp_rss_bytes)

: > "$WORKDIR/timings.txt"
rss_before_hot=$(lsp_rss_bytes)
i=0
while [ "$i" -lt "$REQUESTS" ]; do
    lsp_request textDocument/semanticTokens/full "$params"
    token_data "$WORKDIR/warm.txt" && cmp -s "$WORKDIR/warm.txt" "$WORKDIR/baseline.txt" ||
        fail "warm semantic-token response changed"
    echo "$LSP_ELAPSED_NS" >> "$WORKDIR/timings.txt"
    i=$((i + 1))
done
rss_after_hot=$(lsp_rss_bytes)
lsp_close 1

delta() {
    if [ "$1" = unavailable ] || [ "$2" = unavailable ]; then
        echo unavailable
    else
        echo $(($2 - $1))
    fi
}

set -- $(lsp_stats "$WORKDIR/timings.txt")
printf 'lsp-semantic-tokens source=%s source_bytes=%s tokens=%s encoded_integers=%s result_bytes=%s cold_request_ms=%s cold_open_and_request_ms=%s cold_retained_rss_delta_bytes=%s warm_requests=%s warm_min_ms=%s warm_median_ms=%s warm_p95_ms=%s warm_max_ms=%s warm_retained_rss_delta_bytes=%s\n' \
    "$source_rel" "$(wc -c < "$SOURCE" | tr -d ' ')" "$((encoded_integers / 5))" "$encoded_integers" \
    "$(echo "$result_bytes" | tr -d ' ')" "$(lsp_ms "$cold_request_ns")" "$(lsp_ms "$cold_open_and_request_ns")" \
    "$(delta "$rss_before_open" "$rss_after_cold")" "$REQUESTS" "$1" "$2" "$3" "$4" \
    "$(delta "$rss_before_hot" "$rss_after_hot")"
