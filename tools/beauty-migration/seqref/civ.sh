#!/bin/sh
# civ.sh LOG GATES_CSV: ci-verify on the worktree (--jobs 2 --memory-mib
# 16384) for the gates listed in GATES_CSV, with GNU time for the timing gates.
# TMPDIR stays the system default: the app corpus and the doc-test usage case
# refuse or misbehave in a work directory inside the checkout.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
cd "$W" || exit 1
env -u TMPDIR TLCI_NATIVE_ROUTE_TIME_BIN=/home/jonathan/.local/bin/time \
    DOC_SITE_TIME_BIN=/home/jonathan/.local/bin/time \
    scripts/ci-verify.sh --jobs 2 --memory-mib 16384 --gates "$(cat "$2")" > "$1" 2>&1
echo "ci-verify rc=$?" >> "$1"
