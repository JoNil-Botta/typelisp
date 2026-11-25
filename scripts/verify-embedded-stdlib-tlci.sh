#!/usr/bin/env sh
set -eu

# Prove the checked-in stdlib source set produces a deterministic, source-bound
# host image that the production include-bin and W^X loader path can register.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-build-provenance.sh"

verify_no_checkout_root() {
    checkout_image=$1
    checkout_root=$2
    checkout_root_mixed=$(cygpath -m "$checkout_root" 2>/dev/null || :)
    checkout_root_windows=$(cygpath -w "$checkout_root" 2>/dev/null || :)
    for checkout_spelling in "$checkout_root" "$checkout_root_mixed" "$checkout_root_windows"; do
        # Empty conversions and implausibly short roots would match unrelated
        # image contents (or every image), rather than identify a checkout.
        [ "${#checkout_spelling}" -ge 8 ] || continue
        if grep -aFq -e "$checkout_spelling" "$checkout_image"; then
            printf '%s\n' "embedded stdlib tlci image records the checkout root: $checkout_spelling" >&2
            return 1
        fi
    done
}

run_checkout_root_self_test() (
    selftest_dir=target/exp/embedded-stdlib-tlci-checkout-root-self-test
    mkdir -p "$selftest_dir"
    selftest_image=$selftest_dir/image.tlci
    selftest_root='/c/checkout [1] with space'
    selftest_mixed='C:/checkout [1] with space'
    selftest_windows='C:\checkout [1] with space'
    # Exercise the Windows conversions on every host, without changing the
    # production cygpath lookup outside this subshell.
    cygpath() {
        case "$1" in
            -m) printf '%s\n' "$selftest_mixed" ;;
            -w) printf '%s\n' "$selftest_windows" ;;
        esac
    }

    for selftest_spelling in "$selftest_root" "$selftest_mixed" "$selftest_windows"; do
        for selftest_suffix in '' '/src/checkout-root-probe.tl' '/stdlib/checkout-root-probe.tl'; do
            printf 'TLCI\000%s%s\000' "$selftest_spelling" "$selftest_suffix" > "$selftest_image"
            if verify_no_checkout_root "$selftest_image" "$selftest_root" \
                2> "$selftest_dir/stderr.txt"; then
                printf '%s\n' "checkout root self-test accepted a leaked root: $selftest_spelling$selftest_suffix" >&2
                return 1
            fi
            grep -F -e "records the checkout root: $selftest_spelling" \
                "$selftest_dir/stderr.txt" > /dev/null
        done
    done

    # Individual words and regex lookalikes are not the complete spelling.
    printf 'TLCI\000%s\000' '/c/checkout C:/checkout C:\checkout with space /c/checkout 1 with space' > "$selftest_image"
    verify_no_checkout_root "$selftest_image" "$selftest_root"

    selftest_mixed=
    selftest_windows=
    printf 'TLCI\000/short7 checkout\000' > "$selftest_image"
    verify_no_checkout_root "$selftest_image" ''
    verify_no_checkout_root "$selftest_image" '/short7'
    if verify_no_checkout_root "$selftest_image" checkout \
        2> "$selftest_dir/stderr.txt"; then
        echo "checkout root self-test accepted an eight-character root" >&2
        return 1
    fi
)

required_native_identities() {
    printf '%s\n' \
        stdlib.core_macros/__tl-clone-out \
        stdlib.clone/deep \
        stdlib.clone/clone-nominal-value \
        stdlib.clone/nominal-hook-name \
        stdlib.clone/gen-clone \
        stdlib.clone/gen-clone-named \
        stdlib.dense_list/compiler-dense-list-operations \
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

if [ "$#" -eq 1 ] && [ "$1" = "--self-test-checkout-root" ]; then
    run_checkout_root_self_test
    echo "embedded stdlib tlci checkout root self-test passed"
    exit 0
fi
if [ "$#" -eq 1 ] && [ "$1" = "--self-test-native-identities" ]; then
    run_native_identity_self_test
    echo "embedded stdlib tlci native identity self-test passed"
    exit 0
fi
if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-embedded-stdlib-tlci.sh [--self-test-native-identities|--self-test-checkout-root]" >&2
    exit 2
fi

run_checkout_root_self_test
run_native_identity_self_test

. "$ROOT/scripts/lib-gate.sh"
gate_compiler

case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) HOST_TARGET=windows ;;
    *) HOST_TARGET=linux ;;
