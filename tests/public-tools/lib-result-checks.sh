#!/usr/bin/env sh

# A case's temporary path and URI are literal data. Every placeholder expansion
# and normalization goes through these awk functions, which read them from
# CORPUS_TMP and CORPUS_URI (awk -v would process backslash escapes) and never
# pass them as a gsub replacement (which expands & and \). Placeholders appear
# only inside JSON strings, so expansion inserts the JSON string form.
CORPUS_PATH_AWK='
function corpus_replace(text, needle, replacement,    out, at) {
    if (needle == "") return text
    out = ""
    while ((at = index(text, needle)) > 0) {
        out = out substr(text, 1, at - 1) replacement
        text = substr(text, at + length(needle))
    }
    return out text
}
function corpus_json_text(s) {
    return corpus_replace(corpus_replace(s, "\\", "\\\\"), "\"", "\\\"")
}
# One left-to-right pass, so text inserted for one placeholder is never
# expanded again.
function corpus_expand(text,    out, at) {
    out = ""
    while ((at = index(text, "${{TMP")) > 0) {
        out = out substr(text, 1, at - 1)
        text = substr(text, at)
        if (substr(text, 1, 12) == "${{TMP_URI}}") {
            out = out corpus_json_text(ENVIRON["CORPUS_URI"])
            text = substr(text, 13)
        } else if (substr(text, 1, 8) == "${{TMP}}") {
            out = out corpus_json_text(ENVIRON["CORPUS_TMP"])
            text = substr(text, 9)
        } else {
            out = out "$"
            text = substr(text, 2)
        }
    }
    return out text
}
# The file URI the server builds for a path (lsp-path-to-file-uri): every byte
# outside A-Z a-z 0-9 - . _ ~ / : becomes a lowercase %xx escape.
function corpus_file_uri(path,    i, ch, code, out) {
    if (!corpus_byte_ready) {
        for (code = 1; code < 256; code++) corpus_byte[sprintf("%c", code)] = code
        corpus_byte_ready = 1
    }
    out = ""
    for (i = 1; i <= length(path); i++) {
        ch = substr(path, i, 1)
        if (ch ~ /[A-Za-z0-9._~\/:-]/) out = out ch
        else out = out sprintf("%%%02x", corpus_byte[ch])
    }
    return (substr(path, 1, 1) == "/" ? "file://" : "file:///") out
}
# The URI contains the path, so URI forms go first; JSON string forms go
# before raw forms, which stderr may carry.
function corpus_normalize(text,    uri, path) {
    uri = ENVIRON["CORPUS_URI"]
    path = ENVIRON["CORPUS_TMP"]
    text = corpus_replace(text, corpus_json_text(uri), "${{TMP_URI}}")
    text = corpus_replace(text, uri, "${{TMP_URI}}")
    text = corpus_replace(text, corpus_json_text(path), "${{TMP}}")
    return corpus_replace(text, path, "${{TMP}}")
}
'

file_uri_for_path() {
    CORPUS_TMP=$1 LC_ALL=C awk -v BINMODE=3 "$CORPUS_PATH_AWK"'
BEGIN { printf "%s", corpus_file_uri(ENVIRON["CORPUS_TMP"]) }'
}

# Paths are carried one per line in the run directory, and stdlib.fs reads a
# backslash as a separator on every host, so neither can be in a case path.
corpus_require_literal_path() {
    case "$1" in
        *[[:cntrl:]]*)
            echo "unsupported LSP fixture path (control character): $1" >&2
            return 1
            ;;
        *\\*)
            echo "unsupported LSP fixture path (backslash, a separator to stdlib.fs): $1" >&2
            return 1
            ;;
    esac
}

