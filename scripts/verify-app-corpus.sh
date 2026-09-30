#!/usr/bin/env sh
set -eu

# verify-app-corpus.sh - run the application workflow corpus (tests/apps,
# #7772) against TYPELISP_BIN.
#
# Every scenario in tests/apps/scenarios.tsv is a case of
# tests/apps/<app>.cases, run by scripts/verify-codegen-cases.sh in its own
# work directory outside the checkout, with no TYPELISP_STDLIB_ROOT, so a
# project sees only the compiler under test and its own files. The manifest and
# the case files must name the same scenarios exactly once; a scenario declared
# for this host must report exactly one PASS. Results, the compiler and
# toolchain identity, each scenario's wall time and process-tree peak memory
# go to $APP_CORPUS_OUT (default target/app-corpus) and are printed at the end,
# so the gate log publishes them. A failing scenario keeps
# its work directory, copies it there as <scenario>.work, and prints the
# command that replays it.
#
# A release smoke runs the same corpus against a published compiler:
#   scripts/fetch-stage0.sh <tag> target/release-smoke
#   TYPELISP_BIN=target/release-smoke/typelisp scripts/verify-app-corpus.sh

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
GATE_FAIL_PREFIX="app-corpus: "
. "$ROOT/scripts/lib-gate.sh"

if [ -z "${TYPELISP_BIN:-}" ]; then
    fail "TYPELISP_BIN must name the compiler under test"
fi
gate_compiler
gate_compiler_absolute
gate_require_compiler
TYPELISP_BIN=$COMPILER
export TYPELISP_BIN
unset TYPELISP_STDLIB_ROOT || true

case "$(uname -s)" in
    Linux*) HOST=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST=windows ;;
    *) fail "unsupported host: $(uname -s)" ;;
esac

