#!/usr/bin/env sh

# Page and link contract of the generated docs site, checked in one awk pass.
#
# Source this file. doc_site_check_pages validates every page listed in
# PAGES_FILE (one path per line, in check order) against the site in SITE and
# prints the number of local links it checked. The first violation is printed
# as "FAIL: ..." on stderr and the function returns 1.
#
# Every page must carry the shared stylesheet, search and sidebar markers and
# mark its own sidebar entry as current. Every local href must name a file of
# the site, and an anchored href into an .html page must match an id="..."
# attribute there.
#
# GitHub's Windows runner pays about 17 ms per Git Bash process launch, and one
# grep per anchored link across the site's 11,000 links spent two minutes there
# (#8063). This pass launches three processes for the whole site. Its checks
# are literal and at least as strict as the grep probes it replaced: those read
# the markers, page names and anchors as basic regular expressions, while every
# string here must occur exactly. An anchor matches wherever the target holds
# id="ANCHOR", so ids inside other attributes (data-id="...") still count, as
# grep's substring match did.

doc_site_check_pages() {
    _dscp_site=$1
    _dscp_pages=$2
    _dscp_files=$(mktemp "${TMPDIR:-/tmp}/typelisp-doc-site-files.XXXXXX") ||
        return 1
    # Paths relative to the site, so a link resolves exactly when it names one
    # of its files. The site has no subdirectories or symlinks today, and a
    # "./" or ".." spelling fails rather than resolving through the filesystem.
    if ! (cd "$_dscp_site" && find . -type f) > "$_dscp_files"; then
        rm -f "$_dscp_files"
        echo "FAIL: cannot list docs-site files in $_dscp_site" >&2
        return 1
    fi
    _dscp_status=0
    LC_ALL=C awk -v site="$_dscp_site" -v pages_file="$_dscp_pages" \
        -v files_file="$_dscp_files" '
    function fail(message) {
        print "FAIL: " message > "/dev/stderr"
        failed = 1
        exit 1
    }
    function base(path, b) {
        b = path
        sub(/.*\//, "", b)
        return b
    }
    # Record every value that follows an id=" in the page, including ones that
    # overlap an earlier value, so lookup matches grep -q "id=\"ANCHOR\"".
    function index_ids(page, line, parts, n, k, q) {
        indexed[page] = 1
        while ((getline line < page) > 0) {
            n = split(line, parts, "id=\"")
            for (k = 2; k <= n; k++) {
                q = index(parts[k], "\"")
                if (q > 0)
                    ids[page SUBSEP substr(parts[k], 1, q - 1)] = 1
                else if (k < n)
                    ids[page SUBSEP parts[k] "id="] = 1
            }
        }
        close(page)
    }
    function require_marker(page, marker, message) {
        marker_count++
        marker_text[marker_count] = marker
        marker_message[marker_count] = base(page) " " message
    }
    BEGIN {
        while ((getline line < files_file) > 0) {
            sub(/^\.\//, "", line)
            exists[line] = 1
        }
        close(files_file)
        page_count = 0
        while ((getline line < pages_file) > 0) {
            if (line == "") continue
            page_count++
            pages[page_count] = line
        }
        close(pages_file)
        for (p = 1; p <= page_count; p++)
            index_ids(pages[p])

        link_count = 0
        for (p = 1; p <= page_count; p++) {
            page = pages[p]
            page_base = base(page)
            marker_count = 0
            require_marker(page, "href=\"typelisp-docs.css\"", "does not reference typelisp-docs.css")
            require_marker(page, "src=\"typelisp-docs-search-index.js\"", "does not reference the search index")
            require_marker(page, "src=\"typelisp-docs.js\"", "does not reference the search client")
            require_marker(page, "data-doc-search-input", "does not expose the search control")
            require_marker(page, "<nav class=\"tl-doc-stdlib-sidebar\" aria-label=\"Documentation tree\">", "does not include the documentation sidebar")
            require_marker(page, "href=\"stdlib.html\">stdlib</a>", "does not include the stdlib sidebar root")
            require_marker(page, "href=\"stdlib-io.html\"", "does not include representative stdlib module links")
            require_marker(page, "href=\"readme.html\"", "does not include the README language page link")
            require_marker(page, "href=\"spec.html\"", "does not include the SPEC language page link")
            if (page_base == "readme.html" || page_base == "spec.html")
                require_marker(page, "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"" page_base "\"", "does not mark its language sidebar link as current")
            else if (page_base == "stdlib.html")
                require_marker(page, "class=\"tl-doc-tree-root is-current\" aria-current=\"page\" href=\"stdlib.html\"", "does not mark the stdlib root as current")
            else if (page_base ~ /^stdlib-.*\.html$/)
                require_marker(page, "class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"" page_base "\"", "does not mark its sidebar module link as current")
            for (m = 1; m <= marker_count; m++)
                found[m] = 0

            # Collect the hrefs in document order, as grep -o would report
            # them: a value ends at the first quote, which may belong to the
            # next href=" on the line, and then that one is not a new link.
            href_count = 0
            while ((getline line < page) > 0) {
                for (m = 1; m <= marker_count; m++)
                    if (!found[m] && index(line, marker_text[m]) > 0)
                        found[m] = 1
                n = split(line, parts, "href=\"")
                for (k = 2; k <= n; k++) {
                    q = index(parts[k], "\"")
                    if (q > 0) {
                        value = substr(parts[k], 1, q - 1)
                    } else if (k < n) {
                        value = parts[k] "href="
                        k++
                    } else {
                        continue
                    }
                    # The former shell loop split hrefs into words.
                    words = split(value, word, /[ \t]+/)
                    for (w = 1; w <= words; w++)
                        if (word[w] != "")
                            hrefs[++href_count] = word[w]
                }
            }
            close(page)
            for (m = 1; m <= marker_count; m++)
                if (!found[m])
                    fail(marker_message[m])

            for (h = 1; h <= href_count; h++) {
                href = hrefs[h]
                if (index(href, "://") > 0 || href ~ /^mailto:/)
                    continue
                link_count++
                hash = index(href, "#")
                if (hash > 0) {
                    path = substr(href, 1, hash - 1)
                    anchor = substr(href, hash + 1)
                } else {
                    path = href
                    anchor = ""
                }
                if (path != "") {
                    if (!(path in exists))
                        fail(page_base ": dead local link '\''" href "'\'' (missing " path ")")
                    target = site "/" path
                } else {
                    target = page
                }
                if (anchor != "" && target ~ /\.html$/) {
                    if (!(target in indexed))
                        index_ids(target)
                    if (!((target SUBSEP anchor) in ids))
                        fail(page_base ": link '\''" href "'\'' has no matching id=\"" anchor "\" in " base(target))
                }
            }
        }
        print link_count
    }
    ' || _dscp_status=$?
    rm -f "$_dscp_files"
    return "$_dscp_status"
}

# Fixture self-test: the checks above must accept a conforming site and name
# each kind of violation. Runs in a few processes per case.
doc_site_page_check_self_test() {
    _dspt_root=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-doc-site-pages.XXXXXX") ||
        return 1
    _dspt_status=0
    doc_site_page_check_self_test_cases "$_dspt_root" || _dspt_status=$?
    rm -rf "$_dspt_root"
    return "$_dspt_status"
}

doc_site_page_check_fixture() {
    _dspf_site=$1
    rm -rf "$_dspf_site"
    mkdir -p "$_dspf_site"
    : > "$_dspf_site/typelisp-docs.css"
    for _dspf_page in readme.html spec.html stdlib.html stdlib-io.html; do
        case "$_dspf_page" in
            stdlib.html) _dspf_current='class="tl-doc-tree-root is-current" aria-current="page" href="stdlib.html"' ;;
            *) _dspf_current="class=\"tl-doc-tree-link is-current\" aria-current=\"page\" href=\"$_dspf_page\"" ;;
        esac
        printf '%s\n' \
            '<link href="typelisp-docs.css"><script src="typelisp-docs-search-index.js"></script><script src="typelisp-docs.js"></script>' \
            '<input data-doc-search-input>' \
            '<nav class="tl-doc-stdlib-sidebar" aria-label="Documentation tree"><a href="stdlib.html">stdlib</a><a href="stdlib-io.html">io</a>' \
            "<a href=\"readme.html\">README</a><a href=\"spec.html\">SPEC</a><a $_dspf_current>here</a></nav>" \
            '<h1 id="top">x</h1><a href="#top">self</a><a href="https://example.com/#x">ext</a><a href="mailto:a@b">mail</a>' \
            > "$_dspf_site/$_dspf_page"
    done
    printf '%s\n' '<a href="spec.html#top">spec</a> <a href="stdlib-io.html#tl-io" data-id="tl-io">io</a>' \
        >> "$_dspf_site/readme.html"
    printf '%s\n' '<p data-id="tl-io">substring id counts, as grep matched it</p>' \
        >> "$_dspf_site/stdlib-io.html"
    (cd "$_dspf_site" && find . -maxdepth 1 -type f -name '*.html') |
        sed "s|^\\./|$_dspf_site/|" | LC_ALL=C sort > "$_dspf_site.pages"
}

