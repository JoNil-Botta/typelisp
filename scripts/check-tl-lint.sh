#!/usr/bin/env sh
set -eu

# check-tl-lint.sh - repository TypeLisp lint gate.
#
# Local usage:
#   scripts/check-tl-lint.sh
#   TYPELISP_BIN=./target/stage0/typelisp scripts/check-tl-lint.sh
#
# The public `typelisp lint` command is warn-only so cleanup can happen in
# normal reviewable slices. This gate makes CI fail for any finding.
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
    # No-Rust fallback for local development: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/tl-lint-check"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/findings" "$WORKDIR/stdout" "$WORKDIR/stderr" "$WORKDIR/failures"

FILES="$WORKDIR/files.txt"
ACTUAL="$WORKDIR/findings.actual"

# Lint every git-tracked TypeLisp source that is expected to parse as a source
# unit. The excluded paths are fixture harness inputs rather than direct source
# units:
#   - selfhost/tests/ contains external compiler corpus snippets and errors.
#   - tests/format_golden/ intentionally preserves formatter fixture text.
#   - tests/safety/ includes intentional check-fail/runtime-trap corpus inputs.
git ls-files '*.tl' \
    | grep -v '^selfhost/tests/' \
    | grep -v '^tests/format_golden/' \
    | grep -v '^tests/safety/' \
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

if [ -s "$ACTUAL" ]; then
    echo "TypeLisp lint found finding(s):" >&2
    cat "$ACTUAL" >&2
    exit 1
fi

echo "TypeLisp lint check passed for $count file(s); 0 finding(s)."
