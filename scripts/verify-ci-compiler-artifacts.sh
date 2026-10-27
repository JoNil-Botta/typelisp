#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$(uname -s)" in Linux*) host=linux ;; MINGW*|MSYS*|CYGWIN*) host=windows ;; *) exit 2 ;; esac
# Every invocation gets a new owned root; no fixture cleanup or deletion.
work=${1:-$ROOT/target/ci-compiler-artifact-selftest-$$}
exec "$ROOT/scripts/ci-compiler-artifact.sh" self-test "$ROOT" "$work" "$host"
