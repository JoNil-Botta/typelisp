#!/usr/bin/env sh
set -eu

# verify-fs-rooted-linux.sh - adversarial native checks for the private Linux
# rooted staging, publication, and reusable-read backend. refs #7221, #7409,
# #7550, #7653, #7662

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "rooted filesystem native verification is Linux-only"
        exit 0
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

[ -x "$COMPILER" ] || {
    echo "rooted filesystem compiler is not executable: $COMPILER" >&2
    exit 1
}
command -v as >/dev/null 2>&1 || {
    echo "rooted filesystem verification requires as" >&2
    exit 1
}
command -v ld >/dev/null 2>&1 || {
    echo "rooted filesystem verification requires ld" >&2
    exit 1
}
command -v truncate >/dev/null 2>&1 || {
    echo "rooted filesystem verification requires truncate" >&2
    exit 1
}

WORKDIR="$ROOT/target/fs-rooted-linux-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

MOUNTED_PATH=
MOUNT_RACE_PID=
cleanup_mount_race() {
    if [ -n "$MOUNT_RACE_PID" ]; then
        kill "$MOUNT_RACE_PID" >/dev/null 2>&1 || true
        wait "$MOUNT_RACE_PID" >/dev/null 2>&1 || true
    fi
    if [ -n "$MOUNTED_PATH" ]; then
        umount "$MOUNTED_PATH" >/dev/null 2>&1 || true
    fi
}
trap cleanup_mount_race EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_expect() {
    _label=$1
    _expected=$2
    shift 2
    _stdout="$WORKDIR/$_label.stdout"
    _stderr="$WORKDIR/$_label.stderr"
    set +e
    "$@" > "$_stdout" 2> "$_stderr"
    _actual=$?
    set -e
    if [ "$_actual" -ne "$_expected" ]; then
        echo "FAIL: $_label expected exit $_expected, got $_actual" >&2
        [ ! -s "$_stdout" ] || sed 's/^/  stdout: /' "$_stdout" >&2
        [ ! -s "$_stderr" ] || sed 's/^/  stderr: /' "$_stderr" >&2
        exit 1
    fi
    [ ! -s "$_stdout" ] || fail "$_label wrote unexpected stdout"
    [ ! -s "$_stderr" ] || fail "$_label wrote unexpected stderr"
}

run_reuse_expect() {
    _label=$1
    _component=$2
    _expected=$3
    _stdout="$WORKDIR/$_label.stdout"
    _stderr="$WORKDIR/$_label.stderr"
    set +e
    "$READ_REUSE_BIN" reuse "$WORKDIR/read-reuse-data" \
        "$_component" "$_expected" > "$_stdout" 2> "$_stderr"
    _actual=$?
    set -e
    [ "$_actual" -eq 42 ] || {
        echo "FAIL: $_label expected exit 42, got $_actual" >&2
        [ ! -s "$_stdout" ] || sed 's/^/  stdout: /' "$_stdout" >&2
        [ ! -s "$_stderr" ] || sed 's/^/  stderr: /' "$_stderr" >&2
        exit 1
    }
    [ ! -s "$_stderr" ] || fail "$_label wrote unexpected stderr"
    _extra=
    IFS=' ' read -r _mode _size _reads _consumed _total _live _peak \
        _elapsed _frequency _extra < "$_stdout" ||
        fail "$_label wrote a malformed measurement"
    [ -z "$_extra" ] || fail "$_label wrote extra measurement fields"
    [ "$_mode" = reuse ] || fail "$_label reported mode $_mode"
    [ "$_size" -eq "$_expected" ] || fail "$_label reported size $_size"
    [ "$_consumed" -eq "$_expected" ] ||
        fail "$_label consumed $_consumed bytes"
    [ "$_total" -eq 0 ] || fail "$_label allocated $_total bytes"
    [ "$_live" -eq 0 ] || fail "$_label retained $_live bytes"
    [ "$_peak" -eq 0 ] ||
        fail "$_label raised peak live bytes by $_peak"
    _expected_reads=$(((_expected / 1048576) + 1))
    [ "$_reads" -eq "$_expected_reads" ] ||
        fail "$_label used $_reads reads, expected $_expected_reads"
    [ "$_elapsed" -gt 0 ] || fail "$_label reported a non-positive duration"
    [ "$_frequency" -gt 0 ] ||
        fail "$_label reported an invalid tick frequency"
    [ "$(wc -l < "$_stdout")" -eq 1 ] ||
        fail "$_label wrote extra measurement rows"
    echo "[fs-rooted-linux] $_label: $_reads reads, 0 allocated bytes"
}

