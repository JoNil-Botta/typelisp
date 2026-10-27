#!/usr/bin/env sh
# Versioned #6883 provenance/envelope entry point; existing shell/jq tools only.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-ci-compiler-artifact.sh"
ci_compiler_artifact "$@"
