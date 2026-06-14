#!/usr/bin/env sh
set -eu

# verify-selfhost-cli-build-run.sh - focused public build/run smoke for cli.tl.
#
# This is run against the freshly bootstrapped stage2 cli.tl binary in the
# CI gate (TYPELISP_BIN), so it verifies the branch's public
# `typelisp build` / `typelisp run` behavior instead of the already-published
# seed compiler. The compiler itself is built once by the bootstrap fixpoint
# gate; this smoke does not rebuild it.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "selfhost cli build/run smoke is unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

if [ -z "${TYPELISP_BIN:-}" ]; then
    echo "verify-selfhost-cli-build-run requires TYPELISP_BIN" >&2
    exit 2
fi

COMPILER=$TYPELISP_BIN
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/selfhost-cli-build-run"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

CLI_SURFACE_MANIFEST="$ROOT/tests/public-tools/cli-command-surface.txt"
CLI_SURFACE_DIR="$WORKDIR/cli-surface"
CLI_SURFACE_SRC="$CLI_SURFACE_DIR/main.tl"
CLI_SURFACE_RUN_SRC="$CLI_SURFACE_DIR/run-main.tl"
CLI_SURFACE_DOC_SRC="$CLI_SURFACE_DIR/doc-main.tl"
CLI_SURFACE_DOC_PKG="$CLI_SURFACE_DIR/doc-package"
CLI_SURFACE_CHECK_PKG="$CLI_SURFACE_DIR/check-package"
CLI_SURFACE_FMTLINT_PKG="$CLI_SURFACE_DIR/fmt-lint-package"
CLI_SURFACE_INSPECT_PKG="$CLI_SURFACE_DIR/inspect-package"

