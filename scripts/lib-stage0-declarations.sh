# Inventory top-level source forms, independently of observed binary frames.
# Output: form, category, declaration source, resolved input path.
stage0_payload_declarations() {
    # A legal form name is one contiguous token. Prefiltering avoids lexing
    # modules that cannot contain a relevant declaration; comments/strings may
    # select a module but cannot manufacture a declaration in the token walk.
    declaration_sources=$(awk -v manifests="$1" '
        BEGIN { n = split(manifests, files, " "); for (i = 1; i <= n; i++) manifest[files[i]] = 1 }
        /include-str-lzss/ || (FILENAME in manifest && /include-bin/) {
            if (!seen[FILENAME]++) print FILENAME
        }
    ' $1 $2) || return 1
    [ -n "$declaration_sources" ] || return 0
    awk -v manifests="$1" '
BEGIN {
    n = split(manifests, files, " ")
    for (i = 1; i <= n; i++) manifest[files[i]] = 1
    apostrophe = sprintf("%c", 39)
}
function fail(message) {
    print "stage0 declaration inventory: " FILENAME ":" FNR ": " message > "/dev/stderr"
    bad = 1
    exit 1
}
function end_file() {
    if (depth || in_string) fail("unfinished source form")
}
FNR == 1 {
    end_file()
    depth = 0
    atom = ""
}
function relevant() {
    return head == "include-str-lzss" || (FILENAME in manifest && head == "include-bin")
}
function token(kind, value, escaped) {
    if (depth != 1) return
    fields++
    if (fields == 1) head = (kind == "atom" ? value : "")
    if (!relevant()) return
    if (fields == 2 && kind != "atom") fail("include name must be a symbol")
    if (fields == 3) {
        if (kind != "string") fail("include path must be a string")
        # These layouts cannot be represented in the tabular path inventory.
        # Fail explicitly instead of silently dropping or misreading a form.
        if (escaped || value ~ /[\t\r\n]/) fail("escaped or multiline include path is unsupported")
        path = value
    }
}
function flush_atom() {
    if (atom != "") { token("atom", atom, 0); atom = "" }
}
function emit_input(    directory, resolved, category) {
    if (fields != 3 || path == "") fail("include requires a name and nonempty path")
    resolved = path
    if (resolved ~ /^\.\.\/stdlib\//) {
        sub(/^\.\.\/stdlib\//, "", resolved)
        resolved = "stdlib/" resolved
    } else {
        directory = FILENAME
        sub(/[^\/]*$/, "", directory)
        if (head == "include-bin") sub(/\.tlch$/, "", resolved)
        resolved = directory resolved
    }
    category = (FILENAME in manifest ? "embedded_stdlib_manifest" : "other_compiler_owned")
    print head "\t" category "\t" FILENAME "\t" resolved
}
{
    line = $0 "\n"
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (in_string) {
            if (escape) { escape = 0; string_escaped = 1 }
            else if (c == "\\") { escape = 1; continue }
            else if (c == "\"") {
                in_string = 0
                token("string", string_value, string_escaped)
                continue
            }
            if (capture_string) string_value = string_value c
            continue
        }
        if (c == ";") { flush_atom(); break }
        if (c == "\"") {
            flush_atom()
            in_string = 1
            string_value = ""
            string_escaped = escape = 0
            capture_string = depth == 1 && relevant() && fields == 2
        } else if (c == apostrophe) {
            flush_atom()
            # The lexer accepts one character, or a backslash escape, between
            # apostrophes. A remaining apostrophe is the quote token.
            if (substr(line, i + 1, 1) == "\\" && substr(line, i + 3, 1) == apostrophe) i += 3
            else if (substr(line, i + 2, 1) == apostrophe) i += 2
            token("quote-or-char", "", 0)
        } else if (c == "(" || c == "[") {
            flush_atom()
            if (depth == 1 && relevant()) fail("nested include operand is unsupported")
            depth++
            opener[depth] = c
            if (depth == 1) { fields = 0; head = path = "" }
        } else if (c == ")" || c == "]") {
            flush_atom()
            if (depth == 0 || (c == ")" ? opener[depth] != "(" : opener[depth] != "["))
                fail("unmatched source delimiter")
            if (depth == 1 && relevant()) emit_input()
            if (--depth < 0) fail("unmatched source delimiter")
        } else if (c ~ /[ \t\r\n]/) flush_atom()
        else atom = atom c
    }
}
END { if (!bad) end_file() }
' $declaration_sources
}
