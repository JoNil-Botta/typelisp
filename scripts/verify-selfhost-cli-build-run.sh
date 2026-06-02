#!/usr/bin/env sh
set -eu

# verify-selfhost-cli-build-run.sh - focused public build/run smoke for cli.tl.
#
# This is run against a freshly built selfhost/cli.tl binary in the no-Rust gate,
# so it verifies the branch's public `typelisp build` / `typelisp run` behavior
# instead of the already-published seed compiler.

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
        $1 != "active" && $1 != "pending" && $1 != "retired" {
            printf "cli surface manifest line %d has invalid status: %s\n", NR, $1 > "/dev/stderr"
            exit 2
        }
        $1 != "retired" { print $2 }
    ' "$CLI_SURFACE_MANIFEST" | sort -u
}

cli_surface_help_commands() {
    awk '
        /^[[:space:]]+typelisp / {
            if ($2 == "debug") {
                print $2 " " $3
            } else {
                print $2
            }
        }
    ' "$WORKDIR/cli-surface-help.err" | sort -u
}

assert_cli_surface_help_matches_manifest() {
    run_cli_capture cli-surface-help "$COMPILER" --help
    assert_status cli-surface-help "$status" 0
    assert_empty cli-surface-help "$WORKDIR/cli-surface-help.out"
    assert_contains cli-surface-help "$WORKDIR/cli-surface-help.err" "Usage:"

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
    mkdir -p "$CLI_SURFACE_DIR"
    printf '%s' '(define (main) : i64
  0)' > "$CLI_SURFACE_SRC"
    cat > "$CLI_SURFACE_RUN_SRC" <<'EOF'
(define (main) : i64
  (begin
    (print-string (arg 1))
    33))
EOF
    cat > "$CLI_SURFACE_DOC_SRC" <<'EOF'
;;;; Command surface doc smoke.
(define (main) : i64
  0)
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
            assert_contains "$label" "$WORKDIR/$label.out" "Generated:"
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
            ;;
        fmt)
            run_cli_capture "$label" "$COMPILER" fmt --check "$CLI_SURFACE_SRC"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            ;;
        lint)
            run_cli_capture "$label" "$COMPILER" lint "$CLI_SURFACE_SRC"
            assert_status "$label" "$status" 0
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
            ;;
        compile)
            asm="$CLI_SURFACE_DIR/compile.s"
            run_cli_capture "$label" "$COMPILER" compile "$CLI_SURFACE_SRC" -o "$asm"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "Generated:"
            assert_contains "$label" "$asm" "main:"
            ;;
        "debug tokenize")
            run_cli_capture "$label" "$COMPILER" debug tokenize "$CLI_SURFACE_SRC"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "define"
            ;;
        "debug parse")
            run_cli_capture "$label" "$COMPILER" debug parse "$CLI_SURFACE_SRC"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "Program"
            ;;
        "debug check")
            run_cli_capture "$label" "$COMPILER" debug check "$CLI_SURFACE_SRC"
            assert_status "$label" "$status" 0
            assert_empty "$label" "$WORKDIR/$label.err"
            assert_contains "$label" "$WORKDIR/$label.out" "Type checking passed!"
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

assert_retired_cli_surface_command() {
    command=$1
    label="cli-surface-retired-$(cli_surface_label "$command")"
    case "$command" in
        "debug host-action")
            run_cli_capture "$label" "$COMPILER" debug host-action
            assert_status "$label" "$status" 1
            assert_empty "$label" "$WORKDIR/$label.out"
            assert_contains "$label" "$WORKDIR/$label.err" "Unknown debug command: host-action"
            ;;
        *)
            fail "retired cli surface command has no assertion: $command"
            ;;
    esac
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
            retired) assert_retired_cli_surface_command "$command" ;;
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
assert_contains compile "$WORKDIR/compile.out" "Generated:"
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
assert_contains build "$WORKDIR/build.out" "Generated:"
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
PKG_EXE="$PKG_DIR/target/typelisp/cli_pkg_smoke/cli_pkg_smoke"
if [ "$HOST_OS" = windows ]; then
    PKG_EXE="$PKG_EXE.exe"
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
assert_contains package-build "$WORKDIR/package-build.out" "Generated:"
[ -f "$PKG_EXE" ] || fail "package build did not write executable $PKG_EXE"

