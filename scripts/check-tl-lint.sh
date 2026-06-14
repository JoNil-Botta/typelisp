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
    # Local-development fallback: fetch the published
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
CURRENT_SYNTAX_FILES="$WORKDIR/current-syntax-files.txt"
FILTERED_FILES="$WORKDIR/files.filtered"
ACTUAL="$WORKDIR/findings.actual"
STDOUT="$WORKDIR/lint.stdout"
STDERR="$WORKDIR/lint.stderr"

# Lint every git-tracked TypeLisp source that is expected to parse as a source
# unit. The excluded paths are fixture harness inputs rather than direct source
# units:
#   - tests/format_golden/ intentionally preserves formatter fixture text.
#   - tests/safety/ includes intentional check-fail/runtime-trap corpus inputs.
git ls-files '*.tl' \
    | grep -v '^tests/format_golden/' \
    | grep -v '^tests/safety/' \
    | sort > "$FILES"

: > "$CURRENT_SYNTAX_FILES"

# Some integration fixtures intentionally land in the same PR as parser support
# for their source syntax. The seed lint pass runs before the branch compiler is
# built; defer those files only when the selected compiler cannot parse the new
# syntax. The later fresh-selfhost lint pass uses the branch compiler and covers
# them normally.
if grep -F -x 'tests/integration/struct_field_set.tl' "$FILES" >/dev/null 2>&1; then
    printf '%s\n' 'tests/integration/struct_field_set.tl' >> "$CURRENT_SYNTAX_FILES"
fi

compiler_supports_struct_field_set_lint() {
    probe="$WORKDIR/struct-field-set-probe.tl"
    cat > "$probe" <<'EOF'
(defstruct Pair
  (x i64)
  (y i64))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    (begin
      (set! (struct-get p x) 3)
      (struct-get p x))))
EOF
    "$COMPILER" lint "$probe" > "$WORKDIR/struct-field-set-probe.stdout" 2> "$WORKDIR/struct-field-set-probe.stderr"
}

if [ -s "$CURRENT_SYNTAX_FILES" ] && ! compiler_supports_struct_field_set_lint; then
    grep -F -x -v -f "$CURRENT_SYNTAX_FILES" "$FILES" > "$FILTERED_FILES"
    mv "$FILTERED_FILES" "$FILES"
    deferred_count=$(wc -l < "$CURRENT_SYNTAX_FILES" | tr -d ' ')
    echo "Deferring TypeLisp lint for $deferred_count current-syntax file(s) until the fresh selfhost lint pass."
fi

if [ ! -s "$FILES" ]; then
    echo "no TypeLisp source files selected for lint check" >&2
    exit 1
fi

count=$(wc -l < "$FILES" | tr -d ' ')
echo "Linting TypeLisp sources for $count file(s)."

if ! xargs "$COMPILER" lint --check < "$FILES" > "$STDOUT" 2> "$STDERR"; then
    if [ ! -s "$STDERR" ] && grep -q '^lint: [1-9][0-9]* finding(s)$' "$STDOUT"; then
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