assert_mode() {
    _path=$1
    _expected=$2
    _actual=$(stat -c '%a' "$_path")
    [ "$_actual" = "$_expected" ] ||
        fail "$_path mode was $_actual, expected $_expected"
}

NATIVE_SOURCE="$ROOT/tests/integration/fs_rooted_linux_native.tl"
NATIVE_ASM="$WORKDIR/native.s"
NATIVE_OBJ="$WORKDIR/native.o"
NATIVE_BIN="$WORKDIR/native"

echo "[fs-rooted-linux] compile assembly fallback with fault hooks"
"$COMPILER" compile "$NATIVE_SOURCE" -o "$NATIVE_ASM" \
    --target linux-x86_64 --backend-mode scalar \
    --cfg fs-rooted-linux-test-hooks --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/native-compile.stdout" 2> "$WORKDIR/native-compile.stderr" ||
    fail "native fixture compile failed"
as "$NATIVE_ASM" -o "$NATIVE_OBJ"
ld "$NATIVE_OBJ" -o "$NATIVE_BIN" -e _tl_start

PUBLICATION_SOURCE="$ROOT/tests/integration/fs_rooted_linux_publication.tl"
PUBLICATION_ASM="$WORKDIR/publication.s"
PUBLICATION_OBJ="$WORKDIR/publication.o"
PUBLICATION_BIN="$WORKDIR/publication"

echo "[fs-rooted-linux] compile rooted publication coverage"
"$COMPILER" compile "$PUBLICATION_SOURCE" -o "$PUBLICATION_ASM" \
    --target linux-x86_64 --backend-mode scalar \
    --cfg fs-rooted-linux-test-hooks --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/publication-compile.stdout" \
    2> "$WORKDIR/publication-compile.stderr" ||
    fail "publication fixture compile failed"
as "$PUBLICATION_ASM" -o "$PUBLICATION_OBJ"
ld "$PUBLICATION_OBJ" -o "$PUBLICATION_BIN" -e _tl_start

REOPEN_DIRECTORY_SOURCE="$ROOT/tests/integration/fs_rooted_linux_reopen_directory.tl"
REOPEN_DIRECTORY_ASM="$WORKDIR/reopen-directory.s"
REOPEN_DIRECTORY_OBJ="$WORKDIR/reopen-directory.o"
REOPEN_DIRECTORY_BIN="$WORKDIR/reopen-directory"

echo "[fs-rooted-linux] compile rooted directory-reopen coverage"
"$COMPILER" compile "$REOPEN_DIRECTORY_SOURCE" -o "$REOPEN_DIRECTORY_ASM" \
    --target linux-x86_64 --backend-mode scalar \
    --cfg fs-rooted-linux-test-hooks --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/reopen-directory-compile.stdout" \
    2> "$WORKDIR/reopen-directory-compile.stderr" ||
    fail "directory-reopen fixture compile failed"
as "$REOPEN_DIRECTORY_ASM" -o "$REOPEN_DIRECTORY_OBJ"
ld "$REOPEN_DIRECTORY_OBJ" -o "$REOPEN_DIRECTORY_BIN" -e _tl_start

READ_INTO_SOURCE="$ROOT/tests/integration/fs_rooted_linux_read_into.tl"
READ_INTO_ASM="$WORKDIR/read-into.s"
READ_INTO_OBJ="$WORKDIR/read-into.o"
READ_INTO_BIN="$WORKDIR/read-into"

