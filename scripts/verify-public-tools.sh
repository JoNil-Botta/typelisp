#!/usr/bin/env sh
set -eu

# verify-public-tools.sh - exercise public CLI/tool behavior without Rust tests.
# This is intentionally driven by a built TypeLisp executable via TYPELISP_BIN.
# refs #845

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "public tool verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
    [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/public-tool-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_cmd() {
    case_name=$1
    shift
    out="$WORKDIR/$case_name.out"
    err="$WORKDIR/$case_name.err"
    set +e
    "$@" > "$out" 2> "$err"
    code=$?
    set -e
}

run_stdin() {
    case_name=$1
    input_file=$2
    shift 2
    out="$WORKDIR/$case_name.out"
    err="$WORKDIR/$case_name.err"
    set +e
    "$@" < "$input_file" > "$out" 2> "$err"
    code=$?
    set -e
}

assert_code() {
    expected=$1
    if [ "$code" -ne "$expected" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$out" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$err" >&2 || true
        fail "$case_name expected exit $expected, got $code"
    fi
}

assert_success() {
    assert_code 0
}

assert_failure() {
    if [ "$code" -eq 0 ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$out" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$err" >&2 || true
        fail "$case_name unexpectedly succeeded"
    fi
}

assert_stdout_empty() {
    [ ! -s "$out" ] || fail "$case_name wrote unexpected stdout: $(cat "$out")"
}

assert_stderr_empty() {
    [ ! -s "$err" ] || fail "$case_name wrote unexpected stderr: $(cat "$err")"
}

assert_contains() {
    file=$1
    text=$2
    if ! grep -F -- "$text" "$file" > /dev/null; then
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2 || true
        fail "$case_name missing expected text: $text"
    fi
}

assert_not_contains() {
    file=$1
    text=$2
    if grep -F -- "$text" "$file" > /dev/null; then
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2 || true
        fail "$case_name contained unexpected text: $text"
    fi
}

strip_expected_trailing_lf() {
    src=$1
    dst=$2
    normalized="$WORKDIR/expected-normalized.tmp"
    tr -d '\r' < "$src" > "$normalized"
    size=$(wc -c < "$normalized" | tr -d ' ')
    if [ "$size" -gt 0 ]; then
        last=$(tail -c 1 "$normalized" | od -An -tx1 | tr -d ' \n')
        if [ "$last" = "0a" ]; then
            dd if="$normalized" of="$dst" bs=1 count=$((size - 1)) 2> /dev/null
            return
        fi
    fi
    cp "$normalized" "$dst"
}

check_file_exact() {
    actual=$1
    expected=$2
    if ! cmp -s "$actual" "$expected"; then
        echo "expected:" >&2
        sed 's/^/  /' "$expected" >&2 || true
        echo "actual:" >&2
        sed 's/^/  /' "$actual" >&2 || true
        fail "$case_name produced unexpected file content"
    fi
}

echo "[public-tools] CLI usage and frontend aliases"
run_cmd usage "$COMPILER" --help
assert_success
assert_stdout_empty
assert_contains "$err" "typelisp repl"
assert_contains "$err" "typelisp lsp"
assert_contains "$err" "typelisp fmt"
assert_contains "$err" "typelisp doc"

run_cmd missing-command "$COMPILER"
assert_failure
assert_stdout_empty
assert_contains "$err" "Usage:"

run_cmd tokenize-alias "$COMPILER" tokenize examples/hello.tl
assert_success
assert_stderr_empty
cp "$out" "$WORKDIR/tokenize-alias.expected"

run_cmd tokenize-debug "$COMPILER" debug tokenize examples/hello.tl
assert_success
assert_stderr_empty
cmp -s "$out" "$WORKDIR/tokenize-alias.expected" || fail "debug tokenize differs from public alias"
assert_contains "$out" "("
assert_contains "$out" "define"

run_cmd parse-alias "$COMPILER" parse examples/hello.tl
assert_success
assert_stderr_empty
cp "$out" "$WORKDIR/parse-alias.expected"

run_cmd parse-debug "$COMPILER" debug parse examples/hello.tl
assert_success
assert_stderr_empty
cmp -s "$out" "$WORKDIR/parse-alias.expected" || fail "debug parse differs from public alias"
assert_contains "$out" "Program"

run_cmd check-hello "$COMPILER" check examples/hello.tl
assert_success
assert_stderr_empty
assert_contains "$out" "Type checking passed!"

run_cmd compile-hello "$COMPILER" compile examples/hello.tl -o "$WORKDIR/hello.s"
assert_success
assert_stderr_empty
assert_contains "$out" "Generated:"
assert_contains "$WORKDIR/hello.s" "main:"

run_cmd bad-target "$COMPILER" compile examples/hello.tl --target definitely-not-a-target -o "$WORKDIR/bad-target.s"
assert_failure
assert_stdout_empty
assert_contains "$err" "unknown target"

echo "[public-tools] backend diagnostics"
cat > "$WORKDIR/array_return.tl" <<'EOF'
(define (main) : (Array i64 3)
  (array 1 2 3))
EOF
run_cmd backend-array "$COMPILER" compile "$WORKDIR/array_return.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "return type (Array i64 3)"
assert_contains "$err" "array_return.tl:2:"
assert_contains "$err" " 2 |   (array 1 2 3)"
assert_contains "$err" "^"

cat > "$WORKDIR/tuple_return.tl" <<'EOF'
(define (make-pair [a : i64] [b : bool]) : (Tuple i64 bool)
  (tuple a b))
EOF
run_cmd backend-tuple "$COMPILER" compile "$WORKDIR/tuple_return.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "return type (Tuple i64 bool)"
assert_contains "$err" "tuple_return.tl:2:"
assert_contains "$err" " 2 |   (tuple a b)"
assert_contains "$err" "^"

echo "[public-tools] formatter golden corpus"
format_manifest() {
    cat <<'EOF'
char_literal
comments
decls
flow
negative_int
EOF
}

format_manifest | sort > "$WORKDIR/format-expected.txt"
find tests/format_golden -maxdepth 1 -type f -name '*.tl' |
    sed 's#^tests/format_golden/##; s#\.tl$##' | sort > "$WORKDIR/format-actual.txt"
if ! cmp -s "$WORKDIR/format-expected.txt" "$WORKDIR/format-actual.txt"; then
    diff -u "$WORKDIR/format-expected.txt" "$WORKDIR/format-actual.txt" >&2 || true
    fail "format golden source manifest is out of date"
fi

find tests/format_golden -maxdepth 1 -type f -name '*.expected' |
    sed 's#^tests/format_golden/##; s#\.expected$##' | sort > "$WORKDIR/format-actual-expected.txt"
if ! cmp -s "$WORKDIR/format-expected.txt" "$WORKDIR/format-actual-expected.txt"; then
    diff -u "$WORKDIR/format-expected.txt" "$WORKDIR/format-actual-expected.txt" >&2 || true
    fail "format golden expected-output manifest is out of date"
fi

while IFS= read -r fmt_name; do
    [ -n "$fmt_name" ] || continue
    case_name="fmt-$fmt_name"
    cp "tests/format_golden/$fmt_name.tl" "$WORKDIR/$fmt_name.tl"
    strip_expected_trailing_lf "tests/format_golden/$fmt_name.expected" "$WORKDIR/$fmt_name.expected"

    run_cmd "$case_name" "$COMPILER" fmt "$WORKDIR/$fmt_name.tl"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
    check_file_exact "$WORKDIR/$fmt_name.tl" "$WORKDIR/$fmt_name.expected"

    run_cmd "$case_name-check" "$COMPILER" fmt --check "$WORKDIR/$fmt_name.tl"
    assert_success
    assert_stdout_empty
    assert_stderr_empty

    run_cmd "$case_name-idempotent" "$COMPILER" fmt "$WORKDIR/$fmt_name.tl"
    assert_success
    assert_stdout_empty
    assert_stderr_empty
    check_file_exact "$WORKDIR/$fmt_name.tl" "$WORKDIR/$fmt_name.expected"
done < "$WORKDIR/format-expected.txt"

echo "[public-tools] doc and doctest commands"
cat > "$WORKDIR/docs.tl" <<'EOF'
;;;; Module docs.
;;;; ```typelisp
;;;; (define (main) : i64 42)
;;;; ```

;;; Item docs.
;;; ```tl
;;; (define answer : i64 42)
;;; ```
(define documented : i64 1)
EOF
run_cmd doc-test-pass "$COMPILER" doc --test "$WORKDIR/docs.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 2 example(s)"
[ ! -d "$WORKDIR/.typelisp-doctest" ] || fail "doc --test left temp directory behind"

cat > "$WORKDIR/docs_expected_error.tl" <<'EOF'
;;;; Expected error.
;;;; ```typelisp expect-error
;;;; (define (bad) : i64 true)
;;;; ```
EOF
run_cmd doc-test-expected-error "$COMPILER" doc --test "$WORKDIR/docs_expected_error.tl"
assert_success
assert_stderr_empty
assert_contains "$out" "Doc tests passed: 1 example(s)"

cat > "$WORKDIR/docs_bad.tl" <<'EOF'
;;;; Unexpected error.
;;;; ```typelisp
;;;; (define (bad) : i64 true)
;;;; ```
EOF
run_cmd doc-test-unexpected-error "$COMPILER" doc --test "$WORKDIR/docs_bad.tl"
assert_failure
assert_stdout_empty
assert_contains "$err" "doc tests failed"
assert_contains "$err" "was expected to pass"
assert_contains "$err" "error[E0200]"

if [ "$HOST_OS" = linux ]; then
    cat > "$WORKDIR/doc_source.tl" <<'EOF'
;;;; Module docs.

;;; Item docs.
(define answer : i64 42)
EOF
    run_cmd doc-generate "$COMPILER" doc "$WORKDIR/doc_source.tl" -o "$WORKDIR/doc_source.md"
    assert_success
    assert_stderr_empty
    assert_contains "$out" "Generated:"
    assert_contains "$WORKDIR/doc_source.md" "Module docs."
    assert_contains "$WORKDIR/doc_source.md" "answer"
else
    echo "[public-tools] skipping doc generation on $HOST_OS"
fi

echo "[public-tools] package build"
PKG="$WORKDIR/pkg"
mkdir -p "$PKG/src" "$PKG/vendor/math/src"
cat > "$PKG/typelisp.pkg" <<'EOF'
(package
  (name "public_tool_pkg")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "vendor/math")))
EOF
cat > "$PKG/src/main.tl" <<'EOF'
(import "math.tl")
(import "pkg:math/src/lib.tl")
(define (main) : i64 (add-one (inc 40)))
EOF
cat > "$PKG/src/math.tl" <<'EOF'
(define (inc [x : i64]) : i64 (+ x 1))
EOF
cat > "$PKG/vendor/math/src/lib.tl" <<'EOF'
(define (add-one [x : i64]) : i64 (+ x 1))
EOF
run_cmd package-build "$COMPILER" build --manifest-path "$PKG/typelisp.pkg"
assert_success
assert_stderr_empty
PKG_ASM="$PKG/target/typelisp/public_tool_pkg/public_tool_pkg.s"
[ -f "$PKG_ASM" ] || fail "package build did not write deterministic assembly"
assert_contains "$out" "Generated:"
assert_contains "$PKG_ASM" "main:"
assert_contains "$PKG_ASM" "_tl_inc:"
assert_contains "$PKG_ASM" "_tl_add_one:"

BADPKG="$WORKDIR/badpkg"
mkdir -p "$BADPKG/src"
cat > "$BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "bad_pkg")
  (version "0.1.0")
  (entry "src/main.tl")
  (deps "not-yet"))
