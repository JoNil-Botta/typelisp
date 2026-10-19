#!/usr/bin/env sh
set -eu

# Bounded, cross-host independent-model and production comparisons (#8449).
# A compiler failure, timeout, missing report, stale input or extra output
# fails the campaign. Expected semantic rejection is checked inside TypeLisp;
# process failure is never interpreted as a successful rejection.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
GATE_FAIL_PREFIX='ownership model: '
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_compiler_absolute
gate_require_compiler

[ "$#" -eq 0 ] || fail "usage: scripts/verify-ownership-model.sh"
case "$(uname -s)" in
    Linux*) TARGET=linux-x86_64; SUFFIX= ;;
    MINGW* | MSYS* | CYGWIN*) TARGET=windows-x86_64; SUFFIX=.exe ;;
    *) fail "unsupported host" ;;
esac

WORKDIR=${TYPELISP_OWNERSHIP_MODEL_WORKDIR:-$ROOT/target/exp/ownership-model-verify}
mkdir -p "$WORKDIR"
WORKDIR=$(CDPATH= cd -- "$WORKDIR" && pwd)
RUNNER_SHELL=$(command -v sh)
SOURCE_MODEL="$ROOT/tools/ownership-model/main.tl"
SOURCE_COMPARE="$ROOT/tools/ownership-model/crosscheck.tl"
SOURCE_CORE="$ROOT/src/compiler_ownership_core.tl"
SOURCE_MUTATION="$ROOT/tools/ownership-model/mutation_witness.tl"
SOURCE_LOAN_MODEL="$ROOT/tools/ownership-model/loan_model.tl"
SOURCE_LOAN_MAIN="$ROOT/tools/ownership-model/loan_main.tl"
SOURCE_LOAN_COMPARE="$ROOT/tools/ownership-model/loan_crosscheck.tl"
SOURCE_LOAN_MUTATION="$ROOT/tools/ownership-model/loan_mutation_witness.tl"
SOURCE_LOAN_CASES="$ROOT/tools/ownership-model/loan_cases.tl"
SOURCE_CLEANUP_MODEL="$ROOT/tools/ownership-model/cleanup_model.tl"
SOURCE_CLEANUP_MAIN="$ROOT/tools/ownership-model/cleanup_main.tl"
SOURCE_CLEANUP_CASES="$ROOT/tools/ownership-model/cleanup_cases.tl"
SOURCE_CLEANUP_COMPARE="$ROOT/tools/ownership-model/cleanup_crosscheck.tl"
SOURCE_CLEANUP_CFG="$ROOT/tools/ownership-model/cleanup_cfg_crosscheck.tl"
SOURCE_CLEANUP_RENAME="$ROOT/tools/ownership-model/cleanup_rename.tl"
SOURCE_CLEANUP_MUTATION="$ROOT/tools/ownership-model/cleanup_mutation_witness.tl"
SOURCE_LOAN_LAWS="$ROOT/tools/ownership-model/loan_laws.tl"
SOURCE_LOAN_VALUE="$ROOT/tools/ownership-model/loan_value_crosscheck.tl"
SOURCE_ALLOCATION_MODEL="$ROOT/tools/ownership-model/allocation_model.tl"

# Directory-relative imports precede compiler roots. A stray local core would
# change the baseline authority without changing SOURCE_CORE's digest.
[ ! -e "$ROOT/tools/ownership-model/compiler_ownership_core.tl" ] \
    || fail "model directory must not shadow the production ownership core"

input_identities() {
    # Include the complete stdlib source set so transitive imports, prelude
    # macros, and newly added import candidates cannot change unnoticed.
    # Unrelated compiler modules are not inputs to either standalone program.
    find "$ROOT/stdlib" -type f -name '*.tl' -print \
        > "$WORKDIR/stdlib-files.unsorted"
    LC_ALL=C sort "$WORKDIR/stdlib-files.unsorted" > "$WORKDIR/stdlib-files.txt"
    [ -s "$WORKDIR/stdlib-files.txt" ] || fail "stdlib source inventory is empty"
    sha256sum "$COMPILER" "$SOURCE_MODEL" "$SOURCE_COMPARE" "$SOURCE_CORE" "$SOURCE_MUTATION"
    sha256sum "$SOURCE_LOAN_MODEL" "$SOURCE_LOAN_MAIN" "$SOURCE_LOAN_COMPARE" "$SOURCE_LOAN_MUTATION"
    sha256sum "$SOURCE_LOAN_CASES" "$SOURCE_CLEANUP_MODEL" "$SOURCE_CLEANUP_MAIN" "$SOURCE_CLEANUP_MUTATION"
    sha256sum "$SOURCE_CLEANUP_CASES"
    sha256sum "$SOURCE_CLEANUP_COMPARE" "$SOURCE_CLEANUP_CFG" "$SOURCE_CLEANUP_RENAME"
    sha256sum "$SOURCE_LOAN_LAWS" "$SOURCE_LOAN_VALUE"
    sha256sum "$SOURCE_ALLOCATION_MODEL"
    while IFS= read -r dependency; do
        sha256sum "$dependency"
    done < "$WORKDIR/stdlib-files.txt"
}

