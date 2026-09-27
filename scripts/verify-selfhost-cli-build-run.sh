#!/usr/bin/env sh
set -eu

# verify-selfhost-cli-build-run.sh - public build/run smoke of the freshly
# bootstrapped compiler (TYPELISP_BIN, never the published seed): the command
# surface, builds, packages, git dependencies, scaffolding, REPL and the
# work-queue chooser in tests/cli/selfhost-*.cases.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -z "${TYPELISP_BIN:-}" ]; then
    echo "verify-selfhost-cli-build-run requires TYPELISP_BIN" >&2
    exit 2
fi

# A short work root: Windows file calls stop at 260 characters, and the
# remote-package cases nest the package cache's staging paths below it.
CODEGEN_CASES_WORKDIR=${CODEGEN_CASES_WORKDIR:-$ROOT/target/cc}
export CODEGEN_CASES_WORKDIR
exec scripts/verify-codegen-cases.sh tests/cli/selfhost-surface.cases tests/cli/selfhost-build-run.cases
