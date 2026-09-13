#!/usr/bin/env sh
set -eu

# Exercise source selection and per-file rule coverage without compiling the
# compiler. Real lint and its diagnostic rejection probes run in the next gate.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK="$ROOT/target/exp/tl-lint-gate-tests"
mkdir -p "$WORK"
CASE_ROOT=$(mktemp -d "$WORK/case.XXXXXX")
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
mkdir -p "$CASE_ROOT/scripts" "$CASE_ROOT/src/nested" "$CASE_ROOT/examples" \
    "$CASE_ROOT/tests/integration" "$CASE_ROOT/tests/safety" \
    "$CASE_ROOT/tests/format_golden" "$CASE_ROOT/stdlib"
cp "$ROOT/scripts/check-tl-lint.sh" "$ROOT/scripts/lib-ci-timing.sh" "$CASE_ROOT/scripts/"
for source in src/a.tl 'src/nested/with space.tl' src/z.tl examples/a.tl \
    stdlib/a.tl tests/integration/struct_field_set.tl tests/safety/excluded.tl \
    tests/format_golden/excluded.tl; do
    printf '(define (main) : i64 42)\n' > "$CASE_ROOT/$source"
done
git -C "$CASE_ROOT" init -q
git -C "$CASE_ROOT" add .
cat > "$CASE_ROOT/compiler" <<'EOF'
#!/usr/bin/env sh
set -eu
shift # lint
name=0 redundant=0 concat=0 check=0 files=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --format | --stdlib-root) shift 2; continue ;;
        --name-case) name=1 ;;
        --redundant-function-name) redundant=1 ;;
        --deprecated-string-concat) concat=1 ;;
        --check) check=1 ;;
        */struct-field-set-probe.tl) exit "${SYNTAX_EXIT:-0}" ;;
        */name-case-probe.tl)
            if [ "${LEGACY_NAMES:-0}" = 1 ]; then
                echo 'top-level value bindings use SCREAMING-KEBAB-CASE'
            else echo 'lint: 0 finding(s)'; fi
            exit 0 ;;
        */src-concat-probe.tl)
            if [ "$concat" = 1 ] && [ "${BROKEN_PROBE:-0}" = 0 ]; then
                echo 'deprecated string concatenation primitive'; exit 1
            fi
            echo 'lint: 0 finding(s)'; exit 0 ;;
        --*) echo "unknown option: $1" >&2; exit 2 ;;
        *)
            files=$((files + 1))
            printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$name" "$redundant" "$concat" "$check" >> "$TRACE"
            if [ "$1" = "${FAIL_FILE:-}" ]; then
                echo 'fixture compiler failure' >&2; exit 7
            fi
            echo "--- $1"
            if [ "$1" = "${FINDING_FILE:-}" ]; then
                echo 'fixture lint finding'
                echo 'lint: 1 finding(s)'; exit 1
            fi
            echo 'lint: 0 finding(s)' ;;
    esac
    shift
done
[ "$files" -le "${TYPELISP_LINT_BATCH_SIZE:-32}" ] || exit 8
EOF
chmod +x "$CASE_ROOT/compiler"
export TYPELISP_BIN="$CASE_ROOT/compiler" TRACE="$CASE_ROOT/trace"
# Avoid appending synthetic rows to the enclosing CI artifact.
export TYPELISP_CI_TIMING=0

run_gate() {
    : > "$TRACE"
    sh "$CASE_ROOT/scripts/check-tl-lint.sh" > "$CASE_ROOT/output" 2>&1
}
check_trace() {
    awk -F '\t' -v names="$1" -v syntax="$2" '
        {
            if (++seen[$1] != 1 || $2 != names || $3 != 1 || $5 != 1) exit 1
            if ($4 != ($1 ~ /^src\//)) exit 1
            if ($1 ~ /^tests\/(safety|format_golden)\//) exit 1
        }
        END {
            if (NR != 5 + syntax || !seen["src/a.tl"] ||
                !seen["src/nested/with space.tl"] || !seen["src/z.tl"] ||
                !seen["examples/a.tl"] || !seen["stdlib/a.tl"] ||
                (syntax && !seen["tests/integration/struct_field_set.tl"])) exit 1
        }
    ' "$TRACE" || { cat "$TRACE" >&2; exit 1; }
}
export TYPELISP_LINT_BATCH_SIZE=2
run_gate
check_trace 1 1
LEGACY_NAMES=1; export LEGACY_NAMES
run_gate
check_trace 0 1
unset LEGACY_NAMES
SYNTAX_EXIT=1; export SYNTAX_EXIT
run_gate
check_trace 1 0
unset SYNTAX_EXIT
for invalid in '' 0 00 -1 nope 1.5; do
    TYPELISP_LINT_BATCH_SIZE=$invalid
    if run_gate; then echo "invalid batch size accepted: $invalid" >&2; exit 1; fi
    grep -F 'TYPELISP_LINT_BATCH_SIZE must be a positive integer' "$CASE_ROOT/output" >/dev/null
    [ ! -s "$TRACE" ]
done
TYPELISP_LINT_BATCH_SIZE=2
FAIL_FILE=src/a.tl; export FAIL_FILE
if run_gate; then echo 'compiler failure ignored' >&2; exit 1; fi
grep -F 'fixture compiler failure' "$CASE_ROOT/output" >/dev/null
unset FAIL_FILE
FINDING_FILE=src/a.tl; export FINDING_FILE
if run_gate; then echo 'lint finding ignored' >&2; exit 1; fi
grep -F 'TypeLisp lint found finding(s):' "$CASE_ROOT/output" >/dev/null
grep -F 'fixture lint finding' "$CASE_ROOT/output" >/dev/null
unset FINDING_FILE
BROKEN_PROBE=1; export BROKEN_PROBE
if run_gate; then echo 'broken rejection probe accepted' >&2; exit 1; fi
grep -F 'primitive probe unexpectedly passed' "$CASE_ROOT/output" >/dev/null
echo 'TypeLisp lint gate coverage self-tests passed.'
