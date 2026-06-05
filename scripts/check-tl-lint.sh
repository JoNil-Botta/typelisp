#!/usr/bin/env sh
set -eu

# check-tl-lint.sh - repository TypeLisp lint gate.
#
# Local usage:
#   scripts/check-tl-lint.sh
#   TYPELISP_BIN=./target/stage0/typelisp scripts/check-tl-lint.sh
#
# The public `typelisp lint` command is warn-only by default so cleanup can
# happen in normal reviewable slices. This gate opts into enforcing mode.
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
mkdir -p "$WORKDIR"

FILES="$WORKDIR/files.txt"
ACTUAL="$WORKDIR/findings.actual"
STDOUT="$WORKDIR/lint.stdout"
STDERR="$WORKDIR/lint.stderr"

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

if ! xargs "$COMPILER" lint --check < "$FILES" > "$STDOUT" 2> "$STDERR"; then
    awk '
        /^--- / { next }
        /^lint: [0-9][0-9]* finding\(s\)$/ { next }
        NF { print }
    ' "$STDOUT" | LC_ALL=C sort > "$ACTUAL"

    if [ -s "$ACTUAL" ]; then
        echo "TypeLisp lint found finding(s):" >&2
        cat "$ACTUAL" >&2
        exit 1
    fi

    echo "TypeLisp lint failed for the batched source set:" >&2
    if [ -s "$STDERR" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$STDERR" >&2 || true
    fi
    if [ -s "$STDOUT" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$STDOUT" >&2 || true
    fi
    exit 1
fi

echo "TypeLisp lint check passed for $count file(s); 0 finding(s)."
