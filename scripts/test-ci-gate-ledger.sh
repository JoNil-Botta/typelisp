#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-ci-gate-ledger.sh"
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-ci-ledger.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
fail() { echo "CI gate ledger self-test: $*" >&2; exit 1; }
expect_failure() {
    case_name=$1
    shift
    if "$@" > "$WORKDIR/$case_name.out" 2> "$WORKDIR/$case_name.err"; then
        fail "$case_name unexpectedly succeeded"
    fi
    test ! -s "$WORKDIR/$case_name.out" || fail "$case_name emitted partial stdout"
    grep -F 'CI gate ledger:' "$WORKDIR/$case_name.err" >/dev/null || fail "$case_name lacks diagnostic"
}
# A compact catalog exercises host projection and sequential execution without
# copying the production list into the test. The real list is checked below.
printf '%s\n' \
    '# ci-gate-ledger-schema\t2' \
    '# count\tall\t5' '# count\tlinux\t4' '# count\twindows\t4' \
    'id\thosts\tlabel\tneeds' 'first\tall\tFirst gate\t-' \
    'linux-only\tlinux\tLinux gate\tfirst' 'windows-only\twindows\tWindows gate\tfirst' \
    'shared\tall\tShared gate\tfirst,linux-only@linux' \
    'closing\tall\tClosing gate\t*' \
    | sed 's/\\t/\	/g' > "$WORKDIR/catalog.tsv"
sed 's/$/\r/' "$WORKDIR/catalog.tsv" > "$WORKDIR/catalog-crlf.tsv"
for host in linux windows; do
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" "$host"
    expected_lf_rows=$CI_GATE_LEDGER_ROWS
    ci_gate_ledger_load "$WORKDIR/catalog-crlf.tsv" "$host"
    test "$CI_GATE_LEDGER_ROWS" = "$expected_lf_rows" || fail 'CRLF projection differs'
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" "$host"
    ci_gate_ledger_enter first
    test "$CI_GATE_LEDGER_LABEL" = 'First gate' || fail 'label resolution'
    ci_gate_ledger_leave 0
    ci_gate_ledger_enter "$host-only"
    test "$CI_GATE_LEDGER_LABEL" = "$(if [ "$host" = linux ]; then echo 'Linux gate'; else echo 'Windows gate'; fi)" || fail 'host label resolution'
    test "$CI_GATE_LEDGER_NEEDS" = first || fail 'needs resolution'
    ci_gate_ledger_leave 0
    ci_gate_ledger_enter shared
    # A host-qualified need is projected only onto its own host.
    if [ "$host" = linux ]; then expected_needs=first,linux-only; else expected_needs=first; fi
    test "$CI_GATE_LEDGER_NEEDS" = "$expected_needs" || fail "host need projection: $CI_GATE_LEDGER_NEEDS"
    ci_gate_ledger_leave 0
    ci_gate_ledger_enter closing
    test "$CI_GATE_LEDGER_NEEDS" = '*' || fail 'closing needs resolution'
    ci_gate_ledger_leave 0
    ci_gate_ledger_finish
    expect_failure "duplicate-end-$host" ci_gate_ledger_enter first
    expect_failure "failed-end-$host" ci_gate_ledger_finish
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" "$host"
    expect_failure "missing-all-$host" ci_gate_ledger_finish
    ci_gate_ledger_enter first
    expect_failure "unfinished-$host" ci_gate_ledger_finish
    ci_gate_ledger_leave 0
    expect_failure "missing-tail-$host" ci_gate_ledger_finish
    expect_failure "duplicate-first-$host" ci_gate_ledger_enter first
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" "$host"
    expect_failure "out-of-order-$host" ci_gate_ledger_enter "$host-only"
    expect_failure "poisoned-order-$host" ci_gate_ledger_enter first
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" "$host"
    expect_failure "unknown-$host" ci_gate_ledger_enter unknown
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" "$host"
    ci_gate_ledger_enter first
    ci_gate_ledger_leave 0
    if [ "$host" = linux ]; then wrong=windows-only; else wrong=linux-only; fi
    expect_failure "wrong-host-$host" ci_gate_ledger_enter "$wrong"