# Frames every JSON line of an .in.json fixture. awk in the C locale measures
# the expanded body in bytes, as Content-Length requires; a shell's ${#var}
# counts characters in a UTF-8 locale on some shells (dash 0.5.13).
write_json_frames() {
    CORPUS_TMP=$3 CORPUS_URI=$4 LC_ALL=C awk -v BINMODE=3 "$CORPUS_PATH_AWK"'
{
    line = $0
    sub(/^[[:space:]]*/, "", line)
    sub(/[[:space:]]*,[[:space:]]*$/, "", line)
    if (line ~ /^\{/) {
        body = corpus_expand(line)
        printf "Content-Length: %d\r\n\r\n%s", length(body), body
    }
}
' "$1" > "$2"
}

normalize_lsp_differential_stream() {
    CORPUS_TMP=$3 CORPUS_URI=$4 LC_ALL=C awk "$CORPUS_PATH_AWK"'
{
    line = $0
    sub(/\r$/, "", line)
    print corpus_normalize(line)
}
' "$1" > "$2"
}

# The corpus spec is line-oriented and permits repeated message-check keys.
# Keep their order and fixed-string semantics; a JSON object map would lose checks.
check_corpus_result() {
    # Disable Windows text I/O translation; exact() owns CR normalization.
    CORPUS_SPEC=$1 CORPUS_OUT=$2 CORPUS_ERR=$3 CORPUS_CODE=$4 \
    CORPUS_MESSAGES=$5 CORPUS_TMP=$6 CORPUS_URI=$7 CORPUS_HOST=$8 \
    LC_ALL=C awk -v BINMODE=3 "$CORPUS_PATH_AWK"'
function read_file(path,    text, status) {
    # A nonempty file cannot match ^$: preserve final newlines for exact checks
    # and wc -l semantics, including a final unterminated message.
    RS = "^$"
    status = (getline text < path)
    if (status < 0) {
        print "cannot read corpus result: " path > "/dev/stderr"
        exit 2
    }
    close(path)
    return text
}
function decode(s,    i, ch, esc, out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (ch == "\\") {
            esc = substr(s, ++i, 1)
            if (esc == "n") out = out "\n"
            else if (esc == "r") out = out "\r"
            else if (esc == "t") out = out "\t"
            else out = out esc
        } else out = out ch
    }
    return out
}
# Return the next quoted string; consumed includes its closing quote.
function quoted(text,    start, i, ch, raw) {
    consumed = 0
    start = index(text, "\"")
    if (!start) return ""
    raw = ""
    for (i = start + 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (ch == "\\") raw = raw ch substr(text, ++i, 1)
        else if (ch == "\"") {
            consumed = i
            return decode(raw)
        } else raw = raw ch
    }
    return ""
}
function number(key,    i, rest, pattern) {
    pattern = "\"" key "\"[[:space:]]*:[[:space:]]*-?[0-9]+"
    for (i = 1; i <= spec_count; i++) {
        if (spec[i] !~ pattern) continue
        rest = spec[i]
        sub("^.*\"" key "\"[[:space:]]*:[[:space:]]*", "", rest)
        sub(/[^0-9-].*$/, "", rest)
        return rest
    }
    return ""
}
function string_value(key,    i, at, rest, value) {
    for (i = 1; i <= spec_count; i++) {
        at = index(spec[i], "\"" key "\"")
        if (!at) continue
        rest = substr(spec[i], at + length(key) + 2)
        at = index(rest, ":")
        if (!at) continue
        value = quoted(substr(rest, at + 1))
        if (consumed) return value
    }
    return ""
}
function stream_patterns(key, actual, label, negative,    i, at, rest, active, last, value, n, j, needles, present) {
    for (i = 1; i <= spec_count; i++) {
        rest = spec[i]
        if (!active) {
            at = index(rest, "\"" key "\"")
            if (!at) continue
            rest = substr(rest, at + length(key) + 2)
            at = index(rest, "[")
            if (!at) continue
            active = 1
            rest = substr(rest, at + 1)
        }
        last = index(rest, "]")
        if (last) rest = substr(rest, 1, last - 1)
        while (index(rest, "\"")) {
            value = quoted(rest)
            if (!consumed) break
            rest = substr(rest, consumed + 1)
            # grep -F treats a decoded newline as a separate pattern; the
            # shell reader ignores empty patterns. None may bridge lines.
            n = split(value, needles, "\n")
            for (j = 1; j <= n; j++) {
                if (needles[j] == "") continue
                present = index(actual, needles[j]) != 0
                if (present == negative)
                    print label (negative ? " unexpectedly contains: " : " missing: ") needles[j]
            }
        }
        if (last) return
    }
}
function indented(text,    n, rows, i) {
    n = split(text, rows, "\n")
    for (i = 1; i <= n; i++) {
        if (i == n && rows[i] == "") break
        printf "  %s%s", rows[i], (i < n ? "\n" : "")
    }
}
function exact(key, actual, label,    expected, left, right) {
    if (!index(spec_text, "\"" key "\"")) return
    expected = string_value(key)
    left = expected
    right = actual
    if (ENVIRON["CORPUS_HOST"] == "windows") {
        gsub(/\r/, "", left)
        gsub(/\r/, "", right)
    }
    if ("x" left != "x" right) {
        print label " mismatch"
        print "expected:"
        indented(expected)
        print "got:"
        indented(actual)
    }
}
function message_needles(line, key, message, negative,    marker, at, rest, value, n, needles, j) {
    marker = "\"" key "\""
    rest = line
    while ((at = index(rest, marker))) {
        rest = substr(rest, at + length(marker))
        at = index(rest, ":")
        if (!at) break
        rest = substr(rest, at + 1)
        value = quoted(rest)
        if (!consumed) break
        rest = substr(rest, consumed + 1)
        n = split(corpus_expand(value), needles, "\n")
        for (j = 1; j <= n; j++)
            if (needles[j] != "" && (index(message, needles[j]) != 0) == negative)
                return 0
    }
    return 1
}
function message_matches(line,    id, rest, wants_null, i, message) {
    id = ""
    if (line ~ /"jsonpath_id"[[:space:]]*:[[:space:]]*[0-9]+/) {
        rest = line
        sub(/^.*"jsonpath_id"[[:space:]]*:[[:space:]]*/, "", rest)
        sub(/[^0-9].*$/, "", rest)
        id = rest
    }
    wants_null = index(line, "\"jsonpath_result\": null") != 0
    for (i = 1; i <= message_rows; i++) {
        message = messages[i]
        if (id != "" && !index(message, "\"id\":" id)) continue
        if (wants_null && !index(message, "\"result\":null")) continue
        if (message_needles(line, "raw_contains", message, 0) &&
            message_needles(line, "json_contains", message, 0) &&
            message_needles(line, "raw_not_contains", message, 1)) return 1
    }
    return 0
}
BEGIN {
    spec_text = read_file(ENVIRON["CORPUS_SPEC"])
    spec_count = split(spec_text, spec, "\n")
    out = read_file(ENVIRON["CORPUS_OUT"])
    err = read_file(ENVIRON["CORPUS_ERR"])
    want = number("exit")
    if (want == "") want = 0
    if (ENVIRON["CORPUS_CODE"] + 0 != want + 0)
        print "expected exit " want ", got " ENVIRON["CORPUS_CODE"]
    stream_patterns("stdout_contains", out, "stdout", 0)
    stream_patterns("stdout_not_contains", out, "stdout", 1)
    stream_patterns("stderr_contains", err, "stderr", 0)
    stream_patterns("stderr_not_contains", err, "stderr", 1)
    exact("stdout_exact", out, "stdout")
    exact("stderr_exact", err, "stderr")
    if (ENVIRON["CORPUS_MESSAGES"] == "") exit
    text = read_file(ENVIRON["CORPUS_MESSAGES"])
    message_rows = split(text, messages, "\n")
    if (message_rows && messages[message_rows] == "") message_rows--
    want = number("message_count")
    count_text = text
    count = gsub(/\n/, "", count_text)
    if (index(spec_text, "\"message_count\"") && count != want + 0)
        print "expected " want " messages, got " count
    active = 0
    for (i = 1; i <= spec_count; i++) {
        if (spec[i] ~ /"message_checks"[[:space:]]*:/) { active = 1; continue }
        if (active && spec[i] ~ /^[[:space:]]*\]/) break
        if (active && index(spec[i], "{") && !message_matches(spec[i]))
            print "no message matched: " spec[i]
    }
}'
}
