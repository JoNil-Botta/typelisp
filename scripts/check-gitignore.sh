#!/usr/bin/env sh
set -eu

# Gate for the .gitignore contract (#5161).
#
# `typelisp build foo.tl` writes its executable next to the source: `foo.exe` on
# Windows and an extensionless `foo` on Linux. Git cannot glob "name without an
# extension", so .gitignore ignores extensionless files repo-wide and
# re-includes dotted names. Two things can go wrong with that shape, and both
# are silent:
#
#   * a toolchain output stops being ignored, so an ordinary build leaves a
#     newcomer's first `git status` dirty;
#   * the repo-wide `*` swallows a path that should have been tracked.
#
# Assert both directions against a fixed table, and assert that .gitignore
# never shadows a file the repository already tracks.

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-gitignore.sh
EOF
}

if [ "$#" -gt 0 ]; then
    usage
    exit 2
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

failed=0

fail() {
    echo "gitignore gate: $1" >&2
    failed=1
}

# Generated paths that must never reach `git status`. Kept deliberately broad:
# executables beside their sources (extensionless and .exe), assembly and object
# files from `typelisp compile` plus manual assemble/link steps, static
# libraries, package and bootstrap output below `target/` at the repository root
# and at nested package roots, the fetched stage0 cache, and test scratch space.
IGNORED_PATHS="
examples/hello
examples/hello.exe
examples/hello.s
examples/hello.o
examples/hello.obj
src/lsp_frame_core
src/tests/compiler_backend_runtime_fixture
stdlib/string
benchmarks/arith_loop/bench
benchmarks/arith_loop/baseline
tests/integration/include_bin_payload
tests/scratch/io_edges_probe
target/release/typelisp
target/stage0/typelisp.exe
target/exp/measure/notes.txt
tools/stage0/typelisp
tools/stage0/typelisp.exe
tools/vs-code-extension/node_modules/typescript/package.json
tests/integration/nested-pkg/target/dev/nested.tlci
libtypelisp.a
typelisp.lib
typelisp.pdb
"

# Sources, fixtures, and data that must stay visible. Every entry is also
# required to be tracked, so a rename cannot quietly hollow out the table.
TRACKED_PATHS="
.gitattributes
.gitignore
.github/workflows/ci.yml
CONTRIBUTING.md
README.md
SPEC.md
typelisp.pkg
examples/hello.tl
src/main.tl
src/lsp_frame_core.tl
src/tests/compiler_backend_runtime_fixture.tl
stdlib/string.tl
benchmarks/arith_loop/bench.tl
benchmarks/arith_loop/baseline.c
scripts/check-gitignore.sh
scripts/fetch-stage0.ps1
perf/insn-exec-baseline.tsv
tests/golden/selfhost_compiler_driver_import.s
tests/tlci/corpus/SHA256SUMS
tests/tlci/corpus/malformed-bad-magic.tlci
tests/integration/include_bin_payload.bin
tests/scratch/.gitkeep
tools/vs-code-extension/package.json
"

# Extensionless names that are content rather than build output. These are not
# tracked today, so they only assert that the .gitignore negations for them are
# live and adding the file later needs no .gitignore change.
UNIGNORED_PATHS="
LICENSE
.github/CODEOWNERS
"

ignored_count=0
for path in $IGNORED_PATHS; do
    ignored_count=$((ignored_count + 1))
    if git check-ignore -q -- "$path"; then
        continue
    fi
    fail "generated path is not ignored: $path"
done

tracked_count=0
for path in $TRACKED_PATHS; do
    tracked_count=$((tracked_count + 1))
    if git check-ignore -q -- "$path"; then
        fail "tracked path is ignored: $path"
    fi
    if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
        continue
    fi
    fail "table entry is no longer tracked; update this script: $path"
done

for path in $UNIGNORED_PATHS; do
    if git check-ignore -q -- "$path"; then
        fail "reserved plain-text path is ignored: $path"
    fi
done

# The repo-wide `*` makes over-ignoring the main hazard: a tracked file that
# .gitignore also matches disappears from `git status` after any checkout that
# removes it. Nothing in the repository may be in that state.
SHADOWED=$(git ls-files --cached --ignored --exclude-standard)
if [ -n "$SHADOWED" ]; then
    echo "gitignore gate: .gitignore shadows tracked files:" >&2
    printf '%s\n' "$SHADOWED" | sed 's/^/  - /' >&2
    echo "Add a negation to .gitignore, or stop tracking the path." >&2
    failed=1
fi

# The Cargo template this file replaced kept Rust-only rules alive long after
# the Rust stage0 was removed in #795.
if grep -Eni 'cargo|rustc|rustfmt|rustrover|target_ra|mutants\.out|\.rs\.bk' .gitignore >&2; then
    fail "Rust/Cargo leftovers in .gitignore (lines above)"
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "gitignore gate: $ignored_count generated paths ignored, $tracked_count tracked paths visible"
