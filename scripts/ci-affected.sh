#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CALLER_DIR=$PWD
cd "$ROOT"
TAB=$(printf '\t')

usage() {
    cat >&2 <<'USAGE'
usage: scripts/ci-affected.sh --base REF [--tier required|advisory] [--host linux|windows] [--run]
       scripts/ci-affected.sh --paths FILE [--tier required|advisory] [--host linux|windows]
       scripts/ci-affected.sh --self-test

Print the required local minimum gate IDs using ci-affected-paths.tsv.
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
USAGE
}

fail() { echo "[ci-affected] $*" >&2; exit 2; }
base=
paths=
run=0
host=
tier=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base | --paths | --host | --tier)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
            case "$1" in
                --base) [ -z "$base" ] || fail 'duplicate --base'; base=$2 ;;
                --paths)
                    [ -z "$paths" ] || fail 'duplicate --paths'
                    paths=$2
                    case "$paths" in /* | [A-Za-z]:[/\\]*) ;; *) paths="$CALLER_DIR/$paths" ;; esac ;;
                --host) [ -z "$host" ] || fail 'duplicate --host'; host=$2 ;;
                --tier) [ -z "$tier" ] || fail 'duplicate --tier'; tier=$2 ;;
            esac
            shift 2 ;;
        --run) [ "$run" = 0 ] || fail 'duplicate --run'; run=1; shift ;;
        --self-test)
            [ "$#" = 1 ] && [ -z "$base$paths$host$tier" ] && [ "$run" = 0 ] || fail '--self-test must stand alone'
            exec "$ROOT/scripts/test-ci-affected.sh" ;;
        -h | --help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
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
inventory=$("$ROOT/scripts/ci-verify.sh" --list-gates "$host")
map="$ROOT/scripts/ci-affected-paths.tsv"
expanded_map=$(awk -F '\t' -v tier="$tier" '
    function fail(message) {
        print "ci-affected-paths.tsv: " message > "/dev/stderr"
        invalid = 1
        exit 1
    }
    { sub(/\r$/, "") }
    FILENAME == ARGV[1] {
        if (!/^#/ && $1 != "id") { gates[$1] = 1; order[++total] = $1; kind[$1] = $5 }
        next
    }
    FILENAME == ARGV[2] {
        if (/^#/) next
        if (!inputs_header++) {
            if ($0 != "id\tclasses\treason") fail("expected input id/classes/reason header")
            next
        }
        if (NF != 3 || $1 == "" || $2 == "" || $3 == "") fail("empty input classification")
        if (reviewed[$1]++) fail("duplicate input classification: " $1)
        if (!($1 in gates)) stale = 1
        if ($2 != "-") {
            count = split($2, classes, ",")
            for (i = 1; i <= count; i++) {
                if (classes[i] !~ /^(compiler|stdlib|corpus|docs)$/) fail("unknown input class: " classes[i])
                member[classes[i], $1] = 1
            }
        }
        if (kind[$1] != "-" && ($1 in gates) &&
            (!member["compiler", $1] || !member["stdlib", $1] || !member["corpus", $1]))
            fail("produced compiler consumer missing source class: " $1)
        next
    }
    /^#/ { next }
    !header {
        if ($0 != "path\trequired\tadvisory\treason") fail("expected path/required/advisory/reason header")
        header = 1
        next
    }
    {
        if (NF != 4 || $1 == "" || $2 == "" || $3 == "" || $4 == "") fail("line " FNR ": expected four nonempty fields")
        if ($1 != "@always" && ($1 !~ /^[A-Za-z0-9_.*\/-]+$/ || $1 ~ /^\// || $1 ~ /(^|\/)\.\.(\/|$)/ || $1 ~ /^\*/))
            fail("line " FNR ": invalid or catch-all path: " $1)
        if (seen[$1]++) fail("line " FNR ": duplicate path: " $1)
        rows[++paths] = $0
        count = split($2 "," $3, ids, ",")
        for (i = 1; i <= count; i++) {
            if (ids[i] != "*" && ids[i] != "-" && !(ids[i] in gates) && ids[i] !~ /^@(compiler|stdlib|corpus|docs)$/)
                fail("line " FNR ": unknown gate or group: " ids[i])
        }
    }
    END {
        if (invalid) exit 1
        if (!header || !seen["@always"]) fail("missing header or @always hygiene row")
        if (!inputs_header) fail("missing reviewed input classes")
        for (k = 1; k <= total; k++) if (!reviewed[order[k]]) stale = 1
        if (stale) print "[ci-affected] unreviewed gate inventory; selecting the full table" > "/dev/stderr"
        for (p = 1; p <= paths; p++) {
            split(rows[p], fields, "\t")
            if (stale) { print fields[1] "\t*\t" fields[4]; continue }
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
            print fields[1] "\t" expanded "\t" fields[4]
        }
    }