compiler_batch_path() {
    path=$1
    if [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
    else
        printf '%s\n' "$path"
    fi
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_status() {
    label=$1
    got=$2
    expected=$3
    if [ "$got" -ne "$expected" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$WORKDIR/$label.out" >&2 || true
        echo "stderr:" >&2
        sed 's/^/  /' "$WORKDIR/$label.err" >&2 || true
        fail "$label expected exit $expected, got $got"
    fi
}

assert_empty() {
    label=$1
    file=$2
    [ ! -s "$file" ] || fail "$label wrote unexpected output: $(cat "$file")"
}

assert_contains() {
    label=$1
    file=$2
    text=$3
    if ! grep -F -- "$text" "$file" >/dev/null; then
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2 || true
        fail "$label missing expected text: $text"
    fi
}

assert_not_contains() {
    label=$1
    file=$2
    text=$3
    if grep -F -- "$text" "$file" >/dev/null; then
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2 || true
        fail "$label contained unexpected text: $text"
    fi
}

assert_occurrences() {
    label=$1
    file=$2
    text=$3
    expected=$4
    count=$(grep -F -- "$text" "$file" | wc -l | tr -d ' ')
    if [ "$count" -ne "$expected" ]; then
        echo "file contents:" >&2
        sed 's/^/  /' "$file" >&2 || true
        fail "$label expected $expected occurrence(s) of '$text', got $count"
    fi
}

generated_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

assert_file_exists() {
    label=$1
    file=$2
    [ -f "$file" ] || fail "$label expected file $file"
}

assert_file_nonempty() {
    label=$1
    file=$2
    assert_file_exists "$label" "$file"
    [ -s "$file" ] || fail "$label expected nonempty file $file"
}

run_cli_capture() {
    label=$1
    shift
    set +e
    "$@" > "$WORKDIR/$label.out" 2> "$WORKDIR/$label.err"
    status=$?
    set -e
}

run_cli_capture_in_dir() {
    label=$1
    dir=$2
    shift 2
    set +e
    (
        cd "$dir"
        "$@"
    ) > "$WORKDIR/$label.out" 2> "$WORKDIR/$label.err"
    status=$?
    set -e
}

lsp_frame_append() {
    frame_file=$1
    frame_body=$2
    frame_len=$(printf '%s' "$frame_body" | wc -c | tr -d ' ')
    {
        printf 'Content-Length: %s\r\n\r\n' "$frame_len"
        printf '%s' "$frame_body"
    } >> "$frame_file"
}

cli_surface_label() {
    printf '%s' "$1" | tr ' /' '__'
}

cli_surface_strip_cr() {
    printf '%s' "$1" | tr -d '\r'
}

cli_surface_manifest_commands() {
    awk -F'|' '
        /^[[:space:]]*($|#)/ { next }
        NF != 3 {
            printf "cli surface manifest line %d must have 3 fields: %s\n", NR, $0 > "/dev/stderr"
            exit 2
        }
        $1 != "active" && $1 != "pending" {
            printf "cli surface manifest line %d has invalid status: %s\n", NR, $1 > "/dev/stderr"
            exit 2
        }
        { print $2 }
    ' "$CLI_SURFACE_MANIFEST" | sort -u
}

cli_surface_help_commands() {
    awk '
        /^Commands:/ {
            in_commands = 1
            next
        }
        in_commands && /^[[:space:]]*$/ {
            in_commands = 0
            next
        }
        in_commands && /^[^[:space:]]/ {
            in_commands = 0
        }
        in_commands && /^[[:space:]]+typelisp / {
            print $2
        }
    ' "$WORKDIR/cli-surface-help.err" | sort -u
}

assert_cli_surface_help_matches_manifest() {
    run_cli_capture cli-surface-help "$COMPILER" --help
    assert_status cli-surface-help "$status" 0
    assert_empty cli-surface-help "$WORKDIR/cli-surface-help.out"
    assert_contains cli-surface-help "$WORKDIR/cli-surface-help.err" "Usage:"
    assert_contains cli-surface-help "$WORKDIR/cli-surface-help.err" "Synopsis:"

    cli_surface_manifest_commands > "$WORKDIR/cli-surface-manifest.commands"
    cli_surface_help_commands > "$WORKDIR/cli-surface-help.commands"
    if ! cmp -s "$WORKDIR/cli-surface-manifest.commands" "$WORKDIR/cli-surface-help.commands"; then
        echo "manifest commands:" >&2
        sed 's/^/  /' "$WORKDIR/cli-surface-manifest.commands" >&2
        echo "help commands:" >&2
        sed 's/^/  /' "$WORKDIR/cli-surface-help.commands" >&2
        if command -v diff >/dev/null 2>&1; then
            diff -u "$WORKDIR/cli-surface-manifest.commands" "$WORKDIR/cli-surface-help.commands" >&2 || true
        fi
        fail "cli command surface manifest and --help output drifted"
    fi
}

prepare_cli_surface_files() {
    mkdir -p "$CLI_SURFACE_DIR" "$CLI_SURFACE_DOC_PKG/src" "$CLI_SURFACE_CHECK_PKG/src" "$CLI_SURFACE_FMTLINT_PKG/src" "$CLI_SURFACE_INSPECT_PKG/src"
    printf '%s' '(define (main) : i64
  0)' > "$CLI_SURFACE_SRC"
    cat > "$CLI_SURFACE_RUN_SRC" <<'EOF'
(import "stdlib/io.tl")

(define (fixture-cstr-len [p : (Ptr u8)]) : i64
  (let
    [n : i64 0]
    (begin
      (while (not (= (unsafe (ptr-read (ptr-offset p n))) (cast 0 : u8)))
        (set! n (+ n 1)))
      n)))
(define (fixture-stdout-write [text : String]) : unit
  (stdout-write (& text)))
(define (fixture-arg [index : i64]) : String
  (let
    [argv : (Ptr (Ptr u8)) (unsafe (program-argv))]
    [raw : (Ptr u8) (unsafe (ptr-read (ptr-offset argv index)))]
    (unsafe (string-from-bytes raw (fixture-cstr-len raw)))))
(define (main) : i64
  (begin
    (fixture-stdout-write (fixture-arg 1))
    33))
EOF
    cat > "$CLI_SURFACE_DOC_SRC" <<'EOF'
;# Command surface doc smoke.
(define (main) : i64
  0)
EOF
    cat > "$CLI_SURFACE_DOC_PKG/typelisp.pkg" <<'EOF'
(package
  (name "surface_doc")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
    cat > "$CLI_SURFACE_DOC_PKG/src/main.tl" <<'EOF'
;# Package entry docs.
;# ```typelisp
;# (define doc-entry-example : i64 1)
;# ```
(import "extra.tl")
(define (main) : i64 (doc-extra))
EOF
    cat > "$CLI_SURFACE_DOC_PKG/src/extra.tl" <<'EOF'
;# Package extra docs.
;# ```typelisp
;# (define doc-extra-example : i64 2)
;# ```
(define (doc-extra) : i64 0)
EOF
    cat > "$CLI_SURFACE_CHECK_PKG/typelisp.pkg" <<'EOF'
(package
  (name "surface_check")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
    cat > "$CLI_SURFACE_CHECK_PKG/src/main.tl" <<'EOF'
(import "extra.tl")
(define (main) : i64 (surface-extra))
EOF
    cat > "$CLI_SURFACE_CHECK_PKG/src/extra.tl" <<'EOF'
(define (surface-extra) : i64 0)
EOF
    cat > "$CLI_SURFACE_FMTLINT_PKG/typelisp.pkg" <<'EOF'
(package
  (name "surface_fmt_lint")
  (version "0.1.0")
  (kind "bin")
  (entry "src/main.tl"))
EOF
    printf '%s' '(define (main) : i64
  0)' > "$CLI_SURFACE_FMTLINT_PKG/src/main.tl"
    cat > "$CLI_SURFACE_FMTLINT_PKG/src/needs_fmt.tl" <<'EOF'
(define (needs-format) : i64
(+ 1 2))
EOF
    cat > "$CLI_SURFACE_FMTLINT_PKG/src/lint_bad.tl" <<'EOF'
(define (classify [x : i64]) : i64
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        0))))
EOF
    cat > "$CLI_SURFACE_INSPECT_PKG/typelisp.pkg" <<'EOF'
(package
  (name "surface_inspect")
  (version "0.1.0")
  (kind "lib")
  (entry "src/lib.tl"))
EOF
    cat > "$CLI_SURFACE_INSPECT_PKG/src/lib.tl" <<'EOF'
(define surface-inspect-value : i64 42)
(defstruct SurfaceInspectPoint
  (x i64)
  (y i64))
(defmacro (surface-inspect-macro [expr : Expr]) : Expr expr)
(export
  (value surface-inspect-value)
  (type SurfaceInspectPoint)
  (macro surface-inspect-macro))
EOF
}

assert_active_cli_surface_command() {
    command=$1
    label="cli-surface-active-$(cli_surface_label "$command")"
    case "$command" in
        build)
            exe="$CLI_SURFACE_DIR/build-surface"
            if [ "$HOST_OS" = windows ]; then
                exe="$exe.exe"
            fi
            run_cli_capture "$label" "$COMPILER" build "$CLI_SURFACE_SRC" -o "$exe"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "Built "
            assert_file_exists "$label" "$exe"
            ;;
        run)
            run_cli_capture "$label" "$COMPILER" run "$CLI_SURFACE_RUN_SRC" -- "surface-run"
            assert_status "$label" "$status" 33
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "surface-run"
            ;;
        check)
            run_cli_capture "$label" "$COMPILER" check "$CLI_SURFACE_SRC"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "Type checking passed!"
            package_label="${label}-package"
            run_cli_capture "$package_label" "$COMPILER" check --manifest-path "$CLI_SURFACE_CHECK_PKG/typelisp.pkg"
            assert_status "$package_label" "$status" 0
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "Type checking passed!"
            ;;
        fmt)
            run_cli_capture "$label" "$COMPILER" fmt --check "$CLI_SURFACE_SRC"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            large_label="${label}-large-backend"
            run_cli_capture "$large_label" "$COMPILER" fmt --check src/compiler_backend.tl --stdlib-root stdlib
            assert_status "$large_label" "$status" 0
            assert_empty "$large_label" "$WORKDIR/$large_label.out"
            assert_empty "$large_label" "$WORKDIR/$large_label.err"
            package_label="${label}-package-check"
            run_cli_capture "$package_label" "$COMPILER" fmt --manifest-path "$CLI_SURFACE_FMTLINT_PKG/typelisp.pkg" --check
            assert_status "$package_label" "$status" 1
            assert_empty "$package_label" "$WORKDIR/$package_label.out"
            assert_contains "$package_label" "$WORKDIR/$package_label.err" "needs_fmt.tl"
            package_label="${label}-package-rewrite"
            run_cli_capture "$package_label" "$COMPILER" fmt --manifest-path "$CLI_SURFACE_FMTLINT_PKG/typelisp.pkg"
            assert_status "$package_label" "$status" 0
            assert_empty "$package_label" "$WORKDIR/$package_label.out"
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            package_label="${label}-package-recheck"
            run_cli_capture "$package_label" "$COMPILER" fmt --manifest-path "$CLI_SURFACE_FMTLINT_PKG/typelisp.pkg" --check
            assert_status "$package_label" "$status" 0
            assert_empty "$package_label" "$WORKDIR/$package_label.out"
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            ;;
        lint)
            run_cli_capture "$label" "$COMPILER" lint "$CLI_SURFACE_SRC"
            assert_status "$label" "$status" 0
            package_label="${label}-package-check"
            run_cli_capture "$package_label" "$COMPILER" lint --manifest-path "$CLI_SURFACE_FMTLINT_PKG/typelisp.pkg" --check
            assert_status "$package_label" "$status" 1
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "lint_bad.tl:"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "lint: 1 finding(s)"
            package_label="${label}-package-warn"
            run_cli_capture "$package_label" "$COMPILER" lint --manifest-path "$CLI_SURFACE_FMTLINT_PKG/typelisp.pkg"
            assert_status "$package_label" "$status" 0
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "lint_bad.tl:"
            ;;
        inspect)
            package_label="${label}-build-package"
            tlci="$CLI_SURFACE_INSPECT_PKG/target/release/surface_inspect.tlci"
            run_cli_capture "$package_label" "$COMPILER" build --manifest-path "$CLI_SURFACE_INSPECT_PKG/typelisp.pkg"
            assert_status "$package_label" "$status" 0
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            assert_file_nonempty "$package_label" "$tlci"
            run_cli_capture "$label" "$COMPILER" inspect "$tlci"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "tlci image"
            assert_contains "$label" "$WORKDIR/$label.out" "package-name: surface_inspect"
            assert_contains "$label" "$WORKDIR/$label.out" "metadata-version: v1"
            assert_contains "$label" "$WORKDIR/$label.out" "code: offset=0 bytes=0"
            assert_contains "$label" "$WORKDIR/$label.out" "exports:"
            assert_contains "$label" "$WORKDIR/$label.out" "  value surface-inspect-value signature=i64"
            assert_contains "$label" "$WORKDIR/$label.out" "  type SurfaceInspectPoint layout=size=16 align=8"
            assert_contains "$label" "$WORKDIR/$label.out" "  macro surface-inspect-macro signature=(macro (Expr) -> Expr)"
            assert_not_contains "$label" "$WORKDIR/$label.out" "  (none)"
            bad_tlci="$CLI_SURFACE_DIR/bad.tlci"
            printf 'bad' > "$bad_tlci"
            bad_label="${label}-bad"
            run_cli_capture "$bad_label" "$COMPILER" inspect "$bad_tlci"
            assert_status "$bad_label" "$status" 1
            assert_empty "$bad_label" "$WORKDIR/$bad_label.out"
            assert_contains "$bad_label" "$WORKDIR/$bad_label.err" "inspect: tlci: truncated header"
            ;;
        test)
            run_cli_capture "$label" "$COMPILER" test --check "$CLI_SURFACE_SRC"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "TypeLisp test typecheck passed"
            ;;
        doc)
            doc_out="$CLI_SURFACE_DIR/doc.md"
            run_cli_capture "$label" "$COMPILER" doc "$CLI_SURFACE_DOC_SRC" "$doc_out"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_file_nonempty "$label" "$doc_out"
            package_label="${label}-package-generate"
            package_doc_out="$CLI_SURFACE_DOC_PKG/package-doc.md"
            run_cli_capture "$package_label" "$COMPILER" doc --manifest-path "$CLI_SURFACE_DOC_PKG/typelisp.pkg" -o "$package_doc_out"
            assert_status "$package_label" "$status" 0
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "Wrote "
            assert_contains "$package_label" "$package_doc_out" "Package entry docs."
            if [ "$HOST_OS" = linux ]; then
                assert_contains "$package_label" "$package_doc_out" "Package extra docs."
            fi
            package_label="${label}-package-test"
            run_cli_capture "$package_label" "$COMPILER" doc --test --manifest-path "$CLI_SURFACE_DOC_PKG/typelisp.pkg"
            assert_status "$package_label" "$status" 0
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "---"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "main.tl"
            if [ "$HOST_OS" = linux ]; then
                assert_contains "$package_label" "$WORKDIR/$package_label.out" "extra.tl"
            fi
            package_label="${label}-package-test-nearest"
            run_cli_capture_in_dir "$package_label" "$CLI_SURFACE_DOC_PKG/src" "$COMPILER" doc --test
            assert_status "$package_label" "$status" 0
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "main.tl"
            if [ "$HOST_OS" = linux ]; then
                assert_contains "$package_label" "$WORKDIR/$package_label.out" "extra.tl"
            fi
            package_label="${label}-batch-test"
            batch_list="$CLI_SURFACE_DIR/doc-batch.txt"
            {
                compiler_batch_path "$CLI_SURFACE_DOC_SRC"
                compiler_batch_path "$CLI_SURFACE_DOC_PKG/src/main.tl"
            } > "$batch_list"
            run_cli_capture "$package_label" "$COMPILER" doc --test --batch "$batch_list" --stdlib-root "$ROOT/stdlib"
            assert_status "$package_label" "$status" 0
            assert_empty "$package_label" "$WORKDIR/$package_label.err"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "doc-main.tl"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "main.tl"
            assert_contains "$package_label" "$WORKDIR/$package_label.out" "Doc tests passed:"
            package_label="${label}-package-missing-output"
            run_cli_capture "$package_label" "$COMPILER" doc --manifest-path "$CLI_SURFACE_DOC_PKG/typelisp.pkg"
            assert_status "$package_label" "$status" 1
            assert_empty "$package_label" "$WORKDIR/$package_label.out"
            assert_contains "$package_label" "$WORKDIR/$package_label.err" "package documentation requires -o"
            package_label="${label}-package-mixed-input"
            run_cli_capture "$package_label" "$COMPILER" doc --test --manifest-path "$CLI_SURFACE_DOC_PKG/typelisp.pkg" "$CLI_SURFACE_DOC_SRC"
            assert_status "$package_label" "$status" 1
            assert_empty "$package_label" "$WORKDIR/$package_label.out"
            assert_contains "$package_label" "$WORKDIR/$package_label.err" "cannot combine input paths with --manifest-path"
            package_label="${label}-batch-mixed-input"
            run_cli_capture "$package_label" "$COMPILER" doc --test --batch "$batch_list" "$CLI_SURFACE_DOC_SRC"
            assert_status "$package_label" "$status" 1
            assert_empty "$package_label" "$WORKDIR/$package_label.out"
            assert_contains "$package_label" "$WORKDIR/$package_label.err" "cannot combine input paths with --batch"
            package_label="${label}-batch-empty"
            empty_batch_list="$CLI_SURFACE_DIR/doc-empty-batch.txt"
            : > "$empty_batch_list"
            run_cli_capture "$package_label" "$COMPILER" doc --test --batch "$empty_batch_list"
            assert_status "$package_label" "$status" 1
            assert_empty "$package_label" "$WORKDIR/$package_label.out"
            assert_contains "$package_label" "$WORKDIR/$package_label.err" "--batch list is empty"
            ;;
        compile)
            asm="$CLI_SURFACE_DIR/compile.s"
            run_cli_capture "$label" "$COMPILER" compile "$CLI_SURFACE_SRC" -o "$asm"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "Wrote "
            assert_contains "$label" "$asm" "main:"
            ;;
        clean)
            clean_label=$label
            clean_dry_label="$clean_label-dry-run"
            clean_idempotent_label="$clean_label-idempotent"
            clean_src="$CLI_SURFACE_DIR/clean-surface.tl"
            clean_base="$CLI_SURFACE_DIR/clean-surface"
            printf '%s' '(define (main) : i64 0)' > "$clean_src"
            : > "$clean_base.s"
            : > "$clean_base.ir"
            : > "$clean_base.o"
            : > "$clean_base.obj"
            : > "$clean_base"
            : > "$clean_base.exe"
            run_cli_capture "$clean_dry_label" "$COMPILER" clean --dry-run "$clean_src"
            assert_status "$clean_dry_label" "$status" 0
            assert_empty "$clean_dry_label" "$WORKDIR/$clean_dry_label.err"
            assert_contains "$clean_dry_label" "$WORKDIR/$clean_dry_label.out" "Would remove:"
            assert_contains "$clean_dry_label" "$WORKDIR/$clean_dry_label.out" "clean-surface.s"
            assert_file_exists "$clean_dry_label" "$clean_base.s"
            assert_file_exists "$clean_dry_label" "$clean_base"
            run_cli_capture "$clean_label" "$COMPILER" clean "$clean_src"
            assert_status "$clean_label" "$status" 0
            assert_empty "$clean_label" "$WORKDIR/$clean_label.err"
            assert_contains "$clean_label" "$WORKDIR/$clean_label.out" "Removed:"
            assert_file_exists "$clean_label" "$clean_src"
            [ ! -e "$clean_base.s" ] || fail "$clean_label did not remove $clean_base.s"
            [ ! -e "$clean_base.ir" ] || fail "$clean_label did not remove $clean_base.ir"
            [ ! -e "$clean_base.o" ] || fail "$clean_label did not remove $clean_base.o"
            [ ! -e "$clean_base.obj" ] || fail "$clean_label did not remove $clean_base.obj"
            [ ! -e "$clean_base" ] || fail "$clean_label did not remove $clean_base"
            [ ! -e "$clean_base.exe" ] || fail "$clean_label did not remove $clean_base.exe"
            run_cli_capture "$clean_idempotent_label" "$COMPILER" clean "$clean_src"
            assert_status "$clean_idempotent_label" "$status" 0
            assert_empty "$clean_idempotent_label" "$WORKDIR/$clean_idempotent_label.out"
            assert_empty "$clean_idempotent_label" "$WORKDIR/$clean_idempotent_label.err"
            ;;
        repl)
            cat > "$WORKDIR/$label.in" <<'EOF'
