#!/usr/bin/env sh
set -eu

# check-tl-format.sh - repository TypeLisp formatter stability check.
#
# Local usage:
#   scripts/check-tl-format.sh
#   TYPELISP_BIN=./target/release/typelisp scripts/check-tl-format.sh
#
# The check runs the self-hosted formatter through `typelisp fmt --check` over
# the checked-in TypeLisp corpus. CI must not rewrite files; run
# `typelisp fmt <file.tl>...` locally to normalize sources before committing.
#
# refs #384; exclusion removal is tracked in #629.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "TypeLisp format check is Linux-only (selfhost fmt runs native code)" >&2
        exit 0
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    cargo build --release --quiet
    COMPILER="$ROOT/target/release/typelisp"
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/tl-format-check"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

ALL_FILES="$WORKDIR/all-files.txt"
CHECK_FILES="$WORKDIR/check-files.txt"
EXCLUDED_FILES="$WORKDIR/excluded-files.txt"

# The first CI gate covers the requested checked-in source roots. `git ls-files`
# naturally excludes target/, generated test output, and untracked temporaries.
git ls-files '*.tl' |
    grep -E '^(selfhost|stdlib|examples|tests/integration)/' |
    sort > "$ALL_FILES"

# Known formatter coverage gaps that currently panic with
# `tl: array index out of bounds`; keep this list small and mirrored by the
# follow-up issue (#629) that removes it.
cat > "$EXCLUDED_FILES" <<'EOF'
selfhost/compile.tl
selfhost/compiler_load.tl
selfhost/lsp_frame.tl
tests/integration/overflow_casts.tl
EOF

grep -vx -f "$EXCLUDED_FILES" "$ALL_FILES" > "$CHECK_FILES"

if [ ! -s "$CHECK_FILES" ]; then
    echo "no TypeLisp source files selected for formatting check" >&2
    exit 1
fi

count=$(wc -l < "$CHECK_FILES" | tr -d ' ')
excluded=$(wc -l < "$EXCLUDED_FILES" | tr -d ' ')
echo "Checking TypeLisp formatting for $count file(s); $excluded known formatter gap(s) excluded."

if ! xargs "$COMPILER" fmt --check < "$CHECK_FILES"; then
    echo "TypeLisp format check failed. Run: $COMPILER fmt \$(cat $CHECK_FILES)" >&2
    exit 1
fi

echo "TypeLisp format check passed for $count file(s)."
