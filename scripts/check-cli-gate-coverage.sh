#!/usr/bin/env sh
set -eu

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-cli-gate-coverage.sh [--self-test]
       scripts/check-cli-gate-coverage.sh [--inventory FILE] [--source FILE]...
EOF
}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

INVENTORY=scripts/cli-gate-coverage.tsv
WORKDIR=${CLI_GATE_COVERAGE_DIR:-target/cli-gate-coverage}
SELF_TEST=0
SOURCE_ARGS="$WORKDIR/source-args.txt"

case "$WORKDIR" in
    target/*) ;;
    *)
        echo "CLI_GATE_COVERAGE_DIR must stay below target/: $WORKDIR" >&2
        exit 2
        ;;
esac

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
: > "$SOURCE_ARGS"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --inventory)
            [ "$#" -ge 2 ] || {
                usage
                exit 2
            }
            INVENTORY=$2
            shift
            ;;
        --source)
            [ "$#" -ge 2 ] || {
                usage
                exit 2
            }
            printf '%s\n' "$2" >> "$SOURCE_ARGS"
            shift
            ;;
        --self-test)
            SELF_TEST=1
            ;;
        *)
            usage
            exit 2
            ;;
    esac
    shift
done

if [ "$SELF_TEST" -eq 1 ]; then
    if [ "$INVENTORY" != scripts/cli-gate-coverage.tsv ] || [ -s "$SOURCE_ARGS" ]; then
        usage
        exit 2
    fi
    exec scripts/verify-cli-gate-coverage.sh
fi

if [ ! -f "$INVENTORY" ]; then
    echo "missing CLI gate coverage inventory: $INVENTORY" >&2
    exit 1
fi

ROWS="$WORKDIR/rows.tsv"
REGISTERED_SOURCES="$WORKDIR/registered-sources.txt"
SOURCES="$WORKDIR/sources.txt"
ANNOTATIONS="$WORKDIR/annotations.tsv"
GATE_COUNTS="$WORKDIR/gate-counts.tsv"
SITE_COUNTS="$WORKDIR/site-counts.tsv"
EXPANDED_COUNTS="$WORKDIR/expanded-counts.tsv"
DUPLICATES="$WORKDIR/duplicates.tsv"
SUMMARY="$WORKDIR/summary.tsv"
EXPECTED_COUNTS="$WORKDIR/expected-counts.tsv"
ACTUAL_COUNTS="$WORKDIR/actual-counts.tsv"
CHILD_CORPORA="$WORKDIR/child-corpora.tsv"
COUNT_SCHEMA="$WORKDIR/count-schema.txt"

: > "$ROWS"
: > "$REGISTERED_SOURCES"
: > "$EXPECTED_COUNTS"
: > "$CHILD_CORPORA"
: > "$COUNT_SCHEMA"

if ! awk -F '\t' -v rows_out="$ROWS" -v sources_out="$REGISTERED_SOURCES" '
function fail(message) {
    print message > "/dev/stderr"
    failed = 1
}
function valid_path(path) {
    return path ~ /^[A-Za-z0-9_.][A-Za-z0-9_.\/-]*$/ &&
        path !~ /(^|\/)\.\.($|\/)/ && path !~ /^\//
}
function valid_id(value) {
    return value ~ /^[a-z0-9][a-z0-9._-]*$/
}
function valid_encoding(value, rest) {
    rest = value
    gsub(/%09|%0A|%0D|%25/, "", rest)
    return rest !~ /%/
}
BEGIN {
    expected = "schema\tcase_id\tgate\tsource\tkind\thost\tcompiler\targv\tfixture\tstdin\tcwd\tprocess\tenvironment\texpected_status\tstdout\tstderr\teffects\tcanonical_owner\tduplicate_reason"
    expected_count = split(expected, expected_field, "\t")
}
{
    sub(/\r$/, "", $0)

    if ($0 == "") {
        next
    }
    if ($1 == "# cli-gate-coverage-schema") {
        if (NF != 2 || $2 != "1") {
            fail("CLI gate coverage schema marker must be version 1")
        }
        schema_markers += 1
        next
    }
    if ($1 == "# source") {
        if (NF != 2 || !valid_path($2)) {
            fail("malformed CLI gate coverage source registration at line " FNR)
        } else {
            print $2 > sources_out
        }
        next
    }
    if ($0 ~ /^#/) {
        next
    }
    if (!header_seen) {
        if (NF != expected_count) {
            fail("CLI gate coverage header has " NF " fields; expected " expected_count)
        } else {
            for (i = 1; i <= expected_count; i += 1) {
                if ($i != expected_field[i]) {
                    fail("CLI gate coverage header field " i " must be `" expected_field[i] "`")
                }
            }
        }
        header_seen = 1
        next
    }

    if (NF != 19) {
        fail("CLI gate coverage row " FNR " has " NF " fields; expected 19")
        next
    }
    for (i = 1; i <= 19; i += 1) {
        if ($i == "" || $i ~ /^[[:space:]]+$/) {
            fail("CLI gate coverage row " FNR " field `" expected_field[i] "` is empty")
        } else if ($i ~ /^[[:space:]]/ || $i ~ /[[:space:]]$/) {
            fail("CLI gate coverage row " FNR " field `" expected_field[i] "` has outer whitespace")
        } else if (!valid_encoding($i)) {
            fail("CLI gate coverage row " FNR " field `" expected_field[i] "` has an invalid percent escape")
        }
    }
    if ($1 != "1") {
        fail("CLI gate coverage row " FNR " uses schema `" $1 "`; expected `1`")
    }
    if (!valid_id($2)) {
        fail("CLI gate coverage row " FNR " has invalid case ID `" $2 "`")
    } else if ($2 in case_seen) {
        fail("duplicate CLI gate coverage case ID `" $2 "` at rows " case_seen[$2] " and " FNR)
    } else {
        case_seen[$2] = FNR
    }
    if (!valid_id($3)) {
        fail("CLI gate coverage row " FNR " has invalid gate `" $3 "`")
    }
    if (!valid_path($4)) {
        fail("CLI gate coverage row " FNR " has unsafe source path `" $4 "`")
    }
    if ($5 != "wrapper" && $5 != "direct" && $5 != "delegated") {
        fail("CLI gate coverage row " FNR " has unknown invocation kind `" $5 "`")
    }
    if ($6 != "all" && $6 != "linux" && $6 != "windows") {
        fail("CLI gate coverage row " FNR " has unknown host `" $6 "`")
    }
    if (!valid_id($18)) {
        fail("CLI gate coverage row " FNR " has invalid canonical owner `" $18 "`")
    }

    print $0 > rows_out
    print $4 > sources_out
    row_count += 1
}
END {
    if (schema_markers != 1) {
        fail("CLI gate coverage inventory must contain exactly one version-1 schema marker")
    }
    if (!header_seen) {
        fail("CLI gate coverage inventory is missing its header")
    }
    if (failed) {
        print "CLI gate coverage inventory validation failed" > "/dev/stderr"
        exit 1
    }
}
' "$INVENTORY"; then
    exit 1
fi

# Count expectations live beside the behavior rows so inventory changes cannot
# silently weaken or broaden a gate. Custom fixture inventories may omit the
# count schema; the checked-in production inventory must carry it.
if ! awk -F '\t' \
    -v expected_out="$EXPECTED_COUNTS" \
    -v child_out="$CHILD_CORPORA" \
    -v schema_out="$COUNT_SCHEMA" '
function fail(message) {
    print message > "/dev/stderr"
    failed = 1
}
function valid_key(value) {
    return value ~ /^[A-Za-z0-9][A-Za-z0-9+._-]*$/
}
function valid_path(path) {
    return path ~ /^[A-Za-z0-9_.][A-Za-z0-9_.\/-]*$/ &&
        path !~ /(^|\/)\.\.($|\/)/ && path !~ /^\//
}
{
    sub(/\r$/, "", $0)
    if ($1 == "# cli-gate-coverage-counts") {
        if (NF != 2 || $2 != "1") {
            fail("CLI gate coverage count schema marker must be version 1")
        }
        count_schema += 1
        next
    }
    if ($0 ~ /^# cli-gate-coverage-counts([[:space:]]|$)/) {
        fail("malformed CLI gate coverage count schema marker at line " FNR)
        next
    }
    if ($1 == "# count") {
        if (NF != 5 || !valid_key($2) || !valid_key($3) || !valid_key($4) || $5 !~ /^[0-9]+$/) {
            fail("malformed CLI gate coverage count expectation at line " FNR)
        } else {
            key = $2 SUBSEP $3 SUBSEP $4
            if (key in count_seen) {
                fail("duplicate CLI gate coverage count expectation at line " FNR)
            }
            count_seen[key] = 1
            print $2 "\t" $3 "\t" $4 "\t" $5 > expected_out
            expectation_count += 1
        }
        next
    }
    if ($0 ~ /^# count([[:space:]]|$)/) {
        fail("malformed CLI gate coverage count expectation at line " FNR)
        next
    }
    if ($1 == "# child-corpus") {
        if (NF != 7 || !valid_key($2) || ($3 != "all" && $3 != "linux" && $3 != "windows") ||
                !valid_path($4) || $5 == "" || $5 ~ /[\/[:space:]]/ ||
                ($6 != "-" && ($6 == "" || $6 ~ /[\/[:space:]]/)) || $7 !~ /^[0-9]+$/) {
            fail("malformed CLI gate child-corpus expectation at line " FNR)
        } else {
            key = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP $6
            if (key in child_seen) {
                fail("duplicate CLI gate child-corpus expectation at line " FNR)
            }
            child_seen[key] = 1
            print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 > child_out
            child_count += 1
        }
        next
    }
    if ($0 ~ /^# child-corpus([[:space:]]|$)/) {
        fail("malformed CLI gate child-corpus expectation at line " FNR)
        next
    }
}
END {
    if (count_schema > 1) {
        fail("CLI gate coverage inventory must contain at most one count schema marker")
    }
    if (!count_schema && (expectation_count || child_count)) {
        fail("CLI gate coverage count directives require a version-1 count schema marker")
    }
    if (count_schema && !expectation_count) {
        fail("CLI gate coverage count schema has no count expectations")
    }
    if (count_schema) {
        print "1" > schema_out
    }
    if (failed) {
        print "CLI gate coverage count schema validation failed" > "/dev/stderr"
        exit 1
    }
}
' "$INVENTORY"; then
    exit 1
fi

if [ "$INVENTORY" = scripts/cli-gate-coverage.tsv ] && [ ! -s "$COUNT_SCHEMA" ]; then
    echo "checked-in CLI gate coverage inventory is missing its count schema" >&2
    exit 1
fi

cat "$SOURCE_ARGS" >> "$REGISTERED_SOURCES"
LC_ALL=C sort -u "$REGISTERED_SOURCES" > "$SOURCES"
: > "$ANNOTATIONS"

while IFS= read -r source; do
    [ -n "$source" ] || continue
    case "$source" in
        /* | ../* | */../* | *'/..')
            echo "unsafe CLI gate coverage source path: $source" >&2
            exit 1
            ;;
    esac
    if [ ! -f "$source" ]; then
        echo "CLI gate coverage source not found: $source" >&2
        exit 1
    fi

    if ! awk -v source="$source" '
function fail(message) {
    printf "%s:%d: %s\n", source, annotation_line ? annotation_line : FNR, message > "/dev/stderr"
    failed = 1
}
function valid_id(value) {
    return value ~ /^[a-z0-9][a-z0-9._-]*$/
}
function valid_kind(value) {
    return value == "wrapper" || value == "direct" || value == "delegated"
}
function clear_pending(    i) {
    for (i = 1; i <= pending_count; i += 1) {
        delete pending_id[i]
    }
    pending_count = 0
    pending = 0
    annotation_line = 0
    pending_pattern = ""
    pending_kind = ""
    pending_token = ""
    pending_expanded = 0
}
function begin_annotation(parts, count, expanded,    i) {
    if (pending) {
        fail("annotation is not followed by its registered invocation")
        clear_pending()
    }
    annotation_line = FNR
    pending_pattern = parts[3]
    pending_kind = parts[4]
    pending_token = parts[5]
    pending_expanded = expanded
    pending = 1

    if (!valid_kind(pending_kind)) {
        fail("unknown annotation invocation kind `" pending_kind "`")
    }
    if (pending_token == "" || pending_token ~ /[[:space:]#]/) {
        fail("annotation command token must be one non-comment shell token")
    }

    if (!expanded) {
        if (count != 5 || !valid_id(pending_pattern)) {
            fail("malformed cli-gate-case annotation")
        } else {
            pending_count = 1
            pending_id[1] = pending_pattern
        }
        return
    }

    if (count < 6) {
        fail("cli-gate-expand requires at least one axis")
        return
    }
    axis_count = 0
    for (i = 6; i <= count; i += 1) {
        equals = index(parts[i], "=")
        axis = substr(parts[i], 1, equals - 1)
        values_text = substr(parts[i], equals + 1)
        if (equals <= 1 || axis !~ /^[a-z][a-z0-9_-]*$/ || axis in axis_seen) {
            fail("malformed or duplicate expansion axis `" parts[i] "`")
            continue
        }
        axis_seen[axis] = 1
        axis_count += 1
        axis_name[axis_count] = axis
        value_count[axis_count] = split(values_text, values, ",")
        if (values_text == "" || values_text ~ /^,/ || values_text ~ /,$/ || values_text ~ /,,/) {
            fail("expansion axis `" axis "` has an empty value")
        }
        for (j = 1; j <= value_count[axis_count]; j += 1) {
            value = values[j]
            if (value !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) {
                fail("expansion axis `" axis "` has invalid value `" value "`")
            }
            value_key = axis SUBSEP value
            if (value_key in value_seen) {
                fail("expansion axis `" axis "` repeats value `" value "`")
            }
            value_seen[value_key] = 1
            axis_value[axis_count, j] = value
        }
    }

    pending_count = 1
    pending_id[1] = pending_pattern
    for (i = 1; i <= axis_count; i += 1) {
        placeholder = "\\{" axis_name[i] "\\}"
        if (pending_pattern !~ placeholder) {
            fail("expansion pattern does not use axis `" axis_name[i] "`")
        }
        old_count = pending_count
        new_count = 0
        for (j = 1; j <= old_count; j += 1) {
            base = pending_id[j]
            for (k = 1; k <= value_count[i]; k += 1) {
                expanded_id = base
                gsub(placeholder, axis_value[i, k], expanded_id)
                new_count += 1
                next_id[new_count] = expanded_id
            }
        }
        for (j = 1; j <= old_count; j += 1) {
            delete pending_id[j]
        }
        pending_count = new_count
        for (j = 1; j <= new_count; j += 1) {
            pending_id[j] = next_id[j]
            delete next_id[j]
        }
    }
    for (i = 1; i <= pending_count; i += 1) {
        if (!valid_id(pending_id[i]) || pending_id[i] ~ /[{}]/) {
            fail("expansion produced invalid case ID `" pending_id[i] "`")
        }
    }
    for (i = 1; i <= axis_count; i += 1) {
        delete axis_seen[axis_name[i]]
        for (j = 1; j <= value_count[i]; j += 1) {
            delete value_seen[axis_name[i] SUBSEP axis_value[i, j]]
            delete axis_value[i, j]
        }
        delete axis_name[i]
        delete value_count[i]
    }
}
{
    sub(/\r$/, "", $0)
    text = $0
    sub(/^[[:space:]]*/, "", text)

    if (text ~ /^#[[:space:]]+cli-gate-case[[:space:]]+/) {
        count = split(text, parts, /[[:space:]]+/)
        begin_annotation(parts, count, 0)
        next
    }
    if (text ~ /^#[[:space:]]+cli-gate-expand[[:space:]]+/) {
        count = split(text, parts, /[[:space:]]+/)
        begin_annotation(parts, count, 1)
        next
    }
    if (!pending || text == "" || text ~ /^#/) {
        next
    }

    split(text, command_parts, /[[:space:]]+/)
    if (command_parts[1] != pending_token) {
        fail("annotation expects command token `" pending_token "` but next invocation starts with `" command_parts[1] "`")
    }
    for (i = 1; i <= pending_count; i += 1) {
        printf "%s\t%s\t%d\t%s\t%s\t%d\n", pending_id[i], source, annotation_line, pending_kind, pending_pattern, pending_expanded
    }
    clear_pending()
}
END {
    if (pending) {
        fail("annotation reaches end of file without an invocation")
    }
    if (failed) {
        exit 1
    }
}
' "$source" >> "$ANNOTATIONS"; then
        echo "CLI gate coverage annotation validation failed" >&2
        exit 1
    fi
