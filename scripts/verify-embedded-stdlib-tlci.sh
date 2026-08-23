#!/usr/bin/env sh
set -eu

# Prove the checked-in stdlib source set produces a deterministic, source-bound
# host image that the production include-bin and W^X loader path can register.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-build-provenance.sh"

required_native_identities() {
    printf '%s\n' \
        stdlib.clone/synthesize-helpers \
        stdlib.serialize/serialize \
        stdlib.sort/vec \
        stdlib.text_buf/append! \
        stdlib.vector/vector \
        stdlib.hashmap/hashmap
}

verify_required_native_identities() {
    native_image=$1
    blocker_status=$2
    for native_identity in $(required_native_identities); do
        if ! grep -aFq "$native_identity" "$native_image"; then
            echo "embedded stdlib tlci image is missing $native_identity" >&2
            return 1
        fi
        if awk -F '\t' -v identity="$native_identity" '
            $1 == identity && $2 == "blocked" { found = 1 }
            END { exit !found }
        ' "$blocker_status"; then
            echo "$native_identity regressed to a fallback shell" >&2
            return 1
        fi
    done
}

run_native_identity_self_test() {
    selftest_dir=target/embedded-stdlib-tlci-native-identities-self-test
    selftest_image=$selftest_dir/image.txt
    selftest_blockers=$selftest_dir/blockers.tsv
    selftest_stderr=$selftest_dir/stderr.txt
    mkdir -p "$selftest_dir"

    required_native_identities > "$selftest_image"
    required_native_identities |
        awk '{ print $0 "\twalked\tself-test" }' > "$selftest_blockers"
    verify_required_native_identities "$selftest_image" "$selftest_blockers"

    required_native_identities |
        grep -v '^stdlib.hashmap/hashmap$' > "$selftest_image"
    if verify_required_native_identities \
        "$selftest_image" "$selftest_blockers" \
        > /dev/null 2> "$selftest_stderr"; then
        echo "native identity self-test accepted a missing hashmap identity" >&2
        return 1
    fi
    grep -F "image is missing stdlib.hashmap/hashmap" \
        "$selftest_stderr" > /dev/null || {
        cat "$selftest_stderr" >&2
        echo "missing hashmap identity diagnostic mismatch" >&2
        return 1
    }

    required_native_identities > "$selftest_image"
    required_native_identities |
        awk -v blocked='stdlib.hashmap/hashmap' '
            { status = ($0 == blocked ? "blocked" : "walked") }
            { print $0 "\t" status "\tself-test" }
        ' > "$selftest_blockers"
    if verify_required_native_identities \
        "$selftest_image" "$selftest_blockers" \
        > /dev/null 2> "$selftest_stderr"; then
        echo "native identity self-test accepted a blocked hashmap identity" >&2
        return 1
    fi
    grep -F "stdlib.hashmap/hashmap regressed to a fallback shell" \
        "$selftest_stderr" > /dev/null || {
        cat "$selftest_stderr" >&2
        echo "blocked hashmap identity diagnostic mismatch" >&2
        return 1
    }

    rm -f "$selftest_image" "$selftest_blockers" "$selftest_stderr"
    rmdir "$selftest_dir"
}

if [ "$#" -eq 1 ] && [ "$1" = "--self-test-native-identities" ]; then
    run_native_identity_self_test
    echo "embedded stdlib tlci native identity self-test passed"
    exit 0
fi
if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-embedded-stdlib-tlci.sh [--self-test-native-identities]" >&2
    exit 2
fi

run_native_identity_self_test

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) HOST_TARGET=windows ;;
    *) HOST_TARGET=linux ;;
esac

set +e
"$COMPILER" run tools/compiler-surface-ast-smoke.tl \
    --stdlib-root stdlib --stdlib-root src \
    --cfg compiler-surface-selftest --cfg compiler-surface-producer
surface_status=$?
set -e
if [ "$surface_status" -ne 42 ]; then
    echo "compiler surface selftest exited $surface_status, expected 42" >&2
    exit 1
fi