MANIFEST=tests/apps/scenarios.tsv
OUT=${APP_CORPUS_OUT:-$ROOT/target/app-corpus}
SCENARIO_MEMORY_MIB=${APP_CORPUS_SCENARIO_MEMORY_MIB:-1024}
rm -rf "$OUT"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/typelisp-apps.XXXXXX")
# The work directory is kept only for a failed scenario, to replay it.
KEEP_WORK=0
trap 'if [ "$KEEP_WORK" -eq 0 ]; then rm -rf "$WORK"; fi' EXIT
case "$WORK" in
    "$ROOT"/*) fail "work directory $WORK is inside the checkout" ;;
esac

# Manifest rows: scenario, app, hosts (all, linux or windows), workflows,
# owners. Comment and blank lines are skipped.
manifest_rows() {
    grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$' || true
}

[ -f "$MANIFEST" ] || fail "missing $MANIFEST"
manifest_rows | awk -F '\t' '
    NF != 5 { printf "%s:%d: expected 5 tab-separated fields, found %d\n", FILENAME, NR, NF; bad = 1 }
    $3 != "all" && $3 != "linux" && $3 != "windows" { printf "scenario %s: hosts must be all, linux or windows\n", $1; bad = 1 }
    seen[$1]++ == 1 { printf "scenario %s is declared twice\n", $1; bad = 1 }
    END { exit bad }
' FILENAME="$MANIFEST" >&2 || fail "invalid manifest $MANIFEST"

APPS=$(manifest_rows | cut -f2 | sort -u)
[ -n "$APPS" ] || fail "$MANIFEST declares no scenarios"

# The case files and the manifest must name the same scenarios, each once.
for app in $APPS; do
    cases="tests/apps/$app.cases"
    [ -f "$cases" ] || fail "app $app has no $cases"
    [ -f "tests/apps/$app/typelisp.pkg" ] || fail "app $app has no tests/apps/$app/typelisp.pkg"
    CODEGEN_CASES_WORKDIR="$WORK/list" sh scripts/verify-codegen-cases.sh --list "$cases" \
        | awk '{ print $2 }' | sort > "$OUT/$app.listed"
    manifest_rows | awk -F '\t' -v app="$app" '$2 == app { print $1 }' | sort > "$OUT/$app.declared"
    duplicate=$(uniq -d "$OUT/$app.listed")
    [ -z "$duplicate" ] || fail "$cases runs a scenario more than once (a variant axis?): $duplicate"
    if ! cmp -s "$OUT/$app.listed" "$OUT/$app.declared"; then
        echo "app-corpus: $cases and $MANIFEST disagree (< cases only, > manifest only):" >&2
        diff "$OUT/$app.listed" "$OUT/$app.declared" | grep '^[<>]' >&2 || true
        exit 1
    fi
done

toolchain_identity() {
    if [ "$HOST" = windows ]; then
        { clang --version 2>/dev/null || echo "clang: unavailable"; } | head -n 1
        { lld-link --version 2>/dev/null || echo "lld-link: unavailable"; } | head -n 1
    else
        { as --version 2>/dev/null || echo "as: unavailable"; } | head -n 1
        { ld --version 2>/dev/null || echo "ld: unavailable"; } | head -n 1
    fi
}

{
    echo "compiler	$COMPILER"
    echo "compiler-version	$("$COMPILER" --version 2>&1 | head -n 1)"
    echo "corpus-commit	$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "host	$HOST"
    toolchain_identity | sed 's/^/toolchain	/'
} > "$OUT/identity.tsv"

report_field() {
    sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1
}

printf 'scenario\tapp\thost\tstatus\twall_ms\tpeak_memory_bytes\n' > "$OUT/results.tsv"
manifest_rows | while IFS='	' read -r scenario app hosts _workflows _owners; do
    if [ "$hosts" != all ] && [ "$hosts" != "$HOST" ]; then
        printf '%s\t%s\t%s\tnot-applicable\t-\t-\n' "$scenario" "$app" "$HOST" >> "$OUT/results.tsv"
        echo "[app-corpus] n/a  $scenario (hosts: $hosts)"
        continue
    fi
    log="$OUT/$scenario.log"
    report="$OUT/$scenario.memory"
    status=0
    scripts/run-memory-bounded.sh --limit-mib "$SCENARIO_MEMORY_MIB" --report "$report" -- \
        env CODEGEN_CASES_WORKDIR="$WORK/$scenario" \
        sh scripts/verify-codegen-cases.sh --only "$scenario" "tests/apps/$app.cases" \
        > "$log" 2>&1 < /dev/null || status=$?
    passes=$(grep -c "^\[codegen-cases\] PASS $scenario \[" "$log" || true)
    if [ "$status" -eq 0 ] && [ "$passes" -eq 1 ] \
        && ! grep -q "^\[codegen-cases\] skip $scenario " "$log"; then
        result=pass
    else
        result=fail
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$scenario" "$app" "$HOST" "$result" \
        "$(report_field wall_ms "$report")" "$(report_field peak_memory_bytes "$report")" \
        >> "$OUT/results.tsv"
    if [ "$result" = pass ]; then
        echo "[app-corpus] pass $scenario ($(report_field wall_ms "$report") ms)"
    else
        # The project copy and every step's output, for replay from CI artifacts.
        cp -R "$WORK/$scenario" "$OUT/$scenario.work" 2>/dev/null || true
        echo "[app-corpus] FAIL $scenario (exit $status); log: $log; files: $OUT/$scenario.work" >&2
        sed 's/^/    /' "$log" | tail -n 40 >&2
        echo "    replay: TYPELISP_BIN=$COMPILER CODEGEN_CASES_WORKDIR=$WORK/$scenario sh scripts/verify-codegen-cases.sh --only $scenario tests/apps/$app.cases" >&2
    fi
done

failures=$(awk -F '\t' 'NR > 1 && $4 == "fail"' "$OUT/results.tsv" | wc -l | tr -d ' ')
passed=$(awk -F '\t' 'NR > 1 && $4 == "pass"' "$OUT/results.tsv" | wc -l | tr -d ' ')
declared=$(manifest_rows | wc -l | tr -d ' ')
recorded=$(awk 'NR > 1' "$OUT/results.tsv" | wc -l | tr -d ' ')
[ "$recorded" -eq "$declared" ] || fail "recorded $recorded results for $declared scenarios"
echo "[app-corpus] identity:"
sed 's/^/    /' "$OUT/identity.tsv"
echo "[app-corpus] results:"
sed 's/^/    /' "$OUT/results.tsv"
if [ "$failures" -ne 0 ]; then
    KEEP_WORK=1
    echo "app-corpus: $failures scenario(s) failed on $HOST; work kept in $WORK; results in $OUT/results.tsv" >&2
    exit 1
fi
echo "app-corpus: $passed scenario(s) passed on $HOST; results in $OUT/results.tsv"
