#!/usr/bin/env sh

# A chunk belongs to exactly one compiler invocation (target, cfg, backend,
# optimization and ordered roots). Only equal input paths inside that invocation
# may share an output. Keep the original case records for every byte comparison.
# There is no cross-chunk, cross-producer or on-disk cache lookup.
build_invariance_plan_chunk() {
    _bib_cases=$1
    _bib_entries=$2
    _bib_aliases=$3
    _bib_opt=$4
    _bib_output_dir=$5
    : > "$_bib_entries"
    : > "$_bib_aliases"
    awk -F '|' -v entries="$_bib_entries" -v aliases="$_bib_aliases" \
        -v opt="$_bib_opt" -v output_dir="$_bib_output_dir" '
        function fail(message) {
            print "[build-invariance] invalid chunk: " message > "/dev/stderr"
            failed = 1
            exit 1
        }
        {
            if (NF != 5 || $1 !~ /^[A-Za-z0-9_-]+$/ || $2 == "" || $3 == "")
                fail("malformed case record")
            if ($5 !~ /^[12]$/ || $5 != opt || (opt != 1 && opt != 2))
                fail("optimization identity differs")
            if ($4 != output_dir "/" $1 ".s")
                fail("output does not belong to this producer")
            if (names[$1]++) fail("duplicate logical case " $1)
            if (++count > 64) fail("more than 64 logical cases")
            if ($3 in canonical) {
                print canonical[$3] "|" $4 > aliases
            } else {
                canonical[$3] = $4
                print $3 "|" $4 > entries
            }
        }
        END {
            if (!failed && count == 0) fail("empty chunk")
        }
    ' "$_bib_cases"
}

build_invariance_require_plan() {
    _bib_require_cases=$1
    _bib_require_entries=$2
    _bib_require_aliases=$3
    build_invariance_plan_chunk "$_bib_require_cases" \
        "$_bib_require_entries.expected" "$_bib_require_aliases.expected" "$4" "$5" || return 1
    if ! cmp -s "$_bib_require_entries" "$_bib_require_entries.expected" ||
        ! cmp -s "$_bib_require_aliases" "$_bib_require_aliases.expected"; then
        echo "[build-invariance] chunk plan differs from logical coverage" >&2
        return 1
    fi
    rm -f "$_bib_require_entries.expected" "$_bib_require_aliases.expected"
}

build_invariance_copy_aliases() {
    _bib_alias_file=$1
    while IFS='|' read -r _bib_original _bib_alias; do
        if [ ! -f "$_bib_original" ] || [ ! -s "$_bib_original" ] ||
            [ -L "$_bib_original" ]; then
            echo "[build-invariance] missing fresh canonical assembly: $_bib_original" >&2
            return 1
        fi
        if [ -e "$_bib_alias" ] || [ -L "$_bib_alias" ]; then
            echo "[build-invariance] alias output already exists: $_bib_alias" >&2
            return 1
        fi
        cp "$_bib_original" "$_bib_alias" || return 1
        if ! cmp -s "$_bib_original" "$_bib_alias"; then
            echo "[build-invariance] alias assembly differs: $_bib_alias" >&2
            return 1
        fi
    done < "$_bib_alias_file"
}
