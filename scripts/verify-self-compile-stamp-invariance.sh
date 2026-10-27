#!/usr/bin/env sh
set -eu

# Reuse this checkout's completed bootstrap/measurement, then build and measure
# a distinct commit of the exact same tree at the same path. The synthetic
# commit is local to this experiment; its record is never a main reference.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-self-compile.sh"
[ "$(uname -s)" = Linux ] || { echo 'stamp invariance requires Linux' >&2; exit 2; }
[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 2; }
git diff --quiet && git diff --cached --quiet || {
    echo 'stamp invariance requires a committed, clean source tree' >&2
    exit 1
}

mkdir -p "$ROOT/target/exp"
OUT=$(mktemp -d "$ROOT/target/exp/self-compile-stamp.XXXXXX")
COMMIT_A=$(git rev-parse HEAD)
TREE=$(git rev-parse 'HEAD^{tree}')
ORIGINAL_REF=$(git symbolic-ref --short -q HEAD || printf '%s' "$COMMIT_A")
COMMIT_B=$(printf 'Same-tree stamp invariance probe\n\nRefs #9331\n' |
    git -c user.name=TypeLisp -c user.email=typelisp@example.invalid \
        commit-tree "$TREE" -p "$COMMIT_A")
[ "$COMMIT_A" != "$COMMIT_B" ]
[ "$(git rev-parse "$COMMIT_B^{tree}")" = "$TREE" ]

GATE=target/self-compile/measurement/record.tsv
sc_record_validate "$GATE" gate
[ "$(sc_record_get "$GATE" commit)" = "$COMMIT_A" ]
[ "$(sc_record_get "$GATE" tree)" = "$TREE" ]
COMPILER_A=$(cat target/ci-verify-stage2.path)
[ "$(sha256sum "$COMPILER_A" | cut -c1-64)" = "$(sc_record_get "$GATE" compiler_sha256)" ]
cmp target/bootstrap-fixpoint/stage2.s target/bootstrap-fixpoint/stage3.s
cmp "$COMPILER_A" target/bootstrap-fixpoint/stage2
[ "$("$COMPILER_A" --producer-identity)" = "$TREE" ]
cp "$GATE" "$OUT/a.tsv"
cp "$COMPILER_A" "$OUT/a-stage2"
cp target/bootstrap-fixpoint/stage2.s "$OUT/a-stage2.s"
cp target/ci-verify-stage1.path "$OUT/stage1.path"
cp target/ci-verify-stage2.path "$OUT/stage2.path"
cp target/embedded-stdlib-tlci/stdlib.tlci "$OUT/a.tlci"
cp target/embedded-stdlib-tlci/stdlib.tlci.tlch "$OUT/a.tlch"
cp target/self-compile/measurement/gate.cachegrind.out "$OUT/a.cachegrind.out"
cp target/build-stage0/git-hash.txt "$OUT/commit-input"
cp target/build-stage0/tree-hash.txt "$OUT/tree-input"
SEED="$ROOT/target/stage0/typelisp"
[ -x "$SEED" ]

restore() {
    git -c advice.detachedHead=false checkout --quiet "$ORIGINAL_REF"
    cp "$OUT/commit-input" target/build-stage0/git-hash.txt
    cp "$OUT/tree-input" target/build-stage0/tree-hash.txt
    cp "$OUT/stage1.path" target/ci-verify-stage1.path
    cp "$OUT/stage2.path" target/ci-verify-stage2.path
    cp "$OUT/a.tsv" "$GATE"
    cp "$OUT/a.cachegrind.out" target/self-compile/measurement/gate.cachegrind.out
}
trap 'exit 1' INT TERM HUP
trap restore EXIT

git -c advice.detachedHead=false checkout --quiet --detach "$COMMIT_B"
# A fresh work directory and the same retained seed; no output from the first
# bootstrap can satisfy the second bootstrap's fixpoint or provenance checks.
env -u BASH_ENV scripts/run-memory-bounded.sh --limit-mib 6144 \
    --timeout-seconds 1800 --report "$OUT/bootstrap-b.memory" -- \
    env -u BASH_ENV TYPELISP_BIN="$SEED" \
    TYPELISP_INLINE_TEST_WORKERS=1 TYPELISP_BUILD_INVARIANCE_WORKERS=1 \
    TYPELISP_BOOTSTRAP_WORKDIR="$OUT/bootstrap-b" \
    scripts/ci-verify.sh --gates bootstrap-fixpoint > "$OUT/bootstrap-b.log" 2>&1