done
expect_failure unsupported ci_gate_ledger_load "$WORKDIR/catalog.tsv" macos
expect_failure missing ci_gate_ledger_load "$WORKDIR/absent.tsv" linux
: > "$WORKDIR/empty.tsv"
expect_failure empty ci_gate_ledger_load "$WORKDIR/empty.tsv" linux
# Each mutation starts with a complete valid catalog, then changes one boundary.
for mutation in schema header id host label duplicate-id duplicate-label count fields truncated-tail truncated-record other-host \
    need-forward need-self need-unknown need-syntax need-bad-host need-inapplicable-host need-host-gap need-duplicate need-empty closing-early closing-missing; do
    case "$mutation" in
        schema) sed '1s/2/3/' "$WORKDIR/catalog.tsv" ;;
        header) sed '5s/label/name/' "$WORKDIR/catalog.tsv" ;;
        id) sed '6s/^first/Bad_ID/' "$WORKDIR/catalog.tsv" ;;
        host) sed '7s/linux\t/unix\t/' "$WORKDIR/catalog.tsv" ;;
        label) sed '6s/First gate/ First gate/' "$WORKDIR/catalog.tsv" ;;
        duplicate-id) sed '7s/^linux-only/first/' "$WORKDIR/catalog.tsv" ;;
        duplicate-label) sed '7s/Linux gate/First gate/' "$WORKDIR/catalog.tsv" ;;
        count) sed '2s/5/6/' "$WORKDIR/catalog.tsv" ;;
        fields) sed '7s/$/\	extra/' "$WORKDIR/catalog.tsv" ;;
        truncated-tail) sed '$d' "$WORKDIR/catalog.tsv" ;;
        truncated-record) head -c -1 "$WORKDIR/catalog.tsv" ;;
        other-host) sed '8s/windows\t/invalid\t/' "$WORKDIR/catalog.tsv" ;;
        # Needs: only earlier, distinct, known gates that run wherever the
        # consumer does; one closing gate, and it must be last.
        need-forward) sed '6s/-$/shared/' "$WORKDIR/catalog.tsv" ;;
        need-self) sed '7s/first$/linux-only/' "$WORKDIR/catalog.tsv" ;;
        need-unknown) sed '7s/first$/absent/' "$WORKDIR/catalog.tsv" ;;
        need-syntax) sed '7s/first$/First/' "$WORKDIR/catalog.tsv" ;;
        need-bad-host) sed '9s/@linux$/@macos/' "$WORKDIR/catalog.tsv" ;;
        need-inapplicable-host) sed '8s/first$/first@linux/' "$WORKDIR/catalog.tsv" ;;
        need-host-gap) sed '9s/@linux$//' "$WORKDIR/catalog.tsv" ;;
        need-duplicate) sed '9s/^\(.*\)first,/\1first,first,/' "$WORKDIR/catalog.tsv" ;;
        need-empty) sed '7s/first$//' "$WORKDIR/catalog.tsv" ;;
        closing-early) sed '9s/first,linux-only@linux$/*/' "$WORKDIR/catalog.tsv" ;;
        closing-missing) sed '10s/\*$/first/' "$WORKDIR/catalog.tsv" ;;
    esac > "$WORKDIR/$mutation.tsv"
    expect_failure "$mutation" ci_gate_ledger_load "$WORKDIR/$mutation.tsv" linux
    expect_failure "stale-after-$mutation" ci_gate_ledger_enter first
done
# Selection is the transitive closure of host-projected needs, in ledger order.
expect_selection() {
    selection_host=$1
    selection_request=$2
    selection_expected=$3
    selection_complete=$4
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" "$selection_host"
    ci_gate_ledger_select "$selection_request"
    selection_actual=$(printf '%s\n' "$CI_GATE_LEDGER_REMAINING" | cut -f1 | tr '\n' ' ')
    test "$selection_actual" = "$selection_expected " ||
        fail "$selection_host selection of $selection_request: got '$selection_actual'"
    test "$CI_GATE_LEDGER_COMPLETE" = "$selection_complete" ||
        fail "$selection_host selection of $selection_request: completeness $CI_GATE_LEDGER_COMPLETE"
    test "$CI_GATE_LEDGER_SELECTED_COUNT" = "$(printf '%s\n' "$selection_expected" | wc -w | tr -d ' ')" ||
        fail "$selection_host selection of $selection_request: count $CI_GATE_LEDGER_SELECTED_COUNT"
}
expect_selection linux first 'first' 0
expect_selection linux shared 'first linux-only shared' 0
expect_selection windows shared 'first shared' 0
expect_selection linux shared,first 'first linux-only shared' 0
expect_selection windows windows-only,shared 'first windows-only shared' 0
expect_selection linux closing 'first linux-only shared closing' 1
expect_selection windows closing 'first windows-only shared closing' 1
# A selection that happens to name every gate is complete too.
expect_selection linux first,linux-only,shared,closing 'first linux-only shared closing' 1
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
ci_gate_ledger_select shared
ci_gate_selected linux-only || fail 'closure need is not selected'
if ci_gate_selected windows-only 2>/dev/null; then fail 'wrong-host guard selected'; fi
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
ci_gate_ledger_select shared
if ci_gate_selected closing; then fail 'unrequested gate selected'; fi
ci_gate_ledger_unselected closing || fail 'unrequested gate is not reported as unselected'
if ci_gate_ledger_unselected unknown; then fail 'unknown gate reported as unselected'; fi
if ci_gate_ledger_unselected windows-only; then fail 'wrong-host gate reported as unselected'; fi
ci_gate_ledger_enter first
ci_gate_ledger_leave 0
expect_failure selected-out-of-order ci_gate_ledger_enter shared
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
ci_gate_ledger_select shared
ci_gate_ledger_enter first
ci_gate_ledger_leave 0
ci_gate_ledger_enter linux-only
ci_gate_ledger_leave 0
expect_failure selected-missing-tail ci_gate_ledger_finish
ci_gate_ledger_enter shared
ci_gate_ledger_leave 0
ci_gate_ledger_finish
expect_failure selected-unrequested-after-end ci_gate_ledger_enter closing
# A guard naming no gate of this host is a runner defect and poisons completion.
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
if ci_gate_selected unknown 2> "$WORKDIR/guard-unknown.err"; then fail 'unknown guard selected'; fi
grep -F 'selection guard names no linux gate: unknown' "$WORKDIR/guard-unknown.err" >/dev/null ||
    fail 'unknown guard lacks diagnostic'
