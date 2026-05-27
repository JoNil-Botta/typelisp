#!/usr/bin/env sh
set -eu

# verify-doc-site.sh - build and validate the selfhost docs site, no publish.
# refs #873
#
# Builds the static stdlib/API HTML site via selfhost/doc_site.tl, runs the
# in-memory smoke driver, and validates the on-disk output contract: required
# pages/assets exist, every local link resolves, every in-page/cross-page anchor
# target exists, and pages reference the stylesheet. Escaping and manifest-count
# behavior is asserted authoritatively by selfhost/doc_site_smoke.tl.
#
# This is independent of `cargo test`: it drives the published/staged selfhost
# compiler. CI runs it on pull requests and default-branch pushes WITHOUT
# deploying; #874 consumes it as the gate before the Pages publish step.
#
# Linux builds the native ELF site builder (GNU as/ld). Windows (Git Bash / MSYS
# / Cygwin) builds a native windows-x86_64 program. Set TYPELISP_BIN to a
# prebuilt/staged compiler, otherwise a local `cargo build --release` is used.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

EXE=
TARGET_ARGS=
case "$(uname -s)" in
    Linux*) ;;
    MINGW* | MSYS* | CYGWIN*)
        EXE=.exe
        TARGET_ARGS="--target windows-x86_64"
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

SITE="$ROOT/target/doc-site-verify"
rm -rf "$SITE"
mkdir -p "$SITE"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "[doc-site] building site via selfhost/doc_site.tl"
if ! "$COMPILER" run selfhost/doc_site.tl $TARGET_ARGS -- "$SITE" >"$SITE/.build.out" 2>"$SITE/.build.err"; then
    echo "site builder failed:" >&2
    sed 's/^/  /' "$SITE/.build.err" >&2 || true
    fail "selfhost/doc_site.tl did not build the site"
fi

echo "[doc-site] running selfhost/doc_site_smoke.tl"
set +e
"$COMPILER" run selfhost/doc_site_smoke.tl $TARGET_ARGS -- >"$SITE/.smoke.out" 2>"$SITE/.smoke.err"
smoke_code=$?
set -e
if [ "$smoke_code" -ne 42 ]; then
    sed 's/^/  /' "$SITE/.smoke.err" >&2 || true
    fail "doc_site_smoke.tl returned $smoke_code (expected 42)"
fi

# Required pages and assets.
for required in index.html stdlib.html typelisp-docs.css; do
    [ -f "$SITE/$required" ] || fail "missing required output: $required"
done

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

    page_base=$(basename "$page")
    case "$page_base" in
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

echo "doc-site verification passed: $stdlib_pages module page(s), $link_count local link(s) checked"
