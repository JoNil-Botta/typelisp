#!/usr/bin/env sh
set -eu

# No-Rust REPL and LSP corpus runner for tests/public-tools/.
# Usage:
#   TYPELISP_BIN=./target/release/typelisp tests/public-tools/run-corpus.sh [repl|lsp]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIXTURE_ROOT="$ROOT/tests/public-tools"
WORKDIR="$ROOT/target/public-tools-corpus"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *) HOST_OS=other ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    COMPILER="$ROOT/target/release/typelisp"
    [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe"
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "Compiler not found or not executable: $COMPILER" >&2
    exit 1
fi

MODE=${1:-all}
case "$MODE" in
    all | repl | lsp) ;;
    *)
        echo "usage: tests/public-tools/run-corpus.sh [repl|lsp]" >&2
        exit 1
        ;;
esac

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

failed=0
passed=0

record_pass() {
    printf '  PASS %s\n' "$1"
    passed=$((passed + 1))
}

record_fail() {
    printf '  FAIL %s\n' "$1"
    failed=$((failed + 1))
}

contains_file() {
    file=$1
    text=$2
    grep -F -- "$text" "$file" >/dev/null 2>&1
}

json_has_key() {
    file=$1
    key=$2
    grep -F "\"$key\"" "$file" >/dev/null 2>&1
}

json_number_value() {
    file=$1
    key=$2
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\\(-\\{0,1\\}[0-9][0-9]*\\).*/\\1/p" "$file" | head -n 1
}

write_json_string_value() {
    file=$1
    key=$2
    dest=$3
    awk -v key="$key" '
function decode(s,    i, n, ch, esc, out) {
    out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1)
        if (ch == "\\") {
            i++
            esc = substr(s, i, 1)
            if (esc == "n") out = out "\n"
            else if (esc == "r") out = out "\r"
            else if (esc == "t") out = out "\t"
            else out = out esc
        } else {
            out = out ch
        }
    }
    return out
}
{
    marker = "\"" key "\""
    pos = index($0, marker)
    if (!pos) next
    rest = substr($0, pos + length(marker))
    colon = index(rest, ":")
    if (!colon) next
    rest = substr(rest, colon + 1)
    start = index(rest, "\"")
    if (!start) next
    rest = substr(rest, start + 1)
    out = ""
    for (i = 1; i <= length(rest); i++) {
        ch = substr(rest, i, 1)
        if (ch == "\\") {
            out = out ch substr(rest, i + 1, 1)
            i++
        } else if (ch == "\"") {
            printf "%s", decode(out)
            exit
        } else {
            out = out ch
        }
    }
}
' "$file" > "$dest"
}

json_array_strings() {
    file=$1
    key=$2
    awk -v key="$key" '
function decode(s,    i, n, ch, esc, out) {
    out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1)
        if (ch == "\\") {
            i++
            esc = substr(s, i, 1)
            if (esc == "n") out = out "\n"
            else if (esc == "r") out = out "\r"
            else if (esc == "t") out = out "\t"
            else out = out esc
        } else {
            out = out ch
        }
    }
    return out
}
function emit_strings(text,    i, ch, raw) {
    for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (ch != "\"") continue
        raw = ""
        i++
        while (i <= length(text)) {
            ch = substr(text, i, 1)
            if (ch == "\\") {
                raw = raw ch substr(text, i + 1, 1)
                i += 2
                continue
            }
            if (ch == "\"") {
                print decode(raw)
                break
            }
            raw = raw ch
            i++
        }
    }
}
{
    if (!active) {
        marker = "\"" key "\""
        pos = index($0, marker)
        if (!pos) next
        rest = substr($0, pos + length(marker))
        open = index(rest, "[")
        if (!open) next
        active = 1
        rest = substr(rest, open + 1)
    } else {
        rest = $0
    }

    close_pos = index(rest, "]")
    if (close_pos) {
        emit_strings(substr(rest, 1, close_pos - 1))
        exit
    }
    emit_strings(rest)
}
' "$file"
}

