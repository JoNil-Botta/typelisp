#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/target/exp/fetch-work-queue-tests"
WORKDIR=$(mktemp -d "$ROOT/target/exp/fetch-work-queue-tests/run.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir "$WORKDIR/bin"
cat > "$WORKDIR/bin/gh" <<'EOF'
#!/usr/bin/env sh
set -eu
lane=$1
shift
[ "$1" = list ]
[ "$2" = --repo ]
[ "$3" = fixture/queue ]
[ "$4" = --state ]
[ "$5" = open ]
[ "$6" = --limit ]
limit=$7
[ "$8" = --json ]
case "$lane" in
    pr) [ "$9" = number,title,body,headRefName,baseRefName,isDraft,labels,statusCheckRollup ] ;;
    issue) [ "$9" = number,title,labels ] ;;
    *) exit 90 ;;
esac
printf '%s %s\n' "$lane" "$limit" >> "$FETCH_TEST_CALLS"
if [ "$lane" = issue ]; then
    case "$FETCH_TEST_CASE" in
        api-failure) printf '[{"number":'; echo 'fixture API failure' >&2; exit 17 ;;
        invalid-json) printf 'not JSON'; exit 0 ;;
        multiple-documents) printf '[]\n[]\n'; exit 0 ;;
        empty-output) exit 0 ;;
        object) printf '{}\n'; exit 0 ;;
        negative-id) printf '[{"number":-1,"title":"x","labels":[]}]\n'; exit 0 ;;
        fractional-id) printf '[{"number":1.5,"title":"x","labels":[]}]\n'; exit 0 ;;
        string-id) printf '[{"number":"1","title":"x","labels":[]}]\n'; exit 0 ;;
        bad-labels) printf '[{"number":1,"title":"x","labels":[{}]}]\n'; exit 0 ;;
        duplicate) printf '[{"number":1,"title":"x","labels":[]},{"number":1,"title":"y","labels":[]}]\n'; exit 0 ;;
    esac
fi
count=557
if [ "$lane" = pr ]; then count=1; fi
case "$FETCH_TEST_CASE" in
    empty) count=0 ;;
    grow)
        if [ "$lane" = pr ]; then count=1001; else count=10001; fi
        if [ "$count" -gt "$limit" ]; then count=$limit; fi
        ;;
    saturated) count=$limit ;;
    oversize) count=$((limit + 1)) ;;
esac
jq -n --arg lane "$lane" --argjson count "$count" '
    [range(1; $count + 1) |
        {number:.,title:("record " + tostring),labels:[]} |
        if $lane == "pr" then
            . + {body:"Fixes #557\nDepends on #556",headRefName:"feature",baseRefName:"main",isDraft:true,
                labels:[{name:"review-claimed"}],statusCheckRollup:[{status:"IN_PROGRESS"}]}
        elif .number == 557 then .labels = [{name:"ready-for-implementation"},{name:"p0"}]
        else . end]
' | case "$FETCH_TEST_CASE" in
    bad-pr) jq '.[0].body = null' ;;
    bad-draft) jq '.[0].isDraft = "false"' ;;
    bad-checks) jq '.[0].statusCheckRollup = {}' ;;
    null-checks) jq 'if .[0].isDraft then .[0].statusCheckRollup = null else . end' ;;
    *) cat ;;
esac
EOF
chmod +x "$WORKDIR/bin/gh"
PATH="$WORKDIR/bin:$PATH"
FETCH_TEST_CALLS="$WORKDIR/calls"
export PATH FETCH_TEST_CALLS
run_case() {
    FETCH_TEST_CASE=$1
    export FETCH_TEST_CASE
    : > "$FETCH_TEST_CALLS"
    sh "$ROOT/scripts/fetch-work-queue.sh" fixture/queue > "$WORKDIR/out" 2> "$WORKDIR/err"
}
run_case complete
jq -e '.issues | length == 557' "$WORKDIR/out" >/dev/null
jq -e '.issues[-1] | .number == 557 and .labels == [{name:"ready-for-implementation"},{name:"p0"}]' "$WORKDIR/out" >/dev/null
jq -e '.prs[0] | .isDraft and .labels[0].name == "review-claimed" and .body == "Fixes #557\nDepends on #556" and .statusCheckRollup[0].status == "IN_PROGRESS"' "$WORKDIR/out" >/dev/null
[ "$(wc -l < "$FETCH_TEST_CALLS" | tr -d ' ')" = 2 ] || fail 'complete input retried'
# Filtering occurs after the complete raw capture; the late p0 survives.
jq '.issues |= map(select(any(.labels[]; .name == "ready-for-implementation" or .name == "needs-research")))' "$WORKDIR/out" > "$WORKDIR/filtered"
jq -e '.issues | length == 1 and .[0].number == 557' "$WORKDIR/filtered" >/dev/null
run_case empty
jq -e '. == {prs:[],issues:[]}' "$WORKDIR/out" >/dev/null
run_case null-checks
jq -e '.prs[0].statusCheckRollup == null' "$WORKDIR/out" >/dev/null
run_case grow
jq -e '(.prs | length) == 1001 and (.issues | length) == 10001' "$WORKDIR/out" >/dev/null
printf 'pr 1000\npr 2000\nissue 10000\nissue 20000\n' > "$WORKDIR/expected-calls"
cmp "$FETCH_TEST_CALLS" "$WORKDIR/expected-calls" || fail 'reached limits were not increased'
for failure in api-failure invalid-json multiple-documents empty-output object negative-id fractional-id string-id bad-labels duplicate bad-pr bad-draft bad-checks oversize saturated; do
    if run_case "$failure"; then fail "accepted $failure"; fi
    [ ! -s "$WORKDIR/out" ] || fail "$failure emitted a partial snapshot"
    grep -F 'no snapshot emitted' "$WORKDIR/err" >/dev/null || fail "$failure has no actionable diagnostic"
done
[ "$(wc -l < "$FETCH_TEST_CALLS" | tr -d ' ')" = 4 ] || fail 'repeated saturation did not stop at the bound'
grep -F 'complete gh api pagination' "$WORKDIR/err" >/dev/null
if sh "$ROOT/scripts/fetch-work-queue.sh" fixture/queue extra > "$WORKDIR/out" 2> "$WORKDIR/err"; then
    fail 'accepted extra arguments'
fi
[ ! -s "$WORKDIR/out" ] || fail 'usage failure emitted a snapshot'
echo 'work queue fetch boundary: all cases passed'