doc_site_page_check_expect_failure() {
    _dspe_name=$1
    _dspe_site=$2
    _dspe_message=$3
    if doc_site_check_pages "$_dspe_site" "$_dspe_site.pages" \
        > "$_dspe_site.out" 2> "$_dspe_site.err"; then
        echo "docs-site page check self-test $_dspe_name: accepted an invalid site" >&2
        return 1
    fi
    if ! grep -F -- "$_dspe_message" "$_dspe_site.err" >/dev/null; then
        echo "docs-site page check self-test $_dspe_name: expected '$_dspe_message', got:" >&2
        sed 's/^/  /' "$_dspe_site.err" >&2
        return 1
    fi
}

doc_site_page_check_self_test_cases() {
    _dspc_site="$1/site"
    doc_site_page_check_fixture "$_dspc_site"
    _dspc_count=$(doc_site_check_pages "$_dspc_site" "$_dspc_site.pages") || {
        echo "docs-site page check self-test rejected the conforming fixture" >&2
        return 1
    }
    # Four pages with seven local links each (the external and mailto links
    # are not counted), plus the readme's two cross-page anchors.
    [ "$_dspc_count" = 30 ] || {
        echo "docs-site page check self-test counted $_dspc_count local links, expected 30" >&2
        return 1
    }

    doc_site_page_check_fixture "$_dspc_site"
    printf '%s\n' '<a href="missing.html">gone</a>' >> "$_dspc_site/spec.html"
    doc_site_page_check_expect_failure dead-link "$_dspc_site" \
        "spec.html: dead local link 'missing.html' (missing missing.html)" || return 1

    doc_site_page_check_fixture "$_dspc_site"
    printf '%s\n' '<a href="spec.html#nowhere">gone</a>' >> "$_dspc_site/stdlib.html"
    doc_site_page_check_expect_failure missing-anchor "$_dspc_site" \
        "stdlib.html: link 'spec.html#nowhere' has no matching id=\"nowhere\" in spec.html" || return 1

    # Anchors resolve in the link's target: tl-io exists only in other pages.
    doc_site_page_check_fixture "$_dspc_site"
    printf '%s\n' '<a href="spec.html#tl-io">wrong page</a>' >> "$_dspc_site/stdlib.html"
    doc_site_page_check_expect_failure anchor-in-other-page "$_dspc_site" \
        "stdlib.html: link 'spec.html#tl-io' has no matching id=\"tl-io\" in spec.html" || return 1

    doc_site_page_check_fixture "$_dspc_site"
    printf '%s\n' '<a href="#elsewhere">gone</a>' >> "$_dspc_site/stdlib-io.html"
    doc_site_page_check_expect_failure missing-self-anchor "$_dspc_site" \
        "stdlib-io.html: link '#elsewhere' has no matching id=\"elsewhere\" in stdlib-io.html" || return 1

    doc_site_page_check_fixture "$_dspc_site"
    sed 's|<a href="readme.html">README</a>||' "$_dspc_site/stdlib.html" > "$_dspc_site/edit" &&
        mv "$_dspc_site/edit" "$_dspc_site/stdlib.html"
    doc_site_page_check_expect_failure missing-marker "$_dspc_site" \
        "stdlib.html does not include the README language page link" || return 1

    doc_site_page_check_fixture "$_dspc_site"
    sed 's|is-current" aria-current="page" href="stdlib-io.html"|is-current" href="stdlib-io.html"|' \
        "$_dspc_site/stdlib-io.html" > "$_dspc_site/edit" &&
        mv "$_dspc_site/edit" "$_dspc_site/stdlib-io.html"
    doc_site_page_check_expect_failure missing-current "$_dspc_site" \
        "stdlib-io.html does not mark its sidebar module link as current" || return 1

    # The markers and names are literal: a regex-only match must not pass.
    doc_site_page_check_fixture "$_dspc_site"
    sed 's|href="typelisp-docs.css"|href="typelisp-docsXcss"|' "$_dspc_site/spec.html" > "$_dspc_site/edit" &&
        mv "$_dspc_site/edit" "$_dspc_site/spec.html"
    : > "$_dspc_site/typelisp-docsXcss"
    doc_site_page_check_expect_failure literal-marker "$_dspc_site" \
        "spec.html does not reference typelisp-docs.css" || return 1

    # A link path must name a file: a directory with that name is dead.
    doc_site_page_check_fixture "$_dspc_site"
    mkdir "$_dspc_site/guide.html"
    printf '%s\n' '<a href="guide.html">dir</a>' >> "$_dspc_site/readme.html"
    doc_site_page_check_expect_failure directory-link "$_dspc_site" \
        "readme.html: dead local link 'guide.html' (missing guide.html)" || return 1
}
