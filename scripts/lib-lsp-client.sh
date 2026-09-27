#!/usr/bin/env sh

# lib-lsp-client.sh - a stdio JSON-RPC client for the local
# measure-lsp-*-latency.sh harnesses.
#
# Source it (not exec) after lib-gate.sh: `. "$ROOT/scripts/lib-lsp-client.sh"`.
# POSIX sh plus mkfifo, dd and awk. Request timers read `date +%s%N`, so they
# need a date(1) that prints nanoseconds (GNU coreutils, BusyBox, MSYS2); each
# timer includes one date(1) spawn, so sub-millisecond requests read as about
# a millisecond. A timer stops when the response header arrives: the server
# writes Content-Length first, so the response is complete by then, and the
# time does not include copying the body out of the pipe.
#
# Messages are files of compact JSON. The server runs with stdin and stdout on
# FIFOs in the work directory and stderr in WORKDIR/lsp.stderr.

LSP_CR=$(printf '\r')

# lsp_require_clock
#   Exit unless date(1) prints nanoseconds.
lsp_require_clock() {
    case $(date +%s%N) in
        '' | *[!0-9]*) fail "this harness needs a date(1) that supports %N (GNU coreutils, BusyBox or MSYS2)" ;;
    esac
}

# lsp_uri PATH
#   Print the file:// URI of an existing file or directory.
lsp_uri() {
    if [ -d "$1" ]; then
        _lsp_abs=$(CDPATH= cd -- "$1" && pwd)
    else
        _lsp_abs=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
    fi
    if command -v cygpath >/dev/null 2>&1; then
        _lsp_abs=$(cygpath -m "$_lsp_abs")
    fi
    case "$_lsp_abs" in
        /*) ;;
        *) _lsp_abs=/$_lsp_abs ;;
    esac
    printf '%s' "$_lsp_abs" | LC_ALL=C awk '
        BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
        {
            out = ""
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c ~ /[A-Za-z0-9_.~\/-]/) out = out c
                else out = out sprintf("%%%02X", ord[c])
            }
            printf "file://%s", out
        }'
}

# lsp_json_string_file FILE
#   Print the contents of FILE as a JSON string literal (UTF-8 passes through).
lsp_json_string_file() {
    _lsp_nl=0
    if [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -c | tr -d ' ')" = '\n' ]; then
        _lsp_nl=1
    fi
    LC_ALL=C awk -v nl="$_lsp_nl" '
        BEGIN { for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i); printf "\"" }
        {
            gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
            if ($0 ~ /[\001-\037]/) {
                out = ""
                for (i = 1; i <= length($0); i++) {
                    c = substr($0, i, 1)
                    out = out ((c in ctl) ? ctl[c] : c)
                }
                $0 = out
            }
            if (NR > 1) printf "\\n"
            printf "%s", $0
        }
        END { if (nl) printf "\\n"; printf "\"" }' "$1"
}

# lsp_start WORKDIR COMMAND [ARG ...]
#   Start the server and set LSP_PID. Exits through fail() if it cannot start.
lsp_start() {
    LSP_DIR=$1
    shift
    rm -f "$LSP_DIR/lsp.in" "$LSP_DIR/lsp.out"
    mkfifo "$LSP_DIR/lsp.in" "$LSP_DIR/lsp.out"
    "$@" < "$LSP_DIR/lsp.in" > "$LSP_DIR/lsp.out" 2> "$LSP_DIR/lsp.stderr" &
    LSP_PID=$!
    trap lsp_kill EXIT
    exec 3> "$LSP_DIR/lsp.in" 4< "$LSP_DIR/lsp.out"
    LSP_NEXT_ID=1
}

# lsp_kill
#   Kill a server that is still running (the EXIT trap).
lsp_kill() {
    if [ -n "${LSP_PID:-}" ] && kill -0 "$LSP_PID" 2>/dev/null; then
        kill "$LSP_PID" 2>/dev/null || :
    fi
}

lsp_died() {
    fail "$1: $(cat "$LSP_DIR/lsp.stderr" 2>/dev/null)"
}

# lsp_send_file FILE
#   Frame and send the JSON message in FILE.
lsp_send_file() {
    _lsp_size=$(wc -c < "$1")
    printf 'Content-Length: %d\r\n\r\n' "$_lsp_size" >&3
    cat "$1" >&3
}

# lsp_send_text JSON
#   Frame and send a short ASCII JSON message without forking.
lsp_send_text() {
    printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1" >&3
}

# lsp_notify METHOD PARAMS-JSON
lsp_notify() {
    lsp_send_text "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2}"
}

# lsp_notify_file METHOD PARAMS-FILE
lsp_notify_file() {
    {
        printf '{"jsonrpc":"2.0","method":"%s","params":' "$1"
        cat "$2"
        printf '}'
    } > "$LSP_DIR/send.json"
    lsp_send_file "$LSP_DIR/send.json"
}

# lsp_read_message FILE
#   Read one framed message into FILE; set LSP_HEADER_NS to the clock reading
#   taken when its header ended.
lsp_read_message() {
    _lsp_len=
    while :; do
        IFS= read -r _lsp_line <&4 || lsp_died "LSP ended before a response"
        _lsp_line=${_lsp_line%"$LSP_CR"}
        [ -n "$_lsp_line" ] || break
        case "$_lsp_line" in
            [Cc]ontent-[Ll]ength:*)
                _lsp_len=${_lsp_line#*:}
                _lsp_len=${_lsp_len# }
                ;;
            *:*) ;;
            *) fail "malformed LSP header: $_lsp_line" ;;
        esac
    done
    LSP_HEADER_NS=$(date +%s%N)
    case "$_lsp_len" in
        '' | *[!0-9]*) fail "missing or invalid Content-Length" ;;
    esac
    : > "$1"
    _lsp_have=0
    while [ "$_lsp_have" -lt "$_lsp_len" ]; do
        dd bs=$((_lsp_len - _lsp_have)) count=1 2>/dev/null <&4 >> "$1"
        _lsp_now=$(wc -c < "$1")
        [ "$_lsp_now" -gt "$_lsp_have" ] || fail "LSP payload ended early"
        _lsp_have=$_lsp_now
    done
}

# lsp_request METHOD PARAMS-JSON
#   Send a request and wait for its response, skipping other messages. Leaves
#   the response in $LSP_DIR/response.json, and the time from just before the
#   send to the response header in LSP_ELAPSED_NS; fails on a JSON-RPC error.
lsp_request() {
    _lsp_id=$LSP_NEXT_ID
    LSP_NEXT_ID=$((LSP_NEXT_ID + 1))
    _lsp_message="{\"jsonrpc\":\"2.0\",\"id\":$_lsp_id,\"method\":\"$1\",\"params\":$2}"
    _lsp_started=$(date +%s%N)
    lsp_send_text "$_lsp_message"
    while :; do
        lsp_read_message "$LSP_DIR/response.json"
        _lsp_got=$(LC_ALL=C awk '
            { s = s $0 }
            END {
                if (match(s, /"id":[0-9]+/)) print substr(s, RSTART + 5, RLENGTH - 5)
                else print "none"
            }' "$LSP_DIR/response.json")
        [ "$_lsp_got" = "$_lsp_id" ] && break
    done
    if LC_ALL=C awk '{ s = s $0 } END { exit !(s ~ /^\{"jsonrpc":"2\.0","id":[0-9]+,"error":/) }' "$LSP_DIR/response.json"; then
        fail "$1 returned JSON-RPC error: $(cat "$LSP_DIR/response.json")"
    fi
    LSP_ELAPSED_NS=$((LSP_HEADER_NS - _lsp_started))
}

# lsp_ms NANOSECONDS
#   Print a nanosecond count as milliseconds with three decimals.
lsp_ms() {
    awk -v ns="$1" 'BEGIN { printf "%.3f\n", ns / 1000000 }'
}

# lsp_result_text
#   Print the "result" value of the last response.
lsp_result_text() {
    LC_ALL=C awk '
        { s = s $0 }
        END {
            if (!match(s, /^\{"jsonrpc":"2\.0","id":[0-9]+,"result":/)) exit 1
            print substr(s, RLENGTH + 1, length(s) - RLENGTH - 1)
        }' "$LSP_DIR/response.json"
}

# lsp_rss_bytes
#   Print the server's resident set size, or "unavailable".
lsp_rss_bytes() {
    if [ -r "/proc/$LSP_PID/status" ]; then
        awk '$1 == "VmRSS:" { print $2 * 1024; found = 1; exit }
            END { if (!found) print "unavailable" }' "/proc/$LSP_PID/status"
    else
        echo unavailable
    fi
}

# lsp_close [STRICT]
#   Shut the server down and wait for it (30 s at most). Fails if it exits
#   non-zero, or with STRICT=1 also if it wrote anything to stderr.
lsp_close() {
    lsp_request shutdown null
    lsp_notify exit null
    exec 3>&-
    ( sleep 30; kill "$LSP_PID" 2>/dev/null ) &
    _lsp_watchdog=$!
    cat <&4 > /dev/null
    exec 4<&-
    _lsp_status=0
    wait "$LSP_PID" || _lsp_status=$?
    kill "$_lsp_watchdog" 2>/dev/null || :
    LSP_PID=
    [ "$_lsp_status" -eq 0 ] || fail "LSP exited with status $_lsp_status: $(cat "$LSP_DIR/lsp.stderr")"
    if [ "${1:-0}" = 1 ] && [ -s "$LSP_DIR/lsp.stderr" ]; then
        fail "LSP exited with status 0: $(cat "$LSP_DIR/lsp.stderr")"
    fi
}

# lsp_stats FILE
#   For one nanosecond count per line, print "<min> <median> <p95> <max>" in
#   milliseconds with three decimals (the median averages the middle pair; p95
#   is the sorted value at 0-based index floor(0.95 n), clamped to the last).
lsp_stats() {
    sort -n "$1" | awk '
        { v[++n] = $1 }
        END {
            if (n % 2) median = v[(n + 1) / 2]
            else median = (v[n / 2] + v[n / 2 + 1]) / 2
            p = int(n * 0.95) + 1
            if (p > n) p = n
            printf "%.3f %.3f %.3f %.3f\n", v[1] / 1e6, median / 1e6, v[p] / 1e6, v[n] / 1e6
        }'
}