WORKDIR=target/embedded-stdlib-tlci-verify
EMBEDDED_IMAGE=target/embedded-stdlib-tlci/stdlib.tlci
IMAGE_A=$WORKDIR/stdlib-a.tlci
IMAGE_B=$WORKDIR/stdlib-b.tlci
ENVELOPE_A=$IMAGE_A.tlch
ENVELOPE_B=$IMAGE_B.tlch
FULL_BLOCKER_IMAGE=$WORKDIR/stdlib-full-blockers.tlci
FULL_BLOCKER_STDOUT=$WORKDIR/full-blockers.stdout
FULL_BLOCKER_STDERR=$WORKDIR/full-blockers.stderr
MUTATED_ROOT=$WORKDIR/stdlib-mutated
MUTATED_IMAGE=$WORKDIR/stdlib-mutated.tlci
MUTATED_SURFACE=$WORKDIR/stdlib-mutated-surface.rodata
MANIFEST=target/embedded-stdlib-tlci/modules.txt
mkdir -p "$WORKDIR"

if [ "$HOST_TARGET" = windows ]; then
    OTHER_HOST_TARGET=linux
else
    OTHER_HOST_TARGET=windows
fi
if scripts/build-embedded-stdlib-tlci.sh \
    "$COMPILER" "$WORKDIR/wrong-host.tlci" "$OTHER_HOST_TARGET" \
    >"$WORKDIR/wrong-host.stdout" 2>"$WORKDIR/wrong-host.stderr"; then
    echo "embedded stdlib wrapper accepted the opposite host platform" >&2
    exit 1
fi
[ ! -s "$WORKDIR/wrong-host.stdout" ] || {
    echo "opposite-host wrapper rejection wrote stdout" >&2
    exit 1
}
grep -F "does not match build host '$HOST_TARGET'" \
    "$WORKDIR/wrong-host.stderr" >/dev/null || {
    cat "$WORKDIR/wrong-host.stderr" >&2
    echo "opposite-host wrapper rejection diagnostic mismatch" >&2
    exit 1
}
if "$COMPILER" run tools/embedded-stdlib-tlci/build.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$WORKDIR/missing-manifest" "$WORKDIR/missing-root" \
    "$WORKDIR/wrong-host-direct.tlci" "$OTHER_HOST_TARGET" \
    "0000000000000000000000000000000000000000" \
    "$WORKDIR/missing-rodata" \
    >"$WORKDIR/wrong-host-direct.stdout" \
    2>"$WORKDIR/wrong-host-direct.stderr"; then
    echo "embedded stdlib producer accepted the opposite host platform" >&2
    exit 1
fi
[ ! -s "$WORKDIR/wrong-host-direct.stdout" ] || {
    echo "opposite-host producer rejection wrote stdout" >&2
    exit 1
}
grep -F "requested host target \`$OTHER_HOST_TARGET\` does not match build host \`$HOST_TARGET\`" \
    "$WORKDIR/wrong-host-direct.stderr" >/dev/null || {
    cat "$WORKDIR/wrong-host-direct.stderr" >&2
    echo "opposite-host producer rejection diagnostic mismatch" >&2
    exit 1
}

COVERAGE_FLOOR=tools/embedded-stdlib-tlci/coverage-floor.txt
COVERAGE_LOG=$WORKDIR/coverage.txt

scripts/build-embedded-stdlib-tlci.sh \
    "$COMPILER" "$EMBEDDED_IMAGE" "$HOST_TARGET" > "$COVERAGE_LOG"
cat "$COVERAGE_LOG"
cp "$EMBEDDED_IMAGE" "$IMAGE_A"
cp "$EMBEDDED_IMAGE.tlch" "$ENVELOPE_A"
scripts/build-embedded-stdlib-tlci.sh \
    "$COMPILER" "$EMBEDDED_IMAGE" "$HOST_TARGET"
cp "$EMBEDDED_IMAGE" "$IMAGE_B"
cp "$EMBEDDED_IMAGE.tlch" "$ENVELOPE_B"

if ! cmp -s "$IMAGE_A" "$IMAGE_B"; then
    echo "embedded stdlib tlci build is not deterministic" >&2
    exit 1
