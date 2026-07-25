#!/usr/bin/env sh
set -eu

# check-cli-help-surface.sh - fail closed when a command parses a flag its
# `--help` does not document.
#
# Help text and the option parser live in different files -- the text in
# `src/main.tl`, the parsing in `src/<name>_cli_core.tl` -- so a flag can be
# added, or a feature landed, without the text moving. That has now happened
# three times: #5160 landed the REPL's `.load` without updating `src/main.tl`,
# and #5692 found `typelisp test` documenting `--batch` as `--check`-only while
# `scripts/verify-inline-tests.sh` depended on the undocumented run mode, plus
# `--backend-mode` missing entirely.
#
# The existing CLI gates cannot catch this. `verify-public-tools.sh` asserts
# that help output *exists* and contains `Usage:`/`Summary:`; nothing compares
# it against what the parser accepts.
#
# Deliberately undocumented flags (worker subprocess protocols, the help flag
# itself) are listed in scripts/cli-help-undocumented.tsv with a reason, so an
# internal flag costs one line and a user-facing one cannot pass silently.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

ALLOWLIST=scripts/cli-help-undocumented.tsv
MAIN=src/main.tl
SELF_TEST=0
if [ "${1:-}" = "--self-test" ]; then
    SELF_TEST=1
elif [ "$#" -ne 0 ]; then
    echo "usage: scripts/check-cli-help-surface.sh [--self-test]" >&2
    exit 2
fi

# Each row is "<cli core basename> <help block name>"; they differ only where
# the command and its module disagree (format/fmt).
COMMANDS='build build
check check
clean clean
compile compile
doc doc
format fmt
inspect inspect
repl repl
run run
test test'

# Print every "--flag" literal a parser source mentions, one per line.
parsed_flags() {
    grep -o '"--[a-z][a-z0-9-]*"' "$1" 2>/dev/null | tr -d '"' | sort -u
}

# Print the help block body for cli-<name>-help-text out of a main.tl-shaped
# file: everything from the defining line to the next top-level `(define `.
help_block() {
    awk -v name="$2" '
        $0 == "(define (cli-" name "-help-text) : String" { inside = 1; next }
        inside && /^\(define / { inside = 0 }
        inside { print }
    ' "$1"
}

allowed() {
    awk -F'\t' -v cmd="$1" -v flag="$2" '
        /^#/ { next }
        NF >= 2 && $1 == cmd && $2 == flag { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$3"
}

check_surface() {
    _main=$1
    _allowlist=$2
    _status=0
    echo "$COMMANDS" | while IFS=' ' read -r core help_name; do
        [ -n "$core" ] || continue
        _source="src/${core}_cli_core.tl"
        [ -f "$_source" ] || continue
        _block=$(help_block "$_main" "$help_name")
        if [ -z "$_block" ]; then
            echo "no cli-$help_name-help-text block in $_main" >&2
            exit 1
        fi
        for _flag in $(parsed_flags "$_source"); do
            case "$_block" in
                *"$_flag"*) continue ;;
            esac
            if allowed "$core" "$_flag" "$_allowlist"; then
                continue
            fi
            echo "$core parses $_flag but 'typelisp $core --help' does not document it" >&2
            echo "  document it in cli-$help_name-help-text ($_main), or add it to $_allowlist with a reason" >&2
            exit 1
        done
    done || _status=1
    return "$_status"
}

if [ "$SELF_TEST" -eq 1 ]; then
    WORKDIR=target/cli-help-surface-selftest
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    # An undocumented, unlisted flag must fail. Drop --backend-mode from the
    # test help block while the parser keeps accepting it: exactly the #5692
    # shape.
    BAD="$WORKDIR/main-missing-flag.tl"
    awk '
        $0 == "(define (cli-test-help-text) : String" { inside = 1 }
        inside && /--backend-mode/ { next }
        inside && /^\(define / && $0 != "(define (cli-test-help-text) : String" { inside = 0 }
        { print }
    ' "$MAIN" > "$BAD"
    if grep -q -- "--backend-mode" "$(printf '%s' "$BAD")" && \
        awk '$0 == "(define (cli-test-help-text) : String" { i = 1; next }
             i && /^\(define / { i = 0 } i { print }' "$BAD" | grep -q -- "--backend-mode"; then
        echo "self-test: fixture still documents --backend-mode" >&2
        exit 1
    fi
    if check_surface "$BAD" "$ALLOWLIST" 2>/dev/null; then
        echo "self-test: an undocumented parsed flag was not rejected" >&2
        exit 1
    fi
    # The same flag listed in the allowlist must pass, so the escape hatch works.
    ALLOW_OK="$WORKDIR/allow.tsv"
    cp "$ALLOWLIST" "$ALLOW_OK"
    printf 'test\t--backend-mode\tself-test\n' >> "$ALLOW_OK"
    if ! check_surface "$BAD" "$ALLOW_OK"; then
        echo "self-test: an allowlisted flag was still rejected" >&2
        exit 1
    fi
    echo "cli help surface self-tests passed"
fi

check_surface "$MAIN" "$ALLOWLIST"
echo "cli help surface matches the parsed flag set"
