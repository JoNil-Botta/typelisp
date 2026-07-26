#!/usr/bin/env sh
set -eu

# verify-doc-site.sh - build and validate the selfhost docs site, no publish.
# refs #873
#
# Builds the static stdlib/API and language-reference HTML site via
# tools/doc-site/doc_site.tl, runs the
# in-memory smoke driver, and validates the on-disk output contract: required
# pages/assets exist, every top-level stdlib module has exactly one page, every
# local link resolves, every in-page/cross-page anchor target exists, and pages
# reference the stylesheet. Escaping and manifest duplicate/emptiness behavior is
# asserted authoritatively by tools/doc-site/doc_site_smoke.tl.
#
# It drives the published/staged selfhost
# compiler. CI runs it on pull requests and default-branch pushes WITHOUT
# deploying; #874 consumes it as the gate before the Pages publish step. Set
# DOC_SITE_OUT to choose the generated-site directory and DOC_SITE_WORK to
# choose the scratch directory for native builders, logs, and objects.
#
# Linux builds the native ELF site builder (GNU as/ld). Windows (Git Bash / MSYS
# / Cygwin) builds a host-default native program. Set TYPELISP_BIN to a
# prebuilt/staged compiler, otherwise the published stage0 is fetched.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-entry.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

parse_doc_site_max_rss_kb() {
    _time_log=$1
    awk -F: '
        /Maximum resident set size/ {
            value = $2
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            print value
        }
    ' "$_time_log" | tail -n 1
}

check_doc_site_max_rss_kb() {
    _rss_kb=$1
    _limit_kb=$2
    case "$_rss_kb" in
        "" | *[!0-9]*)
            echo "invalid docs-site max RSS measurement: $_rss_kb" >&2
            return 2
            ;;
    esac
    case "$_limit_kb" in
        "" | *[!0-9]* | 0)
            echo "invalid docs-site max RSS limit: $_limit_kb" >&2
            return 2
            ;;
    esac
    if [ "$_rss_kb" -gt "$_limit_kb" ]; then
        echo "docs-site native builder peak RSS $_rss_kb KiB exceeds limit $_limit_kb KiB" >&2
        return 1
    fi
}

doc_site_rss_guard_self_test() {
    _fixture=${TMPDIR:-/tmp}/typelisp-doc-site-rss-guard.$$
    printf '%s\n' \
        'Maximum resident set size (kbytes): 3999999' \
        >"$_fixture"
    _parsed=$(parse_doc_site_max_rss_kb "$_fixture")
    rm -f "$_fixture"
    [ "$_parsed" = 3999999 ] \
        || fail "docs-site RSS guard self-test parsed '$_parsed' instead of 3999999"
    check_doc_site_max_rss_kb "$_parsed" 4000000 \
        || fail "docs-site RSS guard self-test rejected a below-limit measurement"
    if check_doc_site_max_rss_kb 4000001 4000000 >/dev/null 2>&1; then
        fail "docs-site RSS guard self-test accepted an above-limit measurement"
    fi
}

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