set +e
"$PKG_EXE" > "$WORKDIR/package-program.out" 2> "$WORKDIR/package-program.err"
status=$?
set -e
assert_status package-program "$status" 29
assert_empty package-program "$WORKDIR/package-program.out"
assert_empty package-program "$WORKDIR/package-program.err"

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
STATICLIB_ARCHIVE="$STATICLIB_DIR/target/typelisp/cli_staticlib_smoke/libcli_staticlib_smoke.a"
if [ "$HOST_OS" = windows ]; then
    STATICLIB_ARCHIVE="$STATICLIB_DIR/target/typelisp/cli_staticlib_smoke/cli_staticlib_smoke.lib"
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
assert_contains staticlib-package-build "$WORKDIR/staticlib-package-build.out" "Generated:"
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
STATICLIB_OVERRIDE_ARCHIVE="$STATICLIB_OVERRIDE/target/typelisp/cli_staticlib_override/libcli_staticlib_override.a"
if [ "$HOST_OS" = windows ]; then
    STATICLIB_OVERRIDE_ARCHIVE="$STATICLIB_OVERRIDE/target/typelisp/cli_staticlib_override/cli_staticlib_override.lib"
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
assert_contains staticlib-entry-override "$WORKDIR/staticlib-entry-override.out" "Generated:"
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

NEW_BIN_EXE="$NEW_BIN_DIR/target/typelisp/cli_new_bin/cli_new_bin"
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
assert_contains scaffold-new-bin-build "$WORKDIR/scaffold-new-bin-build.out" "Generated:"
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

NEW_LIB_ARCHIVE="$NEW_LIB_DIR/target/typelisp/cli_new_lib/libcli_new_lib.a"
if [ "$HOST_OS" = windows ]; then
    NEW_LIB_ARCHIVE="$NEW_LIB_DIR/target/typelisp/cli_new_lib/cli_new_lib.lib"
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
assert_contains scaffold-new-lib-build "$WORKDIR/scaffold-new-lib-build.out" "Generated:"
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
(define (main) : i64
  (begin
    (print-string (arg 1))
    17))
EOF

set +e
"$COMPILER" run "$RUN_SRC" -- "run-arg-ok" > "$WORKDIR/run.out" 2> "$WORKDIR/run.err"
status=$?
set -e
assert_status run "$status" 17
assert_empty run "$WORKDIR/run.err"
assert_contains run "$WORKDIR/run.out" "run-arg-ok"

cat > "$WORKDIR/repl.in" <<'EOF'
.help
.type true
(+ 1 2)
.exit
EOF

set +e
"$COMPILER" repl < "$WORKDIR/repl.in" > "$WORKDIR/repl.out" 2> "$WORKDIR/repl.err"
status=$?
set -e
assert_status repl "$status" 0
assert_empty repl "$WORKDIR/repl.err"
assert_contains repl "$WORKDIR/repl.out" "TypeLisp REPL commands:"
assert_contains repl "$WORKDIR/repl.out" ".type <expr>"
assert_contains repl "$WORKDIR/repl.out" "bool"
assert_contains repl "$WORKDIR/repl.out" "3"

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

cat > "$WORKDIR/queue.json" <<'EOF'
{"prs":[],"issues":[{"number":1645,"title":"Host actions direct","labels":[{"name":"ready-for-implementation"}]}]}
EOF

set +e
"$COMPILER" run tools/work-queue-chooser/chooser.tl --stdlib-root stdlib \
    < "$WORKDIR/queue.json" > "$WORKDIR/chooser.out" 2> "$WORKDIR/chooser.err"
status=$?
set -e
assert_status chooser "$status" 0
assert_empty chooser "$WORKDIR/chooser.err"
assert_contains chooser "$WORKDIR/chooser.out" "implement issue #1645: Host actions direct"

run_cli_command_surface_matrix

echo "selfhost cli build/run smoke passed"
