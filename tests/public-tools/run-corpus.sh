#!/usr/bin/env sh
set -eu

# Self-hosted REPL and LSP corpus runner for tests/public-tools/.
# Usage:
#   TYPELISP_BIN=./target/stage0/typelisp tests/public-tools/run-corpus.sh [repl|lsp] [fresh|batch|differential]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIXTURE_ROOT="$ROOT/tests/public-tools"
WORKDIR="$ROOT/target/public-tools-corpus"

. "$ROOT/scripts/lib-linux-entry.sh"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *) HOST_OS=other ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Local-development fallback: fetch the published stage0 (CI passes TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
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
        echo "usage: tests/public-tools/run-corpus.sh [repl|lsp] [fresh|batch|differential]" >&2
        exit 1
        ;;
esac
LSP_MODE=${2:-}
if [ -z "$LSP_MODE" ]; then
    if [ "$HOST_OS" = linux ]; then
        LSP_MODE=differential
    elif [ "$HOST_OS" = windows ]; then
        LSP_MODE=batch
    else
        LSP_MODE=fresh
    fi
fi
case "$LSP_MODE" in
    fresh | batch | differential) ;;
    *)
        echo "usage: tests/public-tools/run-corpus.sh [repl|lsp] [fresh|batch|differential]" >&2
        exit 1
        ;;
esac
if [ "$HOST_OS" != linux ] && [ "$LSP_MODE" = differential ]; then
    echo "LSP differential mode is supported only on Linux" >&2
    exit 1
fi
TIME_BIN=
if [ "$HOST_OS" = linux ] && [ -x /usr/bin/time ]; then
    TIME_BIN=/usr/bin/time
fi
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
                print decode(raw)
                rest = substr(rest, i + 1)
                break
            } else {
                raw = raw ch
            }
        }
    }
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
        actual_cmp=$actual
        expected_cmp=$expected
        actual_normalized=
        expected_normalized=
        if [ "$HOST_OS" = windows ]; then
            actual_normalized="$WORKDIR/actual.$$.$key.normalized"
            expected_normalized="$WORKDIR/expected.$$.$key.normalized"
            tr -d '\r' < "$actual" > "$actual_normalized"
            tr -d '\r' < "$expected" > "$expected_normalized"
            actual_cmp=$actual_normalized
            expected_cmp=$expected_normalized
        fi
        if ! cmp -s "$actual_cmp" "$expected_cmp"; then
            {
                printf '%s mismatch\n' "$label"
                printf 'expected:\n'
                sed 's/^/  /' "$expected" || true
                printf 'got:\n'
                sed 's/^/  /' "$actual" || true
            } >> "$errors"
        fi
        rm -f "$expected" "$actual_normalized" "$expected_normalized"
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