.help
.exit
EOF
            set +e
            "$COMPILER" repl < "$WORKDIR/$label.in" > "$WORKDIR/$label.out" 2> "$WORKDIR/$label.err"
            status=$?
            set -e
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "TypeLisp REPL commands:"
            ;;
        lsp)
            lsp_in="$CLI_SURFACE_DIR/lsp-init-shutdown.in"
            : > "$lsp_in"
            lsp_frame_append "$lsp_in" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
            lsp_frame_append "$lsp_in" '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
            set +e
            "$COMPILER" lsp < "$lsp_in" > "$WORKDIR/$label.out" 2> "$WORKDIR/$label.err"
            status=$?
            set -e
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" '"id":1'
            assert_contains "$label" "$WORKDIR/$label.out" '"textDocumentSync"'
            assert_contains "$label" "$WORKDIR/$label.out" '"id":2'
            ;;
        new)
            run_cli_capture_in_dir "$label" "$CLI_SURFACE_DIR" "$COMPILER" new surface_new
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "scaffold: created bin package surface_new"
            assert_file_exists "$label" "$CLI_SURFACE_DIR/surface_new/typelisp.pkg"
            assert_file_exists "$label" "$CLI_SURFACE_DIR/surface_new/src/main.tl"
            ;;
        init)
            init_dir="$CLI_SURFACE_DIR/surface_init"
            mkdir -p "$init_dir"
            run_cli_capture_in_dir "$label" "$init_dir" "$COMPILER" init surface_init
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "scaffold: created bin package surface_init"
            assert_file_exists "$label" "$init_dir/typelisp.pkg"
            assert_file_exists "$label" "$init_dir/src/main.tl"
            ;;
        *)
            fail "active cli surface command has no smoke assertion: $command"
            ;;
    esac
}

assert_pending_cli_surface_command() {
    command=$1
    issue=$2
    label="cli-surface-pending-$(cli_surface_label "$command")"
    set -- $command
    run_cli_capture "$label" "$COMPILER" "$@"
    assert_status "$label" "$status" 1
    assert_empty "$label" "$WORKDIR/$label.out"
    assert_contains "$label" "$WORKDIR/$label.err" "typelisp: '$command' is not yet available in the selfhost CLI"
    assert_contains "$label" "$WORKDIR/$label.err" "$issue"
}

run_cli_command_surface_matrix() {
    [ -f "$CLI_SURFACE_MANIFEST" ] || fail "missing cli command surface manifest: $CLI_SURFACE_MANIFEST"
    assert_cli_surface_help_matches_manifest
    prepare_cli_surface_files
    while IFS='|' read -r kind command note || [ -n "$kind" ]; do
        kind=$(cli_surface_strip_cr "$kind")
        command=$(cli_surface_strip_cr "$command")
        note=$(cli_surface_strip_cr "$note")
        case "$kind" in
            "" | \#*) continue ;;
            active) assert_active_cli_surface_command "$command" ;;
            pending) assert_pending_cli_surface_command "$command" "$note" ;;
            *) fail "invalid cli command surface status: $kind" ;;
        esac
    done < "$CLI_SURFACE_MANIFEST"
}

COMPILE_SRC="$WORKDIR/compile-main.tl"
COMPILE_ASM="$WORKDIR/compile-main.s"
cat > "$COMPILE_SRC" <<'EOF'
(define (main) : i64 23)
EOF

set +e
"$COMPILER" compile "$COMPILE_SRC" -o "$COMPILE_ASM" > "$WORKDIR/compile.out" 2> "$WORKDIR/compile.err"
status=$?
set -e
assert_status compile "$status" 0
assert_empty compile "$WORKDIR/compile.err"
assert_contains compile "$WORKDIR/compile.out" "Wrote "
assert_contains compile "$COMPILE_ASM" "main:"

BUILD_SRC="$WORKDIR/build-main.tl"
BUILD_EXE="$WORKDIR/built-program"
BUILD_TARGET=linux-x86_64
if [ "$HOST_OS" = windows ]; then
    BUILD_EXE="$BUILD_EXE.exe"
    BUILD_TARGET=windows-x86_64
fi
cat > "$BUILD_SRC" <<'EOF'
(define (main) : i64 19)
EOF

set +e
"$COMPILER" build "$BUILD_SRC" -o "$BUILD_EXE" > "$WORKDIR/build.out" 2> "$WORKDIR/build.err"
status=$?
set -e
assert_status build "$status" 0
assert_empty build "$WORKDIR/build.err"
assert_contains build "$WORKDIR/build.out" "Built "
[ -f "$BUILD_EXE" ] || fail "build did not write executable $BUILD_EXE"

set +e
"$BUILD_EXE" > "$WORKDIR/built-program.out" 2> "$WORKDIR/built-program.err"
status=$?
set -e
assert_status built-program "$status" 19
assert_empty built-program "$WORKDIR/built-program.out"
assert_empty built-program "$WORKDIR/built-program.err"

PKG_DIR="$WORKDIR/package-build"
mkdir -p "$PKG_DIR/src"
cat > "$PKG_DIR/typelisp.pkg" <<'EOF'
(package
  (name "cli_pkg_smoke")
  (version "0.1.0")
  (kind bin))
EOF
cat > "$PKG_DIR/src/main.tl" <<'EOF'
(define (main) : i64 29)
EOF
PKG_EXE="$PKG_DIR/target/release/cli_pkg_smoke"
if [ "$HOST_OS" = windows ]; then
    PKG_EXE="$PKG_EXE.exe"
fi
PKG_DEV_EXE="$PKG_DIR/target/dev/cli_pkg_smoke"
if [ "$HOST_OS" = windows ]; then
    PKG_DEV_EXE="$PKG_DEV_EXE.exe"
fi

set +e
(
    cd "$PKG_DIR"
    "$COMPILER" build --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-build.out" 2> "$WORKDIR/package-build.err"
)
status=$?
set -e
assert_status package-build "$status" 0
assert_empty package-build "$WORKDIR/package-build.err"
assert_contains package-build "$WORKDIR/package-build.out" "Built "
[ -f "$PKG_EXE" ] || fail "package build did not write executable $PKG_EXE"

set +e
"$PKG_EXE" > "$WORKDIR/package-program.out" 2> "$WORKDIR/package-program.err"
status=$?
set -e
assert_status package-program "$status" 29
assert_empty package-program "$WORKDIR/package-program.out"
assert_empty package-program "$WORKDIR/package-program.err"

rm -rf "$PKG_DIR/target"
set +e
(
    cd "$PKG_DIR"
    "$COMPILER" build --target "$BUILD_TARGET" --profile dev > "$WORKDIR/package-build-dev.out" 2> "$WORKDIR/package-build-dev.err"
)
status=$?
set -e
assert_status package-build-dev "$status" 0
assert_empty package-build-dev "$WORKDIR/package-build-dev.err"
assert_contains package-build-dev "$WORKDIR/package-build-dev.out" "Built "
[ -f "$PKG_DEV_EXE" ] || fail "package dev profile build did not write executable $PKG_DEV_EXE"

ROOT_PKG_OUT_DIR="$ROOT/target/release"
ROOT_PKG_EXE="$ROOT_PKG_OUT_DIR/typelisp"
if [ "$HOST_OS" = windows ]; then
    ROOT_PKG_EXE="$ROOT_PKG_EXE.exe"
fi
rm -rf "$ROOT_PKG_OUT_DIR"