done < "$SOURCES"

: > "$GATE_COUNTS"
: > "$SITE_COUNTS"
: > "$EXPANDED_COUNTS"
: > "$DUPLICATES"
: > "$SUMMARY"

if ! awk -F '\t' \
    -v rows="$ROWS" \
    -v annotations="$ANNOTATIONS" \
    -v gates_out="$GATE_COUNTS" \
    -v sites_out="$SITE_COUNTS" \
    -v expanded_out="$EXPANDED_COUNTS" \
    -v duplicates_out="$DUPLICATES" \
    -v summary_out="$SUMMARY" '
function fail(message) {
    print message > "/dev/stderr"
    failed = 1
}
FILENAME == rows {
    id = $2
    row[id] = 1
    gate[id] = $3
    source[id] = $4
    kind[id] = $5
    owner[id] = $18
    reason[id] = $19
    identity = $5
    for (i = 6; i <= 17; i += 1) {
        identity = identity SUBSEP $i
    }
    identity_of[id] = identity
    identity_count[identity] += 1
    identity_id[identity, identity_count[identity]] = id
    gate_count[$3] += 1
    row_count += 1
    next
}
FILENAME == annotations {
    id = $1
    if (id in annotation) {
        fail("duplicate executing annotation for case ID `" id "` at " annotation_source[id] ":" annotation_line[id] " and " $2 ":" $3)
        next
    }
    annotation[id] = 1
    annotation_source[id] = $2
    annotation_line[id] = $3
    annotation_kind[id] = $4
    annotation_pattern[id] = $5
    annotation_expanded[id] = $6 + 0
    site = $2 SUBSEP $3
    site_count[site] += 1
    annotation_count += 1
    next
}
END {
    for (id in annotation) {
        if (!(id in row)) {
            fail("executing CLI gate annotation `" id "` has no inventory row")
        } else {
            if (source[id] != annotation_source[id]) {
                fail("CLI gate case `" id "` source mismatch: row `" source[id] "`, annotation `" annotation_source[id] "`")
            }
            if (kind[id] != annotation_kind[id]) {
                fail("CLI gate case `" id "` kind mismatch: row `" kind[id] "`, annotation `" annotation_kind[id] "`")
            }
        }
    }
    for (id in row) {
        if (!(id in annotation)) {
            fail("CLI gate inventory row `" id "` has no executing annotation")
        }
        if (!(owner[id] in row)) {
            fail("CLI gate case `" id "` names unknown canonical owner `" owner[id] "`")
        }
    }

    for (identity in identity_count) {
        count = identity_count[identity]
        if (count == 1) {
            id = identity_id[identity, 1]
            if (owner[id] != id) {
                fail("unique CLI gate case `" id "` must own its canonical behavior")
            }
            if (reason[id] != "-") {
                fail("unique CLI gate case `" id "` must use `-` as its duplicate reason")
            }
            continue
        }

        canonical = owner[identity_id[identity, 1]]
        owner_in_group = 0
        group_valid = 1
        for (i = 1; i <= count; i += 1) {
            id = identity_id[identity, i]
            if (owner[id] != canonical) {
                group_valid = 0
            }
            if (id == canonical) {
                owner_in_group = 1
            }
            if (reason[id] == "-") {
                group_valid = 0
            }
        }
        if (!group_valid || !owner_in_group) {
            fail("exact duplicate CLI gate behavior lacks one in-group canonical owner and checked reasons")
            continue
        }
        for (i = 1; i <= count; i += 1) {
            id = identity_id[identity, i]
            printf "%s\t%s\t%s\t%s:%d\t%s\n", canonical, id, gate[id], annotation_source[id], annotation_line[id], reason[id] > duplicates_out
        }
    }

    if (failed) {
        print "CLI gate coverage check failed" > "/dev/stderr"
        exit 1
    }

    for (name in gate_count) {
        printf "%s\t%d\n", name, gate_count[name] > gates_out
    }
    site_total = 0
    for (site in site_count) {
        split(site, site_parts, SUBSEP)
        printf "%s:%d\t%d\n", site_parts[1], site_parts[2], site_count[site] > sites_out
        site_total += 1
    }
    for (id in annotation) {
        if (annotation_expanded[id]) {
            printf "%s\t%s:%d\t%s\t1\n", id, annotation_source[id], annotation_line[id], annotation_pattern[id] > expanded_out
        }
    }
    printf "%d\t%d\t%d\n", row_count, annotation_count, site_total > summary_out
}
' "$ROWS" "$ANNOTATIONS"; then
    exit 1
