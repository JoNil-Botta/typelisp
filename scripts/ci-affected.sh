#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CALLER_DIR=$PWD
cd "$ROOT"
. "$ROOT/scripts/lib-ci-gates.sh"
TAB=$(printf '\t')

usage() {
    cat >&2 <<'USAGE'
usage: scripts/ci-affected.sh --base REF [--tier required|advisory] [--host linux|windows] [--run]
       scripts/ci-affected.sh --paths FILE [--tier required|advisory] [--host linux|windows]
       scripts/ci-affected.sh --batch FILE
       scripts/ci-affected.sh --self-test

Print the required local minimum gate IDs using scripts/ci-affected-paths.d/*.tsv.
--tier advisory prints a conservative superset for planning additional checks.
--base compares the merge base of REF and HEAD with the working tree, including
staged, unstaged, deleted, renamed (both paths) and nonignored untracked files.
Unknown paths select the full host table. Invalid refs/maps fail before running.
--run executes the selected tier through ci-verify.sh, one gate at a time.
INLINE_TEST, BUILD_INVARIANCE, INTEGRATION and COMPILE_MANIFEST worker counts
(TYPELISP_*_WORKERS) default to 1; every other explicit value fails.
The required tier is what owners run; the superset is advisory. Ordinary
compiler changes do not require the full local table. Full hosted CI is unchanged.
--paths replays a newline-delimited path inventory for auditing; it cannot run.
--batch replays many such inventories in one process, so each host inventory,
reviewed map and distinct dependency closure loads once instead of once per
query. It cannot run. A record is an "@@" line holding host, tier and output
file, tab separated, followed by that record's path inventory, one path per
line. Each record's selection is written to its output file.
USAGE
}

fail() { echo "[ci-affected] $*" >&2; exit 2; }
base=
paths=
batch=
run=0
host=
tier=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base | --paths | --batch | --host | --tier)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
            case "$1" in
                --base) [ -z "$base" ] || fail 'duplicate --base'; base=$2 ;;
                --paths)
                    [ -z "$paths" ] || fail 'duplicate --paths'
                    paths=$2
                    case "$paths" in /* | [A-Za-z]:[/\\]*) ;; *) paths="$CALLER_DIR/$paths" ;; esac ;;
                --batch)
                    [ -z "$batch" ] || fail 'duplicate --batch'
                    batch=$2
                    case "$batch" in /* | [A-Za-z]:[/\\]*) ;; *) batch="$CALLER_DIR/$batch" ;; esac ;;
                --host) [ -z "$host" ] || fail 'duplicate --host'; host=$2 ;;
                --tier) [ -z "$tier" ] || fail 'duplicate --tier'; tier=$2 ;;
            esac
            shift 2 ;;
        --run) [ "$run" = 0 ] || fail 'duplicate --run'; run=1; shift ;;
        --self-test)
            [ "$#" = 1 ] && [ -z "$base$paths$batch$host$tier" ] && [ "$run" = 0 ] || fail '--self-test must stand alone'
            exec "$ROOT/scripts/test-ci-affected.sh" ;;
        -h | --help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
if [ -n "$batch" ]; then
    [ -z "$base$paths$host$tier" ] && [ "$run" = 0 ] || fail '--batch must stand alone'
else
    [ -n "$base$paths" ] || { usage; exit 2; }
    [ -z "$base" ] || [ -z "$paths" ] || fail 'choose --base or --paths'
    [ "$run" = 0 ] || [ -n "$base" ] || fail '--run requires --base'
    tier=${tier:-required}
    case "$tier" in required | advisory) ;; *) fail "unknown tier: $tier" ;; esac

    native_host=unsupported
    case "$(uname -s)" in
        Linux*) native_host=linux ;;
        MINGW* | MSYS* | CYGWIN*) native_host=windows ;;
    esac
    host=${host:-$native_host}
    case "$host" in linux | windows) ;; *) fail "unsupported host: $host" ;; esac
    [ "$run" = 0 ] || [ "$host" = "$native_host" ] || fail '--run requires the native host'
fi
TYPELISP_INLINE_TEST_WORKERS=${TYPELISP_INLINE_TEST_WORKERS-1}
TYPELISP_BUILD_INVARIANCE_WORKERS=${TYPELISP_BUILD_INVARIANCE_WORKERS-1}
TYPELISP_INTEGRATION_WORKERS=${TYPELISP_INTEGRATION_WORKERS-1}
TYPELISP_COMPILE_MANIFEST_WORKERS=${TYPELISP_COMPILE_MANIFEST_WORKERS-1}
[ "$TYPELISP_INLINE_TEST_WORKERS" = 1 ] || fail 'TYPELISP_INLINE_TEST_WORKERS must be 1 for local preflight'
[ "$TYPELISP_BUILD_INVARIANCE_WORKERS" = 1 ] || fail 'TYPELISP_BUILD_INVARIANCE_WORKERS must be 1 for local preflight'
[ "$TYPELISP_INTEGRATION_WORKERS" = 1 ] || fail 'TYPELISP_INTEGRATION_WORKERS must be 1 for local preflight'
[ "$TYPELISP_COMPILE_MANIFEST_WORKERS" = 1 ] || fail 'TYPELISP_COMPILE_MANIFEST_WORKERS must be 1 for local preflight'
export TYPELISP_INLINE_TEST_WORKERS TYPELISP_BUILD_INVARIANCE_WORKERS TYPELISP_INTEGRATION_WORKERS TYPELISP_COMPILE_MANIFEST_WORKERS

# Reuse the canonical table validator and dependency planner; do not duplicate
# their graph/host semantics. Listing needs no compiler or runtime setup.
mkdir -p "$ROOT/target/exp/ci-affected"
work=$(mktemp -d "$ROOT/target/exp/ci-affected/run.XXXXXX")
gates_dir="$ROOT/scripts/ci-gates.d"
paths_dir="$ROOT/scripts/ci-affected-paths.d"

# A query stream shares one cache file per host inventory and per tier map, so
# a batched replay pays for each of them once instead of once per query.
inventory() { "$ROOT/scripts/ci-verify.sh" --list-gates "$1" > "$2"; }

expand_map() {
    if [ ! -f "$work/gates-full.tsv" ]; then
        ci_gates_load "$gates_dir" > "$work/gates-full.tsv" || exit 1
    fi
    if [ ! -f "$work/affected-paths.tsv" ]; then
        ci_affected_paths_load "$paths_dir" > "$work/affected-paths.tsv" || exit 1
    fi
    : > "$work/inventory-ids.txt"
    for _inv_file in "$work"/inventory.*; do
        [ -f "$_inv_file" ] || continue
        sed '1d' "$_inv_file" | cut -f 1 >> "$work/inventory-ids.txt"
    done
    awk -F '\t' -v tier="$1" '
    function fail(message) {
        print "ci-affected-paths.d: " message > "/dev/stderr"
        invalid = 1
        exit 1
    }
    { sub(/\r$/, "") }
    FILENAME == ARGV[1] {
        gates[$1] = 1
        order[++total] = $1
        kind[$1] = $6
        reviewed[$1] = 1
        if ($12 != "-") {
            count = split($12, classes, ",")
            for (i = 1; i <= count; i++) {
                if (classes[i] !~ /^(compiler|stdlib|corpus|docs)$/) fail("unknown input class: " classes[i])
                member[classes[i], $1] = 1
            }
        }
        if (kind[$1] != "-" &&
            (!member["compiler", $1] || !member["stdlib", $1] || !member["corpus", $1]))
            fail("produced compiler consumer missing source class: " $1)
        next
    }
    FILENAME == ARGV[2] {
        if ($1 != "" && !reviewed[$1]) stale = 1
        next
    }
    {
        if (NF != 4 || $1 == "" || $2 == "" || $3 == "" || $4 == "") fail("row " FNR ": expected four nonempty fields")
        if ($1 != "@always" && ($1 !~ /^[A-Za-z0-9_.*\/-]+$/ || $1 ~ /^\// || $1 ~ /(^|\/)\.\.(\/|$)/ || $1 ~ /^\*/))
            fail("row " FNR ": invalid or catch-all path: " $1)
        if (seen[$1]++) fail("row " FNR ": duplicate path: " $1)
        rows[++paths] = $0
        for (column = 2; column <= 3; column++)
            if ($column != "-" && $column != "*" && $column ~ /(^|,)(-|\*)(,|$)/)
                fail("row " FNR ": empty/full marker must stand alone")
        count = split($2 "," $3, ids, ",")
        for (i = 1; i <= count; i++) {
            if (ids[i] != "*" && ids[i] != "-" && !(ids[i] in gates) && ids[i] !~ /^@(compiler|stdlib|corpus|docs)$/)
                fail("row " FNR ": unknown gate or group: " ids[i])
        }
    }
    END {
        if (invalid) exit 1
        if (!seen["@always"]) fail("missing @always hygiene row")
        if (stale) print "[ci-affected] unreviewed gate inventory; selecting the full table" > "/dev/stderr"
        for (p = 1; p <= paths; p++) {
            split(rows[p], fields, "\t")
            if (stale) { print fields[1] "\t*\t" fields[4] "\t1"; continue }
            request = fields[2] (tier == "advisory" ? "," fields[3] : "")
            count = split(request, ids, ",")
            expanded = ""
            for (i = 1; i <= count; i++) {
                if (ids[i] == "-") continue
                if (ids[i] == "*") { expanded = "*,"; break }
                if (ids[i] !~ /^@/) expanded = expanded ids[i] ","
                else {
                    group = substr(ids[i], 2)
                    before = length(expanded)
                    for (k = 1; k <= total; k++) if (member[group, order[k]]) expanded = expanded order[k] ","
                    if (length(expanded) == before) fail("empty input group: " group)
                }
            }
            sub(/,$/, "", expanded)
            if (expanded == "") expanded = "-"
            print fields[1] "\t" expanded "\t" fields[4] "\t" (fields[2] != "-")
        }
    }