compiler_file_path() {
    path=$1
    if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m -a -l "$path"
    else
        printf '%s' "$path"
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

write_lsp_case_list() {
    cases=$1
    : > "$cases"
    lsp_dir="$FIXTURE_ROOT/lsp"
    if [ -d "$lsp_dir" ]; then
        for path in "$lsp_dir"/*.in.json; do
            [ -f "$path" ] || continue
            base=${path%.in.json}
            name="lsp/$(basename "$path")"
            printf '%s\t%s\t%s\t%s\n' "$path" "$name" public "$base.spec.json" >> "$cases"
        done
    fi

    selfhost_lsp_dir="$FIXTURE_ROOT/selfhost-lsp"
    if [ "$HOST_OS" = linux ] && [ -d "$selfhost_lsp_dir" ]; then
        for path in "$selfhost_lsp_dir"/*.linux.in "$selfhost_lsp_dir"/*.linux.in.json; do
            [ -f "$path" ] || continue
            case "$path" in
                *.linux.in.json) base=${path%.linux.in.json} ;;
                *.linux.in) base=${path%.linux.in} ;;
                *) continue ;;
            esac
            name="selfhost-lsp/$(basename "$path")"
            printf '%s\t%s\t%s\t%s\n' "$path" "$name" selfhost "$base.linux.spec.json" >> "$cases"
        done
    fi
}

prepare_lsp_case() {
    run_dir=$1
    path=$2
    name=$3
    kind=$4
    manifest=$5
    case_id=$(printf '%s' "$name" | tr '/.' '__')
    stdin_file="$run_dir/$case_id.in"
    out="$run_dir/$case_id.out"
    err="$run_dir/$case_id.err"
    status="$run_dir/$case_id.status"
    errors="$run_dir/$case_id.errors"
    : > "$errors"

    shared_group=
    case "$name" in
        lsp/reset-document-*) shared_group=reset-document-shared ;;
        lsp/reset-compiler-state-*) shared_group=reset-compiler-state-shared ;;
    esac
    if [ -n "$shared_group" ]; then
        tmpdir="$run_dir/$shared_group"
        mkdir -p "$tmpdir"
    else
        tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-lsp-fixture.XXXXXX")
    fi
    tmp_path=$(canonical_tmp_path "$tmpdir")
    tmp_uri=$(file_uri_for_path "$tmp_path")
    printf '%s\n' "$tmpdir" > "$run_dir/$case_id.tmpdir"
    printf '%s\n' "$tmp_path" > "$run_dir/$case_id.tmp-path"
    printf '%s\n' "$tmp_uri" > "$run_dir/$case_id.tmp-uri"

    if [ "$kind" = public ]; then
        base=${path%.in.json}
        prep="$base.prep.sh"
        if [ -f "$prep" ]; then
            FIXTURE_TMP=$tmpdir FIXTURE_TMP_URI=$tmp_uri sh "$prep"
        fi
        write_json_frames "$path" "$stdin_file" "$tmp_path" "$tmp_uri"
    else
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
    fi

    if [ -n "$manifest" ]; then
        compiler_stdin=$(compiler_file_path "$stdin_file")
        compiler_out=$(compiler_file_path "$out")
        compiler_err=$(compiler_file_path "$err")
        compiler_status=$(compiler_file_path "$status")
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$case_id" "$compiler_stdin" "$compiler_out" "$compiler_err" "$compiler_status" >> "$manifest"
        printf 'lsp-transcript-batch-result\t%s\n' "$case_id" >> "$run_dir/expected-results.tsv"
    fi
}

prepare_lsp_cases() {
    run_dir=$1
    cases=$2
    manifest=$3
    mkdir -p "$run_dir"
    if [ -n "$manifest" ]; then
        printf '%s\n' 'typelisp-lsp-transcript-batch-v1' > "$manifest"
        : > "$run_dir/expected-results.tsv"
    fi
    while IFS="$(printf '\t')" read -r path name kind spec || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        prepare_lsp_case "$run_dir" "$path" "$name" "$kind" "$manifest"
    done < "$cases"
}

run_lsp_fresh_cases() {
    run_dir=$1
    cases=$2
    prepare_lsp_cases "$run_dir" "$cases" ""
    while IFS="$(printf '\t')" read -r path name kind spec || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        case_id=$(printf '%s' "$name" | tr '/.' '__')
        set +e
        if [ -n "$TIME_BIN" ]; then
            "$TIME_BIN" -f '%e\t%M' -o "$run_dir/$case_id.time" \
                "$COMPILER" lsp < "$run_dir/$case_id.in" \
                > "$run_dir/$case_id.out" 2> "$run_dir/$case_id.err"
            code=$?
        else
            "$COMPILER" lsp < "$run_dir/$case_id.in" \
                > "$run_dir/$case_id.out" 2> "$run_dir/$case_id.err"
            code=$?
        fi
        set -e
        printf '%s\n' "$code" > "$run_dir/$case_id.status"
    done < "$cases"
}

run_lsp_batch_cases() {
    run_dir=$1
    cases=$2
    manifest="$run_dir/manifest.tsv"
    prepare_lsp_cases "$run_dir" "$cases" "$manifest"
    compiler_manifest=$(compiler_file_path "$manifest")
    batch_stdout="$run_dir/results.tsv"
    batch_stderr="$run_dir/batch.stderr"
    batch_status=0
    if [ -n "$TIME_BIN" ]; then
        if "$TIME_BIN" -f '%e\t%M' -o "$run_dir/batch.time" \
            "$COMPILER" lsp --transcript-batch "$compiler_manifest" \
            --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" \
            > "$batch_stdout" 2> "$batch_stderr"; then
            :
        else
            batch_status=$?
        fi
    else
        if "$COMPILER" lsp --transcript-batch "$compiler_manifest" \
            --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" \
            > "$batch_stdout" 2> "$batch_stderr"; then
            :
        else
            batch_status=$?
        fi
    fi
    if [ "$batch_status" -ne 0 ]; then
        echo "LSP transcript batch exited $batch_status" >&2
        sed 's/^/  /' "$batch_stderr" >&2 || true
        return "$batch_status"
    fi
    if [ -s "$batch_stderr" ]; then
        echo "LSP transcript batch wrote unexpected process stderr" >&2
        sed 's/^/  /' "$batch_stderr" >&2 || true
        return 1
    fi
    if ! cmp -s "$run_dir/expected-results.tsv" "$batch_stdout"; then
        echo "LSP transcript batch result rows were missing, duplicated, reordered, or extra" >&2
        diff -u "$run_dir/expected-results.tsv" "$batch_stdout" >&2 || true
        return 1
    fi
}

lsp_now_ms() {
    value=$(date +%s%3N 2>/dev/null || true)
    case "$value" in
        '' | *[!0-9]*) value=$(($(date +%s) * 1000)) ;;
    esac
    printf '%s' "$value"
}

report_lsp_fresh_memory() {
    run_dir=$1
    if [ -n "$TIME_BIN" ]; then
        awk -F '\t' '
            BEGIN { max = 0 }
            $2 + 0 > max { max = $2 + 0 }
            END { printf "[public-tools] LSP fresh max_child_peak_rss_kib=%d\n", max }
        ' "$run_dir"/*.time
    fi
}

report_lsp_batch_memory() {
    run_dir=$1
    if [ -n "$TIME_BIN" ] && [ -f "$run_dir/batch.time" ]; then
        awk -F '\t' '
            { printf "[public-tools] LSP batch child_elapsed_s=%s peak_rss_kib=%s\n", $1, $2 }
        ' "$run_dir/batch.time"
    fi
}

normalize_lsp_differential_stream() {
    input=$1
    output=$2
    tmp_path=$3
    tmp_uri=$4
    awk -v tmp_path="$tmp_path" -v tmp_uri="$tmp_uri" '
function replace_literal(text, needle, replacement,    out, at) {
    if (needle == "") return text
    out = ""
    while ((at = index(text, needle)) > 0) {
        out = out substr(text, 1, at - 1) replacement
        text = substr(text, at + length(needle))
    }
    return out text
}
{
    line = $0
    sub(/\r$/, "", line)
    line = replace_literal(line, tmp_uri, "${{TMP_URI}}")
    line = replace_literal(line, tmp_path, "${{TMP}}")
    print line
}
' "$input" > "$output"
}

compare_lsp_differential_cases() {
    fresh_dir=$1
    batch_dir=$2
    cases=$3
    while IFS="$(printf '\t')" read -r path name kind spec || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        case_id=$(printf '%s' "$name" | tr '/.' '__')
        errors="$batch_dir/$case_id.errors"
        for stream in out err status; do
            fresh="$fresh_dir/$case_id.$stream"
            batch="$batch_dir/$case_id.$stream"
            if [ ! -f "$fresh" ] || [ ! -f "$batch" ]; then
                printf 'differential %s result missing\n' "$stream" >> "$errors"
                continue
            fi
            fresh_normal="$fresh_dir/$case_id.$stream.normalized"
            batch_normal="$batch_dir/$case_id.$stream.normalized"
            fresh_tmp_path=$(sed -n '1p' "$fresh_dir/$case_id.tmp-path")
            fresh_tmp_uri=$(sed -n '1p' "$fresh_dir/$case_id.tmp-uri")
            batch_tmp_path=$(sed -n '1p' "$batch_dir/$case_id.tmp-path")
            batch_tmp_uri=$(sed -n '1p' "$batch_dir/$case_id.tmp-uri")
            normalize_lsp_differential_stream \
                "$fresh" "$fresh_normal" "$fresh_tmp_path" "$fresh_tmp_uri"
            normalize_lsp_differential_stream \
                "$batch" "$batch_normal" "$batch_tmp_path" "$batch_tmp_uri"
            if ! cmp -s "$fresh_normal" "$batch_normal"; then
                printf 'fresh-vs-batch %s mismatch\n' "$stream" >> "$errors"
            fi
        done
    done < "$cases"
}

check_lsp_cases() {
    run_dir=$1
    cases=$2
    while IFS="$(printf '\t')" read -r path name kind spec || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        case_id=$(printf '%s' "$name" | tr '/.' '__')
        out="$run_dir/$case_id.out"
        err="$run_dir/$case_id.err"
        status="$run_dir/$case_id.status"
        messages="$run_dir/$case_id.messages"
        errors="$run_dir/$case_id.errors"
        tmp_path=$(sed -n '1p' "$run_dir/$case_id.tmp-path")
        tmp_uri=$(sed -n '1p' "$run_dir/$case_id.tmp-uri")
        if [ ! -f "$out" ] || [ ! -f "$err" ] || [ ! -f "$status" ]; then
            printf 'missing transcript result file\n' >> "$errors"
            : > "$out"
            : > "$err"
            code=255
        else
            code=$(sed -n '1p' "$status" | tr -d '\r')
            case "$code" in
                '' | *[!0-9]*)
                    printf 'malformed transcript status: %s\n' "$code" >> "$errors"
                    code=255
                    ;;
            esac
        fi
        extract_lsp_bodies "$out" "$messages"
        check_lsp_result \
            "$name" "$spec" "$out" "$err" "$code" "$messages" \
            "$tmp_path" "$tmp_uri" "$errors"
    done < "$cases"
}

cleanup_lsp_cases() {
    run_dir=$1
    cases=$2
    while IFS="$(printf '\t')" read -r path name kind spec || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        case_id=$(printf '%s' "$name" | tr '/.' '__')
        if [ -f "$run_dir/$case_id.tmpdir" ]; then
            tmpdir=$(sed -n '1p' "$run_dir/$case_id.tmpdir")
            rm -rf "$tmpdir"
        fi
    done < "$cases"
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
        for path in "$selfhost_repl_dir"/*.linux.in; do
            [ -f "$path" ] || continue
            base=${path%.linux.in}
            run_repl_fixture "$path" "selfhost-repl/$(basename "$path")" "$base.linux.spec.json" "$COMPILER"
        done
    fi
}

run_lsp_corpus() {
    cases="$WORKDIR/lsp-cases.tsv"
    write_lsp_case_list "$cases"
    case_count=$(wc -l < "$cases" | tr -d ' ')
    if [ "$case_count" -eq 0 ]; then
        echo "LSP corpus found no fixtures" >&2
        exit 1
    fi

    case "$LSP_MODE" in
        fresh)
            echo "[public-tools] LSP fresh mode: $case_count process(es)"
            run_dir="$WORKDIR/lsp-fresh"
            phase_start=$(lsp_now_ms)
            run_lsp_fresh_cases "$run_dir" "$cases"
            phase_end=$(lsp_now_ms)
            echo "[public-tools] LSP fresh elapsed_ms=$((phase_end - phase_start))"
            report_lsp_fresh_memory "$run_dir"
            check_lsp_cases "$run_dir" "$cases"
            cleanup_lsp_cases "$run_dir" "$cases"
            ;;
        batch)
            echo "[public-tools] LSP batch mode: 1 process for $case_count session(s)"
            run_dir="$WORKDIR/lsp-batch"
            phase_start=$(lsp_now_ms)
            run_lsp_batch_cases "$run_dir" "$cases"
            phase_end=$(lsp_now_ms)
            echo "[public-tools] LSP batch elapsed_ms=$((phase_end - phase_start))"
            report_lsp_batch_memory "$run_dir"
            check_lsp_cases "$run_dir" "$cases"
            cleanup_lsp_cases "$run_dir" "$cases"
            ;;
        differential)
            echo "[public-tools] LSP differential mode: $case_count fresh + 1 batch process(es)"
            fresh_dir="$WORKDIR/lsp-fresh"
            batch_dir="$WORKDIR/lsp-batch"
            phase_start=$(lsp_now_ms)
            run_lsp_fresh_cases "$fresh_dir" "$cases"
            phase_end=$(lsp_now_ms)
            echo "[public-tools] LSP fresh elapsed_ms=$((phase_end - phase_start))"
            report_lsp_fresh_memory "$fresh_dir"
            phase_start=$(lsp_now_ms)
            run_lsp_batch_cases "$batch_dir" "$cases"
            phase_end=$(lsp_now_ms)
            echo "[public-tools] LSP batch elapsed_ms=$((phase_end - phase_start))"
            report_lsp_batch_memory "$batch_dir"
            compare_lsp_differential_cases "$fresh_dir" "$batch_dir" "$cases"
            check_lsp_cases "$batch_dir" "$cases"
            cleanup_lsp_cases "$fresh_dir" "$cases"
            cleanup_lsp_cases "$batch_dir" "$cases"
            ;;
    esac
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