echo "[fs-rooted-linux] compile caller-owned read contract coverage"
"$COMPILER" compile "$READ_INTO_SOURCE" -o "$READ_INTO_ASM" \
    --target linux-x86_64 --backend-mode scalar \
    --cfg fs-rooted-linux-test-hooks --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/read-into-compile.stdout" \
    2> "$WORKDIR/read-into-compile.stderr" ||
    fail "caller-owned read fixture compile failed"
as "$READ_INTO_ASM" -o "$READ_INTO_OBJ"
ld "$READ_INTO_OBJ" -o "$READ_INTO_BIN" -e _tl_start

READ_REUSE_SOURCE="$ROOT/tests/integration/fs_rooted_linux_read_reuse.tl"
READ_REUSE_ASM="$WORKDIR/read-reuse.s"
READ_REUSE_OBJ="$WORKDIR/read-reuse.o"
READ_REUSE_BIN="$WORKDIR/read-reuse"

echo "[fs-rooted-linux] compile reusable-read allocation coverage"
"$COMPILER" compile "$READ_REUSE_SOURCE" -o "$READ_REUSE_ASM" \
    --target linux-x86_64 --backend-mode scalar \
    --cfg fs-rooted-linux-test-hooks --stdlib-root "$ROOT/stdlib" \
    > "$WORKDIR/read-reuse-compile.stdout" \
    2> "$WORKDIR/read-reuse-compile.stderr" ||
    fail "reusable-read allocation fixture compile failed"
as "$READ_REUSE_ASM" -o "$READ_REUSE_OBJ"
ld "$READ_REUSE_OBJ" -o "$READ_REUSE_BIN" -e _tl_start

mkdir -p "$WORKDIR/happy"
run_expect happy 42 "$NATIVE_BIN" happy "$WORKDIR/happy"
printf 'rooted payload\n' > "$WORKDIR/happy.expected"
cmp -s "$WORKDIR/happy.expected" "$WORKDIR/happy/tree/payload.txt" ||
    fail "happy-path payload mismatch"
printf '#!/bin/sh\nexit 0\n' > "$WORKDIR/executable.expected"
cmp -s "$WORKDIR/executable.expected" "$WORKDIR/happy/tree/run.sh" ||
    fail "executable payload mismatch"
assert_mode "$WORKDIR/happy/tree" 755
assert_mode "$WORKDIR/happy/tree/payload.txt" 644
assert_mode "$WORKDIR/happy/tree/run.sh" 755

mkdir -p "$WORKDIR/rename"
run_expect rename 42 \
    "$NATIVE_BIN" rename "$WORKDIR/rename" "$WORKDIR/renamed"
[ ! -e "$WORKDIR/rename" ] || fail "old root name survived rename"
printf 'retained descriptor\n' > "$WORKDIR/rename.expected"
cmp -s "$WORKDIR/rename.expected" "$WORKDIR/renamed/after-rename.txt" ||
    fail "retained descriptor did not create below renamed root"

mkdir -p "$WORKDIR/child-rename"
run_expect child-rename 42 \
    "$NATIVE_BIN" child-rename "$WORKDIR/child-rename"
[ ! -e "$WORKDIR/child-rename/child-before" ] ||
    fail "old child name survived rename"
printf 'retained child descriptor\n' > "$WORKDIR/child-rename.expected"
cmp -s \
    "$WORKDIR/child-rename.expected" \
    "$WORKDIR/child-rename/child-after/after-child-rename.txt" ||
    fail "retained child descriptor did not survive child rename"