case "${1:-}" in
    "")
        ;;
    --self-test-rss-guard)
        doc_site_rss_guard_self_test
        echo "docs-site RSS guard self-tests passed"
        exit 0
        ;;
    *)
        fail "unknown docs-site verification option: $1"
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Local-development fallback: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
[ -x "$COMPILER" ] || {
    echo "typelisp compiler is not executable: $COMPILER" >&2
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

if [ "$HOST_OS" = linux ]; then
    # Exercise both threshold outcomes on every Linux docs-site gate. This is
    # intentionally allocation-free so the failure path stays cheap to test.
    doc_site_rss_guard_self_test
fi

compile_linux_binary() {
    _label=$1
    _source=$2
    _bin=$3
    _asm="$_bin.s"
    _obj="$_bin.o"
    _out="$WORK/.$_label.compile.out"
    _err="$WORK/.$_label.compile.err"

    if ! "$COMPILER" compile "$_source" --stdlib-root stdlib --stdlib-root src -o "$_asm" >"$_out" 2>"$_err"; then
        echo "$_label compile failed:" >&2
        sed 's/^/  /' "$_err" >&2 || true
        fail "$_source did not compile"
    fi
    if ! as "$_asm" -o "$_obj" >>"$_out" 2>>"$_err"; then
        echo "$_label assemble failed:" >&2
        sed 's/^/  /' "$_err" >&2 || true
        fail "$_source did not assemble"
    fi
    if ! ld "$_obj" -o "$_bin" -static -e "$(linux_entry_symbol_for_asm "$_asm")" \
        >>"$_out" 2>>"$_err"; then
        echo "$_label link failed:" >&2
        sed 's/^/  /' "$_err" >&2 || true
        fail "$_source did not link"
    fi
}

echo "[doc-site] building site via tools/doc-site/doc_site.tl"
if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || fail "missing assembler: as"
    command -v ld >/dev/null 2>&1 || fail "missing linker: ld"
    SITE_BUILDER="$WORK/.doc_site"
    compile_linux_binary doc-site tools/doc-site/doc_site.tl "$SITE_BUILDER"
    DOC_SITE_TIME_BIN=${DOC_SITE_TIME_BIN:-/usr/bin/time}
    DOC_SITE_MAX_RSS_KB=${DOC_SITE_MAX_RSS_KB:-4000000}
    [ -x "$DOC_SITE_TIME_BIN" ] \
        || fail "GNU time is required for the docs-site RSS guard: $DOC_SITE_TIME_BIN"
    if ! "$DOC_SITE_TIME_BIN" -v -o /dev/null true >/dev/null 2>&1; then
        fail "GNU time with -v support is required for the docs-site RSS guard: $DOC_SITE_TIME_BIN"
    fi
    case "$DOC_SITE_MAX_RSS_KB" in
        "" | *[!0-9]* | 0)
            fail "DOC_SITE_MAX_RSS_KB must be a positive integer"
            ;;
    esac
    SITE_BUILDER_TIME="$WORK/.build.time"
    if ! LC_ALL=C "$DOC_SITE_TIME_BIN" -v -o "$SITE_BUILDER_TIME" \
        "$SITE_BUILDER" "$SITE" >"$WORK/.build.out" 2>"$WORK/.build.err"; then
        echo "site builder failed:" >&2
        sed 's/^/  /' "$WORK/.build.err" >&2 || true
        fail "tools/doc-site/doc_site.tl did not build the site"
    fi
    site_builder_max_rss_kb=$(parse_doc_site_max_rss_kb "$SITE_BUILDER_TIME")
    [ -n "$site_builder_max_rss_kb" ] \
        || fail "could not parse docs-site max RSS from $SITE_BUILDER_TIME"
    echo "[doc-site] native site builder peak RSS: $site_builder_max_rss_kb KiB (limit: $DOC_SITE_MAX_RSS_KB KiB)"
    check_doc_site_max_rss_kb "$site_builder_max_rss_kb" "$DOC_SITE_MAX_RSS_KB" \
        || fail "docs-site native builder exceeded its resident-memory budget"
else
    if ! "$COMPILER" run tools/doc-site/doc_site.tl --stdlib-root stdlib --stdlib-root src -- "$SITE" >"$WORK/.build.out" 2>"$WORK/.build.err"; then
        echo "site builder failed:" >&2
        sed 's/^/  /' "$WORK/.build.err" >&2 || true
        fail "tools/doc-site/doc_site.tl did not build the site"
    fi
fi

echo "[doc-site] expanding generated-module API sections"
if [ "$HOST_OS" = linux ]; then
    SITE_EXPAND="$WORK/.doc_site_expand"
    compile_linux_binary doc-site-expand tools/doc-site/doc_site_expand_pages.tl "$SITE_EXPAND"
    if ! "$SITE_EXPAND" "$SITE" >"$WORK/.expand.out" 2>"$WORK/.expand.err"; then
        echo "site generated-module expansion failed:" >&2
        sed 's/^/  /' "$WORK/.expand.err" >&2 || true
        fail "tools/doc-site/doc_site_expand_pages.tl did not update the site"
    fi
else
    if ! "$COMPILER" run tools/doc-site/doc_site_expand_pages.tl --stdlib-root stdlib --stdlib-root src -- "$SITE" >"$WORK/.expand.out" 2>"$WORK/.expand.err"; then
        echo "site generated-module expansion failed:" >&2
        sed 's/^/  /' "$WORK/.expand.err" >&2 || true
        fail "tools/doc-site/doc_site_expand_pages.tl did not update the site"
    fi
fi

echo "[doc-site] running tools/doc-site/doc_site_smoke.tl"
set +e
if [ "$HOST_OS" = linux ]; then
    SITE_SMOKE="$WORK/.doc_site_smoke"
    compile_linux_binary doc-site-smoke tools/doc-site/doc_site_smoke.tl "$SITE_SMOKE"
    "$SITE_SMOKE" >"$WORK/.smoke.out" 2>"$WORK/.smoke.err"
else
    "$COMPILER" run tools/doc-site/doc_site_smoke.tl --stdlib-root stdlib --stdlib-root src -- >"$WORK/.smoke.out" 2>"$WORK/.smoke.err"
fi
smoke_code=$?
set -e
if [ "$smoke_code" -ne 42 ]; then
    sed 's/^/  /' "$WORK/.smoke.err" >&2 || true
    fail "doc_site_smoke.tl returned $smoke_code (expected 42)"
fi

echo "[doc-site] running tools/doc-site/doc_site_expand_smoke.tl"
set +e
if [ "$HOST_OS" = linux ]; then
    SITE_EXPAND_SMOKE="$WORK/.doc_site_expand_smoke"
    compile_linux_binary doc-site-expand-smoke tools/doc-site/doc_site_expand_smoke.tl "$SITE_EXPAND_SMOKE"
    "$SITE_EXPAND_SMOKE" >"$WORK/.expand_smoke.out" 2>"$WORK/.expand_smoke.err"
