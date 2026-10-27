#!/usr/bin/env sh
# Exact expectation locations: @loc{repository-relative-path;column;source-line}.
# The source line must match exactly once (CRLF is accepted). Only the line
# number is derived; the column remains an independent, exact expectation.
# Read source inputs, never compiler output, to determine the expected span.
resolve_source_locations() {
    case "$1" in
        *'@loc{'*) ;;
        *) printf '%s' "$1"; return ;;
    esac
    SOURCE_LOCATION_SPEC=$1 SOURCE_LOCATION_ROOT=${2:-$ROOT} awk '
        function fail(message) {
            print "source location expectation: " message > "/dev/stderr"
            exit 1
        }
        BEGIN {
            rest = ENVIRON["SOURCE_LOCATION_SPEC"]
            root = ENVIRON["SOURCE_LOCATION_ROOT"]
            result = ""
            while (start = index(rest, "@loc{")) {
                result = result substr(rest, 1, start - 1)
                rest = substr(rest, start + 5)
                end = index(rest, "}")
                if (!end) fail("unterminated anchor")
                spec = substr(rest, 1, end - 1)
                rest = substr(rest, end + 1)
                sep = index(spec, ";")
                path = substr(spec, 1, sep - 1)
                spec = substr(spec, sep + 1)
                sep = index(spec, ";")
                column = substr(spec, 1, sep - 1)
                anchor = substr(spec, sep + 1)
                if (path !~ /^[A-Za-z0-9_][A-Za-z0-9_.\/-]*\.tl$/ || path ~ /\.\./ ||
                    column !~ /^[1-9][0-9]*$/ || anchor == "")
                    fail("invalid path, column or source line")
                matches = line_number = 0
                input = root "/" path
                while ((status = (getline line < input)) > 0) {
                    line_number++
                    sub(/\r$/, "", line)
                    if (line == anchor) {
                        matches++
                        found = line_number
                    }
                }
                close(input)
                if (status < 0) fail("cannot read " path)
                if (matches != 1) fail(path ": expected one anchor, found " matches)
                if (column + 0 > length(anchor)) fail(path ": column outside source line")
                result = result path ":" found ":" column
            }
            printf "%s", result rest
        }
    ' < /dev/null
}

# Called by the existing native and safety harnesses, including their fast
# self-test entry points. Use a new child directory; retain all probe evidence.
source_location_self_test() (
    set -eu
    mkdir -p "$1"
    sl_test_root=$(mktemp -d "$1/probe.XXXXXX")
    printf 'prefix\n  (anchor)\ntail\n' > "$sl_test_root/site.tl"
    sl_test_spec='before @loc{site.tl;3;  (anchor)} after'
    sl_test_actual=$(resolve_source_locations "$sl_test_spec" "$sl_test_root")
    [ "$sl_test_actual" = 'before site.tl:2:3 after' ]
    printf 'prefix\n\n  (anchor)\ntail\n' > "$sl_test_root/site.tl"
    [ "$(resolve_source_locations "$sl_test_spec" "$sl_test_root")" = 'before site.tl:3:3 after' ]
    printf 'prefix\r\n  (anchor)\r\ntail\r\n' > "$sl_test_root/site.tl"
    [ "$(resolve_source_locations "$sl_test_spec" "$sl_test_root")" = "$sl_test_actual" ]
    [ "$(resolve_source_locations 'literal\\n' "$sl_test_root")" = 'literal\\n' ]
    [ "$(resolve_source_locations '@loc{site.tl;3;  (anchor)} @loc{site.tl;4;  (anchor)}' "$sl_test_root")" = 'site.tl:2:3 site.tl:2:4' ]
    for sl_test_bad in \
        '@loc{site.tl;3;missing}' '@loc{absent.tl;3;  (anchor)}' \
        '@loc{site.tl;0;  (anchor)}' '@loc{site.tl;99;  (anchor)}' \
        '@loc{../site.tl;3;  (anchor)}' '@loc{/site.tl;3;  (anchor)}' \
        '@loc{site.tl;3;}' '@loc{site.tl;3;  (anchor)' '@loc{site.tl}'; do
        if resolve_source_locations "$sl_test_bad" "$sl_test_root" > "$sl_test_root/bad.out" 2> "$sl_test_root/bad.err"; then
            echo "source location self-test accepted: $sl_test_bad" >&2
            exit 1
        fi
    done
    printf '  (anchor)\n  (anchor)\n' > "$sl_test_root/site.tl"
    if resolve_source_locations "$sl_test_spec" "$sl_test_root" > "$sl_test_root/duplicate.out" 2> "$sl_test_root/duplicate.err"; then
        echo 'source location self-test accepted duplicate anchor' >&2
        exit 1
    fi
    echo 'source location expectation self-test passed'
)