mkdir -p "$WORKDIR/outside" "$WORKDIR/symlink"
printf 'outside sentinel\n' > "$WORKDIR/outside/sentinel.txt"
ln -s "$WORKDIR/outside" "$WORKDIR/symlink/link"
run_expect symlink-child 42 "$NATIVE_BIN" symlink "$WORKDIR/symlink"
printf 'outside sentinel\n' > "$WORKDIR/outside.expected"
cmp -s "$WORKDIR/outside.expected" "$WORKDIR/outside/sentinel.txt" ||
    fail "symlink child modified the outside sentinel"
[ -L "$WORKDIR/symlink/link" ] || fail "symlink child was replaced"

mkdir -p "$WORKDIR/root-target"
ln -s "$WORKDIR/root-target" "$WORKDIR/root-link"
run_expect symlink-root 42 "$NATIVE_BIN" root-symlink "$WORKDIR/root-link"
[ -z "$(find "$WORKDIR/root-target" -mindepth 1 -print -quit)" ] ||
    fail "root final-component symlink was followed"

mkdir -p "$WORKDIR/race"
run_expect symlink-race 42 "$NATIVE_BIN" race "$WORKDIR/race"
[ -L "$WORKDIR/race/race-child" ] ||
    fail "deterministic race did not leave the substituted symlink"
[ -d "$WORKDIR/race/race-original" ] ||
    fail "deterministic race removed the renamed original directory"
cmp -s "$WORKDIR/outside.expected" "$WORKDIR/outside/sentinel.txt" ||
    fail "deterministic symlink race modified the outside sentinel"

mkdir -p "$WORKDIR/exclusive"
set +e
"$NATIVE_BIN" exclusive "$WORKDIR/exclusive" \
    > "$WORKDIR/exclusive-a.stdout" 2> "$WORKDIR/exclusive-a.stderr" &
EXCLUSIVE_A_PID=$!
"$NATIVE_BIN" exclusive "$WORKDIR/exclusive" \
    > "$WORKDIR/exclusive-b.stdout" 2> "$WORKDIR/exclusive-b.stderr" &
EXCLUSIVE_B_PID=$!
wait "$EXCLUSIVE_A_PID"
EXCLUSIVE_A_STATUS=$?
wait "$EXCLUSIVE_B_PID"
EXCLUSIVE_B_STATUS=$?
set -e
EXCLUSIVE_STATUSES=$(printf '%s\n%s\n' \
    "$EXCLUSIVE_A_STATUS" "$EXCLUSIVE_B_STATUS" | sort -n | tr '\n' ' ')
[ "$EXCLUSIVE_STATUSES" = "17 42 " ] ||
    fail "competing creates exited $EXCLUSIVE_A_STATUS and $EXCLUSIVE_B_STATUS"
[ ! -s "$WORKDIR/exclusive-a.stdout" ] || fail "exclusive writer A wrote stdout"
[ ! -s "$WORKDIR/exclusive-a.stderr" ] || fail "exclusive writer A wrote stderr"
[ ! -s "$WORKDIR/exclusive-b.stdout" ] || fail "exclusive writer B wrote stdout"
[ ! -s "$WORKDIR/exclusive-b.stderr" ] || fail "exclusive writer B wrote stderr"
printf 'winner\n' > "$WORKDIR/exclusive.expected"
cmp -s "$WORKDIR/exclusive.expected" "$WORKDIR/exclusive/winner.txt" ||
    fail "exclusive winner payload mismatch"
assert_mode "$WORKDIR/exclusive/winner.txt" 644

mkdir -p "$WORKDIR/faults"
run_expect fault-injection 42 "$NATIVE_BIN" faults "$WORKDIR/faults"
[ -d "$WORKDIR/faults/unsupported-directory" ] ||
    fail "failed directory reacquisition deleted the exclusively created node"
[ ! -e "$WORKDIR/faults/unsupported-file.txt" ] ||
    fail "injected unsupported openat2 unexpectedly created a file"

mkdir -p "$WORKDIR/reopen-retained/generation"
printf 'original generation\n' > \
    "$WORKDIR/reopen-retained/generation/payload.txt"
