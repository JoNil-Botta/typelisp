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
    # Local-development fallback: fetch the published
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
CURRENT_CLI_ASM="$WORKDIR/current-cli.s"
CURRENT_CLI_OBJ=
CURRENT_CLI_BIN=
CURRENT_CLI_COMPILE_STDOUT="$WORKDIR/current-cli-compile.stdout"
CURRENT_CLI_COMPILE_STDERR="$WORKDIR/current-cli-compile.stderr"

build_current_cli_for_format() {
    . "$ROOT/scripts/lib-native-link.sh"
    native_link_detect_host
    configure_toolchain

    CURRENT_CLI_OBJ="$WORKDIR/current-cli.$NL_OBJ_EXT"
    CURRENT_CLI_BIN="$WORKDIR/current-cli$NL_BIN_EXT"

    echo "Building current formatter for current-syntax-aware TypeLisp formatting."
    if ! run_with_heartbeat_capture \
        "compile current formatter for format" \
        "$CURRENT_CLI_COMPILE_STDOUT" \
        "$CURRENT_CLI_COMPILE_STDERR" \
        "$COMPILER" compile selfhost/format.tl -o "$CURRENT_CLI_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root selfhost \
        --opt-level 1; then
        echo "Failed to compile current formatter for current-syntax-aware formatting." >&2
        sed 's/^/  /' "$CURRENT_CLI_COMPILE_STDOUT" >&2 || true
        sed 's/^/  /' "$CURRENT_CLI_COMPILE_STDERR" >&2 || true
        exit 1
    fi

    [ -s "$CURRENT_CLI_ASM" ] || {
        echo "Current formatter compile did not produce assembly: $CURRENT_CLI_ASM" >&2
        exit 1
    }

    assemble_and_link "current-formatter" "$CURRENT_CLI_ASM" "$CURRENT_CLI_OBJ" "$CURRENT_CLI_BIN"
}

# Check every git-tracked *.tl file in the repository so TypeLisp code in any
# directory (including tools/, benchmarks/) meets the same formatting standard.
# Exclusions below are explicit:
#   - tests/format_golden/ — these are formatter golden-test fixtures that
#     intentionally encode specific formatting; formatting them would destroy
#     the test assertions.
git ls-files '*.tl' | grep -v '^tests/format_golden/' | sort > "$ALL_FILES"

xargs grep -lE '\(:(symbol|abi|link-lib|link-search|link-arg)([[:space:]]|\)|$)|\(unsafe([[:space:]]|\)|$)' < "$ALL_FILES" > "$METADATA_FILES" || true

# The published seed formatter tokenizes real variadic macro ellipses as three
# dot atoms. Keep these files under the current-source formatter until the
# published seed is refreshed with the ellipsis lexer fix.
if grep -F -x 'stdlib/core_macros.tl' "$ALL_FILES" >/dev/null 2>&1; then
    printf '%s\n' 'stdlib/core_macros.tl' >> "$METADATA_FILES"
fi

# The #806 safety fixture uses mutable-borrow expression syntax before the
# published seed formatter can parse it.
if grep -F -x 'tests/safety/mutable_reference_reject.tl' "$ALL_FILES" >/dev/null 2>&1; then
    printf '%s\n' 'tests/safety/mutable_reference_reject.tl' >> "$METADATA_FILES"
fi
sort -u "$METADATA_FILES" > "$WORKDIR/current-syntax-files.sorted"
mv "$WORKDIR/current-syntax-files.sorted" "$METADATA_FILES"

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
    build_current_cli_for_format
    if ! xargs "$CURRENT_CLI_BIN" --check < "$METADATA_FILES"; then
        echo "Current-syntax-aware TypeLisp format check failed." >&2
        echo "Run: $CURRENT_CLI_BIN --check \$(cat $METADATA_FILES)" >&2
        exit 1
    fi
fi

echo "TypeLisp format check passed for $count file(s), plus $metadata_count current-syntax-aware file(s)."
