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
    '# ci-gate-ledger-schema\t1' \
    '# count\tall\t3' '# count\tlinux\t2' '# count\twindows\t2' \
    'id\thosts\tlabel' 'first\tall\tFirst gate' \
    'linux-only\tlinux\tLinux gate' 'windows-only\twindows\tWindows gate' \
    | sed 's/\\t/\	/g' > "$WORKDIR/catalog.tsv"
for host in linux windows; do
    ci_gate_ledger_load "$WORKDIR/catalog.tsv" "$host"
    ci_gate_ledger_enter first
    test "$CI_GATE_LEDGER_LABEL" = 'First gate' || fail 'label resolution'
    ci_gate_ledger_leave 0
    ci_gate_ledger_enter "$host-only"
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
for mutation in schema header id host label duplicate-id duplicate-label count fields truncated-tail truncated-record other-host; do
    case "$mutation" in
        schema) sed '1s/1/2/' "$WORKDIR/catalog.tsv" ;;
        header) sed '5s/label/name/' "$WORKDIR/catalog.tsv" ;;
        id) sed '6s/^first/Bad_ID/' "$WORKDIR/catalog.tsv" ;;
        host) sed '7s/linux\t/unix\t/' "$WORKDIR/catalog.tsv" ;;
        label) sed '6s/First gate/ First gate/' "$WORKDIR/catalog.tsv" ;;
        duplicate-id) sed '7s/^linux-only/first/' "$WORKDIR/catalog.tsv" ;;
        duplicate-label) sed '7s/Linux gate/First gate/' "$WORKDIR/catalog.tsv" ;;
        count) sed '2s/3/4/' "$WORKDIR/catalog.tsv" ;;
        fields) sed '7s/$/\	extra/' "$WORKDIR/catalog.tsv" ;;
        truncated-tail) sed '$d' "$WORKDIR/catalog.tsv" ;;
        truncated-record) head -c -1 "$WORKDIR/catalog.tsv" ;;
        other-host) sed '8s/windows\t/invalid\t/' "$WORKDIR/catalog.tsv" ;;
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
    printf 'id\thosts\tlabel\n%s\n' "$CI_GATE_LEDGER_ROWS" > "$WORKDIR/expected-$host.tsv"
    cmp "$WORKDIR/expected-$host.tsv" "$WORKDIR/list-$host.tsv" || fail 'CLI projection mismatch'
    while IFS="$(printf '\t')" read -r gate_id gate_hosts gate_label; do
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
expect_failure list-unsupported sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates unsupported
cp "$WORKDIR/other-host.tsv" "$WORKDIR/list-root/scripts/ci-gates.tsv"
expect_failure list-malformed sh "$WORKDIR/list-root/scripts/ci-verify.sh" --list-gates linux
ci_gate_ledger_validate_bindings "$ROOT/scripts/ci-gates.tsv" "$ROOT/scripts/ci-verify.sh"
sed '/^run_gate cli-gate-inventory-and-ownership /d' "$ROOT/scripts/ci-verify.sh" > "$WORKDIR/missing-binding.sh"
expect_failure missing-binding ci_gate_ledger_validate_bindings "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/missing-binding.sh"
sed 's/^run_gate cli-gate-inventory-and-ownership /run_gate unknown-ledger-id /' "$ROOT/scripts/ci-verify.sh" > "$WORKDIR/unknown-binding.sh"
expect_failure unknown-binding ci_gate_ledger_validate_bindings "$ROOT/scripts/ci-gates.tsv" "$WORKDIR/unknown-binding.sh"
printf '%s\n' 'CI gate ledger self-tests passed'