expect_failure poisoned-by-unknown-guard ci_gate_ledger_enter first
ci_gate_ledger_load "$WORKDIR/catalog.tsv" windows
if ci_gate_selected linux-only 2>/dev/null; then fail 'wrong-host guard selected'; fi
expect_failure poisoned-by-wrong-host-guard ci_gate_ledger_enter first
for invalid in empty-request empty-element trailing-comma leading-comma invalid-id duplicate duplicate-closure-member unknown other-host; do
    case "$invalid" in
        empty-request) request= ;;
        empty-element) request=first,,shared ;;
        trailing-comma) request=first, ;;
        leading-comma) request=,first ;;
        invalid-id) request=First ;;
        duplicate) request=shared,shared ;;
        duplicate-closure-member) request=first,shared,first ;;
        unknown) request=first,absent ;;
        other-host) request=windows-only ;;
    esac
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
    expect_failure "select-$invalid" ci_gate_ledger_select "$request"
    expect_failure "select-$invalid-poisons" ci_gate_ledger_enter first
done
grep -F 'gate does not run on linux (windows): windows-only' "$WORKDIR/select-other-host.err" >/dev/null ||
    fail 'other-host selection is not diagnosed as such'
grep -F 'unknown gate in selection: absent' "$WORKDIR/select-unknown.err" >/dev/null ||
    fail 'unknown selection is not diagnosed as such'
# A plan narrows once, before any gate starts.
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
ci_gate_ledger_select shared
expect_failure select-twice ci_gate_ledger_select first
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
ci_gate_ledger_enter first
expect_failure select-after-start ci_gate_ledger_select shared
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
ci_gate_ledger_enter first
ci_gate_ledger_leave 0
expect_failure select-after-completed-gate ci_gate_ledger_select shared
# Source the real command wrappers, so nonzero command propagation, completion
# bookkeeping, selection skips and compiler scoping are covered at their actual
# integration boundary.
awk '/^(run_gate|run_with_compiler)\(\) \{$/ {inside=1} inside {print} inside && /^\}$/ {inside=0}' \
    "$ROOT/scripts/ci-verify.sh" > "$WORKDIR/run-gate.sh"
grep -F 'ci_gate_ledger_leave "$status"' "$WORKDIR/run-gate.sh" >/dev/null || fail 'missing actual run_gate body'
grep -F 'CI_VERIFY_GATE_COMPILER=$1' "$WORKDIR/run-gate.sh" >/dev/null || fail 'missing actual run_with_compiler body'
. "$WORKDIR/run-gate.sh"
ci_timing_enabled() { return 1; }
CI_VERIFY_NO_COMPILER="$WORKDIR/no-compiler"
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
run_gate first true > "$WORKDIR/wrapper-success.out"
set +e
run_gate linux-only sh -c 'exit 37' > "$WORKDIR/wrapper-failure.out" 2> "$WORKDIR/wrapper-failure.err"
wrapper_status=$?
set -e
test "$wrapper_status" = 37 || fail "command failure status became $wrapper_status"
expect_failure failed-command ci_gate_ledger_finish
# A gate sees only the compiler its own binding names. A gate that names none
# sees a path that cannot exist, whatever the entry environment or earlier gates
# provided, including after a skipped compiler binding.
printf '#!/usr/bin/env sh\nexit 0\n' > "$WORKDIR/stub-compiler"
chmod +x "$WORKDIR/stub-compiler"
report_compiler='printf "%s\n" "${TYPELISP_BIN-<unset>}" > "$0"'
for entry in unset set; do
    if [ "$entry" = set ]; then TYPELISP_BIN="$WORKDIR/entry-compiler"; export TYPELISP_BIN; expected_entry=$TYPELISP_BIN
    else unset TYPELISP_BIN; expected_entry='<unset>'; fi
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
    ci_gate_ledger_select shared
    run_with_compiler "$WORKDIR/stub-compiler" first sh -c "$report_compiler" "$WORKDIR/first-$entry.env" > /dev/null
    test "$(cat "$WORKDIR/first-$entry.env")" = "$WORKDIR/stub-compiler" || fail 'gate did not receive its compiler'
    test "${TYPELISP_BIN-<unset>}" = "$expected_entry" || fail 'compiler leaked into the runner environment'
    run_gate linux-only sh -c "$report_compiler" "$WORKDIR/linux-only-$entry.env" > /dev/null
    test "$(cat "$WORKDIR/linux-only-$entry.env")" = "$CI_VERIFY_NO_COMPILER" || fail 'a gate without a compiler saw one'
    run_gate shared sh -c "$report_compiler" "$WORKDIR/shared-$entry.env" > /dev/null
    # The skipped closing gate names a compiler; nothing runs and nothing leaks.
    run_with_compiler "$WORKDIR/stub-compiler" closing sh -c 'exit 99' > "$WORKDIR/skipped-$entry.out"
    test ! -s "$WORKDIR/skipped-$entry.out" || fail 'unselected gate produced output'
    test -z "${CI_VERIFY_GATE_COMPILER:-}" || fail 'skipped gate left its compiler behind'
    ci_gate_ledger_finish
