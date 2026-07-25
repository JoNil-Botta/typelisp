#!/usr/bin/env sh
set -eu

# verify-build-provenance.sh - self-tests for the build provenance helper.
#
# `build_provenance_hash` is only exercised in production by its success path:
# CI checks out an ordinary clone, so the diagnostic it exists for never runs
# there. Without this gate the failure branch could rot into a silent empty
# stamp and nothing would notice until someone hit it on a worktree checkout.
# Refs #5697.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-build-provenance.sh"

if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-build-provenance.sh" >&2
    exit 2
fi

WORKDIR="$ROOT/target/build-provenance-self-test"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

STDOUT="$WORKDIR/stdout.txt"
STDERR="$WORKDIR/stderr.txt"

fail() {
    echo "build provenance self-test: $*" >&2
    exit 1
}

# An unresolvable gitdir is the shape a Windows-path worktree presents to a git
# that cannot follow it, forced here so the branch runs on every host.
set +e
(
    GIT_DIR="$WORKDIR/absent-gitdir"
    GIT_WORK_TREE="$WORKDIR"
    export GIT_DIR GIT_WORK_TREE
    build_provenance_hash "self-test-context"
) > "$STDOUT" 2> "$STDERR"
status=$?
set -e
if [ "$status" -eq 0 ]; then
    fail "an unresolvable gitdir reported success"
fi
if [ -s "$STDOUT" ]; then
    fail "a failed lookup still printed a hash: $(cat "$STDOUT")"
fi
for phrase in \
    "self-test-context" \
    "cannot read the build provenance commit" \
    "GIT_DIR"; do
    grep -F "$phrase" "$STDERR" > /dev/null ||
        fail "the diagnostic does not mention '$phrase'"
done

# The repository probe is the same shape for the callers that hash content
# rather than read a commit.
set +e
(
    GIT_DIR="$WORKDIR/absent-gitdir"
    GIT_WORK_TREE="$WORKDIR"
    export GIT_DIR GIT_WORK_TREE
    build_provenance_require_repository "self-test-context"
) > "$STDOUT" 2> "$STDERR"
status=$?
set -e
if [ "$status" -eq 0 ]; then
    fail "an unresolvable gitdir passed the repository probe"
fi
grep -F "cannot read this checkout's git directory" "$STDERR" > /dev/null ||
    fail "the repository probe diagnostic does not name what it needed"

# The success path must echo exactly what the callers used to read directly.
# A checkout where git cannot resolve HEAD is itself the case the helper is
# for, so assert the diagnostic there instead of skipping the gate.
if EXPECTED=$(git rev-parse --verify HEAD 2>/dev/null); then
    ACTUAL=$(build_provenance_hash "self-test-context")
    [ "$ACTUAL" = "$EXPECTED" ] ||
        fail "resolved '$ACTUAL', expected '$EXPECTED'"
    build_provenance_require_repository "self-test-context" ||
        fail "the repository probe rejected a resolvable checkout"
    echo "build provenance self-test passed (HEAD $EXPECTED)"
else
    set +e
    build_provenance_hash "self-test-context" > "$STDOUT" 2> "$STDERR"
    status=$?
    set -e
    [ "$status" -ne 0 ] ||
        fail "an unresolvable checkout reported success"
    grep -F "cannot read the build provenance commit" "$STDERR" > /dev/null ||
        fail "an unresolvable checkout produced no diagnostic"
    echo "build provenance self-test passed (this checkout cannot resolve HEAD)"
fi