esac

WORKDIR=target/embedded-stdlib-tlci-verify
EMBEDDED_IMAGE=target/embedded-stdlib-tlci/stdlib.tlci
IMAGE_A=$WORKDIR/stdlib-a.tlci
IMAGE_B=$WORKDIR/stdlib-b.tlci
ENVELOPE_A=$IMAGE_A.tlch
ENVELOPE_B=$IMAGE_B.tlch
FULL_BLOCKER_IMAGE=$WORKDIR/stdlib-full-blockers.tlci
FULL_BLOCKER_STDOUT=$WORKDIR/full-blockers.stdout
FULL_BLOCKER_STDERR=$WORKDIR/full-blockers.stderr
IDENTITY_IMAGE=$WORKDIR/stdlib-identity-manifest.tlci
IDENTITY_STDOUT=$WORKDIR/identity-manifest.stdout
IDENTITY_ACTUAL=$WORKDIR/identity-manifest.actual.tsv
IDENTITY_ACTUAL_SORTED=$WORKDIR/identity-manifest.actual.sorted.tsv
IDENTITY_EXPECTED=$WORKDIR/identity-manifest.expected.tsv
IDENTITY_FIXTURES_DIR=tools/embedded-stdlib-tlci/identity-fixtures.d
MUTATED_ROOT=$WORKDIR/stdlib-mutated
MUTATED_IMAGE=$WORKDIR/stdlib-mutated.tlci
MUTATED_SURFACE=$WORKDIR/stdlib-mutated-surface.rodata
MANIFEST=target/embedded-stdlib-tlci/modules.txt
mkdir -p "$WORKDIR"

ACTIVE_BG_PIDS=
cleanup_bg_pids() {
    for _bg_pid in $ACTIVE_BG_PIDS; do
        kill "$_bg_pid" 2>/dev/null || true
    done
    for _bg_pid in $ACTIVE_BG_PIDS; do
        wait "$_bg_pid" 2>/dev/null || true
    done
    ACTIVE_BG_PIDS=
}
trap 'cleanup_bg_pids' EXIT
trap 'trap "" HUP INT TERM; cleanup_bg_pids; exit 1' HUP INT TERM

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