done
unset TYPELISP_BIN
# A compiler that its producer never made fails the gate instead of letting the
# command fall back to another compiler.
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
set +e
run_with_compiler "$WORKDIR/unproduced/compiler" first sh -c 'exit 0' > /dev/null 2> "$WORKDIR/unproduced.err"
unproduced_status=$?
set -e
test "$unproduced_status" = 126 || fail "unproduced compiler returned $unproduced_status"
grep -F 'compiler was not produced by this run' "$WORKDIR/unproduced.err" >/dev/null || fail 'unproduced compiler lacks diagnostic'
expect_failure unproduced-compiler ci_gate_ledger_finish
# Exercise listing through the real CLI in an otherwise empty checkout. Missing
# runtime libraries/compilers make accidental execution fail immediately.
mkdir -p "$WORKDIR/list-root/scripts"
cp "$ROOT/scripts/ci-verify.sh" "$ROOT/scripts/lib-ci-gate-ledger.sh" \
    "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/list-root/scripts/"
for host in linux windows; do
    TYPELISP_BIN="$WORKDIR/nonexistent-compiler" \
    TYPELISP_CI_TIMING=1 TYPELISP_CI_COMPILER_ARTIFACT_TRACE="$WORKDIR/must-not-exist" \
        sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates "$host" \
        > "$WORKDIR/list-$host.tsv" 2> "$WORKDIR/list-$host.err"
    test ! -s "$WORKDIR/list-$host.err" || fail 'listing wrote stderr'
    test ! -e "$WORKDIR/list-root/target" || fail 'listing created target'
    test ! -e "$WORKDIR/must-not-exist" || fail 'listing initialized trace'
    ci_gate_ledger_load "$ROOT/scripts/ci-gates.tsv" "$host"
    printf 'id\thosts\tlabel\tneeds\n%s\n' "$CI_GATE_LEDGER_ROWS" > "$WORKDIR/expected-$host.tsv"
    cmp "$WORKDIR/expected-$host.tsv" "$WORKDIR/list-$host.tsv" || fail 'CLI projection mismatch'
    while IFS="$(printf '\t')" read -r gate_id gate_hosts gate_label gate_needs; do
        ci_gate_ledger_enter "$gate_id"
        test "$CI_GATE_LEDGER_LABEL" = "$gate_label" || fail 'production label mismatch'
        ci_gate_ledger_leave 0
    done <<EOF
$CI_GATE_LEDGER_ROWS
EOF
    ci_gate_ledger_finish
done
# The closure listing is equally side-effect-free and is the selection runners use.
for host in linux windows; do
    for request in bootstrap-fixpoint tlci-native-route-sustained-stress stage2-opt2-built-cli-compile-cross-fixpoint-regression gate-reachability,stage2-deterministic-assembly ci-compiler-artifact-hosted-trace-completeness; do
        TYPELISP_BIN="$WORKDIR/nonexistent-compiler" \
        TYPELISP_CI_TIMING=1 TYPELISP_CI_COMPILER_ARTIFACT_TRACE="$WORKDIR/must-not-exist" \
            sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates "$host" --gates "$request" \
            > "$WORKDIR/closure-$host.tsv" 2> "$WORKDIR/closure-$host.err"
        test ! -s "$WORKDIR/closure-$host.err" || fail 'closure listing wrote stderr'
        test ! -e "$WORKDIR/list-root/target" || fail 'closure listing created target'
        test ! -e "$WORKDIR/must-not-exist" || fail 'closure listing initialized trace'
        ci_gate_ledger_load "$ROOT/scripts/ci-gates.tsv" "$host"
        ci_gate_ledger_select "$request"
        printf 'id\thosts\tlabel\tneeds\n%s\n' "$CI_GATE_LEDGER_REMAINING" > "$WORKDIR/expected-closure-$host.tsv"
        cmp "$WORKDIR/expected-closure-$host.tsv" "$WORKDIR/closure-$host.tsv" || fail "closure CLI projection mismatch: $request"
    done
    # Every production need of a selected gate is selected and precedes it.
    awk -F '\t' 'NR > 1 {
        if ($4 == "*") { if (NR - 2 != total) exit 1 }
        else if ($4 != "-") { n = split($4, need, ","); for (i = 1; i <= n; i++) if (!(need[i] in seen)) exit 1 }
        seen[$1] = 1; total++
    }' "$WORKDIR/closure-$host.tsv" || fail "$host closure is not dependency-closed"
    test "$(awk 'END {print NR - 1}' "$WORKDIR/closure-$host.tsv")" = "$(awk 'END {print NR - 1}' "$WORKDIR/expected-$host.tsv")" ||
        fail "$host closing-gate closure is not the complete inventory"