EOF
run_cmd package-parse-error "$COMPILER" build --manifest-path "$BADPKG/typelisp.pkg"
assert_failure
assert_stdout_empty
assert_contains "$err" 'unknown manifest field `deps`'

cat > "$BADPKG/typelisp.pkg" <<'EOF'
(package
  (name "missing_alias")
  (version "0.1.0")
  (entry "src/main.tl"))
EOF
cat > "$BADPKG/src/main.tl" <<'EOF'
(import "pkg:math/src/lib.tl")
(define (main) : i64 0)
EOF
run_cmd package-missing-alias "$COMPILER" build --manifest-path "$BADPKG/typelisp.pkg"
assert_failure
assert_stdout_empty
assert_contains "$err" "pkg:math/src/lib.tl"
assert_contains "$err" 'alias `math`'

echo "[public-tools] REPL"
cat > "$WORKDIR/repl.in" <<'EOF'
.help
.type 42
(define answer : i64 41)
.type (+ answer 1)
.exit
EOF
run_stdin repl-basic "$WORKDIR/repl.in" "$COMPILER" repl
assert_success
assert_stderr_empty
assert_contains "$out" "TypeLisp REPL commands:"
assert_contains "$out" ".type"
assert_contains "$out" "i64"

printf '(+ 1\n' > "$WORKDIR/repl-incomplete.in"
run_stdin repl-incomplete "$WORKDIR/repl-incomplete.in" "$COMPILER" repl
assert_success
assert_stdout_empty
assert_contains "$err" "Error: incomplete REPL input at EOF"