fi
if ! cmp -s "$ENVELOPE_A" "$ENVELOPE_B"; then
    echo "embedded stdlib tlci envelope build is not deterministic" >&2
    exit 1
fi
"$COMPILER" run tools/embedded-stdlib-tlci/verify-envelope.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$IMAGE_A" "$ENVELOPE_A"

# Ratchet the native-coverage numbers. The native entry count overstates
# coverage on its own: a native entry can still hand single match arms back to
# the interpreter, so every fallback dimension is checked. Refs #5596.
coverage_field() {
    sed -n 's/^embedded stdlib tlci: coverage .*'"$1"'=\([0-9][0-9]*\).*$/\1/p' \
        "$COVERAGE_LOG"
}
floor_field() {
    sed -n 's/^'"$1"'[[:space:]][[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' \
        "$COVERAGE_FLOOR"
}

NATIVE_ENTRIES=$(coverage_field native-entries)
SHELL_ENTRIES=$(coverage_field shell-entries)
PARTIAL_ENTRIES=$(coverage_field partial-entries)
INTERPRETED_ARMS=$(coverage_field interpreted-arms)
NATIVE_ENTRIES_MIN=$(floor_field native-entries-min)
SHELL_ENTRIES_MAX=$(floor_field shell-entries-max)
PARTIAL_ENTRIES_MAX=$(floor_field partial-entries-max)
INTERPRETED_ARMS_MAX=$(floor_field interpreted-arms-max)

for pair in \
    "native entry count:$NATIVE_ENTRIES" \
    "shell entry count:$SHELL_ENTRIES" \
    "partial entry count:$PARTIAL_ENTRIES" \
    "interpreted arm count:$INTERPRETED_ARMS" \
    "native-entries-min:$NATIVE_ENTRIES_MIN" \
    "shell-entries-max:$SHELL_ENTRIES_MAX" \
    "partial-entries-max:$PARTIAL_ENTRIES_MAX" \
    "interpreted-arms-max:$INTERPRETED_ARMS_MAX"; do
    if [ -z "${pair#*:}" ]; then
        echo "embedded stdlib tlci: cannot read ${pair%%:*}" >&2
        exit 1
    fi
done

# The opt-in census is diagnostics-only: it must preserve the normal image and
# the two stdout coverage lines while replacing scalar stderr rows with an
# explicit, duplicate-free blocked/walked relation. Refs #5742.
if PRODUCER_IDENTITY=$($COMPILER --producer-identity 2>/dev/null); then
    :
else
    PRODUCER_VERSION=$($COMPILER --version 2>/dev/null) || {
        echo "cannot read producer identity from compiler: $COMPILER" >&2
        exit 1
    }
    PRODUCER_IDENTITY=$(printf '%s\n' "$PRODUCER_VERSION" |
        awk 'NR == 1 && $1 == "typelisp" { print $2 }')
fi
SURFACE=target/embedded-stdlib-tlci/prelude-surface-$HOST_TARGET.rodata
"$COMPILER" run tools/embedded-stdlib-tlci/build.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$MANIFEST" stdlib "$FULL_BLOCKER_IMAGE" "$HOST_TARGET" \
    "$PRODUCER_IDENTITY" "$SURFACE" --full-blockers \
    > "$FULL_BLOCKER_STDOUT" 2> "$FULL_BLOCKER_STDERR"
"$COMPILER" run tools/embedded-stdlib-tlci/encode-envelope.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$FULL_BLOCKER_IMAGE" "$FULL_BLOCKER_IMAGE.tlch"

if ! cmp -s "$IMAGE_A" "$FULL_BLOCKER_IMAGE"; then
    echo "full-blocker diagnostics changed the embedded stdlib tlci image" >&2
    exit 1
fi
if ! cmp -s "$ENVELOPE_A" "$FULL_BLOCKER_IMAGE.tlch"; then
    echo "full-blocker diagnostics changed the embedded stdlib tlci envelope" >&2
    exit 1
fi
if ! cmp -s "$COVERAGE_LOG" "$FULL_BLOCKER_STDOUT"; then
    echo "full-blocker diagnostics changed the coverage output" >&2
    exit 1