done
ci_gate_ledger_load "$ROOT/scripts/ci-gates.tsv" linux
ci_gate_ledger_select stage2-opt2-built-cli-compile-cross-fixpoint-regression
test "$(printf '%s\n' "$CI_GATE_LEDGER_REMAINING" | cut -f1 | tr '\n' ' ')" = 'bootstrap-fixpoint stage2-opt1-opt2-build-invariance stage2-opt2-built-cli-compile-cross-fixpoint-regression ' ||
    fail 'Linux opt2 closure lost its build-invariance reference producer'
ci_gate_ledger_load "$ROOT/scripts/ci-gates.tsv" windows
ci_gate_ledger_select stage2-opt2-built-cli-compile-cross-fixpoint-regression
test "$(printf '%s\n' "$CI_GATE_LEDGER_REMAINING" | cut -f1 | tr '\n' ' ')" = 'bootstrap-fixpoint stage2-opt2-built-cli-compile-cross-fixpoint-regression ' ||
    fail 'Windows opt2 closure is not its standalone reference compile'
expect_failure list-closure-unknown sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates linux --gates absent-gate
expect_failure list-closure-other-host sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates windows --gates stage2-opt1-opt2-build-invariance
expect_failure list-closure-empty sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates linux --gates ''
for bad_args in missing extra closure-missing closure-flag closure-extra run-missing run-extra run-flag run-empty; do
    case "$bad_args" in
        missing) set -- --list-gates ;;
        extra) set -- --list-gates linux extra ;;
        closure-missing) set -- --list-gates linux --gates ;;
        closure-flag) set -- --list-gates linux --only gate-reachability ;;
        closure-extra) set -- --list-gates linux --gates gate-reachability extra ;;
        run-missing) set -- --gates ;;
        run-extra) set -- --gates gate-reachability extra ;;
        run-flag) set -- --only gate-reachability ;;
        run-empty) set -- --gates '' ;;
    esac
    set +e
    sh "$WORKDIR/list-root/scripts/ci-verify.sh" "$@" > "$WORKDIR/args.out" 2> "$WORKDIR/args.err"
    args_status=$?
    set -e
    test "$args_status" = 2 || fail "invalid arguments ($bad_args) must exit 2"
    test ! -s "$WORKDIR/args.out" || fail "invalid arguments ($bad_args) emitted output"
    grep -F 'usage:' "$WORKDIR/args.err" >/dev/null || fail 'missing listing usage'
done
# The complete entrypoint must check bookkeeping, then leave through the partial
# result unless the plan is complete, before either success signal.
awk '
    /^ci_gate_ledger_finish$/ {finish++; position=NR}
    /^if \[ "\$CI_GATE_LEDGER_COMPLETE" != 1 \]; then$/ {if (finish != 1) exit 1; partial++; partial_line=NR}
    partial_line && !partial_exit && /^    exit 0$/ {partial_exit=NR}
    /ci_timing_record_verification_complete/ {if (finish != 1 || !partial_exit || partial_exit >= NR) exit 1; timing++}
    /^echo "CI verification passed"$/ {if (finish != 1 || !partial_exit || partial_exit >= NR) exit 1; success++}
    END {if (finish != 1 || partial != 1 || timing != 1 || success != 1) exit 1}
' "$ROOT/scripts/ci-verify.sh" || fail 'completion must guard both success signals'
sed 's/$/\r/' "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/list-root/scripts/ci-gates.tsv"
for host in linux windows; do
    sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates "$host" > "$WORKDIR/crlf-list-$host.tsv"
    cmp "$WORKDIR/expected-$host.tsv" "$WORKDIR/crlf-list-$host.tsv" || fail 'CRLF CLI projection mismatch'
