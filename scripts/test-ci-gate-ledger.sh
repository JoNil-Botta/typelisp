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
# Source the real command wrapper, so nonzero command propagation and completion
# bookkeeping are covered at their actual integration boundary.
awk '/^run_gate\(\) \{$/ {inside=1} inside {print} inside && /^\}$/ {exit}' \
    "$ROOT/scripts/ci-verify.sh" > "$WORKDIR/run-gate.sh"
grep -F 'ci_gate_ledger_leave "$status"' "$WORKDIR/run-gate.sh" >/dev/null || fail 'missing actual run_gate body'
. "$WORKDIR/run-gate.sh"
ci_timing_enabled() { return 1; }
ci_gate_ledger_load "$WORKDIR/catalog.tsv" linux
run_gate first true > "$WORKDIR/wrapper-success.out"
set +e
run_gate linux-only sh -c 'exit 37' > "$WORKDIR/wrapper-failure.out" 2> "$WORKDIR/wrapper-failure.err"
wrapper_status=$?
set -e
test "$wrapper_status" = 37 || fail "command failure status became $wrapper_status"
expect_failure failed-command ci_gate_ledger_finish
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
for bad_args in missing extra; do
    if [ "$bad_args" = missing ]; then set -- --list-gates; else set -- --list-gates linux extra; fi
    set +e
    sh "$WORKDIR/list-root/scripts/ci-verify.sh" "$@" > "$WORKDIR/args.out" 2> "$WORKDIR/args.err"
    args_status=$?
    set -e
    test "$args_status" = 2 || fail "invalid listing arity must exit 2"
    test ! -s "$WORKDIR/args.out" || fail "invalid listing arity emitted output"
    grep -F 'usage:' "$WORKDIR/args.err" >/dev/null || fail 'missing listing usage'
done
# The complete entrypoint must check bookkeeping before either success signal.
awk '
    /^ci_gate_ledger_finish$/ {finish++; position=NR}
    /ci_timing_record_verification_complete/ {if (finish != 1 || position >= NR) exit 1; timing++}
    /^echo "CI verification passed"$/ {if (finish != 1 || position >= NR) exit 1; success++}
    END {if (finish != 1 || timing != 1 || success != 1) exit 1}
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
ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint
tab=$(printf '\t')
sed "s/^\\(stage2-safety-corpus${tab}.*${tab}\\)bootstrap-fixpoint\$/\\1-/" "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/needs-missing-compiler.tsv"
cmp -s "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/needs-missing-compiler.tsv" && fail 'compiler-need mutation did not apply'
expect_failure needs-missing-compiler ci_gate_ledger_validate_needs "$WORKDIR/needs-missing-compiler.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint
sed "s/^\\(stage2-deterministic-assembly${tab}.*${tab}\\)bootstrap-fixpoint,stage2-selfhost-compile-manifest\$/\\1bootstrap-fixpoint/" "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/needs-missing-artifact.tsv"
cmp -s "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/needs-missing-artifact.tsv" && fail 'artifact-need mutation did not apply'
expect_failure needs-missing-artifact ci_gate_ledger_validate_needs "$WORKDIR/needs-missing-artifact.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint
sed "s/^\\(stage2-safety-corpus${tab}.*${tab}\\)bootstrap-fixpoint\$/\\1bootstrap-fixpoint,embedded-stdlib-tlci-image/" "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/needs-unjustified.tsv"
cmp -s "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/needs-unjustified.tsv" && fail 'unjustified-need mutation did not apply'
expect_failure needs-unjustified ci_gate_ledger_validate_needs "$WORKDIR/needs-unjustified.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" bootstrap-fixpoint
# A host-qualified edge must not be widened away: the Windows opt2 gate does not
# consume the Linux-only build-invariance reference.
sed 's/stage2-opt1-opt2-build-invariance@linux$/stage2-opt1-opt2-build-invariance/' "$ROOT/scripts/ci-gates.tsv" > "$WORKDIR/needs-widened-host.tsv"
cmp -s "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/needs-widened-host.tsv" && fail 'host-widening mutation did not apply'
expect_failure needs-widened-host ci_gate_ledger_load "$WORKDIR/needs-widened-host.tsv" windows
# The inventory gaining a consumer the ledger does not know about is drift too.
awk -F '\t' 'BEGIN {OFS=FS} {print} $2 == "manifest-deterministic-consumer" {$2="drifted-consumer"; $3="stage2 safety corpus"; print}' "$INVENTORY" > "$WORKDIR/inventory-new-consumer.tsv"
expect_failure inventory-new-consumer ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$WORKDIR/inventory-new-consumer.tsv" bootstrap-fixpoint
# A harness gate that starts naming the produced compiler has moved behind it.
sed 's|^run_gate ci-timing-helper-self-tests scripts/verify-ci-timing.sh$|run_gate ci-timing-helper-self-tests scripts/verify-ci-timing.sh "$STAGE2_BIN"|' "$ROOT/scripts/ci-verify.sh" > "$WORKDIR/early-compiler.sh"
cmp -s "$ROOT/scripts/ci-verify.sh" "$WORKDIR/early-compiler.sh" && fail 'early-compiler mutation did not apply'
expect_failure early-compiler ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/early-compiler.sh" "$INVENTORY" bootstrap-fixpoint
expect_failure unknown-compiler-gate ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$INVENTORY" absent-gate
expect_failure missing-inventory ci_gate_ledger_validate_needs "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh" "$WORKDIR/absent-inventory.tsv" bootstrap-fixpoint
printf '%s\n' 'CI gate ledger self-tests passed'