COMPILER_B=$(cat target/ci-verify-stage2.path)
cmp "$OUT/bootstrap-b/stage2.s" "$OUT/bootstrap-b/stage3.s"
cmp "$COMPILER_B" "$OUT/bootstrap-b/stage2"
[ "$("$COMPILER_B" --producer-identity)" = "$TREE" ]
cp "$COMPILER_B" "$OUT/b-stage2"
cp "$OUT/bootstrap-b/stage2.s" "$OUT/b-stage2.s"
cp target/embedded-stdlib-tlci/stdlib.tlci "$OUT/b.tlci"
cp target/embedded-stdlib-tlci/stdlib.tlci.tlch "$OUT/b.tlch"
cmp "$OUT/a.tlci" "$OUT/b.tlci"
cmp "$OUT/a.tlch" "$OUT/b.tlch"

env -u BASH_ENV scripts/run-memory-bounded.sh --limit-mib 6144 \
    --timeout-seconds 1800 --report "$OUT/measure-b.memory" -- \
    env -u BASH_ENV scripts/self-compile.sh measure --compiler "$COMPILER_B" \
    > "$OUT/measure-b.log" 2>&1
cp "$GATE" "$OUT/b.tsv"
cp target/self-compile/measurement/gate.cachegrind.out "$OUT/b.cachegrind.out"
sc_record_validate "$OUT/b.tsv" gate
[ "$(sc_record_get "$OUT/b.tsv" commit)" = "$COMMIT_B" ]
[ "$(sc_record_get "$OUT/b.tsv" tree)" = "$TREE" ]
sc_records_comparable "$OUT/a.tsv" "$OUT/b.tsv"
[ "$(sc_record_get "$OUT/a.tsv" ir_count)" = "$(sc_record_get "$OUT/b.tsv" ir_count)" ]

# Require exactly one verbatim provenance field, at the same byte offset.
# Replacing only that field must make the entire native compiler identical.
[ "$(LC_ALL=C grep -ao "$COMMIT_A" "$OUT/a-stage2" | wc -l)" -eq 1 ]
[ "$(LC_ALL=C grep -ao "$COMMIT_B" "$OUT/b-stage2" | wc -l)" -eq 1 ]
OFFSET_A=$(LC_ALL=C grep -aob "$COMMIT_A" "$OUT/a-stage2" | cut -d: -f1)
OFFSET_B=$(LC_ALL=C grep -aob "$COMMIT_B" "$OUT/b-stage2" | cut -d: -f1)
[ "$OFFSET_A" = "$OFFSET_B" ]
LC_ALL=C sed "s/$COMMIT_A/0000000000000000000000000000000000000000/g" \
    "$OUT/a-stage2" > "$OUT/a-normalized"
LC_ALL=C sed "s/$COMMIT_B/0000000000000000000000000000000000000000/g" \
    "$OUT/b-stage2" > "$OUT/b-normalized"
cmp "$OUT/a-normalized" "$OUT/b-normalized"

{
    printf 'commit_a\t%s\ncommit_b\t%s\ntree\t%s\n' "$COMMIT_A" "$COMMIT_B" "$TREE"
    printf 'ir_count\t%s\nir_delta\t0\n' "$(sc_record_get "$OUT/a.tsv" ir_count)"
    printf 'stamp_offset\t%s\nstamp_bytes\t40\n' "$OFFSET_A"
    printf 'normalized_sha256\t%s\n' "$(sha256sum "$OUT/a-normalized" | cut -c1-64)"
    printf 'seed_sha256\t%s\n' "$(sha256sum "$SEED" | cut -c1-64)"
    printf 'image_sha256\t%s\n' "$(sha256sum "$OUT/a.tlci" | cut -c1-64)"
    printf 'envelope_sha256\t%s\n' "$(sha256sum "$OUT/a.tlch" | cut -c1-64)"
    printf 'outcome\tpass\n'
} > "$OUT/result.tsv"
git cat-file commit "$COMMIT_A" > "$OUT/a.commit"
git cat-file commit "$COMMIT_B" > "$OUT/b.commit"
cat "$OUT/result.tsv"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '\n### Identical-tree commit stamp invariance\n\n```text\n' >> "$GITHUB_STEP_SUMMARY"
    cat "$OUT/result.tsv" >> "$GITHUB_STEP_SUMMARY"
    printf '```\n' >> "$GITHUB_STEP_SUMMARY"
fi
printf 'stamp invariance evidence: %s\n' "$OUT"