fi
if ! awk -F '\t' '
    NF != 3 || ($2 != "blocked" && $2 != "walked") { bad = 1 }
    END { exit bad }
' "$FULL_BLOCKER_STDERR"; then
    echo "full-blocker diagnostics emitted a malformed status row" >&2
    exit 1
fi
if [ -n "$(sort "$FULL_BLOCKER_STDERR" | uniq -d)" ]; then
    echo "full-blocker diagnostics emitted a duplicate status row" >&2
    exit 1
fi
BLOCKED_SHELLS=$(awk -F '\t' '$2 == "blocked" { print $1 }' \
    "$FULL_BLOCKER_STDERR" | sort -u | wc -l | tr -d ' ')
if [ "$BLOCKED_SHELLS" -ne "$SHELL_ENTRIES" ]; then
    echo "full-blocker diagnostics reported $BLOCKED_SHELLS blocked shells," \
        "coverage reports $SHELL_ENTRIES" >&2
    exit 1
fi
# Pin the landed families, not just the aggregate ratchet. Each identity must
# exist in the catalog and, because every shell is accounted for by the blocked
# relation above, must not be one of those blocked identities. Refs #6550,
# #6552, #6553, #6554, #6555, #6556. The same assertion has deterministic
# missing and blocked identity coverage in run_native_identity_self_test.
verify_required_native_identities "$IMAGE_A" "$FULL_BLOCKER_STDERR"
if [ "$SHELL_ENTRIES" -gt 0 ] &&
    ! grep -q "$(printf '\twalked\t')" "$FULL_BLOCKER_STDERR"; then
    echo "full-blocker diagnostics did not report any walked capability" >&2
    exit 1
fi

if [ "$NATIVE_ENTRIES" -lt "$NATIVE_ENTRIES_MIN" ]; then
    echo "embedded stdlib tlci native coverage regressed:" \
        "$NATIVE_ENTRIES native entries, floor is $NATIVE_ENTRIES_MIN" >&2
    echo "lower the floor in $COVERAGE_FLOOR only with an explicit reason" >&2
    exit 1
fi
if [ "$SHELL_ENTRIES" -gt "$SHELL_ENTRIES_MAX" ]; then
    echo "embedded stdlib tlci shell coverage regressed:" \
        "$SHELL_ENTRIES shell entries, ceiling is $SHELL_ENTRIES_MAX" >&2
    exit 1
fi
if [ "$PARTIAL_ENTRIES" -gt "$PARTIAL_ENTRIES_MAX" ]; then
    echo "embedded stdlib tlci partial coverage regressed:" \
        "$PARTIAL_ENTRIES partial entries, ceiling is $PARTIAL_ENTRIES_MAX" >&2
    exit 1
fi
if [ "$INTERPRETED_ARMS" -gt "$INTERPRETED_ARMS_MAX" ]; then
    echo "embedded stdlib tlci interpreted arms regressed:" \
        "$INTERPRETED_ARMS arm sites, ceiling is $INTERPRETED_ARMS_MAX" >&2
    echo "a native entry may still interpret single match arms; see $COVERAGE_FLOOR" >&2
    exit 1
fi
# Improving past the ratchet is not an error -- several macro families land
# concurrently and an exact expectation would collide on every merge -- but the
# floor has to be re-ratcheted or it stops catching later regressions.
if [ "$NATIVE_ENTRIES" -gt "$NATIVE_ENTRIES_MIN" ] ||
    [ "$INTERPRETED_ARMS" -lt "$INTERPRETED_ARMS_MAX" ]; then
    echo "embedded stdlib tlci coverage improved past the ratchet;" \
        "re-ratchet $COVERAGE_FLOOR to" \
        "native-entries-min $NATIVE_ENTRIES," \
        "interpreted-arms-max $INTERPRETED_ARMS" >&2
fi

set +e
"$COMPILER" run tools/embedded-stdlib-tlci/verify.tl \
    --stdlib-root stdlib --stdlib-root src \
    --cfg embedded-stdlib-tlci
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "embedded stdlib tlci loader verifier exited $status, expected 42" >&2
    exit 1
