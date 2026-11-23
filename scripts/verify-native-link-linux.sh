#!/usr/bin/env sh
set -eu

# verify-native-link-linux.sh - Linux native checks for the selfhost driver.
#
# Runs tests/codegen/native-link.cases with the supplied compiler.
# The assembly it emits must assemble, link and run.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "selfhost native verification is Linux-only (requires as + ld)"
        exit 0
        ;;
esac

GATE_FAIL_PREFIX='FAIL: '
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_compiler_absolute
gate_require_compiler
for tool in as ld; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

exec env NATIVE_LINK_COMPILER="$COMPILER" TYPELISP_BIN="$COMPILER" \
    scripts/verify-codegen-cases.sh tests/codegen/native-link.cases