input_identities > "$WORKDIR/identities.before.sha256"
git rev-parse HEAD > "$WORKDIR/source-commit.txt"
"$COMPILER" --version > "$WORKDIR/compiler-version.txt"
cp "$SOURCE_MODEL" "$WORKDIR/model.source.tl"
cp "$SOURCE_COMPARE" "$WORKDIR/crosscheck.source.tl"
cp "$SOURCE_CORE" "$WORKDIR/core.source.tl"
cp "$SOURCE_MUTATION" "$WORKDIR/mutation-witness.source.tl"
cp "$SOURCE_LOAN_MODEL" "$WORKDIR/loan-model.source.tl"
cp "$SOURCE_LOAN_MAIN" "$WORKDIR/loan-main.source.tl"
cp "$SOURCE_LOAN_COMPARE" "$WORKDIR/loan-crosscheck.source.tl"
cp "$SOURCE_LOAN_MUTATION" "$WORKDIR/loan-mutation-witness.source.tl"
cp "$SOURCE_LOAN_CASES" "$WORKDIR/loan-cases.source.tl"
cp "$SOURCE_CLEANUP_MODEL" "$WORKDIR/cleanup-model.source.tl"
cp "$SOURCE_CLEANUP_MAIN" "$WORKDIR/cleanup-main.source.tl"
cp "$SOURCE_CLEANUP_CASES" "$WORKDIR/cleanup-cases.source.tl"
cp "$SOURCE_CLEANUP_COMPARE" "$WORKDIR/cleanup-crosscheck.source.tl"
cp "$SOURCE_CLEANUP_CFG" "$WORKDIR/cleanup-cfg-crosscheck.source.tl"
cp "$SOURCE_CLEANUP_RENAME" "$WORKDIR/cleanup-rename.source.tl"
cp "$SOURCE_CLEANUP_MUTATION" "$WORKDIR/cleanup-mutation-witness.source.tl"
cp "$SOURCE_LOAN_LAWS" "$WORKDIR/loan-laws.source.tl"
cp "$SOURCE_LOAN_VALUE" "$WORKDIR/loan-value-crosscheck.source.tl"
cp "$SOURCE_ALLOCATION_MODEL" "$WORKDIR/allocation-model.source.tl"

bounded() {
    _phase=$1
    _limit=$2
    _expected_status=$3
    shift 3
    _status=0
    # A reused workdir must not let a wrapper failure reuse an older child
    # witness or resource report, especially for expected failing mutations.
    rm -f "$WORKDIR/$_phase.report" "$WORKDIR/$_phase.stdout" \
        "$WORKDIR/$_phase.stderr"
    "$ROOT/scripts/run-memory-bounded.sh" --limit-mib "$_limit" \
        --timeout-seconds 120 --report "$WORKDIR/$_phase.report" \
        -- "$RUNNER_SHELL" -c \
        'out=$1; err=$2; shift 2; exec "$@" >"$out" 2>"$err"' \
        sh "$WORKDIR/$_phase.stdout" "$WORKDIR/$_phase.stderr" "$@" \
        > "$WORKDIR/$_phase.wrapper.stdout" 2> "$WORKDIR/$_phase.wrapper.stderr" || _status=$?
    if [ "$_status" -ne "$_expected_status" ]; then
        cat "$WORKDIR/$_phase.stdout" "$WORKDIR/$_phase.stderr" \
            "$WORKDIR/$_phase.wrapper.stdout" "$WORKDIR/$_phase.wrapper.stderr" >&2
        fail "$_phase failed with status $_status; artifacts: $WORKDIR"
    fi
    [ -s "$WORKDIR/$_phase.report" ] || fail "$_phase has no resource report"
    _reason=success
    [ "$_expected_status" -eq 0 ] || _reason=command-failure
    grep -Fx "reason=$_reason" "$WORKDIR/$_phase.report" >/dev/null || fail "$_phase incomplete"
    grep -Fx "exit_code=$_expected_status" "$WORKDIR/$_phase.report" >/dev/null || fail "$_phase wrong exit report"
    [ ! -s "$WORKDIR/$_phase.stderr" ] || {
        cat "$WORKDIR/$_phase.stderr" >&2
        fail "$_phase produced stderr"
    }
}

# Literal replacement supports multiline proof guards without treating source
# text as a regular expression. Missing or repeated sites are harness failures.
mutate_literal() {
    OWNERSHIP_MUTATION_ORIGINAL=$3 OWNERSHIP_MUTATION_REPLACEMENT=$4 \
    awk '
        BEGIN {
            original = ENVIRON["OWNERSHIP_MUTATION_ORIGINAL"]
            replacement = ENVIRON["OWNERSHIP_MUTATION_REPLACEMENT"]
        }
        { source = source $0 "\n" }
        END {
            at = index(source, original)
            if (!length(original) || !at) exit 1
            rest = substr(source, at + length(original))
            if (index(rest, original)) exit 1
            printf "%s%s%s", substr(source, 1, at - 1), replacement, rest
        }
    ' "$1" > "$2" || fail "mutation target is missing or repeated: $2"
    cmp -s "$1" "$2" && fail "mutation left source unchanged: $2"
    return 0
}