fi

LC_ALL=C sort -o "$GATE_COUNTS" "$GATE_COUNTS"
LC_ALL=C sort -o "$SITE_COUNTS" "$SITE_COUNTS"
LC_ALL=C sort -o "$EXPANDED_COUNTS" "$EXPANDED_COUNTS"
LC_ALL=C sort -o "$DUPLICATES" "$DUPLICATES"

TAB=$(printf '\t')
IFS="$TAB" read -r row_count annotation_count site_count < "$SUMMARY"
source_count=$(wc -l < "$SOURCES" | tr -d ' ')

if [ -s "$COUNT_SCHEMA" ]; then
    : > "$ACTUAL_COUNTS"
    if ! awk -F '\t' \
        -v rows="$ROWS" \
        -v annotations="$ANNOTATIONS" \
        -v duplicates="$DUPLICATES" \
        -v source_count="$source_count" \
        -v actual_out="$ACTUAL_COUNTS" '
FILENAME == rows {
    id = $2
    gate[id] = $3
    gate_rows[$3] += 1
    host_rows[$6] += 1
    kind_rows[$5] += 1
    process_rows[$12] += 1
    if ($6 == "all" || $6 == "linux") {
        platform_rows["linux"] += 1
    }
    if ($6 == "all" || $6 == "windows") {
        platform_rows["windows"] += 1
    }
    row_count += 1
    next
}
FILENAME == annotations {
    annotation_count += 1
    source_site[$2 SUBSEP $3] = 1
    gate_site[gate[$1] SUBSEP $2 SUBSEP $3] = 1
    if ($6 + 0) {
        gate_expanded[gate[$1]] += 1
        expanded_count += 1
    }
    next
}
FILENAME == duplicates {
    duplicate_owner[$1] = 1
    duplicate_rows += 1
    next
}
END {
    for (site in source_site) {
        site_count += 1
    }
    for (site in gate_site) {
        split(site, parts, SUBSEP)
        gate_sites[parts[1]] += 1
    }
    for (owner in duplicate_owner) {
        duplicate_groups += 1
    }

    print "total\tall\trows\t" row_count > actual_out
    print "total\tall\tannotations\t" annotation_count > actual_out
    print "total\tall\tsources\t" source_count > actual_out
    print "total\tall\tsource-sites\t" site_count > actual_out
    print "total\tall\texpanded-cases\t" (expanded_count + 0) > actual_out
    for (name in gate_rows) {
        print "gate\t" name "\trows\t" gate_rows[name] > actual_out
        print "gate\t" name "\tsource-sites\t" gate_sites[name] > actual_out
        print "gate\t" name "\texpanded-cases\t" (gate_expanded[name] + 0) > actual_out
    }
    for (name in host_rows) {
        print "host\t" name "\trows\t" host_rows[name] > actual_out
    }
    for (name in platform_rows) {
        print "platform\t" name "\trows\t" platform_rows[name] > actual_out
    }
    for (name in kind_rows) {
        print "kind\t" name "\trows\t" kind_rows[name] > actual_out
    }
    for (name in process_rows) {
        print "process\t" name "\trows\t" process_rows[name] > actual_out
    }
    print "duplicates\tall\tgroups\t" (duplicate_groups + 0) > actual_out
    print "duplicates\tall\trows\t" (duplicate_rows + 0) > actual_out
}
' "$ROWS" "$ANNOTATIONS" "$DUPLICATES"; then
        exit 1
    fi

    LC_ALL=C sort -o "$EXPECTED_COUNTS" "$EXPECTED_COUNTS"
    LC_ALL=C sort -o "$ACTUAL_COUNTS" "$ACTUAL_COUNTS"
    if ! cmp -s "$EXPECTED_COUNTS" "$ACTUAL_COUNTS"; then
        echo "CLI gate coverage authoritative counts are stale or incomplete:" >&2
        diff -u "$EXPECTED_COUNTS" "$ACTUAL_COUNTS" >&2 || true
        exit 1
    fi
