#!/usr/bin/env sh
set -eu

# Reuse this checkout's completed bootstrap/measurement, then build and measure
# a distinct commit of the exact same tree at the same path. The synthetic
# commit is local to this experiment; its record is never a main reference.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-self-compile.sh"
[ "$(uname -s)" = Linux ] || { echo 'stamp invariance requires Linux' >&2; exit 2; }

# These are the shared inputs/handoffs rewritten or removed by the nested
# bootstrap and measurement. Preserve entire input directories, not just the
# files a successful run happens to produce. Absence is part of the snapshot.
STAMP_INPUTS='target/embedded-stdlib-tlci
target/build-stage0/git-hash.txt
target/build-stage0/tree-hash.txt
target/ci-verify-stage1.path
target/ci-verify-stage2.path
target/ci-verify-opt2-reference.path
target/ci-verify-compile-profile-cli.path
target/self-compile/measurement'

stamp_state() {
    _ss_action=$1
    _ss_root=$2
    _ss_backup=$3
    case "$_ss_root" in
        "$ROOT" | "$ROOT"/target/exp/*) ;;
        *) echo 'stamp state root is outside its owned workspace' >&2; return 1 ;;
    esac
    case "$_ss_backup" in
        "$ROOT"/target/exp/*) ;;
        *) echo 'stamp state backup is outside target/exp' >&2; return 1 ;;
    esac
    for _ss_path in $STAMP_INPUTS; do
        _ss_live="${_ss_root:?}/${_ss_path:?}"
        _ss_saved="${_ss_backup:?}/original/${_ss_path:?}"
        if [ "$_ss_action" = restore ]; then
            # Move experiment outputs aside even when the original was absent.
            # Retain failed/partial artifacts without deleting any variable path.
            if [ -e "$_ss_live" ] || [ -L "$_ss_live" ]; then
                _ss_displaced="${_ss_backup:?}/displaced/${_ss_path:?}"
                mkdir -p "$(dirname -- "$_ss_displaced")"
                mv "$_ss_live" "$_ss_displaced"
            fi
            if [ -e "$_ss_saved" ] || [ -L "$_ss_saved" ]; then
                mkdir -p "$(dirname -- "$_ss_live")"
                cp -pR "$_ss_saved" "$_ss_live"
            fi
        elif [ "$_ss_action" = save ]; then
            if [ -e "$_ss_live" ] || [ -L "$_ss_live" ]; then
                mkdir -p "$(dirname -- "$_ss_saved")"
                cp -pR "$_ss_live" "$_ss_saved"
            fi
        else
            echo "unknown stamp state action: $_ss_action" >&2
            return 1
        fi
    done
}

stamp_restore_self_test() {
    mkdir -p "$ROOT/target/exp"
    _st_dir=$(mktemp -d "$ROOT/target/exp/stamp-restore-test.XXXXXX")
    for _st_optional in ci-verify-opt2-reference.path ci-verify-compile-profile-cli.path; do
        _st_case="$_st_dir/$_st_optional"
        _st_root="$_st_case/root"
        mkdir -p "$_st_root/target/embedded-stdlib-tlci" \
            "$_st_root/target/build-stage0" "$_st_root/target/self-compile/measurement"
        for _st_path in embedded-stdlib-tlci/stdlib.tlci.tlch \
            embedded-stdlib-tlci/source-hash.txt build-stage0/git-hash.txt \
            build-stage0/tree-hash.txt self-compile/measurement/record.tsv \
            ci-verify-stage1.path ci-verify-stage2.path "$_st_optional"; do
            printf 'original %s\n' "$_st_path" > "$_st_root/target/$_st_path"
        done
        cp -pR "$_st_root/target" "$_st_case/expected"
        stamp_state save "$_st_root" "$_st_case/snapshot"
        set +e
        (
            set -e
            trap 'stamp_state restore "$_st_root" "$_st_case/snapshot"' EXIT
            printf 'partial image' > "$_st_root/target/embedded-stdlib-tlci/stdlib.tlci.tlch"
            printf 'partial hash' > "$_st_root/target/embedded-stdlib-tlci/source-hash.txt"
            printf 'new artifact' > "$_st_root/target/embedded-stdlib-tlci/extra"
            printf 'synthetic' > "$_st_root/target/build-stage0/git-hash.txt"
            printf 'synthetic' > "$_st_root/target/build-stage0/tree-hash.txt"
            printf 'partial record' > "$_st_root/target/self-compile/measurement/record.tsv"
            for _st_path in ci-verify-stage1.path ci-verify-stage2.path \
                ci-verify-opt2-reference.path ci-verify-compile-profile-cli.path; do
                if [ -f "$_st_root/target/$_st_path" ]; then
                    mv "$_st_root/target/$_st_path" "$_st_case/removed-$_st_path"
                fi
                printf 'synthetic' > "$_st_root/target/$_st_path"
            done
            exit 17
        )
        _st_status=$?
        set -e
        [ "$_st_status" -eq 17 ]
        diff -r "$_st_case/expected" "$_st_root/target"
    done
    echo 'stamp restoration failure-injection self-test passed'
}

case "${1:-}" in
    --self-test) [ "$#" -eq 1 ]; stamp_restore_self_test; exit ;;
    '') [ "$#" -eq 0 ] ;;
    *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
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
cp target/embedded-stdlib-tlci/stdlib.tlci "$OUT/a.tlci"
cp target/embedded-stdlib-tlci/stdlib.tlci.tlch "$OUT/a.tlch"
cp target/self-compile/measurement/gate.cachegrind.out "$OUT/a.cachegrind.out"
SEED="$ROOT/target/stage0/typelisp"
[ -x "$SEED" ]
stamp_state save "$ROOT" "$OUT/state"

restore() {
    git -c advice.detachedHead=false checkout --quiet "$ORIGINAL_REF"
    stamp_state restore "$ROOT" "$OUT/state"
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
[ "$(sha256sum "$OUT/b-stage2" | cut -c1-64)" = "$(sc_record_get "$OUT/b.tsv" compiler_sha256)" ]
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
