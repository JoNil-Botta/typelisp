#!/usr/bin/env sh

# Exact, single-pass manifests for the generated documentation search index.
# This file is sourced by verify-doc-site.sh.

doc_site_search_parse_index() {
    _doc_search_index=$1
    _doc_search_identities=$2
    _doc_search_hrefs=$3
    _doc_search_metadata=$4

    LC_ALL=C awk \
        -v identity_file="$_doc_search_identities" \
        -v href_file="$_doc_search_hrefs" \
        -v metadata_file="$_doc_search_metadata" '
        function invalid(message) {
            print "malformed documentation search index: " message > "/dev/stderr"
            failed = 1
            exit 1
        }

        function expect(literal) {
            if (substr(input, position, length(literal)) != literal) {
                invalid("expected " literal " at byte " position)
            }
            position += length(literal)
        }

        function parse_string(capture,    value, character, escape, hex) {
            if (substr(input, position, 1) != "\"") {
                invalid("expected JSON string at byte " position)
            }
            position++
            value = ""
            while (position <= length(input)) {
                character = substr(input, position, 1)
                if (character == "\"") {
                    position++
                    parsed = value
                    return
                }
                if (character == "\\") {
                    if (capture) value = value character
                    position++
                    if (position > length(input)) {
                        invalid("unterminated JSON escape")
                    }
                    escape = substr(input, position, 1)
                    if (index("\"\\/bfnrtu", escape) == 0) {
                        invalid("invalid JSON escape at byte " position)
                    }
                    if (capture) value = value escape
                    position++
                    if (escape == "u") {
                        hex = substr(input, position, 4)
                        if (length(hex) != 4 || hex !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) {
                            invalid("invalid JSON unicode escape at byte " position)
                        }
                        if (capture) value = value hex
                        position += 4
                    }
                    continue
                }
                if (character ~ /[[:cntrl:]]/) {
                    invalid("unescaped control character in JSON string")
                }
                if (capture) value = value character
                position++
            }
            invalid("unterminated JSON string")
        }

        function require_manifest_value(value, label) {
            if (value == "" || index(value, "\\") || index(value, "\t") || index(value, "\r")) {
                invalid(label " is empty or not manifest-normalized")
            }
        }

        BEGIN {
            printf "%s", "" > identity_file
            printf "%s", "" > href_file
            printf "%s", "" > metadata_file
            close(identity_file)
            close(href_file)
            close(metadata_file)
        }

        NR == 1 {
            if ($0 == "") invalid("index is empty")
            input = $0
            position = 1
            expect("globalThis.TYPELISP_DOC_SEARCH=Object.freeze({\"schema\":1,\"compilerIdentity\":")
            parse_string(1)
            compiler_identity = parsed
            require_manifest_value(compiler_identity, "compiler identity")
            expect(",\"sourceIdentity\":")
            parse_string(1)
            source_identity = parsed
            require_manifest_value(source_identity, "source identity")
            expect(",\"packageIdentity\":")
            parse_string(1)
            package_identity = parsed
            require_manifest_value(package_identity, "package identity")
            expect(",\"records\":Object.freeze([")

            record_count = 0
            if (substr(input, position, 1) != "]") {
                while (1) {
                    expect("{\"identity\":")
                    parse_string(1)
                    record_identity = parsed
                    require_manifest_value(record_identity, "record identity")
                    if (record_identity !~ /^[A-Za-z0-9._#-]+$/) {
                        invalid("record identity is not normalized: " record_identity)
                    }

                    expect(",\"kind\":")
                    parse_string(0)
                    expect(",\"label\":")
                    parse_string(0)
                    expect(",\"module\":")
                    parse_string(0)
                    expect(",\"href\":")
                    parse_string(1)
                    record_href = parsed
                    require_manifest_value(record_href, "record href")
                    if (record_href !~ /^[A-Za-z0-9][A-Za-z0-9._-]*[.]html(#tl-[A-Za-z0-9._-]+)?$/) {
                        invalid("record href is not a normalized local documentation target: " record_href)
                    }

                    expect(",\"signature\":")
                    parse_string(0)
                    expect(",\"docs\":")
                    parse_string(0)
                    expect(",\"sourceLine\":")
                    number_start = position
                    while (substr(input, position, 1) ~ /^[0-9]$/) position++
                    if (position == number_start) invalid("sourceLine is not a non-negative integer")
                    expect("}")

                    print record_identity > identity_file
                    print record_href > href_file
                    record_count++
                    separator = substr(input, position, 1)
                    if (separator == ",") {
                        position++
                        continue
                    }
                    if (separator == "]") break
                    invalid("expected record separator at byte " position)
                }
            }
            expect("])});")
            if (position != length(input) + 1) {
                invalid("trailing content at byte " position)
            }
            if (record_count == 0) invalid("index has no search records")
            printf "%s\t%s\t%s\n", compiler_identity, source_identity, package_identity > metadata_file
            close(identity_file)
            close(href_file)
            close(metadata_file)
            parsed_index = 1
            next
        }

        { invalid("index must contain exactly one physical line") }

        END {
            if (!failed && !parsed_index) invalid("index is empty")
        }
    ' "$_doc_search_index"
}

doc_site_search_extract_pages() {
    _doc_search_page_list=$1
    _doc_search_expected_compiler=$2
    _doc_search_expected_source=$3
    _doc_search_expected_package=$4
    _doc_search_page_hrefs=$5
    _doc_search_page_metadata=$6

    LC_ALL=C awk \
        -v expected_compiler="$_doc_search_expected_compiler" \
        -v expected_source="$_doc_search_expected_source" \
        -v expected_package="$_doc_search_expected_package" \
        -v href_file="$_doc_search_page_hrefs" \
        -v metadata_file="$_doc_search_page_metadata" '
        function invalid(message) {
            print message > "/dev/stderr"
            failed = 1
            exit 1
        }

        function meta_value(line, marker,    start, tail, finish) {
            start = index(line, marker)
            if (!start) return ""
            tail = substr(line, start + length(marker))
            finish = index(tail, "\"")
            if (!finish) invalid(page " has malformed documentation identity metadata")
            return substr(tail, 1, finish - 1)
        }

        BEGIN {
            printf "%s", "" > href_file
            printf "%s", "" > metadata_file
            close(href_file)
            close(metadata_file)
        }

        {
            path = $0
            if (path == "") invalid("documentation page manifest contains an empty path")
            page = path
            sub(/^.*\//, "", page)
            compiler_identity = ""
            source_identity = ""
            package_identity = ""
            read_status = 0

            while ((read_status = (getline html < path)) > 0) {
                if (compiler_identity == "") {
                    compiler_identity = meta_value(html, "name=\"typelisp-compiler-identity\" content=\"")
                }
                if (source_identity == "") {
                    source_identity = meta_value(html, "name=\"typelisp-source-identity\" content=\"")
                }
                if (package_identity == "") {
                    package_identity = meta_value(html, "name=\"typelisp-package-identity\" content=\"")
                }

                remaining = html
                while (match(remaining, /id="[^"]*"/)) {
                    anchor_id = substr(remaining, RSTART + 4, RLENGTH - 5)
                    anchor_key = page SUBSEP anchor_id
                    if (anchor_key in seen_anchor) {
                        invalid(page " contains duplicate anchor id=\"" anchor_id "\"")
                    }
                    seen_anchor[anchor_key] = 1
                    if (index(anchor_id, "tl-") == 1 && index(anchor_id, "tl-doc-search-") != 1) {
                        if (anchor_id !~ /^tl-[A-Za-z0-9._-]+$/) {
                            invalid(page ": searchable anchor is not manifest-normalized: " anchor_id)
                        }
                        print page "#" anchor_id > href_file
                    }
                    remaining = substr(remaining, RSTART + RLENGTH)
                }
            }
            close(path)
            if (read_status < 0) invalid("could not read documentation page: " path)

            if (compiler_identity == "") invalid(page " is missing compiler identity")
            if (source_identity == "") invalid(page " is missing source identity")
            if (package_identity == "") invalid(page " is missing package identity")
            if (compiler_identity != expected_compiler) {
                invalid(page " compiler identity disagrees with search index")
            }
            if (source_identity != expected_source) {
                invalid(page " source identity disagrees with search index")
            }
            if (package_identity != expected_package) {
                invalid(page " package identity disagrees with search index")
            }
            printf "%s\t%s\t%s\t%s\n", page, compiler_identity, source_identity, package_identity > metadata_file
            page_count++
        }

        END {
            close(href_file)
            close(metadata_file)
            if (!failed && page_count == 0) invalid("documentation page manifest is empty")
        }
    ' "$_doc_search_page_list"
}

doc_site_search_validate_manifests() {
    _doc_search_site=$1
    _doc_search_work=$2
    _doc_search_index=$3
    _doc_search_pages=$4
    _doc_search_index_identities="$_doc_search_work/.search-identities.index"
    _doc_search_index_identities_sorted="$_doc_search_work/.search-identities.index.sorted"
    _doc_search_index_hrefs="$_doc_search_work/.search-hrefs.index"
    _doc_search_index_hrefs_sorted="$_doc_search_work/.search-hrefs.index.sorted"
    _doc_search_index_metadata="$_doc_search_work/.search-metadata.index"
    _doc_search_page_hrefs="$_doc_search_work/.search-hrefs.pages"
    _doc_search_page_hrefs_sorted="$_doc_search_work/.search-hrefs.pages.sorted"
    _doc_search_page_metadata="$_doc_search_work/.search-metadata.pages"
    _doc_search_missing="$_doc_search_work/.search-hrefs.missing"

    doc_site_search_parse_index \
        "$_doc_search_index" \
        "$_doc_search_index_identities" \
        "$_doc_search_index_hrefs" \
        "$_doc_search_index_metadata" || return $?

    IFS='	' read -r \
        _doc_search_compiler_identity \
        _doc_search_source_identity \
        _doc_search_package_identity < "$_doc_search_index_metadata"

    LC_ALL=C sort "$_doc_search_index_identities" > "$_doc_search_index_identities_sorted"
    _doc_search_duplicate_identity=$(uniq -d "$_doc_search_index_identities_sorted" | head -n 1)
    if [ -n "$_doc_search_duplicate_identity" ]; then
        echo "duplicate search identity: \"identity\":\"$_doc_search_duplicate_identity\"" >&2
        return 1
    fi
    LC_ALL=C sort -u "$_doc_search_index_hrefs" > "$_doc_search_index_hrefs_sorted"

    doc_site_search_extract_pages \
        "$_doc_search_pages" \
        "$_doc_search_compiler_identity" \
        "$_doc_search_source_identity" \
        "$_doc_search_package_identity" \
        "$_doc_search_page_hrefs" \
        "$_doc_search_page_metadata" || return $?
    LC_ALL=C sort -u "$_doc_search_page_hrefs" > "$_doc_search_page_hrefs_sorted"
    LC_ALL=C comm -23 \
        "$_doc_search_page_hrefs_sorted" \
        "$_doc_search_index_hrefs_sorted" > "$_doc_search_missing"
    if [ -s "$_doc_search_missing" ]; then
        _doc_search_missing_href=$(head -n 1 "$_doc_search_missing")
        _doc_search_missing_page=${_doc_search_missing_href%%#*}
        _doc_search_missing_anchor=${_doc_search_missing_href#*#}
        echo "$_doc_search_missing_page: anchor '$_doc_search_missing_anchor' is missing from search index" >&2
        return 1
    fi

    DOC_SITE_SEARCH_RECORD_COUNT=$(wc -l < "$_doc_search_index_identities" | tr -d ' ')
    DOC_SITE_SEARCH_INDEX_BYTES=$(wc -c < "$_doc_search_index" | tr -d ' ')
}

doc_site_search_structure_guard() {
    _doc_search_script=$1
    LC_ALL=C awk '
        /# doc-site-search-index-scan-guard: page-loop-begin/ {
            begin_count++
            in_page_loop = 1
            next
        }
        /# doc-site-search-index-scan-guard: page-loop-end/ {
            end_count++
            in_page_loop = 0
            next
        }
        in_page_loop && (/\$SEARCH_INDEX/ || /\$search_index/ || /for[ \t]+searchable_id/) {
            print "search-index scan reintroduced inside docs page loop at line " NR ": " $0 > "/dev/stderr"
            forbidden = 1
        }
        END {
            if (begin_count != 1 || end_count != 1 || in_page_loop) {
                print "docs page-loop search-scan guard markers are missing or unbalanced" > "/dev/stderr"
                exit 1
            }
            if (forbidden) exit 1
        }
    ' "$_doc_search_script"
}

doc_site_search_manifest_self_test() {
    _doc_search_verify_script=$1
    _doc_search_fixture=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-doc-search-manifests.XXXXXX") \
        || return 1
    trap 'rm -rf "$_doc_search_fixture"' EXIT HUP INT TERM
    _doc_search_fixture_site="$_doc_search_fixture/site"
    _doc_search_fixture_work="$_doc_search_fixture/work"
    mkdir -p "$_doc_search_fixture_site" "$_doc_search_fixture_work"

    printf '%s\n' \
        '<meta name="typelisp-compiler-identity" content="compiler-a"><meta name="typelisp-source-identity" content="source-a"><meta name="typelisp-package-identity" content="package@1"><h1 id="tl-z"></h1><div id="tl-doc-search-input"></div><h2 id="tl-A-32value"></h2>' \
        > "$_doc_search_fixture_site/a.html"
    printf '%s\n' \
        '<meta name="typelisp-compiler-identity" content="compiler-a"><meta name="typelisp-source-identity" content="source-a"><meta name="typelisp-package-identity" content="package@1"><h1 id="tl-b"></h1>' \
        > "$_doc_search_fixture_site/b.html"
    printf '%s\n' \
        "$_doc_search_fixture_site/a.html" \
        "$_doc_search_fixture_site/b.html" \
        > "$_doc_search_fixture/pages"

    _doc_search_fixture_index="$_doc_search_fixture_site/typelisp-docs-search-index.js"
    printf '%s\n' 'globalThis.TYPELISP_DOC_SEARCH=Object.freeze({"schema":1,"compilerIdentity":"compiler-a","sourceIdentity":"source-a","packageIdentity":"package@1","records":Object.freeze([{"identity":"a.html#tl-z","kind":"heading","label":"z","module":"a","href":"a.html#tl-z","signature":"","docs":"","sourceLine":1},{"identity":"a.html#tl-A-32value","kind":"heading","label":"A","module":"a","href":"a.html#tl-A-32value","signature":"","docs":"escaped \\u0026 value","sourceLine":2},{"identity":"b.html#tl-b","kind":"heading","label":"b","module":"b","href":"b.html#tl-b","signature":"","docs":"","sourceLine":1}])});' \
        > "$_doc_search_fixture_index"

    doc_site_search_validate_manifests \
        "$_doc_search_fixture_site" \
        "$_doc_search_fixture_work" \
        "$_doc_search_fixture_index" \
        "$_doc_search_fixture/pages" || return $?
    printf '%s\n' \
        'a.html#tl-A-32value' \
        'a.html#tl-z' \
        'b.html#tl-b' \
        > "$_doc_search_fixture/expected-page-hrefs"
    if ! cmp -s \
        "$_doc_search_fixture/expected-page-hrefs" \
        "$_doc_search_fixture_work/.search-hrefs.pages.sorted"; then
        echo "search manifest self-test did not normalize hrefs in C-locale order or exclude the search UI" >&2
        return 1
    fi

    cp "$_doc_search_fixture_site/b.html" "$_doc_search_fixture/b.html.saved"
    printf '%s\n' '<div id="tl-b"></div>' >> "$_doc_search_fixture_site/b.html"
    if doc_site_search_validate_manifests \
        "$_doc_search_fixture_site" "$_doc_search_fixture_work" \
        "$_doc_search_fixture_index" "$_doc_search_fixture/pages" \
        >/dev/null 2>&1; then
        echo "search manifest self-test accepted a duplicate page anchor" >&2
        return 1
    fi
    mv "$_doc_search_fixture/b.html.saved" "$_doc_search_fixture_site/b.html"

    sed 's|"href":"a.html#tl-z"|"href":"a.html#tl-not-z"|' \
        "$_doc_search_fixture_index" > "$_doc_search_fixture/missing.js"
    if doc_site_search_validate_manifests \
        "$_doc_search_fixture_site" "$_doc_search_fixture_work" \
        "$_doc_search_fixture/missing.js" "$_doc_search_fixture/pages" \
        >/dev/null 2>&1; then
        echo "search manifest self-test accepted a missing searchable record" >&2
        return 1
    fi

    sed 's|"identity":"b.html#tl-b"|"identity":"a.html#tl-z"|' \
        "$_doc_search_fixture_index" > "$_doc_search_fixture/duplicate.js"
    if doc_site_search_validate_manifests \
        "$_doc_search_fixture_site" "$_doc_search_fixture_work" \
        "$_doc_search_fixture/duplicate.js" "$_doc_search_fixture/pages" \
        >/dev/null 2>&1; then
        echo "search manifest self-test accepted a duplicate search identity" >&2
        return 1
    fi

    for _doc_search_identity_kind in compiler source package; do
        case "$_doc_search_identity_kind" in
            compiler) _doc_search_identity_field=compilerIdentity ;;
            source) _doc_search_identity_field=sourceIdentity ;;
            package) _doc_search_identity_field=packageIdentity ;;
        esac
        sed "s|\"$_doc_search_identity_field\":\"[^\"]*\"|\"$_doc_search_identity_field\":\"stale\"|" \
            "$_doc_search_fixture_index" > "$_doc_search_fixture/stale.js"
        if doc_site_search_validate_manifests \
            "$_doc_search_fixture_site" "$_doc_search_fixture_work" \
            "$_doc_search_fixture/stale.js" "$_doc_search_fixture/pages" \
            >/dev/null 2>&1; then
            echo "search manifest self-test accepted a stale $_doc_search_identity_kind identity" >&2
            return 1
        fi
    done

    sed 's|"records":Object.freeze|"records":Object.broken|' \
        "$_doc_search_fixture_index" > "$_doc_search_fixture/malformed.js"
    if doc_site_search_validate_manifests \
        "$_doc_search_fixture_site" "$_doc_search_fixture_work" \
        "$_doc_search_fixture/malformed.js" "$_doc_search_fixture/pages" \
        >/dev/null 2>&1; then
        echo "search manifest self-test accepted a malformed index" >&2
        return 1
    fi

    : > "$_doc_search_fixture/empty.js"
    if doc_site_search_validate_manifests \
        "$_doc_search_fixture_site" "$_doc_search_fixture_work" \
        "$_doc_search_fixture/empty.js" "$_doc_search_fixture/pages" \
        >/dev/null 2>&1; then
        echo "search manifest self-test accepted an empty index" >&2
        return 1
    fi

    sed 's|"href":"b.html#tl-b"|"href":"b.html#tl-b\\u0020bad"|' \
        "$_doc_search_fixture_index" > "$_doc_search_fixture/non-normalized.js"
    if doc_site_search_validate_manifests \
        "$_doc_search_fixture_site" "$_doc_search_fixture_work" \
        "$_doc_search_fixture/non-normalized.js" "$_doc_search_fixture/pages" \
        >/dev/null 2>&1; then
        echo "search manifest self-test accepted a non-normalized href" >&2
        return 1
    fi

    doc_site_search_structure_guard "$_doc_search_verify_script" || return $?
    printf '%s\n' \
        '# doc-site-search-index-scan-guard: page-loop-begin' \
        'grep -Fq "$needle" "$SEARCH_INDEX"' \
        'for searchable_id in $searchable_ids; do :; done' \
        '# doc-site-search-index-scan-guard: page-loop-end' \
        > "$_doc_search_fixture/reintroduced-scan.sh"
    if doc_site_search_structure_guard "$_doc_search_fixture/reintroduced-scan.sh" \
        >/dev/null 2>&1; then
        echo "search manifest structural self-test accepted a page-loop index rescan" >&2
        return 1
    fi

    rm -rf "$_doc_search_fixture"
    trap - EXIT HUP INT TERM
}