chmod 711 "$WORKDIR/reopen-retained/generation"
run_expect reopen-retained 42 \
    "$REOPEN_DIRECTORY_BIN" retained \
    "$WORKDIR/reopen-retained" "$WORKDIR/reopen-retained-moved"
[ ! -e "$WORKDIR/reopen-retained" ] ||
    fail "old directory-reopen root name survived rename"
printf 'original generation\n' > "$WORKDIR/reopen-original.expected"
cmp -s \
    "$WORKDIR/reopen-original.expected" \
    "$WORKDIR/reopen-retained-moved/generation-moved/payload.txt" ||
    fail "reopened child capability did not retain the original directory"
printf 'replacement generation\n' > "$WORKDIR/reopen-replacement.expected"
cmp -s \
    "$WORKDIR/reopen-replacement.expected" \
    "$WORKDIR/reopen-retained-moved/generation/payload.txt" ||
    fail "replacement directory payload mismatch"
assert_mode "$WORKDIR/reopen-retained-moved/generation-moved" 711
assert_mode "$WORKDIR/reopen-retained-moved/generation" 755

mkdir -p "$WORKDIR/reopen-before/generation"
printf 'original before acquisition\n' > \
    "$WORKDIR/reopen-before/generation/payload.txt"
mv \
    "$WORKDIR/reopen-before/generation" \
    "$WORKDIR/reopen-before/generation-before"
mkdir "$WORKDIR/reopen-before/generation"
printf 'replacement before acquisition\n' > \
    "$WORKDIR/reopen-before/generation/payload.txt"
run_expect reopen-renamed-before 42 \
    "$REOPEN_DIRECTORY_BIN" renamed-before "$WORKDIR/reopen-before"
printf 'original before acquisition\n' > "$WORKDIR/reopen-before.expected"
cmp -s \
    "$WORKDIR/reopen-before.expected" \
    "$WORKDIR/reopen-before/generation-before/payload.txt" ||
    fail "pre-acquisition rename modified the original directory"

mkdir -p "$WORKDIR/reopen-classify" "$WORKDIR/reopen-outside"
printf 'ordinary\n' > "$WORKDIR/reopen-classify/ordinary"
mkfifo "$WORKDIR/reopen-classify/special"
printf 'outside sentinel\n' > "$WORKDIR/reopen-outside/sentinel.txt"
ln -s "$WORKDIR/reopen-outside" "$WORKDIR/reopen-classify/symlink"
run_expect reopen-missing 42 \
    "$REOPEN_DIRECTORY_BIN" missing "$WORKDIR/reopen-classify"
run_expect reopen-file 42 \
    "$REOPEN_DIRECTORY_BIN" file "$WORKDIR/reopen-classify"
run_expect reopen-special 42 \
    "$REOPEN_DIRECTORY_BIN" special "$WORKDIR/reopen-classify"
run_expect reopen-symlink 42 \
    "$REOPEN_DIRECTORY_BIN" symlink "$WORKDIR/reopen-classify"
cmp -s "$WORKDIR/outside.expected" "$WORKDIR/reopen-outside/sentinel.txt" ||
    fail "directory reopen followed a symlink outside the root"

mkdir -p "$WORKDIR/reopen-faults/generation"
run_expect reopen-faults 42 \
    "$REOPEN_DIRECTORY_BIN" faults "$WORKDIR/reopen-faults"

mkdir -p \
    "$WORKDIR/publication-source/directory-entry" \
    "$WORKDIR/publication-source/empty-dir" \
    "$WORKDIR/publication-source/nonempty" \
    "$WORKDIR/publication-destination" \
    "$WORKDIR/publication-destination/collision-dir" \
    "$WORKDIR/publication-outside"
printf 'child\n' > "$WORKDIR/publication-source/nonempty/child"
printf 'outside sentinel\n' > "$WORKDIR/publication-outside/sentinel"
printf 'collision existing\n' > "$WORKDIR/publication-destination/collision.txt"
ln -s ../publication-outside/sentinel \
    "$WORKDIR/publication-source/symlink-entry"