fi

if [ -s "$CHILD_CORPORA" ]; then
    if ! awk -F '\t' -v rows="$ROWS" -v children="$CHILD_CORPORA" '
FILENAME == rows {
    row[$2] = 1
    kind[$2] = $5
    host[$2] = $6
    next
}
FILENAME == children {
    if (!($1 in row)) {
        print "child-corpus expectation names unknown case `" $1 "`" > "/dev/stderr"
        failed = 1
    } else if (kind[$1] != "delegated") {
        print "child-corpus expectation names non-delegated case `" $1 "`" > "/dev/stderr"
        failed = 1
    } else if (host[$1] != "all" && host[$1] != $2) {
        print "child-corpus host `" $2 "` is incompatible with case `" $1 "` host `" host[$1] "`" > "/dev/stderr"
        failed = 1
    }
}
END { exit failed ? 1 : 0 }
' "$ROWS" "$CHILD_CORPORA"; then
        exit 1
    fi

    child_index=0
    while IFS="$TAB" read -r case_id host directory include exclude expected; do
        [ -n "$case_id" ] || continue
        if [ ! -d "$directory" ]; then
            echo "CLI gate child corpus directory not found: $directory" >&2
            exit 1
        fi
        child_index=$((child_index + 1))
        matches="$WORKDIR/child-matches-$child_index.txt"
        find "$directory" -maxdepth 1 -type f -name "$include" -print > "$matches"
        actual=0
        while IFS= read -r child_path; do
            child_name=${child_path##*/}
            if [ "$exclude" != "-" ]; then
                case "$child_name" in
                    $exclude) continue ;;
                esac
            fi
            actual=$((actual + 1))
        done < "$matches"
        if [ "$actual" -ne "$expected" ]; then
            echo "CLI gate child corpus count is stale for $case_id ($host, $directory/$include excluding $exclude): expected $expected, found $actual" >&2
            exit 1
        fi
        printf 'count\tchild-corpus\t%s\t%s\t%s\t%s\n' "$case_id" "$host" "$directory" "$actual"
    done < "$CHILD_CORPORA"
fi

printf 'CLI gate coverage check passed: %s row(s), %s annotation(s), %s source(s), %s source site(s)\n' \
    "$row_count" "$annotation_count" "$source_count" "$site_count"
while IFS="$TAB" read -r gate count; do
    [ -n "$gate" ] || continue
    printf 'count\tgate\t%s\t%s\n' "$gate" "$count"
done < "$GATE_COUNTS"
while IFS="$TAB" read -r site count; do
    [ -n "$site" ] || continue
    printf 'count\tsource-site\t%s\t%s\n' "$site" "$count"
done < "$SITE_COUNTS"
while IFS="$TAB" read -r id site pattern count; do
    [ -n "$id" ] || continue
    printf 'count\texpanded-case\t%s\t%s\t%s\t%s\n' "$id" "$site" "$pattern" "$count"
done < "$EXPANDED_COUNTS"
while IFS="$TAB" read -r owner id gate site reason; do
    [ -n "$owner" ] || continue
    printf 'duplicate\t%s\t%s\t%s\t%s\t%s\n' "$owner" "$id" "$gate" "$site" "$reason"
done < "$DUPLICATES"
