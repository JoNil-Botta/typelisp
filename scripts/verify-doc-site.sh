#!/usr/bin/env sh
set -eu

# verify-doc-site.sh - build and validate the selfhost docs site, no publish.
# refs #873
#
# Builds the static stdlib/API and language-reference HTML site via
# selfhost/doc_site.tl, runs the
# in-memory smoke driver, and validates the on-disk output contract: required
# pages/assets exist, every local link resolves, every in-page/cross-page anchor
# target exists, and pages reference the stylesheet. Escaping and manifest-count
# behavior is asserted authoritatively by selfhost/doc_site_smoke.tl.
#
# This is independent of `cargo test`: it drives the published/staged selfhost
# compiler. CI runs it on pull requests and default-branch pushes WITHOUT
# deploying; #874 consumes it as the gate before the Pages publish step. Set
# DOC_SITE_OUT to choose the generated-site directory and DOC_SITE_WORK to
# choose the scratch directory for native builders, logs, and objects.
#
# Linux builds the native ELF site builder (GNU as/ld). Windows (Git Bash / MSYS
# / Cygwin) builds a host-default native program. Set TYPELISP_BIN to a
# prebuilt/staged compiler, otherwise a local `cargo build --release` is used.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

EXE=
HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        EXE=.exe
        ;;
    *)
        echo "docs-site verification is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp$EXE"
fi
[ -x "$COMPILER" ] || {
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

SITE=${DOC_SITE_OUT:-"$ROOT/target/doc-site-verify"}
WORK=${DOC_SITE_WORK:-"$ROOT/target/doc-site-verify-work"}

case "$SITE" in
    "" | / | . | ./)
        fail "unsafe docs-site output directory: $SITE"
        ;;
esac
case "$WORK" in
    "" | / | . | ./)
        fail "unsafe docs-site work directory: $WORK"
        ;;
esac
[ "$SITE" != "$ROOT" ] || fail "docs-site output directory must not be the repo root"
[ "$WORK" != "$ROOT" ] || fail "docs-site work directory must not be the repo root"

rm -rf "$SITE" "$WORK"
mkdir -p "$SITE" "$WORK"

compile_linux_binary() {
    _label=$1
    _source=$2
    _bin=$3
    _asm="$_bin.s"
    _obj="$_bin.o"
    _out="$WORK/.$_label.compile.out"
    _err="$WORK/.$_label.compile.err"

    if ! "$COMPILER" compile "$_source" --stdlib-root "$ROOT/stdlib" -o "$_asm" >"$_out" 2>"$_err"; then
        echo "$_label compile failed:" >&2
        sed 's/^/  /' "$_err" >&2 || true
        fail "$_source did not compile"
    fi
    if ! as "$_asm" -o "$_obj" >>"$_out" 2>>"$_err"; then
        echo "$_label assemble failed:" >&2
        sed 's/^/  /' "$_err" >&2 || true
        fail "$_source did not assemble"
    fi
    if ! ld "$_obj" -o "$_bin" -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lc \
        >>"$_out" 2>>"$_err"; then
        echo "$_label link failed:" >&2
        sed 's/^/  /' "$_err" >&2 || true
        fail "$_source did not link"
    fi
}

echo "[doc-site] building site via selfhost/doc_site.tl"
if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || fail "missing assembler: as"
    command -v ld >/dev/null 2>&1 || fail "missing linker: ld"
    SITE_BUILDER="$WORK/.doc_site"
    compile_linux_binary doc-site selfhost/doc_site.tl "$SITE_BUILDER"
    if ! "$SITE_BUILDER" "$SITE" >"$WORK/.build.out" 2>"$WORK/.build.err"; then
        echo "site builder failed:" >&2
        sed 's/^/  /' "$WORK/.build.err" >&2 || true
        fail "selfhost/doc_site.tl did not build the site"
    fi
else
    if ! "$COMPILER" run selfhost/doc_site.tl -- "$SITE" >"$WORK/.build.out" 2>"$WORK/.build.err"; then
        echo "site builder failed:" >&2
        sed 's/^/  /' "$WORK/.build.err" >&2 || true
        fail "selfhost/doc_site.tl did not build the site"
    fi
fi

echo "[doc-site] running selfhost/doc_site_smoke.tl"
set +e
if [ "$HOST_OS" = linux ]; then
    SITE_SMOKE="$WORK/.doc_site_smoke"
    compile_linux_binary doc-site-smoke selfhost/doc_site_smoke.tl "$SITE_SMOKE"
    "$SITE_SMOKE" >"$WORK/.smoke.out" 2>"$WORK/.smoke.err"
