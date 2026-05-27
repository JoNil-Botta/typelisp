#!/usr/bin/env sh
set -eu

# check-tl-lint.sh - repository TypeLisp lint baseline gate.
#
# Local usage:
#   scripts/check-tl-lint.sh
#   TYPELISP_BIN=./target/release/typelisp scripts/check-tl-lint.sh
#   TYPELISP_LINT_UPDATE_BASELINE=1 scripts/check-tl-lint.sh
#
# The public `typelisp lint` command is warn-only so cleanup can happen in
# normal reviewable slices. This gate makes CI fail only for findings not listed
# in scripts/tl-lint-baseline.txt. Removing a finding is allowed; delete stale
# baseline lines when doing the cleanup.
#
# refs #1164.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "TypeLisp lint check is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
    [ "$HOST_OS" = windows ] && COMPILER="$COMPILER.exe"
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

BASELINE="$ROOT/scripts/tl-lint-baseline.txt"
WORKDIR="$ROOT/target/tl-lint-check"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/findings" "$WORKDIR/stdout" "$WORKDIR/stderr" "$WORKDIR/failures"

FILES="$WORKDIR/files.txt"
ACTUAL="$WORKDIR/findings.actual"
EXPECTED="$WORKDIR/findings.expected"
NEW_FINDINGS="$WORKDIR/findings.new"
RESOLVED_FINDINGS="$WORKDIR/findings.resolved"

# Lint every git-tracked TypeLisp source that is expected to parse and load as a
# standalone program. The excluded paths are fixture harness inputs rather than
# direct source units:
#   - selfhost/tests/ contains external compiler corpus snippets and errors.
#   - import-heavy public tool drivers currently exceed the lint gate budget by
#     linting large imported compiler/tool graphs; #1438 owns re-enabling them.
#   - tests/format_golden/ intentionally preserves formatter fixture text.
#   - the listed integration drivers depend on manifest-staged helper files.
git ls-files '*.tl' \
    | grep -v '^selfhost/tests/' \
    | grep -v '^selfhost/lsp_frame\.tl$' \
    | grep -v '^selfhost/repl\.tl$' \
    | grep -v '^selfhost/run\.tl$' \
    | grep -v '^selfhost/test\.tl$' \
    | grep -v '^tests/format_golden/' \
    | grep -v '^tests/integration/format_.*_integration\.tl$' \
    | grep -v '^tests/integration/sym_i64_env\.tl$' \
    | grep -v '^tests/integration/text_buf\.tl$' \
    | sort > "$FILES"

if [ ! -s "$FILES" ]; then
    echo "no TypeLisp source files selected for lint check" >&2
    exit 1
fi

count=$(wc -l < "$FILES" | tr -d ' ')
echo "Linting TypeLisp sources for $count file(s)."

JOBS=${TYPELISP_LINT_JOBS:-4}
case "$JOBS" in
    '' | *[!0-9]* | 0)
        echo "TYPELISP_LINT_JOBS must be a positive integer" >&2
        exit 2
        ;;
esac

export COMPILER WORKDIR
xargs -n 1 -P "$JOBS" sh -c '
for file do
    safe=$(printf "%s" "$file" | cksum | awk "{ print \$1 }")
    stdout="$WORKDIR/stdout/$safe.out"
    stderr="$WORKDIR/stderr/$safe.err"
    if "$COMPILER" lint "$file" > "$stdout" 2> "$stderr"; then
        awk '"'"'/^lint: [0-9][0-9]* finding\(s\)$/ { next } NF { print }'"'"' "$stdout" \
            > "$WORKDIR/findings/$safe.out"
    else
        {
            printf "%s\n" "$file"
            cat "$stderr"
            cat "$stdout"
        } > "$WORKDIR/failures/$safe.fail"
    fi
done
' sh < "$FILES"

if find "$WORKDIR/failures" -type f | grep -q .; then
    echo "TypeLisp lint failed for one or more files:" >&2
    find "$WORKDIR/failures" -type f -print | sort | while IFS= read -r failure; do
        echo "---" >&2
        cat "$failure" >&2
    done
    exit 1
fi

find "$WORKDIR/findings" -type f -name '*.out' -exec cat {} + | LC_ALL=C sort > "$ACTUAL"

if [ "${TYPELISP_LINT_UPDATE_BASELINE:-}" = 1 ]; then
    {
        echo "# Baseline for scripts/check-tl-lint.sh."
        echo "# Each non-comment line is a currently accepted typelisp lint finding."
        echo "# Remove entries as code is cleaned up; new findings fail CI."
        cat "$ACTUAL"
    } > "$BASELINE.tmp"
    mv "$BASELINE.tmp" "$BASELINE"
    baseline_count=$(wc -l < "$ACTUAL" | tr -d ' ')
    echo "Updated TypeLisp lint baseline with $baseline_count finding(s)."
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "missing lint baseline: $BASELINE" >&2
    echo "Run TYPELISP_LINT_UPDATE_BASELINE=1 scripts/check-tl-lint.sh to create it." >&2
    exit 1
fi

grep -v '^#' "$BASELINE" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort > "$EXPECTED"

LC_ALL=C comm -13 "$EXPECTED" "$ACTUAL" > "$NEW_FINDINGS"
LC_ALL=C comm -23 "$EXPECTED" "$ACTUAL" > "$RESOLVED_FINDINGS"

if [ -s "$NEW_FINDINGS" ]; then
    echo "TypeLisp lint found unbaselined finding(s):" >&2
    cat "$NEW_FINDINGS" >&2
    echo >&2
    echo "Fix the finding(s), or refresh scripts/tl-lint-baseline.txt only for accepted legacy debt." >&2
    exit 1
fi

if [ -s "$RESOLVED_FINDINGS" ]; then
    echo "TypeLisp lint baseline has resolved finding(s); remove these lines when cleaning up:" >&2
    cat "$RESOLVED_FINDINGS" >&2
fi

actual_count=$(wc -l < "$ACTUAL" | tr -d ' ')
baseline_count=$(wc -l < "$EXPECTED" | tr -d ' ')
echo "TypeLisp lint check passed for $count file(s); $actual_count finding(s), $baseline_count baselined."
