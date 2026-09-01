#!/usr/bin/env sh
set -eu

# verify-fs-rooted-linux.sh - adversarial native checks for the private Linux
# rooted exclusive-create backend. refs #7221

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