json_object_strings() {
    text=$1
    key=$2
    tmp_path=$3
    tmp_uri=$4
    printf '%s\n' "$text" | awk -v key="$key" -v tmp_path="$tmp_path" -v tmp_uri="$tmp_uri" '
function decode(s,    i, n, ch, esc, out) {
    out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1)
        if (ch == "\\") {
            i++
            esc = substr(s, i, 1)
            if (esc == "n") out = out "\n"
            else if (esc == "r") out = out "\r"
            else if (esc == "t") out = out "\t"
            else out = out esc
        } else {
            out = out ch
        }
    }
    gsub(/\$\{\{TMP_URI\}\}/, tmp_uri, out)
    gsub(/\$\{\{TMP\}\}/, tmp_path, out)
    return out
}
{
    rest = $0
    marker = "\"" key "\""
    while ((pos = index(rest, marker)) > 0) {
        rest = substr(rest, pos + length(marker))
        colon = index(rest, ":")
        if (!colon) exit
        rest = substr(rest, colon + 1)
        start = index(rest, "\"")
        if (!start) continue
        rest = substr(rest, start + 1)
        raw = ""
        for (i = 1; i <= length(rest); i++) {
            ch = substr(rest, i, 1)
            if (ch == "\\") {
                raw = raw ch substr(rest, i + 1, 1)
                i++
            } else if (ch == "\"") {
                last = decode(raw)
                found = 1
                rest = substr(rest, i + 1)
                break
            } else {
                raw = raw ch
            }
        }
    }
}
END {
    if (found) print last
}
'
}

check_exact_if_present() {
    spec=$1
    key=$2
    actual=$3
    label=$4
    errors=$5
    if json_has_key "$spec" "$key"; then
        expected="$WORKDIR/expected.$$.$key"
        write_json_string_value "$spec" "$key" "$expected"
        if ! cmp -s "$actual" "$expected"; then
            {
                printf '%s mismatch\n' "$label"
                printf 'expected:\n'
                sed 's/^/  /' "$expected" || true
                printf 'got:\n'
                sed 's/^/  /' "$actual" || true
            } >> "$errors"
        fi
        rm -f "$expected"
    fi
}

check_stream_patterns() {
    spec=$1
    key=$2
    actual=$3
    label=$4
    mode=$5
    errors=$6
    json_array_strings "$spec" "$key" | while IFS= read -r pattern || [ -n "$pattern" ]; do
        [ -n "$pattern" ] || continue
        if [ "$mode" = contains ]; then
            if ! contains_file "$actual" "$pattern"; then
                printf '%s missing: %s\n' "$label" "$pattern" >> "$errors"
            fi
        else
            if contains_file "$actual" "$pattern"; then
                printf '%s unexpectedly contains: %s\n' "$label" "$pattern" >> "$errors"
            fi
        fi
    done
}

check_repl_like_result() {
    name=$1
    spec=$2
    out=$3
    err=$4
    code=$5
    errors=$6

    want_code=$(json_number_value "$spec" exit)
    [ -n "$want_code" ] || want_code=0
    if [ "$code" -ne "$want_code" ]; then
        printf 'expected exit %s, got %s\n' "$want_code" "$code" >> "$errors"
    fi

    check_stream_patterns "$spec" stdout_contains "$out" stdout contains "$errors"
    check_stream_patterns "$spec" stdout_not_contains "$out" stdout not_contains "$errors"
    check_stream_patterns "$spec" stderr_contains "$err" stderr contains "$errors"
    check_stream_patterns "$spec" stderr_not_contains "$err" stderr not_contains "$errors"
    check_exact_if_present "$spec" stdout_exact "$out" stdout "$errors"
    check_exact_if_present "$spec" stderr_exact "$err" stderr "$errors"

    if [ -s "$errors" ]; then
        record_fail "$name"
        sed 's/^/    - /' "$errors"
    else
        record_pass "$name"
    fi
}

run_repl_fixture() {
    path=$1
    name=$2
    spec=$3
    binary=$4
    invocation=${5:-compiler}
    case_id=$(printf '%s' "$name" | tr '/.' '__')
    out="$WORKDIR/$case_id.out"
    err="$WORKDIR/$case_id.err"
    errors="$WORKDIR/$case_id.errors"
    : > "$errors"

    set +e
    if [ "$invocation" = compiler ]; then
        "$binary" repl < "$path" > "$out" 2> "$err"
    else
        "$binary" < "$path" > "$out" 2> "$err"
    fi
    code=$?
    set -e

    if [ ! -f "$spec" ]; then
        if [ "$code" -ne 0 ]; then
            printf 'expected exit 0, got %s\n' "$code" > "$errors"
        fi
        if [ -s "$err" ]; then
            printf 'expected empty stderr\n' >> "$errors"
        fi
    else
        check_repl_like_result "$name" "$spec" "$out" "$err" "$code" "$errors"
        return
    fi

    if [ -s "$errors" ]; then
        record_fail "$name"
        sed 's/^/    - /' "$errors"
    else
        record_pass "$name"
    fi
}