' "$work/gates-full.tsv" "$work/inventory-ids.txt" "$work/affected-paths.tsv" > "$2"
}

if [ -n "$base" ]; then
    base_oid=$(git rev-parse --verify --end-of-options "$base^{commit}") || fail "invalid base ref: $base"
    merge_base=$(git merge-base "$base_oid" HEAD) || fail "no merge base with: $base"
    paths="$work/paths.txt"
    # Git quotes unusual paths (including embedded newlines). Such quoted
    # names are unmapped and safely force the full table, never split records.
    git -c core.quotePath=true diff --no-relative --no-ext-diff --no-textconv --name-only --no-renames "$merge_base" -- > "$paths"
    git -c core.quotePath=true ls-files --others --exclude-standard >> "$paths"
    echo "[ci-affected] tier=$tier base=$base_oid merge-base=$merge_base head=$(git rev-parse HEAD); paths=$paths" >&2
fi
if [ -n "$batch" ]; then
    [ -f "$batch" ] && [ -r "$batch" ] || fail "unreadable query file: $batch"
else
    [ -f "$paths" ] && [ -r "$paths" ] || fail "unreadable path inventory: $paths"
fi

# Replays a query stream: a "@@" header (host, tier, output file; tab
# separated) followed by that record's path inventory, one path per line. Each
# record reports one job: host, output file and comma-joined selection.
match_queries() {
    awk -F '\t' -v cache="$work" -v caller="$CALLER_DIR" '
        function load_map(tier, file,   line, fields, row) {
            if (tier in loaded_map) return
            loaded_map[tier] = 1
            while ((getline line < file) > 0) {
                split(line, fields, "\t")
                row = ++row_count[tier]
                pattern[tier, row] = fields[1]
                gates[tier, row] = fields[2]
                covered[tier, row] = fields[4]
                # The map allows only literal characters, dots and stars, so a
                # dotted, starred pattern anchored at both ends matches like
                # the selector case glob.
                regex[tier, row] = "^" fields[1] "$"
                gsub(/\./, "\\.", regex[tier, row])
                gsub(/\*/, ".*", regex[tier, row])
            }
            close(file)
        }
        function load_inventory(host, file,   line, fields, lines) {
            if (host in loaded_inventory) return
            loaded_inventory[host] = 1
            lines = 0
            while ((getline line < file) > 0) {
                split(line, fields, "\t")
                if (++lines > 1) id[host, ++id_count[host]] = fields[1]
            }
            close(file)
        }
        function request(tier, row,   count, list, i) {
            if (gates[tier, row] == "*") { full = 1; return }
            if (gates[tier, row] == "-") return
            count = split(gates[tier, row], list, ",")
            for (i = 1; i <= count; i++) requested[list[i]] = 1
        }
        function record(   i, csv) {
            for (i = 1; i <= id_count[record_host]; i++)
                if (full || (id[record_host, i] in requested)) csv = csv id[record_host, i] ","
            if (csv == "") {
                print "[ci-affected] map selected no gates for this host" > "/dev/stderr"
                exit 2
            }
            sub(/,$/, "", csv)
            print record_host "\t" record_out "\t" csv
            in_record = 0
        }
        $1 == "@@" {
            if (in_record) record()
            record_host = $2
            record_tier = $3
            record_out = $4
            # Like --paths, a relative record path belongs to the caller.
            if (record_out != "-" && record_out !~ /^\// && record_out !~ /^[A-Za-z]:[\/\\]/)
                record_out = caller "/" record_out
            load_map(record_tier, cache "/map." record_tier)
            load_inventory(record_host, cache "/inventory." record_host)
            split("", requested)
            split("", contributed)
            full = 0
            for (i = 1; i <= row_count[record_tier]; i++)
                if (pattern[record_tier, i] == "@always") request(record_tier, i)
            in_record = 1
            next
        }
        in_record {
            if ($0 == "") next
            matched = 0
            for (i = 1; i <= row_count[record_tier]; i++) {
                if (pattern[record_tier, i] == "@always") continue
                if ($0 !~ regex[record_tier, i]) continue
                # An advisory class alone cannot authorize an empty required set.
                if (covered[record_tier, i] == 1) matched = 1
                # Each row contributes once, even for a repository-wide change.
                if (contributed[record_tier, i]++) continue
                request(record_tier, i)
            }
            if (!matched) {
                print "[ci-affected] unmapped path; selecting full table: " $0 > "/dev/stderr"
                full = 1
            }
            next
        }
        END { if (in_record) record() }
    '
}

# Filters requests into canonical table order before asking ci-verify for the
# actual host-specific dependency closure, once per distinct selection.
resolve_plans() {
    cut -f 1,3 "$1" | LC_ALL=C sort -u > "$work/keys"
    : > "$2"
    while IFS=$TAB read -r _affected_host _affected_csv; do
        _affected_plan=$("$ROOT/scripts/ci-verify.sh" --list-gates "$_affected_host" --gates "$_affected_csv")
        printf '%s\t%s\t%s\n' "$_affected_host" "$_affected_csv" \
            "$(printf '%s\n' "$_affected_plan" | sed '1d' | cut -f 1 | paste -sd, -)" >> "$2"
    done < "$work/keys"
}

# Writes each job's planned selection to its output file; "-" is stdout.
emit_plans() {
    awk -F '\t' '
        FILENAME == ARGV[1] { plan[$1 SUBSEP $2] = $3; next }
        {
            reference = $1 SUBSEP $3
            if (!(reference in plan)) {
                print "[ci-affected] missing plan for: " $1 > "/dev/stderr"
                failed = 1
                next
            }
            count = split(plan[reference], selected, ",")
            for (i = 1; i <= count; i++) {
                if ($2 == "-") print selected[i]
                else print selected[i] > $2
            }
            if ($2 != "-") close($2)
        }
        END { exit failed }
    ' "$1" "$2"
}

if [ -n "$batch" ]; then
    : > "$work/hosts.raw"
    : > "$work/tiers.raw"
    : > "$work/directories.raw"
    awk -F '\t' -v cache="$work" -v caller="$CALLER_DIR" '
        $1 != "@@" { next }
        NF != 4 || $4 == "-" {
            print "[ci-affected] malformed batch record: " $0 > "/dev/stderr"
            bad = 1
            next
        }
        {
            print $2 > (cache "/hosts.raw")
            print $3 > (cache "/tiers.raw")
            directory = ""
            out = ($4 !~ /^\// && $4 !~ /^[A-Za-z]:[\/\\]/) ? caller "/" $4 : $4
            count = split(out, parts, "/")
            for (i = 1; i < count; i++) directory = directory (i > 1 ? "/" : "") parts[i]
            print (directory == "" ? "." : directory) > (cache "/directories.raw")
        }
        END { if (bad) exit 2 }
    ' "$batch"
    LC_ALL=C sort -u "$work/hosts.raw" > "$work/hosts"
    LC_ALL=C sort -u "$work/tiers.raw" > "$work/tiers"
    LC_ALL=C sort -u "$work/directories.raw" > "$work/directories"
    [ -s "$work/hosts" ] || fail "no batch records: $batch"
    while IFS= read -r each; do
        [ -d "$each" ] || fail "missing batch output directory: $each"
    done < "$work/directories"
    while IFS= read -r each; do
        case "$each" in linux | windows) ;; *) fail "unsupported host: $each" ;; esac
        inventory "$each" "$work/inventory.$each"
    done < "$work/hosts"
    while IFS= read -r each; do
        case "$each" in required | advisory) ;; *) fail "unknown tier: $each" ;; esac
        expand_map "$each" "$work/map.$each"
    done < "$work/tiers"
    match_queries < "$batch" > "$work/jobs"
    resolve_plans "$work/jobs" "$work/plans"
    emit_plans "$work/plans" "$work/jobs"
else
    inventory "$host" "$work/inventory.$host"
    expand_map "$tier" "$work/map.$tier"
    { printf '@@\t%s\t%s\t-\n' "$host" "$tier"; cat "$paths"; } > "$work/query"
    match_queries < "$work/query" > "$work/jobs"
    resolve_plans "$work/jobs" "$work/plans"
    selected=$(emit_plans "$work/plans" "$work/jobs")
    printf '%s\n' "$selected"
    if [ "$run" = 1 ]; then
        # A full selection uses the original full invocation, with no subset flag.
        all_ids=$(sed '1d' "$work/inventory.$host" | cut -f 1)
        if [ "$selected" = "$all_ids" ]; then
            echo '[ci-affected] running the full host table through ci-verify.sh' >&2
            exec "$ROOT/scripts/ci-verify.sh"
        fi
        echo '[ci-affected] running a partial local preflight; full hosted CI remains required' >&2
        csv=$(printf '%s\n' "$selected" | paste -sd ',' -)
        exec "$ROOT/scripts/ci-verify.sh" --gates "$csv"
    fi
fi
[ -n "$base" ] || rm -rf -- "$work"
