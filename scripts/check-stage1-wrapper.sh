#!/usr/bin/env sh
set -eu

# Smoke-test a TYPELISP_BIN-compatible host-action CLI surface: compile, check,
# source/package build, run, repl, lsp, doc, test, fmt, and lint
# (tests/cli/host-action.cases). The script name is retained for external
# callers that still invoke the legacy path.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "host-action CLI smoke is Linux-only (requires as + ld)" >&2
        exit 0
        ;;
esac

if [ -z "${TYPELISP_BIN:-}" ]; then
    echo "host-action CLI smoke requires TYPELISP_BIN" >&2
    exit 1
fi

exec scripts/verify-codegen-cases.sh tests/cli/host-action.cases