set +e
(
    cd "$ROOT"
    "$COMPILER" build --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/root-package-build.out" 2> "$WORKDIR/root-package-build.err"
)
status=$?
set -e
assert_status root-package-build "$status" 0
assert_empty root-package-build "$WORKDIR/root-package-build.err"
assert_contains root-package-build "$WORKDIR/root-package-build.out" "Built "
[ -f "$ROOT_PKG_EXE" ] || fail "root package build did not write executable $ROOT_PKG_EXE"

set +e
"$ROOT_PKG_EXE" --help > "$WORKDIR/root-package-help.out" 2> "$WORKDIR/root-package-help.err"
status=$?
set -e
assert_status root-package-help "$status" 0
assert_empty root-package-help "$WORKDIR/root-package-help.out"
assert_contains root-package-help "$WORKDIR/root-package-help.err" "Usage:"
assert_contains root-package-help "$WORKDIR/root-package-help.err" "Synopsis:"
assert_contains root-package-help "$WORKDIR/root-package-help.err" "Commands:"
assert_contains root-package-help "$WORKDIR/root-package-help.err" "typelisp build          Build a source file or package artifact"
assert_contains root-package-help "$WORKDIR/root-package-help.err" "typelisp inspect        Inspect a TypeLisp comptime image"
assert_contains root-package-help "$WORKDIR/root-package-help.err" 'Run `typelisp <command> --help` for command-specific usage.'

set +e
"$ROOT_PKG_EXE" build --help > "$WORKDIR/root-package-build-help.out" 2> "$WORKDIR/root-package-build-help.err"
status=$?
set -e
assert_status root-package-build-help "$status" 0
assert_empty root-package-build-help "$WORKDIR/root-package-build-help.out"
assert_contains root-package-build-help "$WORKDIR/root-package-build-help.err" "Summary:"
assert_contains root-package-build-help "$WORKDIR/root-package-build-help.err" "typelisp build [--manifest-path <typelisp.pkg>]"
assert_contains root-package-build-help "$WORKDIR/root-package-build-help.err" "--locked"
assert_contains root-package-build-help "$WORKDIR/root-package-build-help.err" "--update-lock"

CHAIN_DIR="$WORKDIR/package-graph-chain"
CHAIN_ROOT="$CHAIN_DIR/root"
CHAIN_MID="$CHAIN_DIR/mid"
CHAIN_LEAF="$CHAIN_DIR/leaf"
mkdir -p "$CHAIN_ROOT/src" "$CHAIN_MID/src" "$CHAIN_LEAF/src"
cat > "$CHAIN_ROOT/typelisp.pkg" <<'EOF'
(package
  (name "chain_root")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (mid "../mid")))
EOF
cat > "$CHAIN_ROOT/src/main.tl" <<'EOF'
(import "pkg:mid/src/lib.tl")
(define (main) : i64 (mid-answer))
EOF
cat > "$CHAIN_MID/typelisp.pkg" <<'EOF'
(package
  (name "chain_mid")
  (version "0.1.0")
  (kind staticlib)
  (dependencies
    (leaf "../leaf")))
EOF
cat > "$CHAIN_MID/src/lib.tl" <<'EOF'
(import "pkg:leaf/src/lib.tl")
(define (mid-answer) : i64 (leaf-answer))
EOF
cat > "$CHAIN_LEAF/typelisp.pkg" <<'EOF'
(package
  (name "chain_leaf")
  (version "0.1.0")
  (kind staticlib))
EOF
cat > "$CHAIN_LEAF/src/lib.tl" <<'EOF'
(define (leaf-answer) : i64 42)
EOF
CHAIN_EXE="$CHAIN_ROOT/target/release/chain_root"
CHAIN_MID_ARCHIVE="$CHAIN_MID/target/release/libchain_mid.a"
CHAIN_LEAF_ARCHIVE="$CHAIN_LEAF/target/release/libchain_leaf.a"
if [ "$HOST_OS" = windows ]; then
    CHAIN_EXE="$CHAIN_EXE.exe"
    CHAIN_MID_ARCHIVE="$CHAIN_MID/target/release/chain_mid.lib"
    CHAIN_LEAF_ARCHIVE="$CHAIN_LEAF/target/release/chain_leaf.lib"
fi

set +e
"$COMPILER" build --manifest-path "$CHAIN_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-graph-chain.out" 2> "$WORKDIR/package-graph-chain.err"
status=$?
set -e
assert_status package-graph-chain "$status" 0
assert_empty package-graph-chain "$WORKDIR/package-graph-chain.err"
assert_contains package-graph-chain "$WORKDIR/package-graph-chain.out" "Built $(generated_path "$CHAIN_LEAF_ARCHIVE")"
assert_contains package-graph-chain "$WORKDIR/package-graph-chain.out" "Built $(generated_path "$CHAIN_MID_ARCHIVE")"
assert_contains package-graph-chain "$WORKDIR/package-graph-chain.out" "Built $(generated_path "$CHAIN_EXE")"

set +e
"$CHAIN_EXE" > "$WORKDIR/package-graph-chain-program.out" 2> "$WORKDIR/package-graph-chain-program.err"
status=$?
set -e
assert_status package-graph-chain-program "$status" 42
assert_empty package-graph-chain-program "$WORKDIR/package-graph-chain-program.out"
assert_empty package-graph-chain-program "$WORKDIR/package-graph-chain-program.err"

GITHUB_DIR="$WORKDIR/package-graph-github-prefetch"
GITHUB_ROOT="$GITHUB_DIR/root"
GITHUB_REMOTE="$GITHUB_ROOT/target/typelisp/git-deps/remote"
mkdir -p "$GITHUB_ROOT/src" "$GITHUB_REMOTE/src"
cat > "$GITHUB_ROOT/typelisp.pkg" <<'EOF'
(package
  (name "github_prefetch_root")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (remote (github "JoNil-Botta/typelisp-test-dep" (rev "abc123")))))
EOF
cat > "$GITHUB_ROOT/src/main.tl" <<'EOF'
(import "pkg:remote/src/lib.tl")
(define (main) : i64 (remote-answer))
EOF
cat > "$GITHUB_REMOTE/typelisp.pkg" <<'EOF'
(package
  (name "github_prefetch_remote")
  (version "0.1.0")
  (kind staticlib))
EOF
cat > "$GITHUB_REMOTE/src/lib.tl" <<'EOF'
(define (remote-answer) : i64 43)
EOF
GITHUB_EXE="$GITHUB_ROOT/target/release/github_prefetch_root"
GITHUB_REMOTE_ARCHIVE="$GITHUB_REMOTE/target/release/libgithub_prefetch_remote.a"
if [ "$HOST_OS" = windows ]; then
    GITHUB_EXE="$GITHUB_EXE.exe"
    GITHUB_REMOTE_ARCHIVE="$GITHUB_REMOTE/target/release/github_prefetch_remote.lib"
fi

set +e
"$COMPILER" build --manifest-path "$GITHUB_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-graph-github-prefetch.out" 2> "$WORKDIR/package-graph-github-prefetch.err"
status=$?
set -e
assert_status package-graph-github-prefetch "$status" 0
assert_empty package-graph-github-prefetch "$WORKDIR/package-graph-github-prefetch.err"
assert_contains package-graph-github-prefetch "$WORKDIR/package-graph-github-prefetch.out" "Built $(generated_path "$GITHUB_REMOTE_ARCHIVE")"
assert_contains package-graph-github-prefetch "$WORKDIR/package-graph-github-prefetch.out" "Built $(generated_path "$GITHUB_EXE")"

set +e
"$GITHUB_EXE" > "$WORKDIR/package-graph-github-prefetch-program.out" 2> "$WORKDIR/package-graph-github-prefetch-program.err"
status=$?
set -e
assert_status package-graph-github-prefetch-program "$status" 43
assert_empty package-graph-github-prefetch-program "$WORKDIR/package-graph-github-prefetch-program.out"
assert_empty package-graph-github-prefetch-program "$WORKDIR/package-graph-github-prefetch-program.err"

GITHUB_CACHE_DIR="$WORKDIR/ghc"
GITHUB_CACHE_ROOT="$GITHUB_CACHE_DIR/root"
GITHUB_CACHE_REMOTE="$GITHUB_CACHE_DIR/remote"
GITHUB_CACHE_REMOTE_OFFLINE="$GITHUB_CACHE_DIR/remote.offline"
GITHUB_CACHE_CONFIG="$GITHUB_CACHE_DIR/gitconfig"
GITHUB_CACHE_URL="https://github.com/a/b.git"
mkdir -p "$GITHUB_CACHE_ROOT/src" "$GITHUB_CACHE_REMOTE/src"
cat > "$GITHUB_CACHE_REMOTE/typelisp.pkg" <<'EOF'
(package
  (name "gc_remote")
  (version "0.1.0")
  (kind staticlib))
EOF
cat > "$GITHUB_CACHE_REMOTE/src/lib.tl" <<'EOF'
(define (remote-answer) : i64 47)
EOF
git -C "$GITHUB_CACHE_REMOTE" init -q
git -C "$GITHUB_CACHE_REMOTE" add typelisp.pkg src/lib.tl
git -C "$GITHUB_CACHE_REMOTE" \
    -c user.email=typelisp@example.invalid \
    -c user.name=typelisp \
    commit -q -m "seed cache smoke remote"
GITHUB_CACHE_REV=$(git -C "$GITHUB_CACHE_REMOTE" rev-parse HEAD)
cat > "$GITHUB_CACHE_ROOT/typelisp.pkg" <<EOF
(package
  (name "gc_root")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (remote (github "a/b" (rev "$GITHUB_CACHE_REV")))))
EOF
cat > "$GITHUB_CACHE_ROOT/src/main.tl" <<'EOF'
(import "pkg:remote/src/lib.tl")
(define (main) : i64 (remote-answer))
EOF
cat > "$GITHUB_CACHE_CONFIG" <<EOF
[url "$GITHUB_CACHE_REMOTE"]
    insteadOf = $GITHUB_CACHE_URL