else
    "$COMPILER" run selfhost/doc_site_smoke.tl -- >"$WORK/.smoke.out" 2>"$WORK/.smoke.err"
fi
smoke_code=$?
set -e
if [ "$smoke_code" -ne 42 ]; then
    sed 's/^/  /' "$WORK/.smoke.err" >&2 || true
    fail "doc_site_smoke.tl returned $smoke_code (expected 42)"
fi

# Required pages and assets.
for required in index.html readme.html spec.html stdlib.html typelisp-docs.css; do
    [ -f "$SITE/$required" ] || fail "missing required output: $required"
done

hidden_payload=$(find "$SITE" -mindepth 1 -maxdepth 1 -name '.*' | head -n 1)
[ -z "$hidden_payload" ] || fail "docs-site output contains scratch artifact: $(basename "$hidden_payload")"

stdlib_pages=$(find "$SITE" -maxdepth 1 -type f -name 'stdlib-*.html' | wc -l)
[ "$stdlib_pages" -ge 1 ] || fail "no stdlib-*.html module pages were generated"

# Validate every local link and anchor across all generated pages.
pages=$(find "$SITE" -maxdepth 1 -type f -name '*.html')
link_count=0
for page in $pages; do
    # Each HTML page should reference the stylesheet.
    grep -q 'href="typelisp-docs.css"' "$page" \
        || fail "$(basename "$page") does not reference typelisp-docs.css"

    # Each page should expose the persistent stdlib module tree sidebar.
    grep -q '<nav class="tl-doc-stdlib-sidebar" aria-label="Stdlib module tree">' "$page" \
        || fail "$(basename "$page") does not include the stdlib module sidebar"
    grep -q 'href="stdlib.html">stdlib</a>' "$page" \
        || fail "$(basename "$page") does not include the stdlib sidebar root"
    grep -q 'href="stdlib-io.html"' "$page" \
        || fail "$(basename "$page") does not include representative stdlib module links"
    grep -q 'href="readme.html"' "$page" \
        || fail "$(basename "$page") does not include the README language page link"
    grep -q 'href="spec.html"' "$page" \
        || fail "$(basename "$page") does not include the SPEC language page link"

    page_base=$(basename "$page")
    case "$page_base" in
        readme.html | spec.html)
            grep -q "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"$page_base\"" "$page" \
                || fail "$page_base does not mark its language sidebar link as current"
            ;;
        stdlib.html)
            grep -q 'class="tl-doc-tree-root is-current" aria-current="page" href="stdlib.html"' "$page" \
                || fail "$page_base does not mark the stdlib root as current"
            ;;
        stdlib-*.html)
            grep -q "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"$page_base\"" "$page" \
                || fail "$page_base does not mark its sidebar module link as current"
            ;;
    esac

    # Extract href targets (strip the href="...") wrapper).
    hrefs=$(grep -oE 'href="[^"]*"' "$page" | sed 's/^href="//; s/"$//')
    for href in $hrefs; do
        case "$href" in
            *://* | mailto:*) continue ;;
        esac
        link_count=$((link_count + 1))
        path=${href%%#*}
        anchor=${href#*#}
        if [ "$href" = "$path" ]; then
            anchor=
        fi

        if [ -n "$path" ]; then
            target="$SITE/$path"
            [ -f "$target" ] || fail "$(basename "$page"): dead local link '$href' (missing $path)"
        else
            target="$page"
        fi

        case "$target" in
            *.html)
                if [ -n "$anchor" ]; then
                    grep -q "id=\"$anchor\"" "$target" \
                        || fail "$(basename "$page"): link '$href' has no matching id=\"$anchor\" in $(basename "$target")"
                fi
                ;;
        esac
    done
done

grep -q 'id="tl-TypeLisp"' "$SITE/readme.html" \
    || fail "readme.html is missing the TypeLisp heading anchor"
grep -q 'id="tl-TypeLisp-32Language-32Specification"' "$SITE/spec.html" \
    || fail "spec.html is missing the language specification heading anchor"
grep -q 'href="spec.html"' "$SITE/readme.html" \
    || fail "readme.html did not rewrite SPEC.md links to spec.html"
grep -q 'href="https://github.com/JoNil-Botta/typelisp/blob/main/CONTRIBUTING.md"' "$SITE/readme.html" \
    || fail "readme.html did not rewrite repository source links to GitHub"

echo "doc-site verification passed: $stdlib_pages module page(s), $link_count local link(s) checked"