else
    "$COMPILER" run tools/doc-site/doc_site_expand_smoke.tl --stdlib-root stdlib --stdlib-root src -- >"$WORK/.expand_smoke.out" 2>"$WORK/.expand_smoke.err"
fi
expand_smoke_code=$?
set -e
if [ "$expand_smoke_code" -ne 42 ]; then
    sed 's/^/  /' "$WORK/.expand_smoke.err" >&2 || true
    fail "doc_site_expand_smoke.tl returned $expand_smoke_code (expected 42)"
fi

echo "[doc-site] running tools/doc-site/doc_md_smoke.tl"
set +e
if [ "$HOST_OS" = linux ]; then
    MD_SMOKE="$WORK/.doc_md_smoke"
    compile_linux_binary doc-md-smoke tools/doc-site/doc_md_smoke.tl "$MD_SMOKE"
    "$MD_SMOKE" >"$WORK/.md_smoke.out" 2>"$WORK/.md_smoke.err"
else
    "$COMPILER" run tools/doc-site/doc_md_smoke.tl --stdlib-root stdlib --stdlib-root src -- >"$WORK/.md_smoke.out" 2>"$WORK/.md_smoke.err"
fi
md_smoke_code=$?
set -e
if [ "$md_smoke_code" -ne 42 ]; then
    sed 's/^/  /' "$WORK/.md_smoke.err" >&2 || true
    fail "doc_md_smoke.tl returned $md_smoke_code (expected 42)"
fi

# Required pages and assets.
for required in index.html readme.html spec.html stdlib.html typelisp-docs.css; do
    [ -f "$SITE/$required" ] || fail "missing required output: $required"
done

grep -q 'stdlib.vector.generated.i64' "$SITE/stdlib-vector.html" \
    || fail "stdlib-vector.html is missing generated vector module docs"
grep -q 'generated-module-import' "$SITE/stdlib-vector.html" \
    || fail "stdlib-vector.html is missing generated module import docs"
grep -q 'href="#tl-push"' "$SITE/stdlib-vector.html" \
    || fail "stdlib-vector.html is missing generated push API docs"

hidden_payload=$(find "$SITE" -mindepth 1 -maxdepth 1 -name '.*' | head -n 1)
[ -z "$hidden_payload" ] || fail "docs-site output contains scratch artifact: $(basename "$hidden_payload")"

stdlib_pages=$(find "$SITE" -maxdepth 1 -type f -name 'stdlib-*.html' | wc -l)
[ "$stdlib_pages" -ge 1 ] || fail "no stdlib-*.html module pages were generated"

# Completeness (#5689): every top-level stdlib module has a published page and
# no published page is stale. The site derives this set from stdlib/ through
# tools/doc-site/doc_site_stdlib_manifest.tl; this independent shell derivation
# catches a broken walk in either direction. Module names separate words with
# `_`; page names use `-`.
EXPECTED_STDLIB_PAGES="$WORK/.stdlib-pages.expected"
ACTUAL_STDLIB_PAGES="$WORK/.stdlib-pages.actual"
find stdlib -maxdepth 1 -type f -name '*.tl' \
    | sed 's|^stdlib/||; s|\.tl$||' \
    | tr '_' '-' \
    | sed 's|^|stdlib-|; s|$|.html|' \
    | LC_ALL=C sort > "$EXPECTED_STDLIB_PAGES"
[ -s "$EXPECTED_STDLIB_PAGES" ] || fail "found no stdlib/*.tl modules to publish"
find "$SITE" -maxdepth 1 -type f -name 'stdlib-*.html' \
    | sed "s|^$SITE/||" \
    | LC_ALL=C sort > "$ACTUAL_STDLIB_PAGES"
if ! cmp -s "$EXPECTED_STDLIB_PAGES" "$ACTUAL_STDLIB_PAGES"; then
    echo "docs-site stdlib pages do not match stdlib/ (-expected +published):" >&2
    diff -u "$EXPECTED_STDLIB_PAGES" "$ACTUAL_STDLIB_PAGES" >&2 || true
    fail "derived docs-site stdlib pages must match every stdlib module"
fi
expected_stdlib_modules=$(wc -l < "$EXPECTED_STDLIB_PAGES" | tr -d ' ')
echo "[doc-site] published all $expected_stdlib_modules top-level stdlib module(s)"

# Validate every local link and anchor across all generated pages.
pages=$(find "$SITE" -maxdepth 1 -type f -name '*.html')
link_count=0
for page in $pages; do
    # Each HTML page should reference the stylesheet.
    grep -q 'href="typelisp-docs.css"' "$page" \
        || fail "$(basename "$page") does not reference typelisp-docs.css"

    # Each page should expose the persistent composed documentation sidebar.
    grep -q '<nav class="tl-doc-stdlib-sidebar" aria-label="Documentation tree">' "$page" \
        || fail "$(basename "$page") does not include the documentation sidebar"
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