EOF
GITHUB_CACHE_EXE="$GITHUB_CACHE_ROOT/target/release/gc_root"
if [ "$HOST_OS" = windows ]; then
    GITHUB_CACHE_EXE="$GITHUB_CACHE_EXE.exe"
fi

set +e
GIT_CONFIG_GLOBAL="$GITHUB_CACHE_CONFIG" "$COMPILER" build --manifest-path "$GITHUB_CACHE_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-graph-github-cache-first.out" 2> "$WORKDIR/package-graph-github-cache-first.err"
status=$?
set -e
assert_status package-graph-github-cache-first "$status" 0
assert_empty package-graph-github-cache-first "$WORKDIR/package-graph-github-cache-first.err"
assert_contains package-graph-github-cache-first "$WORKDIR/package-graph-github-cache-first.out" "Built $(generated_path "$GITHUB_CACHE_EXE")"
GITHUB_CACHE_ENTRY_MANIFEST=$(find "$GITHUB_CACHE_ROOT/target/typelisp/cache/packages/v1/git" -name typelisp.pkg -print | head -n 1)
[ -n "$GITHUB_CACHE_ENTRY_MANIFEST" ] || fail "package-graph-github-cache-first did not create a package cache entry"
GITHUB_CACHE_ENTRY=${GITHUB_CACHE_ENTRY_MANIFEST%/typelisp.pkg}
assert_file_exists package-graph-github-cache-first "$GITHUB_CACHE_ENTRY/.typelisp-cache-complete"
assert_contains package-graph-github-cache-first "$GITHUB_CACHE_ENTRY/typelisp-cache-entry.txt" "url=$GITHUB_CACHE_URL"
assert_contains package-graph-github-cache-first "$GITHUB_CACHE_ENTRY/typelisp-cache-entry.txt" "commit=$GITHUB_CACHE_REV"
GITHUB_CACHE_LOCK="$GITHUB_CACHE_ROOT/typelisp.lock"
assert_file_exists package-graph-github-cache-first "$GITHUB_CACHE_LOCK"
assert_contains package-graph-github-cache-first "$GITHUB_CACHE_LOCK" "(typelisp-lock"
assert_contains package-graph-github-cache-first "$GITHUB_CACHE_LOCK" "(alias \"remote\")"
assert_contains package-graph-github-cache-first "$GITHUB_CACHE_LOCK" "(url \"$GITHUB_CACHE_URL\")"
assert_contains package-graph-github-cache-first "$GITHUB_CACHE_LOCK" "(pin (rev \"$GITHUB_CACHE_REV\"))"
assert_contains package-graph-github-cache-first "$GITHUB_CACHE_LOCK" "(commit \"$GITHUB_CACHE_REV\")"

mv "$GITHUB_CACHE_REMOTE" "$GITHUB_CACHE_REMOTE_OFFLINE"
set +e
GIT_CONFIG_GLOBAL="$GITHUB_CACHE_CONFIG" "$COMPILER" build --manifest-path "$GITHUB_CACHE_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-graph-github-cache-hit.out" 2> "$WORKDIR/package-graph-github-cache-hit.err"
status=$?
set -e
assert_status package-graph-github-cache-hit "$status" 0
assert_empty package-graph-github-cache-hit "$WORKDIR/package-graph-github-cache-hit.err"
assert_contains package-graph-github-cache-hit "$WORKDIR/package-graph-github-cache-hit.out" "Built $(generated_path "$GITHUB_CACHE_EXE")"

mv "$GITHUB_CACHE_REMOTE_OFFLINE" "$GITHUB_CACHE_REMOTE"
printf 'typelisp-package-cache-v1\nurl=%s\ncommit=stale\n' "$GITHUB_CACHE_URL" > "$GITHUB_CACHE_ENTRY/typelisp-cache-entry.txt"
set +e
GIT_CONFIG_GLOBAL="$GITHUB_CACHE_CONFIG" "$COMPILER" build --manifest-path "$GITHUB_CACHE_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-graph-github-cache-refetch.out" 2> "$WORKDIR/package-graph-github-cache-refetch.err"
status=$?
set -e
assert_status package-graph-github-cache-refetch "$status" 0
assert_empty package-graph-github-cache-refetch "$WORKDIR/package-graph-github-cache-refetch.err"
assert_contains package-graph-github-cache-refetch "$WORKDIR/package-graph-github-cache-refetch.out" "Built $(generated_path "$GITHUB_CACHE_EXE")"
[ -d "$GITHUB_CACHE_ENTRY.corrupt.1" ] || fail "package-graph-github-cache-refetch did not preserve corrupt cache entry"
assert_contains package-graph-github-cache-refetch "$GITHUB_CACHE_ENTRY/typelisp-cache-entry.txt" "commit=$GITHUB_CACHE_REV"

set +e
"$GITHUB_CACHE_EXE" > "$WORKDIR/package-graph-github-cache-program.out" 2> "$WORKDIR/package-graph-github-cache-program.err"
status=$?
set -e
assert_status package-graph-github-cache-program "$status" 47
assert_empty package-graph-github-cache-program "$WORKDIR/package-graph-github-cache-program.out"
assert_empty package-graph-github-cache-program "$WORKDIR/package-graph-github-cache-program.err"

GITHUB_LOCK_DIR="$WORKDIR/gl"
GITHUB_LOCK_ROOT="$GITHUB_LOCK_DIR/root"
GITHUB_LOCK_REMOTE="$GITHUB_LOCK_DIR/remote"
GITHUB_LOCK_CONFIG="$GITHUB_LOCK_DIR/gitconfig"
GITHUB_LOCK_URL="https://github.com/l/b.git"
mkdir -p "$GITHUB_LOCK_ROOT/src" "$GITHUB_LOCK_REMOTE/src"
cat > "$GITHUB_LOCK_REMOTE/typelisp.pkg" <<'EOF'
(package
  (name "gl_remote")
  (version "0.1.0")
  (kind staticlib))
EOF
cat > "$GITHUB_LOCK_REMOTE/src/lib.tl" <<'EOF'
(define (remote-answer) : i64 51)
EOF
git -C "$GITHUB_LOCK_REMOTE" init -q
git -C "$GITHUB_LOCK_REMOTE" add typelisp.pkg src/lib.tl
git -C "$GITHUB_LOCK_REMOTE" \
    -c user.email=typelisp@example.invalid \
    -c user.name=typelisp \
    commit -q -m "seed lock smoke remote"
git -C "$GITHUB_LOCK_REMOTE" branch -M main
GITHUB_LOCK_REV1=$(git -C "$GITHUB_LOCK_REMOTE" rev-parse HEAD)
cat > "$GITHUB_LOCK_ROOT/typelisp.pkg" <<'EOF'
(package
  (name "gl_root")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (remote (github "l/b" (branch "main")))))
EOF
cat > "$GITHUB_LOCK_ROOT/src/main.tl" <<'EOF'
(import "pkg:remote/src/lib.tl")
(define (main) : i64 (remote-answer))
EOF
cat > "$GITHUB_LOCK_CONFIG" <<EOF
[url "$GITHUB_LOCK_REMOTE"]
    insteadOf = $GITHUB_LOCK_URL
EOF
GITHUB_LOCK_EXE="$GITHUB_LOCK_ROOT/target/release/gl_root"
if [ "$HOST_OS" = windows ]; then
    GITHUB_LOCK_EXE="$GITHUB_LOCK_EXE.exe"
fi

set +e
GIT_CONFIG_GLOBAL="$GITHUB_LOCK_CONFIG" "$COMPILER" build --manifest-path "$GITHUB_LOCK_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 --locked > "$WORKDIR/package-graph-github-lock-missing.out" 2> "$WORKDIR/package-graph-github-lock-missing.err"
status=$?
set -e
assert_status package-graph-github-lock-missing "$status" 1
assert_empty package-graph-github-lock-missing "$WORKDIR/package-graph-github-lock-missing.out"
assert_contains package-graph-github-lock-missing "$WORKDIR/package-graph-github-lock-missing.err" 'build: --locked requires typelisp.lock entry for remote dependency `remote`'
[ ! -f "$GITHUB_LOCK_ROOT/typelisp.lock" ] || fail "locked missing package build wrote typelisp.lock"

set +e
GIT_CONFIG_GLOBAL="$GITHUB_LOCK_CONFIG" "$COMPILER" build --manifest-path "$GITHUB_LOCK_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-graph-github-lock-first.out" 2> "$WORKDIR/package-graph-github-lock-first.err"
status=$?
set -e
assert_status package-graph-github-lock-first "$status" 0
assert_empty package-graph-github-lock-first "$WORKDIR/package-graph-github-lock-first.err"
assert_contains package-graph-github-lock-first "$GITHUB_LOCK_ROOT/typelisp.lock" "(pin (branch \"main\"))"
assert_contains package-graph-github-lock-first "$GITHUB_LOCK_ROOT/typelisp.lock" "(commit \"$GITHUB_LOCK_REV1\")"
set +e
"$GITHUB_LOCK_EXE" > "$WORKDIR/package-graph-github-lock-first-program.out" 2> "$WORKDIR/package-graph-github-lock-first-program.err"
status=$?
set -e
assert_status package-graph-github-lock-first-program "$status" 51
assert_empty package-graph-github-lock-first-program "$WORKDIR/package-graph-github-lock-first-program.out"
assert_empty package-graph-github-lock-first-program "$WORKDIR/package-graph-github-lock-first-program.err"

cat > "$GITHUB_LOCK_REMOTE/src/lib.tl" <<'EOF'
(define (remote-answer) : i64 52)
EOF
git -C "$GITHUB_LOCK_REMOTE" add src/lib.tl
git -C "$GITHUB_LOCK_REMOTE" \
    -c user.email=typelisp@example.invalid \
    -c user.name=typelisp \
    commit -q -m "move branch after lock"