# Phase 1: warm the cached native producer tools concurrently with one auxiliary
# worker running the independent surface AST smoke and diagnostic-walk bounded
# test, keeping peak memory well inside the gate's 6144 MiB budget.
rm -f "$WORKDIR"/*.status "$WORKDIR"/native-diagnostics.run.* "$WORKDIR"/native-diagnostics.build.*
DIAGNOSTIC_DRIVER=$WORKDIR/native-diagnostics
[ "$HOST_TARGET" != windows ] || DIAGNOSTIC_DRIVER=$DIAGNOSTIC_DRIVER.exe

scripts/build-embedded-stdlib-tlci.sh --ensure-tools "$COMPILER" "$HOST_TARGET" \
    >"$WORKDIR/tools.env" 2>"$WORKDIR/tools.stderr" &
_pid_tools=$!

(
    _aux_child=
    cleanup_aux_child() {
        if [ -n "$_aux_child" ]; then
            kill "$_aux_child" 2>/dev/null || true
            wait "$_aux_child" 2>/dev/null || true
            _aux_child=
        fi
    }
    trap 'cleanup_aux_child' EXIT
    trap 'trap "" HUP INT TERM; cleanup_aux_child; exit 1' HUP INT TERM

    _surface_rc=0
    "$COMPILER" run tools/compiler-surface-ast-smoke.tl \
        --stdlib-root stdlib --stdlib-root src \
        --cfg compiler-surface-selftest --cfg compiler-surface-producer \
        >"$WORKDIR/surface-smoke.stdout" 2>"$WORKDIR/surface-smoke.stderr" &
    _aux_child=$!
    wait "$_aux_child" || _surface_rc=$?
    _aux_child=
    printf '%s\n' "$_surface_rc" > "$WORKDIR/surface-smoke.status"
    [ "$_surface_rc" -eq 42 ] || exit 1

    # Compile outside the short execution deadline so slow compiler hosts retain
    # the same diagnostic-walk bound. The old computed-splice walk never returns.
    _diag_build_rc=0
    "$COMPILER" build tools/embedded-stdlib-tlci/native_diagnostics.tl \
        --stdlib-root stdlib --stdlib-root src -o "$DIAGNOSTIC_DRIVER" \
        >"$WORKDIR/native-diagnostics.build.stdout" 2>"$WORKDIR/native-diagnostics.build.stderr" &
    _aux_child=$!
    wait "$_aux_child" || _diag_build_rc=$?
    _aux_child=
    [ "$_diag_build_rc" -eq 0 ] || exit 1

    diagnostic_status=0
    env -u BASH_ENV scripts/run-memory-bounded.sh \
        --limit-mib 1024 --timeout-seconds 10 \
        --report "$WORKDIR/native-diagnostics.report" -- \
        env -u BASH_ENV "$DIAGNOSTIC_DRIVER" \
        >"$WORKDIR/native-diagnostics.run.stdout" 2>"$WORKDIR/native-diagnostics.run.stderr" &
    _aux_child=$!
    wait "$_aux_child" || diagnostic_status=$?
    _aux_child=
    printf '%s\n' "$diagnostic_status" > "$WORKDIR/native-diagnostics.status"
    [ "$diagnostic_status" -eq 42 ] || exit 1
) &
_pid_aux=$!
ACTIVE_BG_PIDS="$_pid_tools $_pid_aux"

_rc_tools=0
_rc_aux=0
wait "$_pid_tools" || _rc_tools=$?
wait "$_pid_aux" || _rc_aux=$?
ACTIVE_BG_PIDS=

[ ! -f "$WORKDIR/tools.stderr" ] || cat "$WORKDIR/tools.stderr" >&2 || true
if [ "$_rc_tools" -ne 0 ]; then
    echo "embedded stdlib tlci cached tool build failed (status $_rc_tools)" >&2
    exit 1
fi
SURFACE_TOOL=$(sed -n 's/^SURFACE_TOOL=//p' "$WORKDIR/tools.env")
IMAGE_TOOL=$(sed -n 's/^IMAGE_TOOL=//p' "$WORKDIR/tools.env")
if [ ! -x "$SURFACE_TOOL" ] || [ ! -x "$IMAGE_TOOL" ]; then
    echo "embedded stdlib tlci cached tools are missing: surface=$SURFACE_TOOL image=$IMAGE_TOOL" >&2
    exit 1
fi

[ ! -f "$WORKDIR/surface-smoke.stdout" ] || cat "$WORKDIR/surface-smoke.stdout" || true
[ ! -f "$WORKDIR/surface-smoke.stderr" ] || cat "$WORKDIR/surface-smoke.stderr" >&2 || true
surface_status=$(cat "$WORKDIR/surface-smoke.status" 2>/dev/null || printf '1')
if [ "$surface_status" -ne 42 ]; then
    echo "compiler surface selftest exited $surface_status, expected 42" >&2
    exit 1
fi

[ ! -f "$WORKDIR/native-diagnostics.build.stdout" ] || cat "$WORKDIR/native-diagnostics.build.stdout" || true
[ ! -f "$WORKDIR/native-diagnostics.build.stderr" ] || cat "$WORKDIR/native-diagnostics.build.stderr" >&2 || true
[ ! -f "$WORKDIR/native-diagnostics.run.stdout" ] || cat "$WORKDIR/native-diagnostics.run.stdout" || true
[ ! -f "$WORKDIR/native-diagnostics.run.stderr" ] || cat "$WORKDIR/native-diagnostics.run.stderr" >&2 || true
diagnostic_status=$(cat "$WORKDIR/native-diagnostics.status" 2>/dev/null || printf '1')
if [ "$_rc_aux" -ne 0 ] || [ "$diagnostic_status" -ne 42 ]; then
    echo "native producer diagnostic regression exited $diagnostic_status, expected 42" >&2
    exit 1
fi

# Direct opposite-host producer rejection using the cached native build tool.
if "$IMAGE_TOOL" \
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

# Phase 2: build the determinism pair concurrently into isolated workdirs and
# output paths, reusing the cached native tools warmed above.
rm -rf "$WORKDIR/build-b"
scripts/build-embedded-stdlib-tlci.sh \
    "$COMPILER" "$EMBEDDED_IMAGE" "$HOST_TARGET" \
    >"$COVERAGE_LOG" 2>"$WORKDIR/build-a.stderr" &
_pid_build_a=$!
TYPELISP_EMBEDDED_STDLIB_WORKDIR="$ROOT/$WORKDIR/build-b" \
    scripts/build-embedded-stdlib-tlci.sh \
    "$COMPILER" "$IMAGE_B" "$HOST_TARGET" \
    >"$WORKDIR/build-b.stdout" 2>"$WORKDIR/build-b.stderr" &
_pid_build_b=$!
ACTIVE_BG_PIDS="$_pid_build_a $_pid_build_b"

_rc_build_a=0
_rc_build_b=0
wait "$_pid_build_a" || _rc_build_a=$?
wait "$_pid_build_b" || _rc_build_b=$?
ACTIVE_BG_PIDS=

cat "$WORKDIR/build-a.stderr" >&2 || true
cat "$WORKDIR/build-b.stderr" >&2 || true
if [ "$_rc_build_a" -ne 0 ] || [ "$_rc_build_b" -ne 0 ]; then
    echo "embedded stdlib tlci determinism build failed: a=$_rc_build_a b=$_rc_build_b" >&2
    exit 1
fi
cat "$COVERAGE_LOG"
cp "$EMBEDDED_IMAGE" "$IMAGE_A"
cp "$EMBEDDED_IMAGE.tlch" "$ENVELOPE_A"

if ! cmp -s "$IMAGE_A" "$IMAGE_B"; then
    echo "embedded stdlib tlci build is not deterministic" >&2
    exit 1
fi
if ! cmp -s "$ENVELOPE_A" "$ENVELOPE_B"; then
    echo "embedded stdlib tlci envelope build is not deterministic" >&2
    exit 1
fi
# The frontend surface names prelude sources root-relatively (`stdlib/...`), so
# the image must not depend on, or show users, this checkout's location (#9667).
verify_no_checkout_root "$IMAGE_A" "$ROOT"

# Ratchet the native-coverage numbers. The native entry count overstates
# coverage on its own: a native entry can still hand single match arms back to
# the interpreter, so every fallback dimension is checked.
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
# explicit, duplicate-free blocked/walked relation.
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

# Prepare the mutated stdlib tree once so --full-blockers, --identity-manifest,
# and source-mutation image builds can all run concurrently via cached native tools.
rm -rf "$MUTATED_ROOT"
mkdir -p "$MUTATED_ROOT"
while IFS= read -r suffix; do
    destination="$MUTATED_ROOT/$suffix"
    mkdir -p "$(dirname -- "$destination")"
    cp "stdlib/$suffix" "$destination"
done < "$MANIFEST"
printf '\n;; embedded stdlib tlci source binding probe\n' \
    >> "$MUTATED_ROOT/core_macros.tl"
BUILD_HASH=$(build_provenance_hash "$0")
MUTATED_SOURCE_HASH=$(
    while IFS= read -r module_path; do
        source_path="$MUTATED_ROOT/$module_path"
        source_size=$(wc -c < "$source_path" | tr -d ' ')
        printf '%s\000%s\000' "$module_path" "$source_size"
        cat "$source_path"
    done < "$MANIFEST" | git hash-object --stdin
)

"$IMAGE_TOOL" \
    "$MANIFEST" stdlib "$FULL_BLOCKER_IMAGE" "$HOST_TARGET" \
    "$PRODUCER_IDENTITY" "$SURFACE" --full-blockers \
    > "$FULL_BLOCKER_STDOUT" 2> "$FULL_BLOCKER_STDERR" &
_pid_blockers=$!

"$IMAGE_TOOL" \
    "$MANIFEST" stdlib "$IDENTITY_IMAGE" "$HOST_TARGET" \
    "$PRODUCER_IDENTITY" "$SURFACE" --identity-manifest \
    > "$IDENTITY_STDOUT" 2> "$IDENTITY_ACTUAL" &
_pid_identity=$!

(
    _mut_child=
    cleanup_mut_child() {
        if [ -n "$_mut_child" ]; then
            kill "$_mut_child" 2>/dev/null || true
            wait "$_mut_child" 2>/dev/null || true
            _mut_child=
        fi
    }
    trap 'cleanup_mut_child' EXIT
    trap 'trap "" HUP INT TERM; cleanup_mut_child; exit 1' HUP INT TERM

    _mut_rc=0
    "$SURFACE_TOOL" \
        "$MUTATED_ROOT" "$MUTATED_SURFACE" "$HOST_TARGET" \
        "$BUILD_HASH" "$MUTATED_SOURCE_HASH" &
    _mut_child=$!
    wait "$_mut_child" || _mut_rc=$?
    _mut_child=
    [ "$_mut_rc" -eq 0 ] || exit "$_mut_rc"
    exec "$IMAGE_TOOL" \
        "$MANIFEST" "$MUTATED_ROOT" "$MUTATED_IMAGE" \
        "$HOST_TARGET" "$BUILD_HASH" "$MUTATED_SURFACE"
) > "$WORKDIR/mutated.stdout" 2> "$WORKDIR/mutated.stderr" &
_pid_mutated=$!
ACTIVE_BG_PIDS="$_pid_blockers $_pid_identity $_pid_mutated"

_rc_blockers=0
_rc_identity=0
_rc_mutated=0
wait "$_pid_blockers" || _rc_blockers=$?
wait "$_pid_identity" || _rc_identity=$?
wait "$_pid_mutated" || _rc_mutated=$?
ACTIVE_BG_PIDS=

if [ "$_rc_blockers" -ne 0 ]; then
    cat "$FULL_BLOCKER_STDERR" >&2 || true
    echo "full-blocker diagnostics build failed (status $_rc_blockers)" >&2
    exit 1
fi
if [ "$_rc_identity" -ne 0 ]; then
    cat "$IDENTITY_ACTUAL" >&2 || true
    echo "identity-manifest diagnostics build failed (status $_rc_identity)" >&2
    exit 1
fi
if [ "$_rc_mutated" -ne 0 ]; then
    cat "$WORKDIR/mutated.stdout" >&2 || true
    cat "$WORKDIR/mutated.stderr" >&2 || true
    echo "mutated embedded stdlib tlci build failed (status $_rc_mutated)" >&2
    exit 1
fi

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

# Derive identity, declared-parameter shape, and result kind from the
# exact parsed producer inputs, then require the reviewed fixture manifest to
# match it byte-for-byte. This makes catalog additions/removals and declaration
# changes fail before the route corpus can become stale or vacuous.
if ! cmp -s "$IMAGE_A" "$IDENTITY_IMAGE"; then
    echo "identity-manifest diagnostics changed the embedded stdlib tlci image" >&2
    exit 1
fi
if ! cmp -s "$ENVELOPE_A" "$IDENTITY_IMAGE.tlch"; then
    echo "identity-manifest diagnostics changed the embedded stdlib tlci envelope" >&2
    exit 1
fi
if ! cmp -s "$COVERAGE_LOG" "$IDENTITY_STDOUT"; then
    echo "identity-manifest diagnostics changed the coverage output" >&2
    exit 1
fi
if ! awk -F '\t' '
    NF != 4 { bad = 1; next }
    $1 !~ /^stdlib\.[^/]+\/[^/]+$/ { bad = 1 }
    $2 !~ /^[0-9]+$/ { bad = 1 }
    $3 != "fixed" && $3 != "variadic" { bad = 1 }
    $4 != "expr" && $4 != "module" && $4 != "decls" { bad = 1 }
    seen[$1]++ { duplicate = 1 }
    END { exit bad || duplicate || NR == 0 }
' "$IDENTITY_ACTUAL"; then
    echo "identity-manifest diagnostics emitted a malformed or duplicate row" >&2
    exit 1
fi
if [ ! -d "$IDENTITY_FIXTURES_DIR" ]; then
    echo "embedded stdlib tlci identity fixture directory is missing: $IDENTITY_FIXTURES_DIR" >&2
    exit 1
fi
IDENTITY_FIXTURE_FILES=$WORKDIR/identity-fixture-files.txt
: > "$IDENTITY_FIXTURE_FILES"
_if_entries=$(find "$IDENTITY_FIXTURES_DIR" -print | LC_ALL=C sort)
_if_count=0
while IFS= read -r _if_entry; do
    [ -n "$_if_entry" ] || continue
    [ "$_if_entry" != "$IDENTITY_FIXTURES_DIR" ] || continue
    _if_rel=${_if_entry#"$IDENTITY_FIXTURES_DIR"/}
    case "$_if_rel" in
        */*)
            echo "embedded stdlib tlci identity fixture directory contains nested entry: $_if_rel" >&2
            exit 1
            ;;
        .tsv)
            echo "embedded stdlib tlci identity fixture directory contains invalid filename: $_if_rel" >&2
            exit 1
            ;;
        *.tsv) ;;
        *)
            echo "embedded stdlib tlci identity fixture directory contains unexpected non-.tsv entry: $_if_rel" >&2
            exit 1
            ;;
    esac
    if [ ! -f "$_if_entry" ] || [ -L "$_if_entry" ]; then
        echo "embedded stdlib tlci identity fixture directory contains non-regular entry: $_if_rel" >&2
        exit 1
    fi
    printf '%s\n' "$_if_entry" >> "$IDENTITY_FIXTURE_FILES"
    _if_count=$((_if_count + 1))
