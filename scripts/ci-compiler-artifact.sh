#!/usr/bin/env sh
# Versioned #6883 provenance/envelope entry point. Node is already required by CI.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-ci-compiler-artifact.sh"
ci_compiler_artifact "$@"