canonical_tmp_path() {
    path=$1
    if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m -a -l "$path"
    else
        (CDPATH= cd -- "$path" && pwd -P)
    fi
}

file_uri_for_path() {
    path=$1
    uri_path=$(printf '%s' "$path" | sed 's/ /%20/g')
    if [ "$HOST_OS" = windows ]; then
        printf 'file:///%s' "$uri_path"
    else
        printf 'file://%s' "$uri_path"
    fi
}

frame_append() {
    frame_file=$1
    frame_body=$2
    frame_len=$(printf '%s' "$frame_body" | wc -c | tr -d ' ')
    {
        printf 'Content-Length: %s\r\n\r\n' "$frame_len"
        printf '%s' "$frame_body"
    } >> "$frame_file"
}

write_json_frames() {
    input_json=$1
    output_frames=$2
    tmp_path=$3
    tmp_uri=$4
    : > "$output_frames"
    awk -v tmp_path="$tmp_path" -v tmp_uri="$tmp_uri" '
function replace_vars(s) {
    gsub(/\$\{\{TMP_URI\}\}/, tmp_uri, s)
    gsub(/\$\{\{TMP\}\}/, tmp_path, s)
    return s
}
{
    line = $0
    sub(/^[[:space:]]*/, "", line)
    sub(/[[:space:]]*,[[:space:]]*$/, "", line)
    if (line ~ /^\{/) {
        print replace_vars(line)
    }
}
' "$input_json" | while IFS= read -r payload || [ -n "$payload" ]; do
        frame_append "$output_frames" "$payload"
    done
}

extract_lsp_bodies() {
    stdout_file=$1
    messages_file=$2
    awk '
BEGIN { RS = "Content-Length: "; ORS = "" }
NR == 1 { next }
{
    body = $0
    cr = sprintf("%c", 13)
    gsub(cr, "", body)
    sub(/^[0-9]+\n\n/, "", body)
    printf "%s\n", body
}
' "$stdout_file" > "$messages_file"
}

message_has() {
    message=$1
    needle=$2
    case "$message" in
        *"$needle"*) return 0 ;;
        *) return 1 ;;
    esac
}