# Keep a multi-line exact witness in one TSV field. The .expected and child
# stdout artifacts retain the original bytes for the semantic comparison.
record_mutation() {
    _witness=$(printf '%s' "$3" | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')
    printf '%s\t%s\t%s\n' "$1" "$2" "$_witness" >> "$WORKDIR/mutations.tsv"
}

for opt in 0 1 2; do
    for program in model crosscheck mutation-controls loan-model loan-crosscheck loan-mutation-controls cleanup-model cleanup-mutation-controls cleanup-crosscheck cleanup-cfg loan-laws loan-value allocation-model; do
        source=$SOURCE_MODEL
        expected='ownership-model-v1: lattice=82 concrete=16 places=6 operations=4 graphs=460800 passed'
        if [ "$program" = crosscheck ]; then
            source=$SOURCE_COMPARE
            expected='ownership-crosscheck-v1: transfers=2916 graphs=28800 passed'
        fi
        if [ "$program" = mutation-controls ]; then
            source=$SOURCE_MUTATION
            expected='ownership-model mutation controls passed'
        fi
        if [ "$program" = loan-model ]; then
            source=$SOURCE_LOAN_MAIN
            expected='ownership-loan-model-v1: direct=576 reborrow=13 three=8 passed'
        fi
        if [ "$program" = loan-crosscheck ]; then
            source=$SOURCE_LOAN_COMPARE
            expected='ownership-loan-crosscheck-v1: direct=576 reborrow=137 three=3848 graphs=17 paths=54 passed'
        fi
        if [ "$program" = loan-mutation-controls ]; then
            source=$SOURCE_LOAN_MUTATION
            expected='ownership-loan-model mutation controls passed'
        fi
        if [ "$program" = cleanup-model ]; then
            source=$SOURCE_CLEANUP_MAIN
            expected='ownership-cleanup-model-v2: direct=192 controls=18 construction=30 bounds=2 passed'
        fi
        if [ "$program" = cleanup-mutation-controls ]; then
            source=$SOURCE_CLEANUP_MUTATION
            expected='ownership-cleanup-model mutation controls passed'
        fi
        if [ "$program" = cleanup-crosscheck ]; then
            source=$SOURCE_CLEANUP_COMPARE
            expected='ownership-cleanup-crosscheck-v1: direct=576 controls=90 passed'
        fi
        if [ "$program" = cleanup-cfg ]; then
            source=$SOURCE_CLEANUP_CFG
            expected='ownership-cleanup-cfg-crosscheck-v1: graphs=5 paths=16 passed'
        fi
        if [ "$program" = loan-laws ]; then
            source=$SOURCE_LOAN_LAWS
            expected='ownership-loan-laws-v1: scalar=8 pairs=64 triples=512 product-pairs=262144 expiry=4096 transfers=3087 members=15552 monotone=61731 passed'
        fi
        if [ "$program" = loan-value ]; then
            source=$SOURCE_LOAN_VALUE
            expected='ownership-loan-value-crosscheck-v1: values=1160 branch=20 return=12 controls=10 passed'
        fi
        if [ "$program" = allocation-model ]; then
            source=$SOURCE_ALLOCATION_MODEL
            expected='ownership-allocation-model-v1: lifetimes=672 controls=12 page-cases=1224 passed'
        fi
        phase="$program-opt$opt"
        executable="$WORKDIR/$phase$SUFFIX"
        rm -f "$executable"
        bounded "$phase-build" 1024 0 "$COMPILER" build "$source" \
            --target "$TARGET" --opt-level "$opt" \
            --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" -o "$executable"
        [ -s "$executable" ] || fail "$phase produced no executable"
        bounded "$phase-run" 256 0 "$executable"
        printf '%s\n' "$expected" > "$WORKDIR/$phase.expected"
        cmp "$WORKDIR/$phase.expected" "$WORKDIR/$phase-run.stdout" >/dev/null || {
            cat "$WORKDIR/$phase-run.stdout" >&2
            fail "$phase produced incomplete or malformed output"
        }
        printf '%s\n' "$phase passed"
    done
done

# Deliberately wrong production transfers are built only from isolated source
# copies. Each selected edit must occur exactly once. Genuine compilation must
# succeed, then the concrete oracle must find the specific witness and exit 1;
# a parse/type error, crash, timeout, different mismatch or success all fail.
printf 'mutation\tobligation\twitness\n' > "$WORKDIR/mutations.tsv"
for mutation in consume-drop move-drop join-drop-predecessor; do
    mutant_dir="$WORKDIR/mutation-$mutation"
    mkdir -p "$mutant_dir"
    cp "$SOURCE_MODEL" "$mutant_dir/main.tl"
    cp "$SOURCE_COMPARE" "$mutant_dir/crosscheck.tl"
    mutant="$mutant_dir/compiler_ownership_core.tl"
    case "$mutation" in
        consume-drop)
            original='(ownership-set-result!
          places
          state
          place.index
          1'
            replacement='(ownership-set-result!
          places
          state
          place.index
          2'
            obligation='Consume clears non-Copy source'
            expected='ownership-crosscheck transfer mismatch: abstract=1 operation=7'
            ;;
        move-drop)
            original='(match (ownership-set-result!
          places
          state
          source.index
          1'
            replacement='(match (ownership-set-result!
          places
          state
          source.index
          2'
            obligation='Move clears non-Copy source while initializing destination'
            expected='ownership-crosscheck move mismatch: abstract=1 source=1 destination=3'
            ;;
        join-drop-predecessor)
            original='                                  (ownership-state-join'
            replacement='                                  (ownership-mutant-ignore-predecessor'
            obligation='Join includes every predecessor state'
            expected='ownership-crosscheck graph mismatch: initial=15 left=0 right=6 cleanup=false expected=false'
            ;;
    esac
    mutate_literal "$SOURCE_CORE" "$mutant" "$original" "$replacement"
    if [ "$mutation" = join-drop-predecessor ]; then
        # Mutate only the CFG merge. Parent summaries keep their normal join,
        # and the first predecessor still initializes an unreached input.
        cat >> "$mutant" <<'EOF'

(define (ownership-mutant-ignore-predecessor [prior : i64] [incoming : i64]) : i64
  (if (= prior 0) incoming prior))
EOF
    fi
    sha256sum "$mutant_dir/main.tl" "$mutant_dir/crosscheck.tl" "$mutant" \
        > "$mutant_dir/identities.sha256"
    record_mutation "$mutation" "$obligation" "$expected"
    executable="$mutant_dir/check$SUFFIX"
    rm -f "$executable"
    bounded "$mutation-build" 1024 0 "$COMPILER" build "$mutant_dir/crosscheck.tl" \
        --target "$TARGET" --opt-level 1 --stdlib-root "$ROOT/stdlib" -o "$executable"
    [ -s "$executable" ] || fail "$mutation produced no executable"
    bounded "$mutation-run" 256 1 "$executable"
    printf '%s\n' "$expected" > "$WORKDIR/$mutation.expected"
    cmp "$WORKDIR/$mutation.expected" "$WORKDIR/$mutation-run.stdout" >/dev/null || {
        cat "$WORKDIR/$mutation-run.stdout" >&2
        fail "$mutation failed without its independently specified witness"
    }
    printf '%s\n' "$mutation detected"
done