echo "[public-tools] LSP"
frame_append() {
    frame_file=$1
    frame_body=$2
    frame_len=$(printf '%s' "$frame_body" | wc -c | tr -d ' ')
    {
        printf 'Content-Length: %s\r\n\r\n' "$frame_len"
        printf '%s' "$frame_body"
    } >> "$frame_file"
}

LSP_IN="$WORKDIR/lsp.in"
: > "$LSP_IN"
frame_append "$LSP_IN" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
frame_append "$LSP_IN" '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
run_stdin lsp-init-shutdown "$LSP_IN" "$COMPILER" lsp
assert_success
assert_stderr_empty
assert_contains "$out" '"id":1'
assert_contains "$out" '"capabilities"'
assert_contains "$out" '"id":2'

if [ "$HOST_OS" = linux ]; then
    LSP_URI="file://$WORKDIR/lsp_bad.tl"
    LSP_BAD="$WORKDIR/lsp-bad.in"
    : > "$LSP_BAD"
    frame_append "$LSP_BAD" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
    frame_append "$LSP_BAD" '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$LSP_URI"'","languageId":"typelisp","version":1,"text":"(define bad : i64 true)"}}}'
    frame_append "$LSP_BAD" '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
    run_stdin lsp-diagnostics "$LSP_BAD" "$COMPILER" lsp
    assert_success
    assert_stderr_empty
    assert_contains "$out" "textDocument/publishDiagnostics"
    assert_contains "$out" '"code":"E0200"'
else
    echo "[public-tools] skipping LSP diagnostics on $HOST_OS"
fi

echo "[public-tools] SPEC metadata examples"
SPEC_WORK="$WORKDIR/spec"
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
    case "$spec_mode" in
        ignore)
            ;;
        check)
            run_cmd "spec-$spec_name" "$COMPILER" check "$SPEC_WORK/$spec_name.tl"
            assert_success
            ;;
        compile)
            run_cmd "spec-$spec_name" "$COMPILER" compile "$SPEC_WORK/$spec_name.tl" -o "$SPEC_WORK/$spec_name.s"
            assert_success
            ;;
        run)
            if [ "$HOST_OS" != linux ]; then
                echo "[public-tools] skipping SPEC run example $spec_name on $HOST_OS"
                continue
            fi
            run_cmd "spec-$spec_name" "$COMPILER" run "$SPEC_WORK/$spec_name.tl"
            assert_code "$spec_value"
            check_file_exact "$out" "$SPEC_WORK/$spec_name.stdout"
            assert_stderr_empty
            ;;
        *)
            fail "unknown SPEC manifest mode for $spec_name: $spec_mode"
            ;;
    esac
done < "$SPEC_MANIFEST"

echo "public tool verification passed"