GITHUB_LOCK_REV2=$(git -C "$GITHUB_LOCK_REMOTE" rev-parse HEAD)
rm -rf "$GITHUB_LOCK_ROOT/target/typelisp/git-deps"
set +e
GIT_CONFIG_GLOBAL="$GITHUB_LOCK_CONFIG" "$COMPILER" build --manifest-path "$GITHUB_LOCK_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-graph-github-lock-replay.out" 2> "$WORKDIR/package-graph-github-lock-replay.err"
status=$?
set -e
assert_status package-graph-github-lock-replay "$status" 0
assert_empty package-graph-github-lock-replay "$WORKDIR/package-graph-github-lock-replay.err"
assert_contains package-graph-github-lock-replay "$GITHUB_LOCK_ROOT/typelisp.lock" "(commit \"$GITHUB_LOCK_REV1\")"
set +e
"$GITHUB_LOCK_EXE" > "$WORKDIR/package-graph-github-lock-replay-program.out" 2> "$WORKDIR/package-graph-github-lock-replay-program.err"
status=$?
set -e
assert_status package-graph-github-lock-replay-program "$status" 51
assert_empty package-graph-github-lock-replay-program "$WORKDIR/package-graph-github-lock-replay-program.out"
assert_empty package-graph-github-lock-replay-program "$WORKDIR/package-graph-github-lock-replay-program.err"

cp "$GITHUB_LOCK_ROOT/typelisp.lock" "$WORKDIR/package-graph-github-lock-before-locked"
GITHUB_LOCK_REMOTE_OFFLINE="$GITHUB_LOCK_REMOTE.offline"
rm -rf "$GITHUB_LOCK_REMOTE_OFFLINE"
mv "$GITHUB_LOCK_REMOTE" "$GITHUB_LOCK_REMOTE_OFFLINE"
set +e
GIT_CONFIG_GLOBAL="$GITHUB_LOCK_CONFIG" "$COMPILER" build --manifest-path "$GITHUB_LOCK_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 --locked > "$WORKDIR/package-graph-github-lock-locked.out" 2> "$WORKDIR/package-graph-github-lock-locked.err"
status=$?
set -e
mv "$GITHUB_LOCK_REMOTE_OFFLINE" "$GITHUB_LOCK_REMOTE"
assert_status package-graph-github-lock-locked "$status" 0
assert_empty package-graph-github-lock-locked "$WORKDIR/package-graph-github-lock-locked.err"
cmp -s "$WORKDIR/package-graph-github-lock-before-locked" "$GITHUB_LOCK_ROOT/typelisp.lock" || fail "locked package build rewrote typelisp.lock"
set +e
"$GITHUB_LOCK_EXE" > "$WORKDIR/package-graph-github-lock-locked-program.out" 2> "$WORKDIR/package-graph-github-lock-locked-program.err"
status=$?
set -e
assert_status package-graph-github-lock-locked-program "$status" 51
assert_empty package-graph-github-lock-locked-program "$WORKDIR/package-graph-github-lock-locked-program.out"
assert_empty package-graph-github-lock-locked-program "$WORKDIR/package-graph-github-lock-locked-program.err"

git -C "$GITHUB_LOCK_REMOTE" branch next "$GITHUB_LOCK_REV2"
cat > "$GITHUB_LOCK_ROOT/typelisp.pkg" <<'EOF'
(package
  (name "gl_root")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (remote (github "l/b" (branch "next")))))
EOF
rm -rf "$GITHUB_LOCK_ROOT/target/typelisp/git-deps"
cp "$GITHUB_LOCK_ROOT/typelisp.lock" "$WORKDIR/package-graph-github-lock-before-stale"
set +e
GIT_CONFIG_GLOBAL="$GITHUB_LOCK_CONFIG" "$COMPILER" build --manifest-path "$GITHUB_LOCK_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 --locked > "$WORKDIR/package-graph-github-lock-stale.out" 2> "$WORKDIR/package-graph-github-lock-stale.err"
status=$?
set -e
assert_status package-graph-github-lock-stale "$status" 1
assert_empty package-graph-github-lock-stale "$WORKDIR/package-graph-github-lock-stale.out"
assert_contains package-graph-github-lock-stale "$WORKDIR/package-graph-github-lock-stale.err" 'build: package lock entry for remote dependency `remote` is stale'
cmp -s "$WORKDIR/package-graph-github-lock-before-stale" "$GITHUB_LOCK_ROOT/typelisp.lock" || fail "locked stale package build rewrote typelisp.lock"

rm -rf "$GITHUB_LOCK_ROOT/target/typelisp/git-deps"
set +e
GIT_CONFIG_GLOBAL="$GITHUB_LOCK_CONFIG" "$COMPILER" build --manifest-path "$GITHUB_LOCK_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 --update-lock > "$WORKDIR/package-graph-github-lock-update.out" 2> "$WORKDIR/package-graph-github-lock-update.err"
status=$?
set -e
assert_status package-graph-github-lock-update "$status" 0
assert_empty package-graph-github-lock-update "$WORKDIR/package-graph-github-lock-update.err"
assert_contains package-graph-github-lock-update "$GITHUB_LOCK_ROOT/typelisp.lock" "(pin (branch \"next\"))"
assert_contains package-graph-github-lock-update "$GITHUB_LOCK_ROOT/typelisp.lock" "(commit \"$GITHUB_LOCK_REV2\")"
set +e
"$GITHUB_LOCK_EXE" > "$WORKDIR/package-graph-github-lock-update-program.out" 2> "$WORKDIR/package-graph-github-lock-update-program.err"
status=$?
set -e
assert_status package-graph-github-lock-update-program "$status" 52
assert_empty package-graph-github-lock-update-program "$WORKDIR/package-graph-github-lock-update-program.out"
assert_empty package-graph-github-lock-update-program "$WORKDIR/package-graph-github-lock-update-program.err"

DIAMOND_DIR="$WORKDIR/package-graph-diamond"
DIAMOND_ROOT="$DIAMOND_DIR/root"
DIAMOND_LEFT="$DIAMOND_DIR/left"
DIAMOND_RIGHT="$DIAMOND_DIR/right"
DIAMOND_SHARED="$DIAMOND_DIR/shared"
mkdir -p "$DIAMOND_ROOT/src" "$DIAMOND_LEFT/src" "$DIAMOND_RIGHT/src" "$DIAMOND_SHARED/src"
cat > "$DIAMOND_ROOT/typelisp.pkg" <<'EOF'
(package
  (name "diamond_root")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (left "../left")
    (right "../right")))
EOF
cat > "$DIAMOND_ROOT/src/main.tl" <<'EOF'
(import "pkg:left/src/lib.tl")
(import "pkg:right/src/lib.tl")
(define (main) : i64 (+ (left-answer) (right-answer)))
EOF
cat > "$DIAMOND_LEFT/typelisp.pkg" <<'EOF'
(package
  (name "diamond_left")
  (version "0.1.0")
  (kind staticlib)
  (dependencies
    (shared "../shared")))
EOF
cat > "$DIAMOND_LEFT/src/lib.tl" <<'EOF'
(import "pkg:shared/src/lib.tl")
(define (left-answer) : i64 (shared-answer))
EOF
cat > "$DIAMOND_RIGHT/typelisp.pkg" <<'EOF'
(package
  (name "diamond_right")
  (version "0.1.0")
  (kind staticlib)
  (dependencies
    (shared "../shared")))
EOF
cat > "$DIAMOND_RIGHT/src/lib.tl" <<'EOF'
(import "pkg:shared/src/lib.tl")
(define (right-answer) : i64 (shared-answer))
EOF
cat > "$DIAMOND_SHARED/typelisp.pkg" <<'EOF'
(package
  (name "diamond_shared")
  (version "0.1.0")
  (kind staticlib))
EOF
cat > "$DIAMOND_SHARED/src/lib.tl" <<'EOF'
(define (shared-answer) : i64 21)
EOF
DIAMOND_EXE="$DIAMOND_ROOT/target/release/diamond_root"
DIAMOND_SHARED_ARCHIVE="$DIAMOND_SHARED/target/release/libdiamond_shared.a"
DIAMOND_LEFT_ARCHIVE="$DIAMOND_LEFT/target/release/libdiamond_left.a"
DIAMOND_RIGHT_ARCHIVE="$DIAMOND_RIGHT/target/release/libdiamond_right.a"
if [ "$HOST_OS" = windows ]; then
    DIAMOND_EXE="$DIAMOND_EXE.exe"
    DIAMOND_SHARED_ARCHIVE="$DIAMOND_SHARED/target/release/diamond_shared.lib"
    DIAMOND_LEFT_ARCHIVE="$DIAMOND_LEFT/target/release/diamond_left.lib"
    DIAMOND_RIGHT_ARCHIVE="$DIAMOND_RIGHT/target/release/diamond_right.lib"
fi

set +e
"$COMPILER" build --manifest-path "$DIAMOND_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-graph-diamond.out" 2> "$WORKDIR/package-graph-diamond.err"
status=$?
set -e
assert_status package-graph-diamond "$status" 0
assert_empty package-graph-diamond "$WORKDIR/package-graph-diamond.err"
assert_occurrences package-graph-diamond "$WORKDIR/package-graph-diamond.out" "Built $(generated_path "$DIAMOND_SHARED_ARCHIVE")" 1
assert_contains package-graph-diamond "$WORKDIR/package-graph-diamond.out" "Built $(generated_path "$DIAMOND_LEFT_ARCHIVE")"
assert_contains package-graph-diamond "$WORKDIR/package-graph-diamond.out" "Built $(generated_path "$DIAMOND_RIGHT_ARCHIVE")"
assert_contains package-graph-diamond "$WORKDIR/package-graph-diamond.out" "Built $(generated_path "$DIAMOND_EXE")"

set +e
"$DIAMOND_EXE" > "$WORKDIR/package-graph-diamond-program.out" 2> "$WORKDIR/package-graph-diamond-program.err"
status=$?
set -e
assert_status package-graph-diamond-program "$status" 42
assert_empty package-graph-diamond-program "$WORKDIR/package-graph-diamond-program.out"
assert_empty package-graph-diamond-program "$WORKDIR/package-graph-diamond-program.err"