check_lsp_message_line() {
    check_line=$1
    messages_file=$2
    tmp_path=$3
    tmp_uri=$4

    raw_contains="$WORKDIR/check-raw-contains.$$"
    raw_not_contains="$WORKDIR/check-raw-not-contains.$$"
    json_contains="$WORKDIR/check-json-contains.$$"
    json_object_strings "$check_line" raw_contains "$tmp_path" "$tmp_uri" > "$raw_contains"
    json_object_strings "$check_line" raw_not_contains "$tmp_path" "$tmp_uri" > "$raw_not_contains"
    json_object_strings "$check_line" json_contains "$tmp_path" "$tmp_uri" > "$json_contains"

    id_value=$(printf '%s\n' "$check_line" | sed -n 's/.*"jsonpath_id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
    result_null=0
    if printf '%s\n' "$check_line" | grep -F '"jsonpath_result": null' >/dev/null 2>&1; then
        result_null=1
    fi

    found=1
    while IFS= read -r message || [ -n "$message" ]; do
        ok=0

        if [ -n "$id_value" ] && ! message_has "$message" "\"id\":$id_value"; then
            ok=1
        fi
        if [ "$result_null" -eq 1 ] && ! message_has "$message" '"result":null'; then
            ok=1
        fi

        while IFS= read -r needle || [ -n "$needle" ]; do
            [ -n "$needle" ] || continue
            if ! message_has "$message" "$needle"; then
                ok=1
                break
            fi
        done < "$raw_contains"

        while IFS= read -r needle || [ -n "$needle" ]; do
            [ -n "$needle" ] || continue
            if ! message_has "$message" "$needle"; then
                ok=1
                break
            fi
        done < "$json_contains"

        while IFS= read -r needle || [ -n "$needle" ]; do
            [ -n "$needle" ] || continue
            if message_has "$message" "$needle"; then
                ok=1
                break
            fi
        done < "$raw_not_contains"

        if [ "$ok" -eq 0 ]; then
            found=0
            break
        fi
    done < "$messages_file"

    rm -f "$raw_contains" "$raw_not_contains" "$json_contains"
    return "$found"
}

check_lsp_result() {
    name=$1
    spec=$2
    out=$3
    err=$4
    code=$5
    messages=$6
    tmp_path=$7
    tmp_uri=$8
    errors=$9

    want_code=$(json_number_value "$spec" exit)
    [ -n "$want_code" ] || want_code=0
    if [ "$code" -ne "$want_code" ]; then
        printf 'expected exit %s, got %s\n' "$want_code" "$code" >> "$errors"
    fi

    check_stream_patterns "$spec" stdout_contains "$out" stdout contains "$errors"
    check_stream_patterns "$spec" stdout_not_contains "$out" stdout not_contains "$errors"
    check_stream_patterns "$spec" stderr_contains "$err" stderr contains "$errors"
    check_stream_patterns "$spec" stderr_not_contains "$err" stderr not_contains "$errors"
    check_exact_if_present "$spec" stdout_exact "$out" stdout "$errors"
    check_exact_if_present "$spec" stderr_exact "$err" stderr "$errors"

    if json_has_key "$spec" message_count; then
        want_count=$(json_number_value "$spec" message_count)
        got_count=$(wc -l < "$messages" | tr -d ' ')
        if [ "$got_count" -ne "$want_count" ]; then
            printf 'expected %s messages, got %s\n' "$want_count" "$got_count" >> "$errors"
        fi
    fi

    awk '
        /"message_checks"[[:space:]]*:/ { active = 1; next }
        active && /^[[:space:]]*\]/ { exit }
        active && /\{/ { print }
    ' "$spec" | while IFS= read -r check_line || [ -n "$check_line" ]; do
        [ -n "$check_line" ] || continue
        if ! check_lsp_message_line "$check_line" "$messages" "$tmp_path" "$tmp_uri"; then
            printf 'no message matched: %s\n' "$check_line" >> "$errors"
        fi
    done

    if [ -s "$errors" ]; then
        record_fail "$name"
        sed 's/^/    - /' "$errors"
    else
        record_pass "$name"
    fi
}

run_lsp_fixture() {
    path=$1
    name=$2
    binary=$3
    base=${path%.in.json}
    spec="$base.spec.json"
    prep="$base.prep.sh"
    case_id=$(printf '%s' "$name" | tr '/.' '__')
    stdin_file="$WORKDIR/$case_id.in"
    out="$WORKDIR/$case_id.out"
    err="$WORKDIR/$case_id.err"
    messages="$WORKDIR/$case_id.messages"
    errors="$WORKDIR/$case_id.errors"
    : > "$errors"

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-lsp-fixture.XXXXXX")
    tmp_path=$(canonical_tmp_path "$tmpdir")
    tmp_uri=$(file_uri_for_path "$tmp_path")

    if [ -f "$prep" ]; then
        FIXTURE_TMP=$tmpdir FIXTURE_TMP_URI=$tmp_uri sh "$prep"
    fi

    write_json_frames "$path" "$stdin_file" "$tmp_path" "$tmp_uri"

    set +e
    "$binary" lsp < "$stdin_file" > "$out" 2> "$err"
    code=$?
    set -e

    extract_lsp_bodies "$out" "$messages"
    check_lsp_result "$name" "$spec" "$out" "$err" "$code" "$messages" "$tmp_path" "$tmp_uri" "$errors"
    rm -rf "$tmpdir"
}

build_selfhost_binary() {
    name=$1
    bin_path="$WORKDIR/typelisp-corpus-$name"
    src="$ROOT/selfhost/$name.tl"
    set +e
    "$COMPILER" build "$src" --stdlib-root "$ROOT/stdlib" -o "$bin_path" > "$WORKDIR/build-$name.out" 2> "$WORKDIR/build-$name.err"
    code=$?
    set -e
    if [ "$code" -ne 0 ]; then
        printf '  SKIP selfhost %s: build failed\n' "$name" >&2
        return 1
    fi
    printf '%s\n' "$bin_path"
}

run_selfhost_lsp_fixture() {
    path=$1
    name=$2
    spec=$3
    binary=$4
    case_id=$(printf '%s' "$name" | tr '/.' '__')
    stdin_file="$WORKDIR/$case_id.in"
    out="$WORKDIR/$case_id.out"
    err="$WORKDIR/$case_id.err"
    messages="$WORKDIR/$case_id.messages"
    errors="$WORKDIR/$case_id.errors"
    : > "$errors"

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-selfhost-lsp-fixture.XXXXXX")
    tmp_path=$(canonical_tmp_path "$tmpdir")
    tmp_uri=$(file_uri_for_path "$tmp_path")

    case "$path" in
        *.in.json)
            write_json_frames "$path" "$stdin_file" "$tmp_path" "$tmp_uri"
            ;;
        *)
            awk -v tmp_path="$tmp_path" -v tmp_uri="$tmp_uri" '
            {
                line = $0
                gsub(/\$\{\{TMP_URI\}\}/, tmp_uri, line)
                gsub(/\$\{\{TMP\}\}/, tmp_path, line)
                print line
            }
            ' "$path" > "$stdin_file"
            ;;
    esac

    set +e
    "$binary" < "$stdin_file" > "$out" 2> "$err"
    code=$?
    set -e

    extract_lsp_bodies "$out" "$messages"
    check_lsp_result "$name" "$spec" "$out" "$err" "$code" "$messages" "$tmp_path" "$tmp_uri" "$errors"
    rm -rf "$tmpdir"
}