ln -s ../publication-outside/sentinel \
    "$WORKDIR/publication-source/remove-link"
ln -s ../publication-outside/sentinel \
    "$WORKDIR/publication-destination/replace-link"
mkfifo "$WORKDIR/publication-source/fifo-entry"
run_expect publication 42 \
    "$PUBLICATION_BIN" publication \
    "$WORKDIR/publication-source" \
    "$WORKDIR/publication-destination"
printf 'published\n' > "$WORKDIR/publication.expected"
cmp -s \
    "$WORKDIR/publication.expected" \
    "$WORKDIR/publication-destination/published.txt" ||
    fail "no-replace publication payload mismatch"
printf 'replacement\n' > "$WORKDIR/replacement.expected"
cmp -s \
    "$WORKDIR/replacement.expected" \
    "$WORKDIR/publication-destination/replace-link" ||
    fail "replace publication did not replace the destination symlink entry"
printf 'same parent\n' > "$WORKDIR/same-parent.expected"
cmp -s \
    "$WORKDIR/same-parent.expected" \
    "$WORKDIR/publication-source/same-parent.txt" ||
    fail "same-parent publication payload mismatch"
printf 'outside sentinel\n' > "$WORKDIR/publication-outside.expected"
cmp -s \
    "$WORKDIR/publication-outside.expected" \
    "$WORKDIR/publication-outside/sentinel" ||
    fail "publication or cleanup modified the outside sentinel"
[ ! -e "$WORKDIR/publication-source/remove.txt" ] ||
    fail "exact unlink left the regular-file entry"
[ ! -e "$WORKDIR/publication-source/remove-link" ] ||
    fail "exact unlink left the symlink entry"
[ ! -e "$WORKDIR/publication-source/empty-dir" ] ||
    fail "exact rmdir left the empty directory"
[ -d "$WORKDIR/publication-source/nonempty" ] ||
    fail "exact rmdir removed the nonempty directory"
[ -f "$WORKDIR/publication-source/collision.tmp" ] ||
    fail "no-replace collision consumed its source"
[ -d "$WORKDIR/publication-destination/collision-dir" ] ||
    fail "no-replace collision overwrote a directory"

mkdir -p "$WORKDIR/parent-source" "$WORKDIR/parent-destination"
run_expect renamed-parents 42 \
    "$PUBLICATION_BIN" renamed-parents \
    "$WORKDIR/parent-source" \
    "$WORKDIR/parent-destination" \
    "$WORKDIR/parent-source-moved" \
    "$WORKDIR/parent-destination-moved"
[ ! -e "$WORKDIR/parent-source" ] ||
    fail "old source parent name survived retained-descriptor rename"
[ ! -e "$WORKDIR/parent-destination" ] ||
    fail "old destination parent name survived retained-descriptor rename"
printf 'renamed parents\n' > "$WORKDIR/renamed-parents.expected"
cmp -s \
    "$WORKDIR/renamed-parents.expected" \
    "$WORKDIR/parent-destination-moved/renamed.txt" ||
    fail "two-root publication did not survive parent renames"

mkdir -p "$WORKDIR/publication-faults/rmdir-fault"
run_expect publication-faults 42 \
    "$PUBLICATION_BIN" faults "$WORKDIR/publication-faults"
[ -f "$WORKDIR/publication-faults/rename-fault.tmp" ] ||
    fail "injected EXDEV consumed the rename source"
[ -f "$WORKDIR/publication-faults/noreplace-fault.tmp" ] ||
    fail "injected unsupported no-replace consumed the rename source"
[ -f "$WORKDIR/publication-faults/unlink-fault.txt" ] ||
    fail "injected unlink failure removed its target"
[ -d "$WORKDIR/publication-faults/rmdir-fault" ] ||
    fail "injected rmdir failure removed its target"

