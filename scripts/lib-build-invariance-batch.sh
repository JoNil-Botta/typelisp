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

# Compare the multiset of executed logical records with the complete prepared
# inventory, and that inventory with the authoritative corpus. Counts alone
# cannot detect a duplicated chunk substituted for a missing one.
build_invariance_require_coverage() {
    _bib_coverage_corpus=$1
    _bib_coverage_root=$2
    _bib_coverage_cases="$_bib_coverage_root/cases.txt"
    if ! awk -F '|' 'NF != 3 || $1 == "" || seen[$1]++ { exit 1 }
        { count++ } END { if (count == 0) exit 1 }' \
        "$_bib_coverage_corpus"; then
        echo "[build-invariance] malformed or duplicate corpus case" >&2
        return 1
    fi
    LC_ALL=C sort "$_bib_coverage_corpus" > "$_bib_coverage_root/coverage.corpus"
    awk -F '|' '{ print $1 "|" $2 "|" $5 }' "$_bib_coverage_cases" |
        LC_ALL=C sort > "$_bib_coverage_root/coverage.prepared"
    if ! cmp -s "$_bib_coverage_root/coverage.corpus" "$_bib_coverage_root/coverage.prepared"; then
        echo "[build-invariance] prepared inventory differs from corpus" >&2
        return 1
    fi
    : > "$_bib_coverage_root/coverage.chunks"
    for _bib_coverage_opt in 1 2; do
        for _bib_coverage_chunk in "$_bib_coverage_root/opt$_bib_coverage_opt/chunks"/cases.*.txt; do
            [ -f "$_bib_coverage_chunk" ] || continue
            cat "$_bib_coverage_chunk" >> "$_bib_coverage_root/coverage.chunks" || return 1
        done
    done
    LC_ALL=C sort "$_bib_coverage_cases" > "$_bib_coverage_root/coverage.expected"
    LC_ALL=C sort "$_bib_coverage_root/coverage.chunks" > "$_bib_coverage_root/coverage.actual"
    if ! cmp -s "$_bib_coverage_root/coverage.expected" "$_bib_coverage_root/coverage.actual"; then
        echo "[build-invariance] chunk coverage differs from prepared inventory" >&2
        return 1
    fi
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

# A large source remains the only unique input in its process. Consecutive
# logical aliases of that input share the fresh output through the ordinary
# chunk planner; they still count toward the logical-case ceiling.
build_invariance_write_chunks() {
    _bib_chunk_records=$1
    _bib_chunk_dir=$2
    _bib_chunk_size=$3
    rm -rf "$_bib_chunk_dir"
    mkdir -p "$_bib_chunk_dir"
    awk -F'|' -v chunk_dir="$_bib_chunk_dir" -v chunk_size="$_bib_chunk_size" '
        function singleton(name, source) {
            return name ~ /^selfhost_main_/ || source ~ /^src\/tests\/compiler_[^/]*\.tl$/
        }
        function finish_chunk() {
            if (chunk_entries > 0) {
                close(cases_path)
                chunk_index += 1
                chunk_entries = 0
            }
        }
        $1 != "" {
            alone = singleton($1, $2)
            if (chunk_entries > 0 && (alone || chunk_alone) &&
                !(alone && chunk_alone && $3 == chunk_source && $5 == chunk_opt)) {
                finish_chunk()
            }
            if (chunk_entries == 0) {
                cases_path = chunk_dir "/cases." sprintf("%04d", chunk_index) ".txt"
                chunk_source = $3
                chunk_opt = $5
                chunk_alone = alone
            }
            print $0 >> cases_path
            chunk_entries += 1
            if (chunk_entries >= chunk_size) finish_chunk()
        }
        END { finish_chunk() }
    ' "$_bib_chunk_records"
}

# Several logical aliases still represent one complete smoke compilation.
# Classify every row so an unrelated input cannot borrow its memory class.
build_invariance_chunk_is_codegen_smoke() {
    awk -F'|' '
        NF != 5 || $3 != "src/tests/compiler_codegen_smoke_suite.tl" { exit 1 }
        END { if (NR == 0) exit 1 }
    ' "$1"
}