fi

"$COMPILER" inspect "$IMAGE_A" > "$WORKDIR/inspect.txt"
grep -q '^package-name: stdlib$' "$WORKDIR/inspect.txt"
grep -Eq '^  code: .* bytes=[1-9][0-9]*$' "$WORKDIR/inspect.txt"

# A source-only change must alter the image even while the macro identity set
# and generated registration shells remain unchanged.
rm -rf "$MUTATED_ROOT"
mkdir -p "$MUTATED_ROOT"
while IFS= read -r suffix; do
    cp "stdlib/$suffix" "$MUTATED_ROOT/$suffix"
done < "$MANIFEST"
printf '\n;; embedded stdlib tlci source binding probe\n' \
    >> "$MUTATED_ROOT/array.tl"
BUILD_HASH=$(build_provenance_hash "$0")
MUTATED_SOURCE_HASH=$(
    while IFS= read -r module_path; do
        source_path="$MUTATED_ROOT/$module_path"
        source_size=$(wc -c < "$source_path" | tr -d ' ')
        printf '%s\000%s\000' "$module_path" "$source_size"
        cat "$source_path"
    done < "$MANIFEST" | git hash-object --stdin
)
"$COMPILER" run tools/embedded-stdlib-tlci/build-surface.tl \
    --stdlib-root stdlib --stdlib-root src \
    --cfg compiler-surface-producer -- \
    "$MUTATED_ROOT" "$MUTATED_SURFACE" "$HOST_TARGET" \
    "$BUILD_HASH" "$MUTATED_SOURCE_HASH"
"$COMPILER" run tools/embedded-stdlib-tlci/build.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$MANIFEST" "$MUTATED_ROOT" "$MUTATED_IMAGE" \
    "$HOST_TARGET" "$BUILD_HASH" "$MUTATED_SURFACE"
if cmp -s "$IMAGE_A" "$MUTATED_IMAGE"; then
    echo "embedded stdlib source mutation did not change the tlci image" >&2
    exit 1
fi

# #5528: sustained-dispatch stress over the real mapped image. #5460 saw
# corruption after ~13.5k catalog calls, while the loader verifier above makes
# three dispatches -- four orders of magnitude below the failure scale.
#
# The three tiers exist so a failure names an entry/session shape instead of a
# symptom. With #6550 there are no production shells left: tier 1 now sustains
# the newly native text_buf/append! two-operand dynamic set!-place callback
# chain. Tier 2 runs array/length over one persistent set of pools/operands and
# audits the count, operand, cookie and stack state after every fresh session.
# Tier 3 runs that same entry but captures pools and pushes a fresh operand each
# iteration, adding pool/operand cycling. All three run above the observed
# #5460 threshold and on both hosts.
STRESS_ITERATIONS=${TYPELISP_TLCI_STRESS_ITERATIONS:-25000}
for STRESS_TIER in 1 2 3; do
    STRESS_PROGRESS="$WORKDIR/stress-tier$STRESS_TIER.txt"
    echo "[embedded-stdlib-tlci] stress tier $STRESS_TIER"         "($STRESS_ITERATIONS iterations)"
    set +e
    "$COMPILER" run tools/embedded-stdlib-tlci/stress.tl         --stdlib-root stdlib --stdlib-root src --         "$STRESS_TIER" "$STRESS_ITERATIONS" "$STRESS_PROGRESS"
    stress_status=$?
    set -e
    if [ "$stress_status" -ne 42 ]; then
        echo "embedded stdlib tlci stress tier $STRESS_TIER exited"             "$stress_status, expected 42" >&2
        echo "last durable progress record:" >&2
        cat "$STRESS_PROGRESS" >&2 || true
        echo "reproduce with: $COMPILER run tools/embedded-stdlib-tlci/stress.tl"             "--stdlib-root stdlib --stdlib-root src --"             "$STRESS_TIER $STRESS_ITERATIONS $STRESS_PROGRESS" >&2
        exit 1
    fi
done

echo "embedded stdlib tlci image is deterministic, source-bound, and loadable"