FAIL_DIR="$WORKDIR/package-graph-failure"
FAIL_ROOT="$FAIL_DIR/root"
FAIL_GOOD="$FAIL_DIR/good"
FAIL_BAD="$FAIL_DIR/bad"
mkdir -p "$FAIL_ROOT/src" "$FAIL_GOOD/src" "$FAIL_BAD/src"
cat > "$FAIL_ROOT/typelisp.pkg" <<'EOF'
(package
  (name "fail_root")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (good "../good")
    (bad "../bad")))
EOF
cat > "$FAIL_ROOT/src/main.tl" <<'EOF'
(import "pkg:good/src/lib.tl")
(define (main) : i64 (good-answer))
EOF
cat > "$FAIL_GOOD/typelisp.pkg" <<'EOF'
(package
  (name "fail_good")
  (version "0.1.0")
  (kind staticlib))
EOF
cat > "$FAIL_GOOD/src/lib.tl" <<'EOF'
(define (good-answer) : i64 42)
EOF
cat > "$FAIL_BAD/typelisp.pkg" <<'EOF'
(package
  (name "fail_bad")
  (version "0.1.0")
  (kind staticlib))
EOF
cat > "$FAIL_BAD/src/lib.tl" <<'EOF'
(define (bad-answer) : i64 "bad")
EOF

set +e
"$COMPILER" build --manifest-path "$FAIL_ROOT/typelisp.pkg" --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/package-graph-failure.out" 2> "$WORKDIR/package-graph-failure.err"
status=$?
set -e
assert_status package-graph-failure "$status" 1
assert_contains package-graph-failure "$WORKDIR/package-graph-failure.err" "typecheck:"
assert_contains package-graph-failure "$WORKDIR/package-graph-failure.err" 'build: package dependency `fail_bad` failed with status 1'

CYCLE_DIR="$WORKDIR/package-graph-cycle"
CYCLE_ROOT="$CYCLE_DIR/root"
CYCLE_A="$CYCLE_DIR/cycle_a"
CYCLE_B="$CYCLE_DIR/cycle_b"
mkdir -p "$CYCLE_ROOT/src" "$CYCLE_A/src" "$CYCLE_B/src"
cat > "$CYCLE_ROOT/typelisp.pkg" <<'EOF'
(package
  (name "cycle_root")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (a "../cycle_a")))
EOF
cat > "$CYCLE_ROOT/src/main.tl" <<'EOF'
(import "pkg:a/src/lib.tl")
(define (main) : i64 (a-answer))
EOF
cat > "$CYCLE_A/typelisp.pkg" <<'EOF'
(package
  (name "cycle_a")
  (version "0.1.0")
  (kind staticlib)
  (dependencies
    (b "../cycle_b")))
EOF
cat > "$CYCLE_A/src/lib.tl" <<'EOF'
(define (a-answer) : i64 1)
EOF
cat > "$CYCLE_B/typelisp.pkg" <<'EOF'
(package
  (name "cycle_b")
  (version "0.1.0")
  (kind staticlib)
  (dependencies
    (a "../cycle_a")))
EOF
cat > "$CYCLE_B/src/lib.tl" <<'EOF'
(define (b-answer) : i64 2)
EOF

set +e
"$COMPILER" build --manifest-path "$CYCLE_ROOT/typelisp.pkg" --target "$BUILD_TARGET" > "$WORKDIR/package-graph-cycle.out" 2> "$WORKDIR/package-graph-cycle.err"
status=$?
set -e
assert_status package-graph-cycle "$status" 1
assert_empty package-graph-cycle "$WORKDIR/package-graph-cycle.out"
assert_contains package-graph-cycle "$WORKDIR/package-graph-cycle.err" "build: dependency cycle:"
assert_contains package-graph-cycle "$WORKDIR/package-graph-cycle.err" "cycle_a"
assert_contains package-graph-cycle "$WORKDIR/package-graph-cycle.err" "cycle_b"

BADKIND_DIR="$WORKDIR/package-graph-bad-kind"
BADKIND_ROOT="$BADKIND_DIR/root"
BADKIND_DEP="$BADKIND_DIR/dep_bin"
mkdir -p "$BADKIND_ROOT/src" "$BADKIND_DEP/src"
cat > "$BADKIND_ROOT/typelisp.pkg" <<'EOF'
(package
  (name "bad_kind_root")
  (version "0.1.0")
  (kind bin)
  (dependencies
    (dep "../dep_bin")))
EOF
cat > "$BADKIND_ROOT/src/main.tl" <<'EOF'
(define (main) : i64 0)
EOF
cat > "$BADKIND_DEP/typelisp.pkg" <<'EOF'
(package
  (name "dep_bin")
  (version "0.1.0")
  (kind bin))
EOF
cat > "$BADKIND_DEP/src/main.tl" <<'EOF'
(define (main) : i64 0)
EOF

set +e
"$COMPILER" build --manifest-path "$BADKIND_ROOT/typelisp.pkg" --target "$BUILD_TARGET" > "$WORKDIR/package-graph-bad-kind.out" 2> "$WORKDIR/package-graph-bad-kind.err"
status=$?
set -e
assert_status package-graph-bad-kind "$status" 1
assert_empty package-graph-bad-kind "$WORKDIR/package-graph-bad-kind.out"
assert_contains package-graph-bad-kind "$WORKDIR/package-graph-bad-kind.err" 'build: dependency `dep`'
assert_contains package-graph-bad-kind "$WORKDIR/package-graph-bad-kind.err" "must be a staticlib package"

STATICLIB_DIR="$WORKDIR/staticlib-package-build"
mkdir -p "$STATICLIB_DIR/src"
cat > "$STATICLIB_DIR/typelisp.pkg" <<'EOF'
(package
  (name "cli_staticlib_smoke")
  (version "0.1.0")
  (kind staticlib))
EOF
cat > "$STATICLIB_DIR/src/lib.tl" <<'EOF'
(define (static-answer) : i64 42)
EOF
STATICLIB_ARCHIVE="$STATICLIB_DIR/target/release/libcli_staticlib_smoke.a"
if [ "$HOST_OS" = windows ]; then
    STATICLIB_ARCHIVE="$STATICLIB_DIR/target/release/cli_staticlib_smoke.lib"
fi

set +e
(
    cd "$STATICLIB_DIR"
    "$COMPILER" build --target "$BUILD_TARGET" > "$WORKDIR/staticlib-package-build.out" 2> "$WORKDIR/staticlib-package-build.err"
)
status=$?
set -e
assert_status staticlib-package-build "$status" 0
assert_empty staticlib-package-build "$WORKDIR/staticlib-package-build.err"
assert_contains staticlib-package-build "$WORKDIR/staticlib-package-build.out" "Built "
[ -s "$STATICLIB_ARCHIVE" ] || fail "staticlib package build did not write archive $STATICLIB_ARCHIVE"

STATICLIB_OVERRIDE="$WORKDIR/staticlib-entry-override"
mkdir -p "$STATICLIB_OVERRIDE/custom"
cat > "$STATICLIB_OVERRIDE/typelisp.pkg" <<'EOF'
(package
  (name "cli_staticlib_override")
  (version "0.1.0")
  (kind "staticlib")
  (entry "custom/entry.tl"))
EOF
cat > "$STATICLIB_OVERRIDE/custom/entry.tl" <<'EOF'
(define (override-answer) : i64 77)
EOF
STATICLIB_OVERRIDE_ARCHIVE="$STATICLIB_OVERRIDE/target/release/libcli_staticlib_override.a"
if [ "$HOST_OS" = windows ]; then
    STATICLIB_OVERRIDE_ARCHIVE="$STATICLIB_OVERRIDE/target/release/cli_staticlib_override.lib"
fi

set +e
(
    cd "$STATICLIB_OVERRIDE"
    "$COMPILER" build --target "$BUILD_TARGET" > "$WORKDIR/staticlib-entry-override.out" 2> "$WORKDIR/staticlib-entry-override.err"
)
status=$?
set -e
assert_status staticlib-entry-override "$status" 0
assert_empty staticlib-entry-override "$WORKDIR/staticlib-entry-override.err"
assert_contains staticlib-entry-override "$WORKDIR/staticlib-entry-override.out" "Built "
[ -s "$STATICLIB_OVERRIDE_ARCHIVE" ] || fail "staticlib package build did not honor explicit entry"

SCAFFOLD_ROOT="$WORKDIR/scaffold"
mkdir -p "$SCAFFOLD_ROOT"

set +e
(
    cd "$SCAFFOLD_ROOT"
    "$COMPILER" new cli_new_bin > "$WORKDIR/scaffold-new-bin.out" 2> "$WORKDIR/scaffold-new-bin.err"
)
status=$?
set -e
assert_status scaffold-new-bin "$status" 0
assert_empty scaffold-new-bin "$WORKDIR/scaffold-new-bin.err"
assert_contains scaffold-new-bin "$WORKDIR/scaffold-new-bin.out" "scaffold: created bin package cli_new_bin"
NEW_BIN_DIR="$SCAFFOLD_ROOT/cli_new_bin"
[ -f "$NEW_BIN_DIR/typelisp.pkg" ] || fail "new did not write bin manifest"
[ -f "$NEW_BIN_DIR/src/main.tl" ] || fail "new did not write bin main source"
assert_contains scaffold-new-bin-manifest "$NEW_BIN_DIR/typelisp.pkg" '(kind "bin")'
assert_contains scaffold-new-bin-manifest "$NEW_BIN_DIR/typelisp.pkg" '(entry "src/main.tl")'

NEW_BIN_EXE="$NEW_BIN_DIR/target/release/cli_new_bin"
if [ "$HOST_OS" = windows ]; then
    NEW_BIN_EXE="$NEW_BIN_EXE.exe"
fi
set +e
(
    cd "$NEW_BIN_DIR"
    "$COMPILER" build --target "$BUILD_TARGET" --opt-level 0 > "$WORKDIR/scaffold-new-bin-build.out" 2> "$WORKDIR/scaffold-new-bin-build.err"
)
status=$?
set -e
assert_status scaffold-new-bin-build "$status" 0
assert_empty scaffold-new-bin-build "$WORKDIR/scaffold-new-bin-build.err"
assert_contains scaffold-new-bin-build "$WORKDIR/scaffold-new-bin-build.out" "Built "
[ -f "$NEW_BIN_EXE" ] || fail "new bin package build did not write executable"

