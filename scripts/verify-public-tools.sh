#!/usr/bin/env sh
set -eu

# verify-public-tools.sh - the public CLI surface of TYPELISP_BIN: the
# tests/cli/public-*.cases transcripts, package artifact freshness, the LSP and
# REPL corpora of tests/public-tools, and the metadata-bearing SPEC.md examples.
# A crash is a compiler bug: every invocation runs once (no retries).

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

GATE_FAIL_PREFIX='FAIL: '
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_compiler_absolute
gate_require_compiler
export TYPELISP_BIN="$COMPILER"

scripts/verify-codegen-cases.sh tests/cli/public-*.cases

echo "[public-tools] package artifact freshness"
sh scripts/verify-package-artifact-freshness.sh
echo "[public-tools] LSP transcript batch manifest contract"
sh scripts/verify-lsp-transcript-batch.sh
echo "[public-tools] corpus result-check self-test"
sh tests/public-tools/test-result-checks.sh
echo "[public-tools] LSP corpus"
sh tests/public-tools/run-corpus.sh lsp
echo "[public-tools] REPL corpus"
sh tests/public-tools/run-corpus.sh repl

echo "[public-tools] SPEC metadata examples"
SPEC_WORK="$ROOT/target/public-tool-verify/spec"
rm -rf "$SPEC_WORK"
mkdir -p "$SPEC_WORK"
SPEC_MANIFEST="$SPEC_WORK/manifest.txt"
awk -v out="$SPEC_WORK" '
function die(msg) {
    print msg > "/dev/stderr"
    exit 1
}
function is_key_char(ch) {
    return ch ~ /^[A-Za-z0-9_-]$/
}
function clear_meta(    key) {
    for (key in meta) {
        delete meta[key]
    }
}
function parse_meta(text, line,    i, n, ch, key, value, closed, esc) {
    clear_meta()
    i = 1
    n = length(text)
    while (i <= n) {
        ch = substr(text, i, 1)
        while (i <= n && ch ~ /^[ \t]$/) {
            i++
            ch = substr(text, i, 1)
        }
        if (i > n) {
            break
        }

        key = ""
        while (i <= n && is_key_char(substr(text, i, 1))) {
            key = key substr(text, i, 1)
            i++
        }
        if (key == "") {
            die("SPEC.md:" line " has malformed metadata near `" substr(text, i) "`")
        }
        if (substr(text, i, 1) != "=") {
            die("SPEC.md:" line " metadata key `" key "` must be followed by `=`")
        }
        i++

        if (substr(text, i, 1) == "\"") {
            i++
            value = ""
            closed = 0
            while (i <= n) {
                ch = substr(text, i, 1)
                if (ch == "\"") {
                    i++
                    closed = 1
                    break
                }
                if (ch == "\\") {
                    i++
                    if (i > n) {
                        die("SPEC.md:" line " has a trailing escape in metadata")
                    }
                    esc = substr(text, i, 1)
                    if (esc == "n") {
                        value = value "\n"
                    } else if (esc == "r") {
                        value = value "\r"
                    } else if (esc == "t") {
                        value = value "\t"
                    } else if (esc == "\"") {
                        value = value "\""
                    } else if (esc == "\\") {
                        value = value "\\"
                    } else {
                        die("SPEC.md:" line " has unsupported metadata escape `\\" esc "`")
                    }
                    i++
                    continue
                }
                value = value ch
                i++
            }
            if (!closed) {
                die("SPEC.md:" line " has an unterminated quoted metadata value")
            }
        } else {
            value = ""
            while (i <= n && substr(text, i, 1) !~ /^[ \t]$/) {
                value = value substr(text, i, 1)
                i++
            }
            if (value == "") {
                die("SPEC.md:" line " metadata key `" key "` has no value")
            }
        }

        if (key in meta) {
            die("SPEC.md:" line " has duplicate metadata key `" key "`")
        }
        meta[key] = value
    }
}
function required(line, example, key,    value) {
    if (!(key in meta)) {
        if (example == "") {
            die("SPEC.md:" line " lisp fence is missing metadata `" key "`")
        }
        die("SPEC.md:" line " example `" example "` is missing required metadata `" key "`")
    }
    value = meta[key]
    delete meta[key]
    return value
}
function reject_remaining(line, name,    key) {
    for (key in meta) {
        die("SPEC.md:" line " example `" name "` has unsupported metadata key `" key "`")
    }
}
function validate_name(line, name) {
    if (name == "" || name !~ /^[A-Za-z0-9_-]+$/) {
        die("SPEC.md:" line " example `" name "` must use only ASCII letters, digits, `-`, or `_`")
    }
}
function finish_example(    mode, name, reason, exit_code, stdout_file, source_file) {
    mode = required(opening_line, "", "test")
    name = required(opening_line, mode, "name")
    validate_name(opening_line, name)
    if (name in seen) {
        die("SPEC.md:" opening_line " example `" name "` duplicates a previous name")
    }
    seen[name] = 1

    if (mode == "ignore") {
        reason = required(opening_line, name, "reason")
        if (reason ~ /^[ \t]*$/) {
            die("SPEC.md:" opening_line " example `" name "` has an empty ignore reason")
        }
        reject_remaining(opening_line, name)
        print name "|ignore|"
        return
    }

    source_file = out "/" name ".tl"
    printf "%s", source > source_file
    close(source_file)

    if (mode == "check" || mode == "compile") {
        reject_remaining(opening_line, name)
        print name "|" mode "|"
        return
    }

    if (mode == "run") {
        exit_code = required(opening_line, name, "exit")
        if (exit_code !~ /^-?[0-9]+$/) {
            die("SPEC.md:" opening_line " example `" name "` has invalid exit code `" exit_code "`")
        }
        stdout_file = out "/" name ".stdout"
        printf "%s", required(opening_line, name, "stdout") > stdout_file
        close(stdout_file)
        reject_remaining(opening_line, name)
        print name "|run|" exit_code
        return
    }

    die("SPEC.md:" opening_line " example `" name "` has unknown test mode `" mode "`")
}
BEGIN {
    in_fence = 0
    in_other_fence = 0
    count = 0
}
{
    trimmed = $0
    sub(/^[ \t]*/, "", trimmed)

    if (in_fence) {
        if (trimmed ~ /^```/) {
            finish_example()
            in_fence = 0
            source = ""
            next
        }
        source = source $0 "\n"
        next
    }

    if (in_other_fence) {
        if (trimmed ~ /^```/) {
            in_other_fence = 0
        }
        next
    }

    if (trimmed ~ /^```lisp([ \t].*)?$/) {
        info = trimmed
        sub(/^```lisp[ \t]*/, "", info)
        if (info == "") {
            die("SPEC.md:" NR " lisp fence is missing test= metadata")
        }
        parse_meta(info, NR)
        opening_line = NR
        source = ""
        in_fence = 1
        count++
        next
    }

    if (trimmed ~ /^```/) {
        in_other_fence = 1
    }
}
END {
    if (in_fence) {
        die("SPEC.md:" opening_line " has an unclosed Markdown fence")
    }
    if (count == 0) {
        die("SPEC.md should contain metadata-bearing lisp examples")
    }
}
' SPEC.md > "$SPEC_MANIFEST"

while IFS='|' read -r spec_name spec_mode spec_value; do
    [ -n "$spec_name" ] || continue
    out="$SPEC_WORK/$spec_name.out"
    err="$SPEC_WORK/$spec_name.err"
    case "$spec_mode" in
        ignore) continue ;;
        check) set -- check "$SPEC_WORK/$spec_name.tl"; spec_value=0 ;;
        compile) set -- compile "$SPEC_WORK/$spec_name.tl" -o "$SPEC_WORK/$spec_name.s"; spec_value=0 ;;
        run) set -- run "$SPEC_WORK/$spec_name.tl" ;;
        *) fail "unknown SPEC manifest mode for $spec_name: $spec_mode" ;;
    esac
    set +e
    "$COMPILER" "$@" > "$out" 2> "$err"
    code=$?
    set -e
    if [ "$code" -ne "$spec_value" ]; then
        sed 's/^/  /' "$out" "$err" >&2 || true
        fail "spec-$spec_name expected exit $spec_value, got $code"
    fi
    [ "$spec_mode" = run ] || continue
    cp "$SPEC_WORK/$spec_name.stdout" "$out.expected"
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*)
            tr -d '\r' < "$out" > "$out.lf" && mv "$out.lf" "$out"
            tr -d '\r' < "$SPEC_WORK/$spec_name.stdout" > "$out.expected"
            ;;
    esac
    cmp -s "$out" "$out.expected" || fail "spec-$spec_name produced unexpected stdout"
    [ ! -s "$err" ] || fail "spec-$spec_name wrote unexpected stderr: $(cat "$err")"
done < "$SPEC_MANIFEST"

echo "public tool verification passed"
