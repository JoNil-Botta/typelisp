#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p "$ROOT/target/exp/ci-affected-test"
work=$(mktemp -d "$ROOT/target/exp/ci-affected-test/run.XXXXXX")
selector="$ROOT/scripts/ci-affected.sh"
TAB=$(printf '\t')
fail() { echo "ci-affected self-test: $* (evidence: $work)" >&2; exit 1; }
has_gate() { grep -Fx "$2" "$1" >/dev/null || fail "missing $2 in $1"; }

# Exercise Git's actual Windows checkout filter, including the provenance
# table and byte-compared historical paths. Their LF attributes must win.
for path in scripts/ci-affected-paths.tsv scripts/ci-affected-inputs.tsv tests/fixtures/ci-affected/*.paths tests/fixtures/ci-affected/history.tsv; do
    git cat-file blob ":$path" > "$work/checkout.expected"
    git -c core.autocrlf=true cat-file --filters --path="$path" ":$path" > "$work/checkout.actual"
    cmp "$work/checkout.actual" "$work/checkout.expected" || fail "Windows checkout changed line endings: $path"
done

for host in linux windows; do
    "$ROOT/scripts/ci-verify.sh" --list-gates "$host" > "$work/$host.table"
    sed '1d' "$work/$host.table" | cut -f 1 > "$work/$host.full"
    while IFS=$TAB read -r pr run base head gate; do
        case "$pr" in \#* | pr) continue ;; esac
        "$selector" --host "$host" --paths "$ROOT/tests/fixtures/ci-affected/$pr.paths" > "$work/$host-$pr.ids" 2> "$work/$host-$pr.log"
        has_gate "$work/$host-$pr.ids" "$gate"
        # Check the captured original diff when history is available. Shallow
        # checkouts still run the regression offline from the committed fixture.
        if git cat-file -e "$base^{commit}" 2>/dev/null && git cat-file -e "$head^{commit}" 2>/dev/null; then
            git diff --name-only --no-renames "$base...$head" > "$work/$pr.actual"
            cmp "$work/$pr.actual" "$ROOT/tests/fixtures/ci-affected/$pr.paths" || fail "historical paths differ for #$pr run $run"
        fi
    done < "$ROOT/tests/fixtures/ci-affected/history.tsv"

    # Isolate the original triggering paths, so unrelated unmapped files in a
    # historical change cannot mask a missing compiler/stdlib map row.
    for path in src/compiler_backend_tests.tl src/compiler_backend.tl src/compiler_target_cfg.tl stdlib/json.tl tests/safety/division_by_zero_trap.tl; do
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" --tier advisory > "$work/trigger.ids"
        has_gate "$work/trigger.ids" stage2-codegen-target-parity
        has_gate "$work/trigger.ids" stage2-safety-corpus
        has_gate "$work/trigger.ids" tlci-mutation-bootstrap-fixpoint
        case "$path" in
            src/*)
                has_gate "$work/trigger.ids" x64-executable-template-registry-coverage
                has_gate "$work/trigger.ids" compiler-state-schema-boundary ;;
            tests/*)
                has_gate "$work/trigger.ids" cross-mode-differential-oracle-self-tests
                has_gate "$work/trigger.ids" integration-manifest-validator-self-tests ;;
        esac
        has_gate "$work/trigger.ids" zero-cons-fixture-and-embedded-source-invariant
        awk -F '\t' '!/^#/ && $1 != "id" && $5 != "-" {print $1}' "$ROOT/scripts/ci-gates.tsv" |
        while IFS= read -r gate; do
            if grep -Fx "$gate" "$work/$host.full" >/dev/null; then has_gate "$work/trigger.ids" "$gate"; fi
        done
        [ "$(wc -l < "$work/trigger.ids")" -lt "$(wc -l < "$work/$host.full")" ] || fail "source class selected the full table: $path"
        if grep -Fx linux-resident-memory-limit-helper-self-tests "$work/trigger.ids" >/dev/null; then
            fail 'source class includes unrelated memory-helper fixtures'
        fi
        "$selector" --host "$host" --paths "$work/paths" > "$work/required.ids"
        has_gate "$work/required.ids" stage2-codegen-target-parity
        case "$path" in stdlib/* | tests/safety/*) has_gate "$work/required.ids" stage2-safety-corpus ;; esac
        sort "$work/required.ids" > "$work/required.sorted"
        sort "$work/trigger.ids" > "$work/advisory.sorted"
        comm -23 "$work/required.sorted" "$work/advisory.sorted" > "$work/missing-advisory.ids"
        [ ! -s "$work/missing-advisory.ids" ] || fail 'required tier is not included in advisory'
    done
    # Every literal corpus input in a canonical gate command has an owning
    # required trigger, independently of the advisory input classifications.
    awk -F '\t' '!/^#/ && $1 != "id" {n = split($8, words, " "); for (i = 1; i <= n; i++) if (words[i] ~ /^tests\/[A-Za-z0-9._\/-]+$/) print words[i] "\t" $1}' "$ROOT/scripts/ci-gates.tsv" > "$work/literal-inputs.tsv"
    while IFS=$TAB read -r path gate; do
        if ! grep -Fx "$gate" "$work/$host.full" >/dev/null; then continue; fi
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/literal.ids"
        has_gate "$work/literal.ids" "$gate"
    done < "$work/literal-inputs.tsv"
    for row in 'scripts/codegen-target-dispatch-inventory.tsv stage2-codegen-target-parity'; do
        path=${row% *}
        gate=${row##* }
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/subset.ids"
        "$ROOT/scripts/ci-verify.sh" --list-gates "$host" --gates "shared-view-count-ratchet,typelisp-source-formatting,typelisp-source-lint,$gate" > "$work/subset.table"
        sed '1d' "$work/subset.table" | cut -f 1 > "$work/subset.expected"
        cmp "$work/subset.ids" "$work/subset.expected" || fail "wrong dependency closure: $path"
    done
    printf '%s\n' tests/safety/manifest.txt scripts/codegen-target-dispatch-inventory.tsv tests/safety/manifest.txt > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" > "$work/union.ids"
    has_gate "$work/union.ids" stage2-safety-corpus
    has_gate "$work/union.ids" stage2-codegen-target-parity
    [ "$(sort "$work/union.ids" | uniq -d | wc -l)" -eq 0 ] || fail 'duplicate gate IDs'
    printf '%s\n' 'unmapped/new file.tl' > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" > "$work/unknown.ids" 2> "$work/unknown.log"
    cmp "$work/unknown.ids" "$work/$host.full" || fail 'unmapped path did not select full table'
    for path in scripts/ci-verify.sh .github/workflows/ci.yml tests/public-tools/example.sh tests/fixtures/ci-affected/history.tsv; do
        printf '%s\n' "$path" > "$work/paths"
        "$selector" --host "$host" --paths "$work/paths" > "$work/harness.ids"
        cmp "$work/harness.ids" "$work/$host.full" || fail "harness path did not select full table: $path"
    done
    printf '%s\n' docs/testing-guide.md > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" --tier advisory > "$work/docs.ids"
    has_gate "$work/docs.ids" stage2-docs-pages-build-path
    has_gate "$work/docs.ids" stage2-repository-doctests
    if grep -Fx stage2-opt1-opt2-build-invariance "$work/docs.ids" >/dev/null; then fail 'prose selected build invariance'; fi
    printf '%s\n' src/compiler_backend.tl > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" --tier advisory > "$work/one-source.ids"
    awk 'BEGIN {for (i = 1; i <= 128; i++) print "src/compiler_large_" i ".tl"}' > "$work/paths"
    "$selector" --host "$host" --paths "$work/paths" --tier advisory > "$work/many-source.ids"
    cmp "$work/one-source.ids" "$work/many-source.ids" || fail 'large source changes expanded duplicate requests'
done

# Exercise real Git diff discovery and the execution boundary in an isolated
# repository. Only its ci-verify entry point is a recording stub; its listing
# delegates to the real planner above. There is no production command override.
repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/tests/safety"
printf '/target/\n' > "$repo/.gitignore"
cp "$selector" "$ROOT/scripts/ci-affected-paths.tsv" "$ROOT/scripts/ci-affected-inputs.tsv" "$ROOT/scripts/ci-gates.tsv" "$repo/scripts/"
cat > "$repo/scripts/ci-verify.sh" <<'STUB'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = --list-gates ]; then exec "$CI_AFFECTED_TEST_VERIFY" "$@"; fi
printf '%s\n' "$TYPELISP_INLINE_TEST_WORKERS" "$TYPELISP_BUILD_INVARIANCE_WORKERS" "$TYPELISP_INTEGRATION_WORKERS" "$TYPELISP_COMPILE_MANIFEST_WORKERS" "$@" > "$CI_AFFECTED_TEST_CALL"
printf 'run\n' >> "$CI_AFFECTED_TEST_EXECUTIONS"
exit "${CI_AFFECTED_TEST_EXIT:-0}"
STUB
chmod +x "$repo/scripts/ci-verify.sh"
export CI_AFFECTED_TEST_VERIFY="$ROOT/scripts/ci-verify.sh"
export CI_AFFECTED_TEST_CALL="$work/run.call"
export CI_AFFECTED_TEST_EXECUTIONS="$work/run.executions"
: > "$CI_AFFECTED_TEST_EXECUTIONS"
printf 'initial\n' > "$repo/tests/safety/manifest.txt"
git -C "$repo" init -q
git -C "$repo" add .
git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
base=$(git -C "$repo" rev-parse HEAD)
fixture_selector="$repo/scripts/ci-affected.sh"
: > "$work/empty.paths"
"$fixture_selector" --paths "$work/empty.paths" > "$work/empty.ids"
has_gate "$work/empty.ids" shared-view-count-ratchet
has_gate "$work/empty.ids" typelisp-source-formatting
has_gate "$work/empty.ids" typelisp-source-lint
printf 'unstaged\n' >> "$repo/tests/safety/manifest.txt"
"$fixture_selector" --base "$base" > "$work/unstaged.ids" 2> "$work/unstaged.log"
has_gate "$work/unstaged.ids" stage2-safety-corpus
git -C "$repo" add tests/safety/manifest.txt
"$fixture_selector" --base "$base" > "$work/staged.ids" 2> "$work/staged.log"
cmp "$work/staged.ids" "$work/unstaged.ids" || fail 'staged edit missed'
git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm edit
"$fixture_selector" --base "$base" > "$work/committed.ids" 2> "$work/committed.log"
cmp "$work/staged.ids" "$work/committed.ids" || fail 'committed edit missed'

case "$(uname -s)" in Linux*) native_host=linux ;; *) native_host=windows ;; esac
env -u TYPELISP_INLINE_TEST_WORKERS -u TYPELISP_BUILD_INVARIANCE_WORKERS -u TYPELISP_INTEGRATION_WORKERS -u TYPELISP_COMPILE_MANIFEST_WORKERS "$fixture_selector" --base "$base" --run > "$work/run.ids" 2> "$work/run.log"
sed -n '1,4p' "$work/run.call" > "$work/workers.actual"
printf '1\n1\n1\n1\n' > "$work/workers.expected"
cmp "$work/workers.actual" "$work/workers.expected" || fail 'worker defaults were not exported as 1'
sed -n '5p' "$work/run.call" | grep -Fx -- --gates >/dev/null || fail 'subset was not passed to ci-verify'
tr '\n' ',' < "$work/committed.ids" | sed 's/,$//' > "$work/run.expected-csv"
sed -n '6p' "$work/run.call" | tr -d '\n' > "$work/run.actual-csv"
cmp "$work/run.actual-csv" "$work/run.expected-csv" || fail 'executed selection differs from printed selection'

expect_rejected() {
    label=$1
    shift
    cp "$CI_AFFECTED_TEST_EXECUTIONS" "$work/rejected.before"
    status=0
    "$@" > "$work/$label.out" 2> "$work/$label.err" || status=$?
    [ "$status" -ne 0 ] || fail "$label was accepted"
    [ ! -s "$work/$label.out" ] || fail "$label emitted a successful plan before failing"
    cmp "$CI_AFFECTED_TEST_EXECUTIONS" "$work/rejected.before" || fail "$label executed a gate"
}
expect_rejected inline-workers env TYPELISP_INLINE_TEST_WORKERS=2 "$fixture_selector" --base "$base" --run
expect_rejected invariance-workers env TYPELISP_BUILD_INVARIANCE_WORKERS=2 "$fixture_selector" --base "$base" --run
expect_rejected integration-workers env TYPELISP_INTEGRATION_WORKERS=2 "$fixture_selector" --base "$base" --run
expect_rejected manifest-workers env TYPELISP_COMPILE_MANIFEST_WORKERS=2 "$fixture_selector" --base "$base" --run
for name in TYPELISP_INLINE_TEST_WORKERS TYPELISP_BUILD_INVARIANCE_WORKERS TYPELISP_INTEGRATION_WORKERS TYPELISP_COMPILE_MANIFEST_WORKERS; do
    expect_rejected "empty-$name" env "$name=" "$fixture_selector" --base "$base" --run
    expect_rejected "three-$name" env "$name=3" "$fixture_selector" --base "$base" --run
done
expect_rejected invalid-base "$fixture_selector" --base no-such-ref --run
expect_rejected invalid-tier "$fixture_selector" --base "$base" --tier invalid --run
expect_rejected paths-cannot-run "$fixture_selector" --paths "$work/empty.paths" --run
other_host=windows
[ "$native_host" != windows ] || other_host=linux
expect_rejected foreign-host "$fixture_selector" --base "$base" --host "$other_host" --run
status=0
CI_AFFECTED_TEST_EXIT=19 "$fixture_selector" --base "$base" --run > "$work/exit.out" 2> "$work/exit.err" || status=$?
[ "$status" = 19 ] || fail "ci-verify failure not propagated: $status"

# Deletion must keep its old mapped path; renames must include both paths.
git -C "$repo" mv tests/safety/manifest.txt unknown.txt
"$fixture_selector" --base "$base" > "$work/renamed.ids" 2> "$work/renamed.log"
cmp "$work/renamed.ids" "$work/$native_host.full" || fail 'rename destination did not fail safe'
git -C "$repo" reset -q --hard "$base"
git -C "$repo" update-index --force-remove tests/safety/manifest.txt
mv "$repo/tests/safety/manifest.txt" "$work/deleted-manifest.txt"
"$fixture_selector" --base "$base" > "$work/deleted.ids" 2> "$work/deleted.log"
has_gate "$work/deleted.ids" stage2-safety-corpus
printf 'unknown\n' > "$repo/untracked file.txt"
"$fixture_selector" --base "$base" --run > "$work/untracked.ids" 2> "$work/untracked.log"
cmp "$work/untracked.ids" "$work/$native_host.full" || fail 'untracked path did not select full table'
[ "$(wc -l < "$work/run.call")" -eq 4 ] || fail 'full run added a subset flag'
mv "$repo/untracked file.txt" "$work/untracked-file.txt"
printf 'unknown\n' > "$repo/line
break.txt"
"$fixture_selector" --base "$base" > "$work/unusual.ids" 2> "$work/unusual.log"
cmp "$work/unusual.ids" "$work/$native_host.full" || fail 'unusual path did not fail safe'

# Base-only drift is excluded by merge-base; a ref/HEAD direct diff would
# incorrectly include the other branch edit and select the full table.
git -C "$repo" checkout -q -b other-base "$base"
printf 'base drift\n' > "$repo/base-only.txt"
git -C "$repo" add base-only.txt
git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm drift
drift=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q --detach "$base"
# Use a clean tracked-only fixture for this assertion; earlier untracked
# artifacts remain in this repo, so move them to its task-owned evidence root.
mv "$repo/line
break.txt" "$work/newline-file.txt"
"$fixture_selector" --base "$drift" > "$work/drift.ids" 2> "$work/drift.log"
cmp "$work/drift.ids" "$work/empty.ids" || fail 'base-only drift entered selection'
printf 'unknown/path\tnot-a-real-gate\t-\tinvalid test row\n' >> "$repo/scripts/ci-affected-paths.tsv"
expect_rejected invalid-map "$fixture_selector" --base "$base" --run
cp "$ROOT/scripts/ci-affected-paths.tsv" "$repo/scripts/ci-affected-paths.tsv"
printf 'tests/*\tstage2-safety-corpus\t-\tduplicate test row\n' >> "$repo/scripts/ci-affected-paths.tsv"
expect_rejected duplicate-map "$fixture_selector" --base "$base"
awk -F '\t' -v OFS='\t' '$1 == "tests/*" {$2 = ""} {print}' "$ROOT/scripts/ci-affected-paths.tsv" > "$repo/scripts/ci-affected-paths.tsv"
cp "$work/run.call" "$work/empty-map-before.call"
expect_rejected empty-gates "$fixture_selector" --base "$base" --run
cmp "$work/run.call" "$work/empty-map-before.call" || fail 'invalid map executed a gate'
cp "$ROOT/scripts/ci-affected-paths.tsv" "$repo/scripts/ci-affected-paths.tsv"
sed '$d' "$ROOT/scripts/ci-affected-inputs.tsv" > "$repo/scripts/ci-affected-inputs.tsv"
printf '%s\n' src/compiler_backend.tl > "$work/paths"
"$fixture_selector" --paths "$work/paths" > "$work/unreviewed-gate.ids" 2> "$work/unreviewed-gate.log"
cmp "$work/unreviewed-gate.ids" "$work/$native_host.full" || fail 'unreviewed gate inventory did not fail to full'
cp "$ROOT/scripts/ci-affected-inputs.tsv" "$repo/scripts/ci-affected-inputs.tsv"
printf 'bad-gate\tinvalid-class\tinvalid fixture\n' >> "$repo/scripts/ci-affected-inputs.tsv"
expect_rejected invalid-input-class "$fixture_selector" --base "$base"

echo "ci-affected self-tests passed (Linux/Windows plans and checkout filters, three historical failed-run diffs, Git discovery, worker guards and execution); evidence: $work"