done
ci_gate_ledger_validate_bindings "$WORKDIR/list-root/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh"
expect_failure list-unsupported sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates unsupported
cp "$WORKDIR/other-host.tsv" "$WORKDIR/list-root/scripts/ci-gates.tsv"
expect_failure list-malformed sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates linux
ci_gate_ledger_validate_bindings "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh"
sed '/^run_gate cli-gate-inventory-and-ownership /d' "$ROOT/scripts/ci-verify.sh" > "$WORKDIR/missing-binding.sh"
expect_failure missing-binding ci_gate_ledger_validate_bindings "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/missing-binding.sh"
sed 's/^run_gate cli-gate-inventory-and-ownership /run_gate unknown-ledger-id /' "$ROOT/scripts/ci-verify.sh" > "$WORKDIR/unknown-binding.sh"
expect_failure unknown-binding ci_gate_ledger_validate_bindings "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/unknown-binding.sh"
# The needs column must follow the runner and the artifact inventory in both
# directions. Each mutation changes one production fact and must be rejected.
INVENTORY="$ROOT/scripts/ci-compiler-artifacts.tsv"
REUSE_CONSUMER=stage2-cross-mode-semantic-abi-differential
REUSE_MANIFEST="$ROOT/tests/cross-mode/corpus.tsv"
ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint "$REUSE_CONSUMER" "$REUSE_MANIFEST"
tab=$(printf '\t')
sed "s/^\\(stage2-safety-corpus${tab}.*${tab}\\)bootstrap-fixpoint\$/\\1-/" "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/needs-missing-compiler.tsv"
cmp -s "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/needs-missing-compiler.tsv" && fail 'compiler-need mutation did not apply'
expect_failure needs-missing-compiler ci_gate_ledger_validate_needs "$WORKDIR/needs-missing-compiler.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint "$REUSE_CONSUMER" "$REUSE_MANIFEST"
sed "s/^\\(stage2-deterministic-assembly${tab}.*${tab}\\)bootstrap-fixpoint,stage2-selfhost-compile-manifest\$/\\1bootstrap-fixpoint/" "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/needs-missing-artifact.tsv"
cmp -s "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/needs-missing-artifact.tsv" && fail 'artifact-need mutation did not apply'
expect_failure needs-missing-artifact ci_gate_ledger_validate_needs "$WORKDIR/needs-missing-artifact.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint "$REUSE_CONSUMER" "$REUSE_MANIFEST"
sed "s/^\\(stage2-safety-corpus${tab}.*${tab}\\)bootstrap-fixpoint\$/\\1bootstrap-fixpoint,embedded-stdlib-tlci-image/" "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/needs-unjustified.tsv"
cmp -s "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/needs-unjustified.tsv" && fail 'unjustified-need mutation did not apply'
expect_failure needs-unjustified ci_gate_ledger_validate_needs "$WORKDIR/needs-unjustified.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint "$REUSE_CONSUMER" "$REUSE_MANIFEST"
# A gate whose binding names no produced compiler does not need the bootstrap;
# scheduling it behind one would hide that it is independent.
sed "s/^\\(integration-manifest-validator-self-tests${tab}.*${tab}\\)-\$/\\1bootstrap-fixpoint/" "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/needs-compiler-unnamed.tsv"
cmp -s "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/needs-compiler-unnamed.tsv" && fail 'unnamed-compiler mutation did not apply'
expect_failure needs-compiler-unnamed ci_gate_ledger_validate_needs "$WORKDIR/needs-compiler-unnamed.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint "$REUSE_CONSUMER" "$REUSE_MANIFEST"
# Dropping a compiler from a binding without dropping the need is drift too.
sed 's|^run_with_compiler "$STAGE2_BIN" benchmark-wall-clock-harness-self-tests |run_gate benchmark-wall-clock-harness-self-tests |' "$ROOT/scripts/ci-verify.sh" > "$WORKDIR/unnamed-compiler.sh"
cmp -s "$ROOT/scripts/ci-verify.sh" "$WORKDIR/unnamed-compiler.sh" && fail 'unnamed-compiler binding mutation did not apply'
expect_failure unnamed-compiler-binding ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/unnamed-compiler.sh" "$INVENTORY" bootstrap-fixpoint "$REUSE_CONSUMER" "$REUSE_MANIFEST"
# A host-qualified edge must not be widened away: the Windows opt2 gate does not
# consume the Linux-only build-invariance reference.
sed 's/stage2-opt1-opt2-build-invariance@linux$/stage2-opt1-opt2-build-invariance/' "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/needs-widened-host.tsv"
cmp -s "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/needs-widened-host.tsv" && fail 'host-widening mutation did not apply'
expect_failure needs-widened-host ci_gate_ledger_load "$WORKDIR/needs-widened-host.tsv" windows
# The inventory gaining a consumer the ledger does not know about is drift too.
awk -F '\t' 'BEGIN {OFS=FS} {print} $2 == "manifest-deterministic-consumer" {$2="drifted-consumer"; $3="stage2 safety corpus"; print}' "$INVENTORY" > "$WORKDIR/inventory-new-consumer.tsv"
expect_failure inventory-new-consumer ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$WORKDIR/inventory-new-consumer.tsv" bootstrap-fixpoint "$REUSE_CONSUMER" "$REUSE_MANIFEST"
# A harness gate that starts naming the produced compiler has moved behind it.
sed 's|^run_gate ci-timing-helper-self-tests scripts/verify-ci-timing.sh$|run_gate ci-timing-helper-self-tests scripts/verify-ci-timing.sh "$STAGE2_BIN"|' "$ROOT/scripts/ci-verify.sh" > "$WORKDIR/early-compiler.sh"
cmp -s "$ROOT/scripts/ci-verify.sh" "$WORKDIR/early-compiler.sh" && fail 'early-compiler mutation did not apply'
expect_failure early-compiler ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/early-compiler.sh" "$INVENTORY" bootstrap-fixpoint "$REUSE_CONSUMER" "$REUSE_MANIFEST"
expect_failure unknown-compiler-gate ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" absent-gate "$REUSE_CONSUMER" "$REUSE_MANIFEST"
expect_failure missing-inventory ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$WORKDIR/absent-inventory.tsv" bootstrap-fixpoint "$REUSE_CONSUMER" "$REUSE_MANIFEST"
# The cross-mode differential reuses artifacts that other gates leave behind;
# its corpus names each producer gate, and the ledger must follow it exactly.
expect_failure missing-reuse-manifest ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint "$REUSE_CONSUMER" "$WORKDIR/absent-reuse.tsv"
expect_failure unknown-reuse-consumer ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint absent-gate "$REUSE_MANIFEST"
reuse_mutation() {
    reuse_name=$1
    reuse_catalog=$2
    reuse_manifest=$3
    expect_failure "$reuse_name" ci_gate_ledger_validate_needs "$reuse_catalog" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint "$REUSE_CONSUMER" "$reuse_manifest"
}
mutate_reuse_needs() {
    awk -F '\t' -v from="$1" -v to="$2" 'BEGIN {OFS=FS} $1 == "stage2-cross-mode-semantic-abi-differential" {changed=sub(from, to, $4)} {print} END {if (!changed) exit 1}' \
        "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/$3.tsv" || fail "reuse needs mutation did not apply: $3"
}
mutate_reuse_row() {
    awk -F '\t' -v case_name="$1" -v field="$2" -v value="$3" 'BEGIN {OFS=FS} $1 == case_name {$field=value; changed=1} {print} END {if (!changed) exit 1}' \
        "${5:-$REUSE_MANIFEST}" > "$WORKDIR/$4.tsv" || fail "reuse row mutation did not apply: $4"
}
mutate_reuse_needs ',stage2-spmd-simd-comparison$' '' reuse-missing-need
reuse_mutation reuse-missing-need "$WORKDIR/reuse-missing-need.tsv" "$REUSE_MANIFEST"
mutate_reuse_needs 'stage2-windows-coff-batch-plan@windows' 'stage2-windows-coff-batch-plan' reuse-widened-need
reuse_mutation reuse-widened-need "$WORKDIR/reuse-widened-need.tsv" "$REUSE_MANIFEST"
mutate_reuse_needs 'stage2-windows-coff-batch-plan@windows' 'stage2-windows-coff-batch-plan@linux' reuse-wrong-host-need
reuse_mutation reuse-wrong-host-need "$WORKDIR/reuse-wrong-host-need.tsv" "$REUSE_MANIFEST"
mutate_reuse_needs 'stage2-native-integration-corpus,' 'stage2-native-integration-corpus,stage2-examples,' reuse-unjustified-need
reuse_mutation reuse-unjustified-need "$WORKDIR/reuse-unjustified-need.tsv" "$REUSE_MANIFEST"
mutate_reuse_row spmd-tail-avx2 10 stage2-examples reuse-unneeded-producer
reuse_mutation reuse-unneeded-producer "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/reuse-unneeded-producer.tsv"
mutate_reuse_row spmd-tail-avx2 10 absent-gate reuse-unknown-producer
reuse_mutation reuse-unknown-producer "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/reuse-unknown-producer.tsv"
mutate_reuse_row spmd-tail-avx2 10 stage2-spmd-lane-identity reuse-later-producer
reuse_mutation reuse-later-producer "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/reuse-later-producer.tsv"
mutate_reuse_row windows-direct-object 3 linux reuse-row-host-mismatch
reuse_mutation reuse-row-host-mismatch "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/reuse-row-host-mismatch.tsv"
# A Windows-only producer cannot serve a Linux row.
mutate_reuse_row windows-direct-object 10 windows-integration-linker-queue-self-test reuse-producer-host-step
mutate_reuse_row windows-direct-object 3 linux reuse-producer-host "$WORKDIR/reuse-producer-host-step.tsv"
reuse_mutation reuse-producer-host "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/reuse-producer-host.tsv"
grep -F 'reuse manifest producer does not run on linux: windows-integration-linker-queue-self-test' \
    "$WORKDIR/reuse-producer-host.err" >/dev/null || fail 'producer host coverage is not diagnosed'