mkdir -p "$WORKDIR/read-rewind-data"
run_expect retained-read-rewind 42 "$PUBLICATION_BIN" rewind "$WORKDIR/read-rewind-data"
[ "$(cat "$WORKDIR/read-rewind-data/payload")" = replacement ] ||
    fail "rewind changed the replacement pathname contents"
[ ! -e "$WORKDIR/read-rewind-data/moved" ] ||
    fail "rewind retained-identity fixture did not unlink the original entry"

mkdir -p "$WORKDIR/read-into-data"
run_expect caller-owned-read 42 "$READ_INTO_BIN" "$WORKDIR/read-into-data"

mkdir -p "$WORKDIR/read-reuse-data"
truncate -s 16777216 "$WORKDIR/read-reuse-data/size-16m.bin"
truncate -s 67108864 "$WORKDIR/read-reuse-data/size-64m.bin"
truncate -s 268435456 "$WORKDIR/read-reuse-data/size-256m.bin"
run_reuse_expect reusable-read-16m size-16m.bin 16777216
run_reuse_expect reusable-read-64m size-64m.bin 67108864
run_reuse_expect reusable-read-256m size-256m.bin 268435456

# A privileged runner can install a real bind mount during the deterministic
# post-mkdir pause. Unprivileged CI reports the limitation instead of silently
# claiming mount-boundary coverage.
mkdir -p "$WORKDIR/mount-probe-source" "$WORKDIR/mount-probe-target"
if mount --bind "$WORKDIR/mount-probe-source" "$WORKDIR/mount-probe-target" \
    > "$WORKDIR/mount-probe.stdout" 2> "$WORKDIR/mount-probe.stderr"; then
    MOUNTED_PATH="$WORKDIR/mount-probe-target"
    umount "$WORKDIR/mount-probe-target"
    MOUNTED_PATH=
    mkdir -p "$WORKDIR/mount-root" "$WORKDIR/mount-outside"
    set +e
    "$NATIVE_BIN" mount-race "$WORKDIR/mount-root" \
        > "$WORKDIR/mount-race.stdout" 2> "$WORKDIR/mount-race.stderr" &
    MOUNT_RACE_PID=$!
    set -e
    MOUNT_WAIT=0
    while [ ! -d "$WORKDIR/mount-root/mount-child" ] && \
        [ "$MOUNT_WAIT" -lt 100 ]; do
        sleep 0.05
        MOUNT_WAIT=$((MOUNT_WAIT + 1))
    done
    [ -d "$WORKDIR/mount-root/mount-child" ] ||
        fail "mount race did not publish its mkdir window"
    mount --bind "$WORKDIR/mount-outside" "$WORKDIR/mount-root/mount-child" ||
        fail "bind mount became unavailable during mount race"
    MOUNTED_PATH="$WORKDIR/mount-root/mount-child"
    set +e
    wait "$MOUNT_RACE_PID"
    MOUNT_RACE_STATUS=$?
    MOUNT_RACE_PID=
    set -e
    umount "$WORKDIR/mount-root/mount-child"
    MOUNTED_PATH=
    [ "$MOUNT_RACE_STATUS" -eq 42 ] ||
        fail "mount boundary race exited $MOUNT_RACE_STATUS"
    [ ! -s "$WORKDIR/mount-race.stdout" ] || fail "mount race wrote stdout"
    [ ! -s "$WORKDIR/mount-race.stderr" ] || fail "mount race wrote stderr"
    mkdir -p \
        "$WORKDIR/reopen-mount-root/mounted" \
        "$WORKDIR/reopen-mount-outside"
    printf 'outside mount sentinel\n' > \
        "$WORKDIR/reopen-mount-outside/sentinel.txt"
    mount --bind \
        "$WORKDIR/reopen-mount-outside" \
        "$WORKDIR/reopen-mount-root/mounted" ||
        fail "bind mount became unavailable during directory-reopen coverage"
    MOUNTED_PATH="$WORKDIR/reopen-mount-root/mounted"
    run_expect reopen-mount 42 \
        "$REOPEN_DIRECTORY_BIN" mount "$WORKDIR/reopen-mount-root"
    umount "$WORKDIR/reopen-mount-root/mounted"
    MOUNTED_PATH=
    printf 'outside mount sentinel\n' > "$WORKDIR/reopen-mount.expected"
    cmp -s \
        "$WORKDIR/reopen-mount.expected" \
        "$WORKDIR/reopen-mount-outside/sentinel.txt" ||
        fail "directory reopen modified the bind-mounted outside directory"
    echo "[fs-rooted-linux] bind-mount boundary covered"