set +e
"$NEW_BIN_EXE" > "$WORKDIR/scaffold-new-bin-program.out" 2> "$WORKDIR/scaffold-new-bin-program.err"
status=$?
set -e
assert_status scaffold-new-bin-program "$status" 0
assert_empty scaffold-new-bin-program "$WORKDIR/scaffold-new-bin-program.out"
assert_empty scaffold-new-bin-program "$WORKDIR/scaffold-new-bin-program.err"

set +e
(
    cd "$SCAFFOLD_ROOT"
    "$COMPILER" new --lib cli_new_lib > "$WORKDIR/scaffold-new-lib.out" 2> "$WORKDIR/scaffold-new-lib.err"
)
status=$?
set -e
assert_status scaffold-new-lib "$status" 0
assert_empty scaffold-new-lib "$WORKDIR/scaffold-new-lib.err"
assert_contains scaffold-new-lib "$WORKDIR/scaffold-new-lib.out" "scaffold: created staticlib package cli_new_lib"
NEW_LIB_DIR="$SCAFFOLD_ROOT/cli_new_lib"
[ -f "$NEW_LIB_DIR/typelisp.pkg" ] || fail "new --lib did not write manifest"
[ -f "$NEW_LIB_DIR/src/lib.tl" ] || fail "new --lib did not write lib source"
assert_contains scaffold-new-lib-manifest "$NEW_LIB_DIR/typelisp.pkg" '(kind "staticlib")'
assert_contains scaffold-new-lib-manifest "$NEW_LIB_DIR/typelisp.pkg" '(entry "src/lib.tl")'

NEW_LIB_ARCHIVE="$NEW_LIB_DIR/target/release/libcli_new_lib.a"
if [ "$HOST_OS" = windows ]; then
    NEW_LIB_ARCHIVE="$NEW_LIB_DIR/target/release/cli_new_lib.lib"
fi
set +e
(
    cd "$NEW_LIB_DIR"
    "$COMPILER" build --target "$BUILD_TARGET" > "$WORKDIR/scaffold-new-lib-build.out" 2> "$WORKDIR/scaffold-new-lib-build.err"
)
status=$?
set -e
assert_status scaffold-new-lib-build "$status" 0
assert_empty scaffold-new-lib-build "$WORKDIR/scaffold-new-lib-build.err"
assert_contains scaffold-new-lib-build "$WORKDIR/scaffold-new-lib-build.out" "Built "
[ -s "$NEW_LIB_ARCHIVE" ] || fail "new --lib package build did not write archive"

INIT_BIN_DIR="$SCAFFOLD_ROOT/init-bin"
mkdir -p "$INIT_BIN_DIR"
set +e
(
    cd "$INIT_BIN_DIR"
    "$COMPILER" init cli_init_bin > "$WORKDIR/scaffold-init-bin.out" 2> "$WORKDIR/scaffold-init-bin.err"
)
status=$?
set -e
assert_status scaffold-init-bin "$status" 0
assert_empty scaffold-init-bin "$WORKDIR/scaffold-init-bin.err"
assert_contains scaffold-init-bin "$WORKDIR/scaffold-init-bin.out" "scaffold: created bin package cli_init_bin"
[ -f "$INIT_BIN_DIR/typelisp.pkg" ] || fail "init did not write manifest"
[ -f "$INIT_BIN_DIR/src/main.tl" ] || fail "init did not write main source"

set +e
(
    cd "$INIT_BIN_DIR"
    "$COMPILER" init cli_init_bin > "$WORKDIR/scaffold-init-clobber.out" 2> "$WORKDIR/scaffold-init-clobber.err"
)
status=$?
set -e
assert_status scaffold-init-clobber "$status" 1
assert_empty scaffold-init-clobber "$WORKDIR/scaffold-init-clobber.out"
assert_contains scaffold-init-clobber "$WORKDIR/scaffold-init-clobber.err" "scaffold: refusing to overwrite existing file: ./typelisp.pkg"

INIT_LIB_DIR="$SCAFFOLD_ROOT/init-lib"
mkdir -p "$INIT_LIB_DIR"
set +e
(
    cd "$INIT_LIB_DIR"
    "$COMPILER" init --lib cli_init_lib > "$WORKDIR/scaffold-init-lib.out" 2> "$WORKDIR/scaffold-init-lib.err"
)
status=$?
set -e
assert_status scaffold-init-lib "$status" 0
assert_empty scaffold-init-lib "$WORKDIR/scaffold-init-lib.err"
assert_contains scaffold-init-lib "$WORKDIR/scaffold-init-lib.out" "scaffold: created staticlib package cli_init_lib"
[ -f "$INIT_LIB_DIR/typelisp.pkg" ] || fail "init --lib did not write manifest"
[ -f "$INIT_LIB_DIR/src/lib.tl" ] || fail "init --lib did not write lib source"
assert_contains scaffold-init-lib-manifest "$INIT_LIB_DIR/typelisp.pkg" '(kind "staticlib")'
assert_contains scaffold-init-lib-manifest "$INIT_LIB_DIR/typelisp.pkg" '(entry "src/lib.tl")'

RUN_SRC="$WORKDIR/run-main.tl"
cat > "$RUN_SRC" <<'EOF'
(import "stdlib/io.tl")

(define (fixture-cstr-len [p : (Ptr u8)]) : i64
  (let
    [n : i64 0]
    (begin
      (while (not (= (unsafe (ptr-read (ptr-offset p n))) (cast 0 : u8)))
        (set! n (+ n 1)))
      n)))
(define (fixture-stdout-write [text : String]) : unit
  (stdout-write (& text)))
(define (fixture-arg [index : i64]) : String
  (let
    [argv : (Ptr (Ptr u8)) (unsafe (program-argv))]
    [raw : (Ptr u8) (unsafe (ptr-read (ptr-offset argv index)))]
    (unsafe (string-from-bytes raw (fixture-cstr-len raw)))))
(define (main) : i64
  (begin
    (fixture-stdout-write (fixture-arg 1))
    17))
EOF

set +e
"$COMPILER" run "$RUN_SRC" -- "run-arg-ok" > "$WORKDIR/run.out" 2> "$WORKDIR/run.err"
status=$?
set -e
assert_status run "$status" 17
assert_empty run "$WORKDIR/run.err"
assert_contains run "$WORKDIR/run.out" "run-arg-ok"

if [ "$HOST_OS" = windows ]; then
    # Windows process-output still cannot spawn a REPL scratch executable while
    # the REPL owns redirected stdin; Linux keeps expression execution coverage.
    cat > "$WORKDIR/repl.in" <<'EOF'
.help
.type true
.exit
EOF
else
    cat > "$WORKDIR/repl.in" <<'EOF'
.help
.type true
(+ 1 2)
.exit
EOF
fi

set +e
"$COMPILER" repl < "$WORKDIR/repl.in" > "$WORKDIR/repl.out" 2> "$WORKDIR/repl.err"
status=$?
set -e
assert_status repl "$status" 0
assert_empty repl "$WORKDIR/repl.err"
assert_contains repl "$WORKDIR/repl.out" "TypeLisp REPL commands:"
assert_contains repl "$WORKDIR/repl.out" ".type <expr>"
assert_contains repl "$WORKDIR/repl.out" "bool"
if [ "$HOST_OS" != windows ]; then
    assert_contains repl "$WORKDIR/repl.out" "3"
fi

printf '.help\r\n.exit\r\n' > "$WORKDIR/repl-crlf.in"
set +e
"$COMPILER" repl < "$WORKDIR/repl-crlf.in" > "$WORKDIR/repl-crlf.out" 2> "$WORKDIR/repl-crlf.err"
status=$?
set -e
assert_status repl-crlf "$status" 0
assert_empty repl-crlf "$WORKDIR/repl-crlf.err"
assert_contains repl-crlf "$WORKDIR/repl-crlf.out" "TypeLisp REPL commands:"

printf '\357\273\277.help\r\n.exit\r\n' > "$WORKDIR/repl-bom-crlf.in"
set +e
"$COMPILER" repl < "$WORKDIR/repl-bom-crlf.in" > "$WORKDIR/repl-bom-crlf.out" 2> "$WORKDIR/repl-bom-crlf.err"
status=$?
set -e
assert_status repl-bom-crlf "$status" 0
assert_empty repl-bom-crlf "$WORKDIR/repl-bom-crlf.err"
assert_contains repl-bom-crlf "$WORKDIR/repl-bom-crlf.out" "TypeLisp REPL commands:"

set +e
"$COMPILER" repl unexpected > "$WORKDIR/repl-args.out" 2> "$WORKDIR/repl-args.err"
status=$?
set -e
assert_status repl-args "$status" 1
assert_empty repl-args "$WORKDIR/repl-args.out"
assert_contains repl-args "$WORKDIR/repl-args.err" "Error: repl does not accept arguments"

CHOOSER_INPUT="$WORKDIR/work-queue-chooser.json"
cat > "$CHOOSER_INPUT" <<'EOF'
{"prs":[],"issues":[{"number":7,"title":"Fallback issue","labels":[]}]}
EOF
set +e
"$COMPILER" run "$ROOT/tools/work-queue-chooser/chooser.tl" --stdlib-root "$ROOT/stdlib" \
    < "$CHOOSER_INPUT" > "$WORKDIR/work-queue-chooser.out" 2> "$WORKDIR/work-queue-chooser.err"
status=$?
set -e
assert_status work-queue-chooser "$status" 0
assert_empty work-queue-chooser "$WORKDIR/work-queue-chooser.err"
assert_contains work-queue-chooser "$WORKDIR/work-queue-chooser.out" "research/triage issue #7: Fallback issue"

run_cli_command_surface_matrix

echo "[selfhost-cli-build-run] public LSP corpus via run-corpus.sh"
TYPELISP_BIN="$COMPILER" sh "$ROOT/tests/public-tools/run-corpus.sh" lsp

echo "selfhost cli build/run smoke passed"