mutate_reuse_row spmd-tail-avx2 3 macos reuse-invalid-hosts
reuse_mutation reuse-invalid-hosts "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/reuse-invalid-hosts.tsv"
# Execute the real runner on a selection in a fixture checkout whose only gate
# commands are stubs for the two selected gates, one before and one after the
# bootstrap position. Every other binding and all setup those two gates do not
# own must stay inert on both host branches: the fixture has no seed, fetch
# script, compiler or other gate script, so anything else that runs fails.
RUN_ROOT="$WORKDIR/run-root"
mkdir -p "$RUN_ROOT/scripts" "$RUN_ROOT/perf" "$WORKDIR/run-bin"
for runner_file in ci-verify.sh ci-gates.tsv lib-ci-gate-ledger.sh lib-linux-entry.sh \
    lib-ci-timing.sh lib-benchmark-ci-cases.sh lib-ci-compiler-artifact.sh; do
    cp "$ROOT/scripts/$runner_file" "$RUN_ROOT/scripts/"
done
cp "$ROOT/perf/benchmark-ci-cases.tsv" "$RUN_ROOT/perf/"
for stub in check-gate-reachability verify-integration-manifest-validator; do
    cat > "$RUN_ROOT/scripts/$stub.sh" <<'EOF'
#!/usr/bin/env sh
printf '%s %s %s\n' "$(basename "$0" .sh)" "$*" "${TYPELISP_BIN-<unset>}" >> "$RUN_LOG"
case $(basename "$0" .sh) in
    "${STUB_FAIL:-}") exit 3 ;;
