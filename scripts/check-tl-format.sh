#!/usr/bin/env sh
set -eu

# check-tl-format.sh - repository TypeLisp formatter stability check.
#
# Local usage:
#   scripts/check-tl-format.sh
#   TYPELISP_BIN=./target/stage0/typelisp scripts/check-tl-format.sh
#
# The check runs the self-hosted formatter through `typelisp fmt --check` over
# most of the TypeLisp corpus. Files using syntax that the published seed
# formatter may not preserve yet, such as extern metadata `(:symbol ...)` and
# unsafe blocks, are checked with the formatter source in the current tree.
#
# refs #384.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# `typelisp fmt` runs the self-hosted formatter as native code for the host.
# Allow Linux and Windows (Git Bash / MSYS / MINGW / Cygwin) hosts so both CI
# jobs run the check (#763); reject anything else so unsupported hosts do not
# silently pass the gate.
HOST_OS=linux
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) HOST_OS=windows ;;
    *)
        echo "TypeLisp format check is unsupported on this host (selfhost fmt runs native code)" >&2
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

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/tl-format-check"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

ALL_FILES="$WORKDIR/all-files.txt"
CHECK_FILES="$WORKDIR/check-files.txt"
METADATA_FILES="$WORKDIR/metadata-files.txt"

# Check every git-tracked *.tl file in the repository so TypeLisp code in any
# directory (including tools/, benchmarks/) meets the same formatting standard.
# Exclusions below are explicit:
#   - tests/format_golden/ — these are formatter golden-test fixtures that
#     intentionally encode specific formatting; formatting them would destroy
#     the test assertions.
git ls-files '*.tl' | grep -v '^tests/format_golden/' | sort > "$ALL_FILES"

xargs grep -lE '\(:(symbol|abi|link-lib|link-search|link-arg)([[:space:]]|\)|$)|\(unsafe([[:space:]]|\)|$)' < "$ALL_FILES" > "$METADATA_FILES" || true
if [ -s "$METADATA_FILES" ]; then
    grep -F -x -v -f "$METADATA_FILES" "$ALL_FILES" > "$CHECK_FILES"
else
    cp "$ALL_FILES" "$CHECK_FILES"
fi

if [ ! -s "$CHECK_FILES" ] && [ ! -s "$METADATA_FILES" ]; then
    echo "no TypeLisp source files selected for formatting check" >&2
    exit 1
fi

count=$(wc -l < "$CHECK_FILES" | tr -d ' ')
metadata_count=$(wc -l < "$METADATA_FILES" | tr -d ' ')
echo "Checking TypeLisp formatting for $count file(s)."

if [ -s "$CHECK_FILES" ] && ! xargs "$COMPILER" fmt --check < "$CHECK_FILES"; then
    echo "Batch TypeLisp format check failed; probing files one by one." >&2
    while IFS= read -r file; do
        echo "TypeLisp format probe: $file" >&2
        if "$COMPILER" fmt --check "$file"; then
            :
        else
            status=$?
            echo "TypeLisp format probe failed for $file with exit code $status" >&2
            echo "TypeLisp format check failed. Run: $COMPILER fmt $file" >&2
            exit 1
        fi
    done < "$CHECK_FILES"
    echo "Per-file TypeLisp format probe passed after the batch check failed." >&2
    echo "The failure may depend on multi-file formatter driver state or argument handling." >&2
    echo "TypeLisp format check failed. Run: $COMPILER fmt \$(cat $CHECK_FILES)" >&2
    exit 1
fi

if [ -s "$METADATA_FILES" ]; then
    echo "Checking current-syntax-aware TypeLisp formatting for $metadata_count file(s)."
    if ! xargs "$COMPILER" run selfhost/cli.tl \
        --stdlib-root stdlib \
        --stdlib-root selfhost \
        -- fmt --check < "$METADATA_FILES"; then
        echo "Current-syntax-aware TypeLisp format check failed." >&2
        echo "Run: $COMPILER run selfhost/cli.tl --stdlib-root stdlib --stdlib-root selfhost -- fmt \$(cat $METADATA_FILES)" >&2
        exit 1
    fi
fi

echo "TypeLisp format check passed for $count file(s), plus $metadata_count current-syntax-aware file(s)."
