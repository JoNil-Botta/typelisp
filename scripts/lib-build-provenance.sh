# lib-build-provenance.sh — the git identity stamped into build outputs.
#
# stage0 binaries, the bootstrap fixpoint, and the embedded stdlib tlci image
# each stamp `git rev-parse HEAD` into their output so an artifact is traceable
# to a commit. Every one of those scripts runs under `set -e`, so a git failure
# already aborts the run — but what reaches the terminal is git's bare
# `fatal: not a git repository: <path>`, which names neither the script that
# needed the commit nor a way forward, and the reader is left to work out that
# a required validation step did not complete.
#
# The known trigger is a checkout that is a git *worktree* whose `.git` file
# holds an absolute gitdir the running git cannot follow — a Windows path read
# from WSL, for instance:
#
#     $ cat .git
#     gitdir: C:/dev/typelisp/.git/worktrees/typelisp5
#     $ git rev-parse --verify HEAD
#     fatal: not a git repository: /mnt/c/dev/typelisp5/C:/dev/typelisp/.git/...
#
# Setting GIT_DIR/GIT_WORK_TREE to paths that git can resolve makes the same
# command work, so this is a legibility problem, not a missing capability.
# Refs #5697.
#
# Source it (not exec): `. "$ROOT/scripts/lib-build-provenance.sh"`. POSIX sh
# only — no `local`, arrays, or bashisms.

# build_provenance_explain CONTEXT NEED COMMAND
#   Report that CONTEXT needs NEED from git, quote what the failing COMMAND
#   said, and name the escape hatch.
build_provenance_explain() {
    {
        echo "$1: cannot read $2."
        echo "  \`$3\` failed in $(pwd)."
        echo "  git reported:"
        sh -c "$3" 2>&1 >/dev/null | sed 's/^/    /' || true
        echo "  If this checkout is a git worktree whose .git file points at a"
        echo "  gitdir this git cannot follow (a Windows path read from WSL, for"
        echo "  instance), set GIT_DIR and GIT_WORK_TREE to paths valid for this"
        echo "  git and re-run."
    } >&2
}

# build_provenance_hash CONTEXT
#   Echo the HEAD commit that CONTEXT should stamp into its output, or explain
#   why it cannot be read and return non-zero. Callers assign the result under
#   `set -e`, so the failure aborts the build rather than stamping an empty or
#   stale identity.
build_provenance_hash() {
    _bp_hash=$(git rev-parse --verify HEAD 2>/dev/null || true)
    if [ -n "$_bp_hash" ]; then
        printf '%s\n' "$_bp_hash"
        return 0
    fi
    build_provenance_explain \
        "$1" \
        "the build provenance commit" \
        "git rev-parse --verify HEAD"
    echo "  The build output stamps that commit, so continuing would produce" >&2
    echo "  an artifact that cannot be traced to a source revision." >&2
    return 1
}

# build_provenance_require_repository CONTEXT
#   Fail unless git can resolve this checkout. The embedded stdlib image hashes
#   its source set with `git hash-object`, which needs a resolvable repository
#   even though it never reads a commit, and would otherwise die with the same
#   bare git error partway through a build.
build_provenance_require_repository() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        return 0
    fi
    build_provenance_explain \
        "$1" \
        "this checkout's git directory" \
        "git rev-parse --git-dir"
    return 1
}