else
    echo "[fs-rooted-linux] bind-mount boundary unavailable; runner lacks mount permission"
fi

# Exercise the direct-object-enabled source planner. This backend closure uses
# unsupported direct-object records today, so the asserted behavior is the
# documented assembler fallback; the first probe proves the assembler is used.
DIRECT_SOURCE="$ROOT/tests/integration/fs_rooted_linux_direct.tl"
DIRECT_SHIM="$WORKDIR/no-assembler-bin"
mkdir -p "$DIRECT_SHIM" "$WORKDIR/direct-run/root"
printf '%s\n' \
    '#!/usr/bin/env sh' \
    'echo "expected rooted semantic assembler fallback" >&2' \
    'exit 97' > "$DIRECT_SHIM/as"
chmod +x "$DIRECT_SHIM/as"
set +e
(cd "$WORKDIR/direct-run" && \
    PATH="$DIRECT_SHIM:$PATH" TYPELISP_LINUX_DIRECT_OBJECT=1 \
    "$COMPILER" run "$DIRECT_SOURCE" \
        --target linux-x86_64 --backend-mode scalar \
        --cfg fs-rooted-linux-test-hooks --stdlib-root "$ROOT/stdlib") \
        > "$WORKDIR/direct-probe.stdout" 2> "$WORKDIR/direct-probe.stderr"
DIRECT_PROBE_STATUS=$?
set -e
[ "$DIRECT_PROBE_STATUS" -ne 0 ] ||
    fail "rooted semantic fallback unexpectedly bypassed the assembler"
grep -F "expected rooted semantic assembler fallback" \
    "$WORKDIR/direct-probe.stderr" >/dev/null 2>&1 ||
    fail "direct-object-enabled probe did not reach the assembler fallback"

set +e
(cd "$WORKDIR/direct-run" && \
    TYPELISP_LINUX_DIRECT_OBJECT=1 \
    "$COMPILER" run "$DIRECT_SOURCE" \
        --target linux-x86_64 --backend-mode scalar \
        --cfg fs-rooted-linux-test-hooks \
        --stdlib-root "$ROOT/stdlib") \
        > "$WORKDIR/direct-build.stdout" 2> "$WORKDIR/direct-build.stderr"
DIRECT_RUN_STATUS=$?
set -e
[ "$DIRECT_RUN_STATUS" -eq 42 ] ||
    fail "direct-object-enabled rooted fallback exited $DIRECT_RUN_STATUS"
[ ! -s "$WORKDIR/direct-build.stdout" ] ||
    fail "direct-object-enabled rooted fallback run wrote stdout"
[ ! -s "$WORKDIR/direct-build.stderr" ] ||
    fail "direct-object-enabled rooted fallback run wrote stderr"
printf 'direct object\n' > "$WORKDIR/direct.expected"
cmp -s "$WORKDIR/direct.expected" "$WORKDIR/direct-run/root/direct.txt" ||
    fail "direct-object-enabled rooted payload mismatch"
[ -f "$WORKDIR/direct-run/root/injected-failure.txt" ] ||
    fail "direct-object-enabled injected failure did not create its private node"
[ ! -s "$WORKDIR/direct-run/root/injected-failure.txt" ] ||
    fail "direct-object-enabled injected write failure wrote bytes"
assert_mode "$WORKDIR/direct-run/root/injected-failure.txt" 600

echo "[fs-rooted-linux] all checks passed"