run_repl_corpus() {
    repl_dir="$FIXTURE_ROOT/repl"
    if [ -d "$repl_dir" ]; then
        for path in "$repl_dir"/*.in; do
            [ -f "$path" ] || continue
            case "$path" in
                *.linux.in) continue ;;
            esac
            base=${path%.in}
            run_repl_fixture "$path" "repl/$(basename "$path")" "$base.spec.json" "$COMPILER"
        done
        if [ "$HOST_OS" = linux ]; then
            for path in "$repl_dir"/*.linux.in; do
                [ -f "$path" ] || continue
                base=${path%.linux.in}
                run_repl_fixture "$path" "repl/$(basename "$path")" "$base.linux.spec.json" "$COMPILER"
            done
        fi
    fi

    selfhost_repl_dir="$FIXTURE_ROOT/selfhost-repl"
    if [ "$HOST_OS" = linux ] && [ -d "$selfhost_repl_dir" ]; then
        selfhost_repl_bin=$(build_selfhost_binary repl || true)
        if [ -n "$selfhost_repl_bin" ]; then
            for path in "$selfhost_repl_dir"/*.linux.in; do
                [ -f "$path" ] || continue
                base=${path%.linux.in}
                run_repl_fixture "$path" "selfhost-repl/$(basename "$path")" "$base.linux.spec.json" "$selfhost_repl_bin" direct
            done
        fi
    fi
}

run_lsp_corpus() {
    lsp_dir="$FIXTURE_ROOT/lsp"
    if [ -d "$lsp_dir" ]; then
        for path in "$lsp_dir"/*.in.json; do
            [ -f "$path" ] || continue
            run_lsp_fixture "$path" "lsp/$(basename "$path")" "$COMPILER"
        done
    fi

    selfhost_lsp_dir="$FIXTURE_ROOT/selfhost-lsp"
    if [ "$HOST_OS" = linux ] && [ -d "$selfhost_lsp_dir" ]; then
        selfhost_lsp_bin=$(build_selfhost_binary lsp_frame || true)
        if [ -n "$selfhost_lsp_bin" ]; then
            for path in "$selfhost_lsp_dir"/*.linux.in "$selfhost_lsp_dir"/*.linux.in.json; do
                [ -f "$path" ] || continue
                case "$path" in
                    *.linux.in.json) base=${path%.linux.in.json} ;;
                    *.linux.in) base=${path%.linux.in} ;;
                    *) continue ;;
                esac
                run_selfhost_lsp_fixture "$path" "selfhost-lsp/$(basename "$path")" "$base.linux.spec.json" "$selfhost_lsp_bin"
            done
        fi
    fi
}

case "$MODE" in
    all)
        run_repl_corpus
        run_lsp_corpus
        ;;
    repl)
        run_repl_corpus
        ;;
    lsp)
        run_lsp_corpus
        ;;
esac

total=$((passed + failed))
printf '\n%s/%s passed\n' "$passed" "$total"
[ "$failed" -eq 0 ]