# Mutate the model implementation itself, leaving its concrete semantics and
# the independently specified expected-state driver unchanged. Exact line
# selection plus the Move-arm boundary prevents a similarly spelled concrete
# or invalidation operation from becoming the mutation target.
for mutation in move join cleanup backedge; do
    mutant_dir="$WORKDIR/model-mutation-$mutation"
    mkdir -p "$mutant_dir"
    cp "$SOURCE_MUTATION" "$mutant_dir/mutation_witness.tl"
    case "$mutation" in
        move)
            original='              (bit-and facts.definite clear)'
            replacement='              facts.definite'
            ;;
        join)
            original='        (bit-and a.definite b.definite)'
            replacement='        (bit-or a.definite b.definite)'
            ;;
        cleanup)
            original='                          cleanup'
            replacement='                          false'
            ;;
        backedge)
            original='                                (model-join result.header step.facts))'
            replacement='                                result.header)'
            ;;
    esac
    awk -v kind="$mutation" -v original="$original" -v replacement="$replacement" '
        /^        \[\(ModelOperation.Move\)/ { move_arm = 1 }
        {
            if ($0 == original && (kind != "move" || move_arm)) {
                print replacement
                changed++
                move_arm = 0
            } else print
        }
        END { if (changed != 1) exit 1 }
    ' "$SOURCE_MODEL" > "$mutant_dir/main.tl" || fail "model $mutation target is not unique"
    cmp -s "$SOURCE_MODEL" "$mutant_dir/main.tl" && fail "model $mutation left source unchanged"
    sha256sum "$mutant_dir/main.tl" "$mutant_dir/mutation_witness.tl" > "$mutant_dir/identities.sha256"
    phase="model-$mutation"
    executable="$mutant_dir/check$SUFFIX"
    rm -f "$executable"
    bounded "$phase-build" 1024 0 "$COMPILER" build "$mutant_dir/mutation_witness.tl" \
        --target "$TARGET" --opt-level 1 --stdlib-root "$ROOT/stdlib" -o "$executable"
    [ -s "$executable" ] || fail "$phase produced no executable"
    bounded "$phase-run" 256 1 "$executable"
    expected="ownership-model mutation mismatch: $mutation"
    printf '%s\n' "$expected" > "$WORKDIR/$phase.expected"
    cmp "$WORKDIR/$phase.expected" "$WORKDIR/$phase-run.stdout" >/dev/null || {
        cat "$WORKDIR/$phase-run.stdout" >&2
        fail "$phase failed without its specified semantic witness"
    }
    record_mutation "$phase" "Abstract model preserves $mutation semantics" "$expected"
    printf '%s\n' "$phase detected"
done

for mutation in parent-retention shared-write end-demand loan-join second-successor backedge issue-conflict ancestor-retention grant-ancestors definition-retention parent-reissue; do
    mutant_dir="$WORKDIR/loan-mutation-$mutation"
    mkdir -p "$mutant_dir"
    cp "$SOURCE_LOAN_MODEL" "$mutant_dir/loan_model.tl"
    cp "$SOURCE_LOAN_MAIN" "$mutant_dir/loan_main.tl"
    cp "$SOURCE_LOAN_CASES" "$mutant_dir/loan_cases.tl"
    cp "$SOURCE_LOAN_COMPARE" "$mutant_dir/loan_crosscheck.tl"
    case "$mutation" in
        parent-retention)
            original='        (set! cursor (ownership-loan-parent (& (array-ref body.loans cursor))))))))'
            replacement='        (set! cursor -1)))))'
            obligation='A retained child retains its parent capability'
            expected='ownership-loan-crosscheck reborrow mismatch: mode=0'
            ;;
        shared-write)
            original='[(OwnershipAccess.Write) (ownership-loan-exclusive? loan)]'
            replacement='[(OwnershipAccess.Write) true]'
            obligation='Writing through a capability requires exclusive authority'
            expected='ownership-loan-crosscheck reborrow mismatch: mode=6'
            ;;
        end-demand)
            original='(if (ownership-loan-live? live after loan.index)'
            replacement='(if false'
            obligation='Explicit ending cannot discard future child uses'
            expected='ownership-loan-crosscheck reborrow mismatch: mode=3'
            ;;
        loan-join)
            original='(ownership-loan-state-join
                                    prior
                                    (array-ref loan-state i))'
            # Loan states are bit planes; a reached input never changes again,
            # as a nonzero per-loan code would never be replaced.
            replacement='(if (array-ref reached target)
                                    prior
                                    (array-ref loan-state i))'
            obligation='Loan authority includes every reachable predecessor'
            expected='ownership-loan-crosscheck graph facts mismatch: mode=0 path=1'
            ;;
        second-successor)
            original='(while (< edge 2)'
            replacement='(while (< edge 1)'
            obligation='Liveness visits both branch successors'
            expected='ownership-loan-crosscheck graph facts mismatch: mode=7 path=1'
            ;;
        backedge)
            original='          (>= target 0)
          (set! i 0)
          (while (< i wide)'
            replacement='          (> target b)
          (set! i 0)
          (while (< i wide)'
            obligation='Liveness includes loop backedges'
            expected='ownership-loan-crosscheck graph facts mismatch: mode=7 path=1'
            ;;
        issue-conflict)
            original='(match (ownership-loan-access
          body
          state
          loan.place.index
          parent
          (ownership-loan-exclusive? loan)
          block
          index
          (& instr.source)
          work
          limit)'
            replacement='(match OwnershipResult.Ok'
            obligation='Issuing sibling or direct loans checks existing conflicts'
            expected='ownership-loan-crosscheck three-loan mismatch: mode=0'
            ;;
        ancestor-retention)
            original='(set! cursor (ownership-loan-parent (& (array-ref body.loans cursor))))))))'
            replacement='(set! cursor (if (= cursor loan) (ownership-loan-parent (& (array-ref body.loans cursor))) -1))))))'
            obligation='Retained grandchildren keep every ancestor live'
            expected='ownership-loan-crosscheck three-loan mismatch: mode=4'
            ;;
        grant-ancestors)
            original='      (unless (ownership-charge! work limit 1) (return -1))
      (set! cursor (ownership-loan-parent (& (array-ref body.loans cursor)))))'
            replacement='      (unless (ownership-charge! work limit 1) (return -1))
      (set! cursor (if (= cursor loan) (ownership-loan-parent (& (array-ref body.loans cursor))) -1)))'
            obligation='Through access exempts the entire granting chain'
            expected='ownership-loan-crosscheck three-loan mismatch: mode=5'
            ;;
        definition-retention)
            original='      retained?
      (ownership-loan-bit-set! state 0 definition false)'
            replacement='      false
      (ownership-loan-bit-set! state 0 definition false)'
            obligation='Parent definitions preserve old descendants demanded across backedges'
            expected='ownership-loan-crosscheck graph facts mismatch: mode=7 path=1'
            ;;
        parent-reissue)
            original='            (!= (bit-and (ownership-loan-code state definition) 2) 0)
            (ownership-loan-exclusive? loan))'
            replacement='            (!= (bit-and (ownership-loan-code state definition) 2) 0)
            true)'
            obligation='A shared loan issued again joins its retained earlier issue'
            expected='ownership-loan-crosscheck graph mismatch: mode=14 expected=true'
            ;;
    esac
    mutate_literal "$SOURCE_CORE" "$mutant_dir/compiler_ownership_core.tl" "$original" "$replacement"
    sha256sum "$mutant_dir"/*.tl > "$mutant_dir/identities.sha256"
    phase="loan-$mutation"
    executable="$mutant_dir/check$SUFFIX"
    rm -f "$executable"
    bounded "$phase-build" 1024 0 "$COMPILER" build "$mutant_dir/loan_crosscheck.tl" \
        --target "$TARGET" --opt-level 1 --stdlib-root "$ROOT/stdlib" -o "$executable"
    [ -s "$executable" ] || fail "$phase produced no executable"
    bounded "$phase-run" 256 1 "$executable"
    printf '%s\n' "$expected" > "$WORKDIR/$phase.expected"
    cmp "$WORKDIR/$phase.expected" "$WORKDIR/$phase-run.stdout" >/dev/null || {
        cat "$WORKDIR/$phase-run.stdout" >&2
        fail "$phase failed without its independent semantic witness"
    }
    record_mutation "$phase" "$obligation" "$expected"
    printf '%s\n' "$phase detected"
done

for mutation in copy-destination consume-copy move-source branch return; do
    mutant_dir="$WORKDIR/loan-value-mutation-$mutation"
    mkdir -p "$mutant_dir"
    cp "$SOURCE_LOAN_MODEL" "$mutant_dir/loan_model.tl"
    cp "$SOURCE_LOAN_VALUE" "$mutant_dir/loan_value_crosscheck.tl"
    case "$mutation" in
        copy-destination)
            original='[(OwnershipOperation.Copy source dest)
        (match (ownership-loan-access
          body
          state
          source.index
          -1
          false
          block
          index
          (& instr.source)
          work
          limit)
          [(OwnershipResult.Err error) (OwnershipResult.Err error)]
          [(OwnershipResult.Ok)
            (ownership-loan-access
              body
              state
              dest.index
              -1
              true'
            replacement='[(OwnershipOperation.Copy source dest)
        (match (ownership-loan-access
          body
          state
          source.index
          -1
          false
          block
          index
          (& instr.source)
          work
          limit)
          [(OwnershipResult.Err error) (OwnershipResult.Err error)]
          [(OwnershipResult.Ok)
            (ownership-loan-access
              body
              state
              dest.index
              -1
              false'
            obligation='Copy checks destination write conflicts'
            expected='ownership-loan-value mismatch: family=1 case=70'
            ;;
        consume-copy)
            original='(not
            (array-ref
              body.types
              (array-ref body.places place.index).type.index).copy?)'
            replacement='true'
            obligation='Consuming Copy values needs only shared read authority'
            expected='ownership-loan-value mismatch: family=1 case=73'
            ;;
        move-source)
            original='(not
            (array-ref
              body.types
              (array-ref body.places source.index).type.index).copy?)'
            replacement='false'
            obligation='Moving non-Copy values conflicts with retained source loans'
            expected='ownership-loan-value mismatch: family=1 case=212'
            ;;
        branch)
            original='(ownership-loan-access
                            body
                            (& loan-state)
                            condition.index
                            -1
                            false
                            block-id
                            j
                            (& block.source)
                            (&mut work)
                            limits.max-work)'
            replacement='OwnershipResult.Ok'
            obligation='Branch conditions require loan read authority'
            expected='ownership-loan-value terminator mismatch: kind=0 case=17'
            ;;
        return)
            original='(ownership-read
                                  (& state)
                                  (& (array-ref operands.items k))
                                  block-id
                                  j
                                  (& block.source))'
            replacement='OwnershipResult.Ok'
            obligation='Returned values must be initialized'
            expected='ownership-loan-value terminator mismatch: kind=1 case=0'
            ;;
    esac
    mutate_literal "$SOURCE_CORE" "$mutant_dir/compiler_ownership_core.tl" "$original" "$replacement"
    sha256sum "$mutant_dir"/*.tl > "$mutant_dir/identities.sha256"
    phase="loan-value-$mutation"
    executable="$mutant_dir/check$SUFFIX"
    rm -f "$executable"
    bounded "$phase-build" 1024 0 "$COMPILER" build "$mutant_dir/loan_value_crosscheck.tl" \
        --target "$TARGET" --opt-level 1 --stdlib-root "$ROOT/stdlib" -o "$executable"
    [ -s "$executable" ] || fail "$phase produced no executable"
    bounded "$phase-run" 256 1 "$executable"
    printf '%s\n' "$expected" > "$WORKDIR/$phase.expected"
    cmp "$WORKDIR/$phase.expected" "$WORKDIR/$phase-run.stdout" >/dev/null || {
        cat "$WORKDIR/$phase-run.stdout" >&2
        fail "$phase failed without its independent semantic witness"
    }
    record_mutation "$phase" "$obligation" "$expected"
    printf '%s\n' "$phase detected"
done

for mutation in shared-write parent-retention end-demand expiry issue-conflict ancestor-retention; do
    mutant_dir="$WORKDIR/loan-model-mutation-$mutation"
    mkdir -p "$mutant_dir"
    cp "$SOURCE_LOAN_MUTATION" "$mutant_dir/loan_mutation_witness.tl"
    cp "$SOURCE_LOAN_CASES" "$mutant_dir/loan_cases.tl"
    case "$mutation" in
        shared-write)
            original='        (array-ref loans id).exclusive
        (contains?'
            replacement='        true
        (contains?'
            ;;
        parent-retention)
            original='(depends-on? loans memory index token)'
            replacement='(= index loan)'
            ;;
        end-demand)
            original='(not (needed-later? loans count (& memory) trace (+ index 1) id))'
            replacement='true'
            ;;
        expiry)
            original='          (unless
            (array-ref needed index)'
            replacement='          (when
            false'
            ;;
        issue-conflict)
            original='          (permitted?
            loans
            count
            (& memory)
            cell
            (array-ref loans id).exclusive
            parent)'
            replacement='          true'
            ;;
        ancestor-retention)
            original='              (set! current parent)
              (set! current (- 0 1))'
            replacement='              (set! current (if (= current child) parent -1))
              (set! current (- 0 1))'
            ;;
    esac
    mutate_literal "$SOURCE_LOAN_MODEL" "$mutant_dir/loan_model.tl" "$original" "$replacement"
    sha256sum "$mutant_dir"/*.tl > "$mutant_dir/identities.sha256"
    phase="loan-model-$mutation"
    executable="$mutant_dir/check$SUFFIX"
    rm -f "$executable"
    bounded "$phase-build" 1024 0 "$COMPILER" build "$mutant_dir/loan_mutation_witness.tl" \
        --target "$TARGET" --opt-level 1 --stdlib-root "$ROOT/stdlib" -o "$executable"
    [ -s "$executable" ] || fail "$phase produced no executable"
    bounded "$phase-run" 256 1 "$executable"
    expected="ownership-loan-model mutation mismatch: $mutation"
    printf '%s\n' "$expected" > "$WORKDIR/$phase.expected"
    cmp "$WORKDIR/$phase.expected" "$WORKDIR/$phase-run.stdout" >/dev/null || {
        cat "$WORKDIR/$phase-run.stdout" >&2
        fail "$phase failed without its specified semantic witness"
    }
    record_mutation "$phase" "Concrete loan model preserves $mutation semantics" "$expected"
    printf '%s\n' "$phase detected"
done

for mutation in join expiry borrow; do
    mutant_dir="$WORKDIR/loan-laws-mutation-$mutation"
    mkdir -p "$mutant_dir"
    cp "$SOURCE_LOAN_LAWS" "$mutant_dir/loan_laws.tl"
    case "$mutation" in
        join)
            original='(define (ownership-loan-state-join [a : i64] [b : i64]) : i64
  (bit-or a b))'
            replacement='(define (ownership-loan-state-join [a : i64] [b : i64]) : i64
  (bit-and a b))'
            expected='ownership-loan-laws mismatch: law=scalar-union first=0 second=1 third=0'
            ;;
        expiry)
            original='[gone : i64
          (bit-and
            (array-ref state (+ words w))
            (bit-not (array-ref liveness.live (+ base w))))]'
            replacement='[gone : i64 0]'
            expected='ownership-loan-laws mismatch: law=expiry-scalar first=2 second=0 third=2'
            ;;
        borrow)
            original='(when (>= definition 0) (ownership-loan-code-set! state definition 2))'
            replacement='(when (>= definition 0) (ownership-loan-code-set! state definition (ownership-loan-code state definition)))'
            expected='ownership-loan-laws mismatch: law=transfer-inclusion first=0 second=0 third=0'
            ;;
    esac
    mutate_literal "$SOURCE_CORE" "$mutant_dir/compiler_ownership_core.tl" "$original" "$replacement"
    sha256sum "$mutant_dir"/*.tl > "$mutant_dir/identities.sha256"
    phase="loan-laws-$mutation"
    executable="$mutant_dir/check$SUFFIX"
    rm -f "$executable"
    bounded "$phase-build" 1024 0 "$COMPILER" build "$mutant_dir/loan_laws.tl" \
        --target "$TARGET" --opt-level 1 --stdlib-root "$ROOT/stdlib" -o "$executable"
    [ -s "$executable" ] || fail "$phase produced no executable"
    bounded "$phase-run" 256 1 "$executable"
    printf '%s\n' "$expected" > "$WORKDIR/$phase.expected"
    cmp "$WORKDIR/$phase.expected" "$WORKDIR/$phase-run.stdout" >/dev/null || {
        cat "$WORKDIR/$phase-run.stdout" >&2
        fail "$phase failed without its specified semantic witness"
    }
    record_mutation "$phase" "Loan domain preserves $mutation semantics" "$expected"
    printf '%s\n' "$phase detected"
done

for mutation in required-exit cleanup-order live-overwrite partial-discharge activation-order construction-leak premature-activation; do
    mutant_dir="$WORKDIR/cleanup-model-mutation-$mutation"
    mkdir -p "$mutant_dir"
    cp "$SOURCE_CLEANUP_MUTATION" "$mutant_dir/cleanup_mutation_witness.tl"
    cp "$SOURCE_CLEANUP_CASES" "$mutant_dir/cleanup_cases.tl"
    witness=$mutation
    case "$mutation" in
        required-exit)
            original='      ;; With retains its cleanup operand even after a move or explicit cleanup.
      (cleanup! memory owner)'
            replacement='      ;; MUTANT: drop the retained cleanup operand when empty.
      (or (empty? (& memory) owner) (cleanup! memory owner))'
            ;;
        cleanup-order)
            original='    (clean-field! memory owner Field.Right)
    (clean-field! memory owner Field.Left)'
            replacement='    (clean-field! memory owner Field.Left)
    (clean-field! memory owner Field.Right)'
            ;;
        live-overwrite)
            original='  (if (!= (array-ref memory.slots slot) 0)
    false'
            replacement='  (if false
    false'
            ;;
        partial-discharge)
            original='(not (array-ref memory.partial (owner-index owner)))'
            replacement='true'
            ;;
        activation-order)
            original='        [owner : Owner (array-ref memory.stack (- memory.depth 1))]'
            replacement='        [owner : Owner (if (active? (& memory) Owner.Inner) Owner.Inner Owner.Outer)]'
            ;;
        construction-leak)
            original='    ;; Every acquired field must already have been transferred or cleaned.
    (empty? (& memory) owner)'
            replacement='    ;; MUTANT: forget acquired construction fields.
    true'
            ;;
        premature-activation)
            original='                  [(Event.BeginConstruction owner)
                    (push! (&mut memory) owner 1)]'
            replacement='                  [(Event.BeginConstruction owner)
                    (push! (&mut memory) owner 2)]'
            ;;
    esac
    mutate_literal "$SOURCE_CLEANUP_MODEL" "$mutant_dir/cleanup_model.tl" "$original" "$replacement"
    sha256sum "$mutant_dir"/*.tl > "$mutant_dir/identities.sha256"
    phase="cleanup-model-$mutation"
    executable="$mutant_dir/check$SUFFIX"
    rm -f "$executable"
    bounded "$phase-build" 1024 0 "$COMPILER" build "$mutant_dir/cleanup_mutation_witness.tl" \
        --target "$TARGET" --opt-level 1 --stdlib-root "$ROOT/stdlib" -o "$executable"
    [ -s "$executable" ] || fail "$phase produced no executable"
    bounded "$phase-run" 256 1 "$executable"
    expected="ownership-cleanup-model mutation mismatch: $witness"
    printf '%s\n' "$expected" > "$WORKDIR/$phase.expected"
    cmp "$WORKDIR/$phase.expected" "$WORKDIR/$phase-run.stdout" >/dev/null || {
        cat "$WORKDIR/$phase-run.stdout" >&2
        fail "$phase failed without its specified semantic witness"
    }
    record_mutation "$phase" "Concrete cleanup model preserves $mutation semantics" "$expected"
    printf '%s\n' "$phase detected"
done

# Cleanup elaboration is compared to a token interpreter, including static
# action order and a failure witness for each enumerated control-flow path.
for mutation in auto-use discharge partial-discharge construction-leak premature-activation field-order dropped-loop lost-later-failure numeric-order; do
    mutant_dir="$WORKDIR/cleanup-mutation-$mutation"
    mkdir -p "$mutant_dir"
    cp "$SOURCE_CLEANUP_MODEL" "$mutant_dir/cleanup_model.tl"
    cp "$SOURCE_CLEANUP_CASES" "$mutant_dir/cleanup_cases.tl"
    cp "$SOURCE_CLEANUP_RENAME" "$mutant_dir/cleanup_rename.tl"
    cp "$SOURCE_CLEANUP_COMPARE" "$mutant_dir/cleanup_crosscheck.tl"
    cp "$SOURCE_CLEANUP_CFG" "$mutant_dir/cleanup_cfg_crosscheck.tl"
    source="$mutant_dir/cleanup_crosscheck.tl"
    original2=''
    replacement2=''
    case "$mutation" in
        auto-use)
            original='(OwnershipOperation.Read
        (OwnershipPlaceId (ownership-body-id-copy (& body.id)) place))'
            replacement='(OwnershipOperation.Assign
        (OwnershipPlaceId (ownership-body-id-copy (& body.id)) place))'
            obligation='Automatic cleanup retains a read of its operand'
            expected='ownership-cleanup-crosscheck direct mismatch: modes=0 initial=1 operation=2'
            ;;
        discharge)
            original='(OwnershipOperation.RequireEmpty
            (ownership-place-id-copy (& binding.place)))'
            replacement='(OwnershipOperation.Read
            (ownership-place-id-copy (& binding.place)))'
            obligation='Manual discharge requires every resource to be empty'
            expected='ownership-cleanup-crosscheck direct mismatch: modes=1 initial=0 operation=6'
            ;;
        partial-discharge)
            original='(OwnershipOperation.Invalidate (ownership-cleanup-marker body owner)))'
            replacement='(OwnershipOperation.Assign (ownership-cleanup-marker body owner)))'
            obligation='Unrestored partial discharge rejects at normal exit'
            expected='ownership-cleanup-crosscheck control mismatch: case=9'
            ;;
        construction-leak)
            original='(ownership-cleanup-emit!
          output
          (OwnershipOperation.RequireEmpty
            (ownership-place-id-copy (& binding.place)))
          source
          instruction
          work
          limits)'
            replacement='(or (= (ownership-cleanup-phase body plan point owner) 1)
          (ownership-cleanup-emit!
            output
            (OwnershipOperation.RequireEmpty
              (ownership-place-id-copy (& binding.place)))
            source
            instruction
            work
            limits))'
            obligation='Construction frames retain responsibility for acquired fields'
            expected='ownership-cleanup-crosscheck control mismatch: case=2'
            ;;
        premature-activation)
            original='[(OwnershipOperation.BeginConstruction id)
                    (set! owner id.index)
                    (set! action 1)]'
            replacement='[(OwnershipOperation.BeginConstruction id)
                    (set! owner id.index)
                    (set! action 2)]'
            obligation='Construction does not activate automatic cleanup'
            expected='ownership-cleanup-crosscheck control mismatch: case=3'
            ;;
        field-order)
            original='[i : i64 0]
              ;; Ascending push gives reverse declaration order on pop;
              ;; a nested product finishes before its previous sibling.
              (while (< i (array-length fields.items))'
            replacement='[i : i64 (- (array-length fields.items) 1)]
              ;; MUTANT: reverse the push order.
              (while (>= i 0)'
            original2='(set! depth (+ depth 1))
                  (set! i (+ i 1)))))])))'
            replacement2='(set! depth (+ depth 1))
                  (set! i (- i 1)))))])))'
            obligation='Cleanup visits product fields in reverse declaration order'
            expected='ownership-cleanup-crosscheck direct mismatch: modes=0 initial=0 operation=6'
            ;;
        dropped-loop)
            original='(define (ownership-cleanup-final-terminator
  [term : (& term OwnershipTerminator)]) : OwnershipTerminator
  (match term
    [(OwnershipTerminator.Goto target)
      (OwnershipTerminator.Goto (ownership-block-id-copy target))]'
            replacement='(define (ownership-cleanup-final-terminator
  [term : (& term OwnershipTerminator)]) : OwnershipTerminator
  (match term
    [(OwnershipTerminator.Goto target)
      (OwnershipTerminator.Goto
        (OwnershipBlockId (ownership-body-id-copy (& target.body))
          (if (= target.index 1) 3 target.index)))]'
            source="$mutant_dir/cleanup_cfg_crosscheck.tl"
            obligation='Cleanup checking preserves loop backedges'
            expected='ownership-cleanup-cfg-crosscheck mismatch: graph=1'
            ;;
        lost-later-failure)
            original='(set!
                    (array-ref
                      output.failure-kinds
                      (+ (array-ref output.offsets b) i))
                    bits)'
            replacement='(set!
                    (array-ref
                      output.failure-kinds
                      (+ (array-ref output.offsets b) i))
                    (if (and (= b 3) (= i 0)) 0 bits))'
            source="$mutant_dir/cleanup_cfg_crosscheck.tl"
            obligation='Every rejected concrete path has its own failure evidence'
            expected='ownership-cleanup-cfg-crosscheck mismatch: graph=1'
            ;;
        numeric-order)
            original='    (when
      normal?
      (let
        [owner : i64 (array-ref plan.tops point)]
        (while (>= owner 0)
          (unless
            (and
              (ownership-charge! work limits.max-work 1)
              (ownership-cleanup-leave!
                body
                plan
                workspace
                output
                point
                owner
                block
                instruction
                (& original.source)
                work
                limits))
            (return false))
          (set!
            owner
            (ownership-obligation-parent (& (array-ref body.obligations owner)))))))'
            replacement='    (when
      normal?
      (let
        [owner : i64 (- (array-length body.obligations) 1)]
        (while (>= owner 0)
          (unless
            (or
              (= (ownership-cleanup-phase body plan point owner) 0)
              (and
                (ownership-charge! work limits.max-work 1)
                (ownership-cleanup-leave!
                  body
                  plan
                  workspace
                  output
                  point
                  owner
                  block
                  instruction
                  (& original.source)
                  work
                  limits)))
            (return false))
          (set! owner (- owner 1)))))'
            obligation='Cleanup follows the active parent chain after obligation renaming'
            expected='ownership-cleanup-crosscheck renaming mismatch: mode=1
ownership-cleanup-crosscheck direct mismatch: modes=0 initial=1 operation=7'
            ;;
    esac
    mutant="$mutant_dir/compiler_ownership_core.tl"
    mutate_literal "$SOURCE_CORE" "$mutant" "$original" "$replacement"
    if [ -n "$original2" ]; then
        mutate_literal "$mutant" "$mutant_dir/second-edit.tl" "$original2" "$replacement2"
        mv "$mutant_dir/second-edit.tl" "$mutant"
    fi
    sha256sum "$mutant_dir"/*.tl > "$mutant_dir/identities.sha256"
    phase="cleanup-$mutation"
    executable="$mutant_dir/check$SUFFIX"
    rm -f "$executable"
    bounded "$phase-build" 1024 0 "$COMPILER" build "$source" \
        --target "$TARGET" --opt-level 1 --stdlib-root "$ROOT/stdlib" -o "$executable"
    [ -s "$executable" ] || fail "$phase produced no executable"
    bounded "$phase-run" 256 1 "$executable"
    printf '%s\n' "$expected" > "$WORKDIR/$phase.expected"
    cmp "$WORKDIR/$phase.expected" "$WORKDIR/$phase-run.stdout" >/dev/null || {
        cat "$WORKDIR/$phase-run.stdout" >&2
        fail "$phase failed without its independent semantic witness"
    }
    record_mutation "$phase" "$obligation" "$expected"
    printf '%s\n' "$phase detected"
done

for mutation in owner generation serial lifetime extent; do
    mutant_dir="$WORKDIR/allocation-model-$mutation"
    mkdir -p "$mutant_dir"
    case "$mutation" in
        owner) original='(= allocation.owner pointer.owner)' ;;
        generation) original='(= allocation.generation pointer.generation)' ;;
        serial) original='(= allocation.serial pointer.serial)' ;;
        lifetime) original='(< time allocation.retired)' ;;
        extent) original='(<= pointer.offset (- allocation.length width))' ;;
    esac
    mutant="$mutant_dir/allocation_model.tl"
    mutate_literal "$SOURCE_ALLOCATION_MODEL" "$mutant" "$original" true
    sha256sum "$mutant" > "$mutant_dir/identities.sha256"
    executable="$mutant_dir/check$SUFFIX"
    rm -f "$executable"
    phase="allocation-model-$mutation"
    bounded "$phase-build" 1024 0 "$COMPILER" build "$mutant" \
        --target "$TARGET" --opt-level 1 --stdlib-root "$ROOT/stdlib" -o "$executable"
    [ -s "$executable" ] || fail "$phase produced no executable"
    bounded "$phase-run" 256 1 "$executable"
    [ ! -s "$WORKDIR/$phase-run.stdout" ] || fail "$phase produced unexpected output"
    record_mutation "$phase" "Allocation access retains $mutation authority" 'normal exit 1'
    printf '%s\n' "$phase detected"
done

input_identities > "$WORKDIR/identities.after.sha256"
cmp "$WORKDIR/identities.before.sha256" "$WORKDIR/identities.after.sha256" >/dev/null \
    || fail "compiler or source changed during campaign"
printf '%s\n' "ownership model: thirty-nine complete bounded native runs, thirty-one production mutations and twenty-two model mutations passed; artifacts: $WORKDIR"