' "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-affected-inputs.tsv" "$map")

if [ -n "$base" ]; then
    base_oid=$(git rev-parse --verify --end-of-options "$base^{commit}") || fail "invalid base ref: $base"
    merge_base=$(git merge-base "$base_oid" HEAD) || fail "no merge base with: $base"
    mkdir -p "$ROOT/target/exp/ci-affected"
    work=$(mktemp -d "$ROOT/target/exp/ci-affected/run.XXXXXX")
    paths="$work/paths.txt"
    # Git quotes unusual paths (including embedded newlines). Such quoted
    # names are unmapped and safely force the full table, never split records.
    git -c core.quotePath=true diff --no-relative --no-ext-diff --no-textconv --name-only --no-renames "$merge_base" -- > "$paths"
    git -c core.quotePath=true ls-files --others --exclude-standard >> "$paths"
    echo "[ci-affected] tier=$tier base=$base_oid merge-base=$merge_base head=$(git rev-parse HEAD); paths=$paths" >&2
fi
[ -f "$paths" ] && [ -r "$paths" ] || fail "unreadable path inventory: $paths"

requested=,
full=0
contributed=,
add_requested() {
    _affected_old_ifs=$IFS
    IFS=,
    for _affected_id in $1; do
        case "$requested" in *",$_affected_id,"*) ;; *) requested="$requested$_affected_id," ;; esac
    done
    IFS=$_affected_old_ifs
}
while IFS=$TAB read -r pattern gates reason; do
    if [ "$pattern" = '@always' ]; then
        if [ "$gates" = '*' ]; then full=1; elif [ "$gates" != - ]; then add_requested "$gates"; fi
    fi
done <<EOF
$expanded_map
EOF
while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    matched=0
    while IFS=$TAB read -r pattern gates reason; do
        case "$pattern" in '' | \#* | path | @always) continue ;; esac
        case "$path" in $pattern)
            matched=1
            # Each row contributes once, even for a repository-wide change.
            # Otherwise repeated group IDs can exceed the shell argv limit.
            case "$contributed" in *",$pattern,"*) continue ;; esac
            contributed="$contributed$pattern,"
            if [ "$gates" = '*' ]; then full=1; elif [ "$gates" != - ]; then add_requested "$gates"; fi ;;
        esac
    done <<EOF
$expanded_map
EOF
    if [ "$matched" = 0 ]; then
        echo "[ci-affected] unmapped path; selecting full table: $path" >&2
        full=1
    fi
done < "$paths"

# Filter requests into canonical table order and remove duplicates before
# asking ci-verify for the actual host-specific dependency closure.
ids=$(printf '%s\n' "$inventory" | awk -F '\t' -v full="$full" -v request="$requested" '
    NR > 1 && (full || index(request, "," $1 ",")) { print $1 }')
[ -n "$ids" ] || fail 'map selected no gates for this host'
csv=$(printf '%s\n' "$ids" | paste -sd ',' -)
plan=$("$ROOT/scripts/ci-verify.sh" --list-gates "$host" --gates "$csv")
selected=$(printf '%s\n' "$plan" | sed '1d' | cut -f 1)
printf '%s\n' "$selected"
if [ "$run" = 1 ]; then
    # A full selection uses the original full invocation, with no subset flag.
    all_ids=$(printf '%s\n' "$inventory" | sed '1d' | cut -f 1)
    if [ "$selected" = "$all_ids" ]; then
        echo '[ci-affected] running the full host table through ci-verify.sh' >&2
        exec "$ROOT/scripts/ci-verify.sh"
    fi
    echo '[ci-affected] running a partial local preflight; full hosted CI remains required' >&2
    csv=$(printf '%s\n' "$selected" | paste -sd ',' -)
    exec "$ROOT/scripts/ci-verify.sh" --gates "$csv"
fi