esac
EOF
    chmod +x "$RUN_ROOT/scripts/$stub.sh"
done
cat > "$WORKDIR/run-bin/uname" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$RUN_UNAME"
EOF
chmod +x "$WORKDIR/run-bin/uname"
RUN_SELECTION=gate-reachability,integration-manifest-validator-self-tests
run_selection() (
    PATH="$WORKDIR/run-bin:$PATH" RUN_UNAME=$1 RUN_LOG="$WORKDIR/run.log" \
        TYPELISP_CI_TIMING=1 sh "$RUN_ROOT/scripts/ci-verify.sh" --gates "$2"
)
for host in linux windows; do
    if [ "$host" = linux ]; then run_uname=Linux; else run_uname=MINGW64_NT-10.0; fi
    rm -rf "$RUN_ROOT/target" "$WORKDIR/run.log"
    ci_gate_ledger_load "$ROOT/scripts/ci-gates.tsv" "$host"
    host_gate_count=$CI_GATE_LEDGER_HOST_COUNT
    (unset TYPELISP_BIN; run_selection "$run_uname" "$RUN_SELECTION") \
        > "$WORKDIR/run-$host.out" 2> "$WORKDIR/run-$host.err" ||
        { cat "$WORKDIR/run-$host.out" "$WORKDIR/run-$host.err" >&2; fail "$host selected run failed"; }
    no_compiler="$RUN_ROOT/target/ci-verify-unproduced/gate-names-no-compiler"
    printf '%s\n' \
        "check-gate-reachability --self-test $no_compiler" \
        "verify-integration-manifest-validator  $no_compiler" > "$WORKDIR/run-expected.log"
    cmp "$WORKDIR/run-expected.log" "$WORKDIR/run.log" || fail "$host selected run executed other commands or environments"
    test "$(grep -c '^\[ci-verify\] START ' "$WORKDIR/run-$host.out")" = 2 || fail "$host selected run started other gates"
    grep -Fx "[ci-verify] partial run: 2 of $host_gate_count $host gates" \
        "$WORKDIR/run-$host.out" >/dev/null || fail "$host partial run lacks its selection summary"
    grep -Fx '[ci-verify]   requested gate-reachability' "$WORKDIR/run-$host.out" >/dev/null ||
        fail "$host partial run does not list its requested gates"
    grep -Fx "CI verification partial: 2 of $host_gate_count $host gates passed; this is not a complete verification" \
        "$WORKDIR/run-$host.out" >/dev/null || fail "$host partial run lacks its partial result"
    grep -F 'CI verification passed' "$WORKDIR/run-$host.out" >/dev/null && fail "$host partial run reported verification success"
    test ! -e "$RUN_ROOT/target/stage0" || fail "$host partial run fetched a seed it does not use"
    awk -F '\t' '
        NR == 1 {next}
        $3 == "complete-verification" {exit 1}
        $3 == "gate" {gates = gates $1 ";"}
        END {if (gates != "gate reachability;integration manifest validator self-tests;") exit 1}
    ' "$RUN_ROOT/target/ci-timing/$host.tsv" || fail "$host partial run timing rows are not exactly its gates"
    # A failed selected gate stops the run without a partial success.
    rm -f "$WORKDIR/run.log"
    set +e
    (unset TYPELISP_BIN; STUB_FAIL=check-gate-reachability; export STUB_FAIL
        run_selection "$run_uname" "$RUN_SELECTION") > "$WORKDIR/run-fail-$host.out" 2>&1
    run_status=$?
    set -e
    test "$run_status" = 3 || fail "$host failed selected gate returned $run_status"
    test "$(wc -l < "$WORKDIR/run.log" | tr -d ' ')" = 1 || fail "$host run continued after a failed gate"
    grep -F 'CI verification partial' "$WORKDIR/run-fail-$host.out" >/dev/null && fail "$host failed run reported a partial success"
    # A selection whose closure contains the bootstrap requires its seed before
    # any gate starts.
    set +e
    TYPELISP_BIN="$WORKDIR/absent-seed" run_selection "$run_uname" stage2-safety-corpus \
        > "$WORKDIR/run-seed-$host.out" 2>&1
    run_status=$?
    set -e
    test "$run_status" != 0 || fail "$host bootstrap selection ran without a seed"
    grep -F 'seed compiler does not exist' "$WORKDIR/run-seed-$host.out" >/dev/null || fail "$host missing seed lacks diagnostic"
    grep -F '[ci-verify] START' "$WORKDIR/run-seed-$host.out" >/dev/null && fail "$host started a gate without its seed"
    expect_failure "run-unknown-$host" run_selection "$run_uname" absent-gate
    grep -F '[ci-verify] START' "$WORKDIR/run-unknown-$host.err" >/dev/null && fail "$host started a gate for an invalid selection"
done
printf '%s\n' 'CI gate ledger self-tests passed'