done <<EOF
$_if_entries
EOF
if [ "$_if_count" -eq 0 ]; then
    echo "embedded stdlib tlci identity fixture directory is empty: $IDENTITY_FIXTURES_DIR" >&2
    exit 1
fi
if ! awk -F '\t' '
    {
        path = $0
        sub(/\r$/, "", path)
        if (path == "") next
        mod = path
        sub(/^.*\//, "", mod)
        sub(/\.tsv$/, "", mod)
        file_rows = 0
        while ((st = (getline raw < path)) > 0) {
            sub(/\r$/, "", raw)
            if (raw == "" || raw ~ /^#/) continue
            file_rows++
            nf = split(raw, f, "\t")
            if (nf != 8) { bad = 1; continue }
            if (f[1] !~ /^stdlib\.[^\/]+\/[^\/]+$/) { bad = 1 }
            if (index(f[1], mod "/") != 1) { bad = 1 }
            if (f[2] !~ /^[0-9]+$/) { bad = 1 }
            if (f[3] != "fixed" && f[3] != "variadic") { bad = 1 }
            if (f[4] != "expr" && f[4] != "module" && f[4] != "decls") { bad = 1 }
            if (f[5] !~ /^(tests\/integration|stdlib\/tests)\/[^\/]+\.tl$/) { bad = 1 }
            if (f[6] != "ok" || f[7] != "default" || f[8] != "assembly") { bad = 1 }
            if (seen[f[1]]++) { duplicate = 1 }
            print f[1] "\t" f[2] "\t" f[3] "\t" f[4]
        }
        if (st < 0 || file_rows == 0) { bad = 1 }
        close(path)
    }
    END { exit bad || duplicate }
' "$IDENTITY_FIXTURE_FILES" > "$WORKDIR/identity-manifest.expected.unsorted.tsv"; then
    echo "embedded stdlib tlci identity fixture inventory has a malformed, mismatched, empty, or duplicate row" >&2
    exit 1
fi
LC_ALL=C sort "$WORKDIR/identity-manifest.expected.unsorted.tsv" > "$IDENTITY_EXPECTED"
LC_ALL=C sort "$IDENTITY_ACTUAL" > "$IDENTITY_ACTUAL_SORTED"
if ! cmp -s "$IDENTITY_EXPECTED" "$IDENTITY_ACTUAL_SORTED"; then
    echo "embedded stdlib tlci identity fixture inventory is out of date" >&2
    diff -u "$IDENTITY_EXPECTED" "$IDENTITY_ACTUAL_SORTED" >&2 || true
    exit 1
fi
IDENTITY_ROWS=$(wc -l < "$IDENTITY_ACTUAL" | tr -d ' ')
if [ "$IDENTITY_ROWS" -ne "$NATIVE_ENTRIES" ]; then
    echo "identity manifest reports $IDENTITY_ROWS rows, coverage reports $NATIVE_ENTRIES native entries" >&2
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
# Pin the native families, not just the aggregate ratchet. Each identity must
# exist in the catalog and, because every shell is accounted for by the blocked
# relation above, must not be one of those blocked identities. The same
# assertion has deterministic missing and blocked identity coverage in
# run_native_identity_self_test.
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

"$COMPILER" inspect "$IMAGE_A" > "$WORKDIR/inspect.txt"
grep -q '^package-name: stdlib$' "$WORKDIR/inspect.txt"
grep -Eq '^  code: .* bytes=[1-9][0-9]*$' "$WORKDIR/inspect.txt"

# A source-only change must alter the image even while the macro identity set
# and generated registration shells remain unchanged.
if cmp -s "$IMAGE_A" "$MUTATED_IMAGE"; then
    echo "embedded stdlib source mutation did not change the tlci image" >&2
    exit 1
fi

# Phase 3b: run envelope verification, loader verification, and the single
# native stress driver build concurrently.
rm -f "$WORKDIR"/*.status
STRESS_DRIVER=$WORKDIR/stress-driver
[ "$HOST_TARGET" != windows ] || STRESS_DRIVER=$STRESS_DRIVER.exe

"$COMPILER" run tools/embedded-stdlib-tlci/verify-envelope.tl \
    --stdlib-root stdlib --stdlib-root src -- \
    "$IMAGE_A" "$ENVELOPE_A" \
    >"$WORKDIR/verify-envelope.stdout" 2>"$WORKDIR/verify-envelope.stderr" &
_pid_envelope=$!

"$COMPILER" run tools/embedded-stdlib-tlci/verify.tl \
    --stdlib-root stdlib --stdlib-root src \
    --cfg embedded-stdlib-tlci \
    >"$WORKDIR/verify-loader.stdout" 2>"$WORKDIR/verify-loader.stderr" &
_pid_loader=$!

"$COMPILER" build tools/embedded-stdlib-tlci/stress.tl \
    --stdlib-root stdlib --stdlib-root src -o "$STRESS_DRIVER" \
    >"$WORKDIR/stress-build.stdout" 2>"$WORKDIR/stress-build.stderr" &
_pid_stress_build=$!
ACTIVE_BG_PIDS="$_pid_envelope $_pid_loader $_pid_stress_build"

_rc_envelope=0
_rc_loader=0
_rc_stress_build=0
wait "$_pid_envelope" || _rc_envelope=$?
wait "$_pid_loader" || _rc_loader=$?
wait "$_pid_stress_build" || _rc_stress_build=$?
ACTIVE_BG_PIDS=

cat "$WORKDIR/verify-envelope.stdout" || true
cat "$WORKDIR/verify-envelope.stderr" >&2 || true
if [ "$_rc_envelope" -ne 0 ]; then
    echo "embedded stdlib tlci envelope verifier failed (status $_rc_envelope)" >&2
    exit 1
fi

cat "$WORKDIR/verify-loader.stdout" || true
cat "$WORKDIR/verify-loader.stderr" >&2 || true
if [ "$_rc_loader" -ne 42 ]; then
    echo "embedded stdlib tlci loader verifier exited $_rc_loader, expected 42" >&2
    exit 1
fi

cat "$WORKDIR/stress-build.stdout" || true
cat "$WORKDIR/stress-build.stderr" >&2 || true
if [ "$_rc_stress_build" -ne 0 ] || [ ! -x "$STRESS_DRIVER" ]; then
    echo "embedded stdlib tlci stress driver build failed (status $_rc_stress_build)" >&2
    exit 1
fi

# Sustained-dispatch stress over the real mapped image. Dispatch corruption
# has surfaced only after ~13.5k catalog calls, while the loader verifier above
# makes three dispatches.
#
# The three tiers exist so a failure names an entry/session shape instead of a
# symptom. There are no production shells: tier 1 sustains the native
# text_buf/append! two-operand dynamic set!-place callback chain. Tier 2 runs
# core_macros/__tl-box-place over one persistent set of pools/operands and
# audits the count, operand, cookie and stack state after every fresh session.
# Tier 3 runs that same entry but captures pools and pushes a fresh operand each
# iteration, adding pool/operand cycling. All three run above that call count
# and on both hosts, concurrently against the compiled driver.
STRESS_ITERATIONS=${TYPELISP_TLCI_STRESS_ITERATIONS:-25000}
for STRESS_TIER in 1 2 3; do
    STRESS_PROGRESS="$WORKDIR/stress-tier$STRESS_TIER.txt"
    echo "[embedded-stdlib-tlci] stress tier $STRESS_TIER ($STRESS_ITERATIONS iterations)"
    "$STRESS_DRIVER" "$STRESS_TIER" "$STRESS_ITERATIONS" "$STRESS_PROGRESS" \
        >"$WORKDIR/stress-tier$STRESS_TIER.stdout" \
        2>"$WORKDIR/stress-tier$STRESS_TIER.stderr" &
    eval "_pid_stress_$STRESS_TIER=\$!"
    ACTIVE_BG_PIDS="$ACTIVE_BG_PIDS $!"
done

for STRESS_TIER in 1 2 3; do
    eval "_tier_pid=\$_pid_stress_$STRESS_TIER"
    _tier_rc=0
    wait "$_tier_pid" || _tier_rc=$?
    eval "_rc_stress_$STRESS_TIER=\$_tier_rc"
done
ACTIVE_BG_PIDS=

for STRESS_TIER in 1 2 3; do
    STRESS_PROGRESS="$WORKDIR/stress-tier$STRESS_TIER.txt"
    cat "$WORKDIR/stress-tier$STRESS_TIER.stdout" || true
    cat "$WORKDIR/stress-tier$STRESS_TIER.stderr" >&2 || true
    eval "_tier_rc=\$_rc_stress_$STRESS_TIER"
    if [ "$_tier_rc" -ne 42 ]; then
        echo "embedded stdlib tlci stress tier $STRESS_TIER exited $_tier_rc, expected 42" >&2
        echo "last durable progress record:" >&2
        cat "$STRESS_PROGRESS" >&2 || true
        echo "reproduce with: $COMPILER run tools/embedded-stdlib-tlci/stress.tl --stdlib-root stdlib --stdlib-root src -- $STRESS_TIER $STRESS_ITERATIONS $STRESS_PROGRESS" >&2
        exit 1
    fi
done

echo "embedded stdlib tlci image is deterministic, source-bound, and loadable"
