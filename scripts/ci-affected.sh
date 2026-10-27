#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
TAB=$(printf '\t')

usage() {
    cat >&2 <<'USAGE'
usage: scripts/ci-affected.sh --base REF [--host linux|windows] [--run]
       scripts/ci-affected.sh --paths FILE [--host linux|windows]
       scripts/ci-affected.sh --self-test

Print dependency-closed gate IDs, one per line, using ci-affected-paths.tsv.
--base compares the merge base of REF and HEAD with the working tree, including
staged, unstaged, deleted, renamed (both paths) and nonignored untracked files.
Unknown paths select the full host table. Invalid refs/maps fail before running.
--run executes the selection through ci-verify.sh, with one gate at a time and
TYPELISP_INLINE_TEST_WORKERS=1 / TYPELISP_BUILD_INVARIANCE_WORKERS=1. Unset worker
counts default to 1; explicit other values fail. Hosted CI is unchanged.
--paths replays a newline-delimited path inventory for auditing; it cannot run.
USAGE
}

fail() { echo "[ci-affected] $*" >&2; exit 2; }
base=
paths=
run=0
host=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base | --paths | --host)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
            case "$1" in
                --base) [ -z "$base" ] || fail 'duplicate --base'; base=$2 ;;
                --paths) [ -z "$paths" ] || fail 'duplicate --paths'; paths=$2 ;;
                --host) [ -z "$host" ] || fail 'duplicate --host'; host=$2 ;;
            esac
            shift 2 ;;
        --run) [ "$run" = 0 ] || fail 'duplicate --run'; run=1; shift ;;
        --self-test)
            [ "$#" = 1 ] && [ -z "$base$paths$host" ] && [ "$run" = 0 ] || fail '--self-test must stand alone'
            exec "$ROOT/scripts/test-ci-affected.sh" ;;
        -h | --help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
[ -n "$base$paths" ] || { usage; exit 2; }
[ -z "$base" ] || [ -z "$paths" ] || fail 'choose --base or --paths'
[ "$run" = 0 ] || [ -n "$base" ] || fail '--run requires --base'

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
[ "$TYPELISP_INLINE_TEST_WORKERS" = 1 ] || fail 'TYPELISP_INLINE_TEST_WORKERS must be 1 for local preflight'
[ "$TYPELISP_BUILD_INVARIANCE_WORKERS" = 1 ] || fail 'TYPELISP_BUILD_INVARIANCE_WORKERS must be 1 for local preflight'
export TYPELISP_INLINE_TEST_WORKERS TYPELISP_BUILD_INVARIANCE_WORKERS

# Reuse the canonical table validator and dependency planner; do not duplicate
# their graph/host semantics. Listing needs no compiler or runtime setup.
inventory=$("$ROOT/scripts/ci-verify.sh" --list-gates "$host")
map="$ROOT/scripts/ci-affected-paths.tsv"
awk -F '\t' '
    function fail(message) {
        print "ci-affected-paths.tsv: " message > "/dev/stderr"
        invalid = 1
        exit 1
    }
    { sub(/\r$/, "") }
    FNR == NR { if (!/^#/ && $1 != "id") gates[$1] = 1; next }
    /^#/ { next }
    !header {
        if ($0 != "path\tgates\treason") fail("expected path/gates/reason header")
        header = 1
        next
    }
    {
        if (NF != 3 || $3 == "") fail("line " FNR ": expected three nonempty fields")
        if ($1 != "@always" && ($1 !~ /^[A-Za-z0-9_.*\/-]+$/ || $1 ~ /^\// || $1 ~ /(^|\/)\.\.(\/|$)/ || $1 == "*"))
            fail("line " FNR ": invalid or catch-all path: " $1)
        if (seen[$1]++) fail("line " FNR ": duplicate path: " $1)
        if ($2 == "*") next
        count = split($2, ids, ",")
        for (i = 1; i <= count; i++) {
            if (!(ids[i] in gates)) fail("line " FNR ": unknown gate: " ids[i])
        }
    }
    END {
        if (invalid) exit 1
        if (!header || !seen["@always"]) fail("missing header or @always hygiene row")
    }
' "$ROOT/scripts/ci-gates.tsv" "$map"

if [ -n "$base" ]; then
    base_oid=$(git rev-parse --verify --end-of-options "$base^{commit}") || fail "invalid base ref: $base"
    merge_base=$(git merge-base "$base_oid" HEAD) || fail "no merge base with: $base"
    mkdir -p "$ROOT/target/exp"
    work=$(mktemp -d "$ROOT/target/exp/ci-affected.XXXXXX")
    paths="$work/paths.txt"
    # Git quotes unusual paths (including embedded newlines). Such quoted
    # names are unmapped and safely force the full table, never split records.
    git -c core.quotePath=true diff --no-relative --no-ext-diff --no-textconv --name-only --no-renames "$merge_base" -- > "$paths"
    git -c core.quotePath=true ls-files --others --exclude-standard >> "$paths"
    echo "[ci-affected] base=$base_oid merge-base=$merge_base head=$(git rev-parse HEAD); paths=$paths" >&2
fi
[ -f "$paths" ] && [ -r "$paths" ] || fail "unreadable path inventory: $paths"

requested=,
full=0
while IFS=$TAB read -r pattern gates reason; do
    if [ "$pattern" = '@always' ]; then
        if [ "$gates" = '*' ]; then full=1; else requested="$requested$gates,"; fi
    fi
done < "$map"
while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    matched=0
    while IFS=$TAB read -r pattern gates reason; do
        case "$pattern" in '' | \#* | path | @always) continue ;; esac
        case "$path" in $pattern)
            matched=1
            if [ "$gates" = '*' ]; then full=1; else requested="$requested$gates,"; fi ;;
        esac
    done < "$map"
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
