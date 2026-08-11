#!/usr/bin/env sh
set -eu

# Exercise both Linux memory-limit selection and an actual over-limit process.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-linux-memory-limit.sh"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "Linux memory-limit verification is unsupported on this host" >&2
        exit 1
        ;;
esac

WORKDIR="$ROOT/target/linux-memory-limit-verify"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "$*" >&2
    exit 1
}

LIMIT_BYTES=33554432
ALLOCATE_AWK='BEGIN {
    chunk = sprintf("%1048576s", "x")
    for (i = 0; i < 96; i++) values[i] = chunk i
    system("sleep 1")
}'

exercise_backend() {
    _memory_backend=$1
    _memory_stdout="$WORKDIR/$_memory_backend.stdout"
    _memory_stderr="$WORKDIR/$_memory_backend.stderr"

    TYPELISP_MEMORY_LIMIT_SELF_TEST=present
    export TYPELISP_MEMORY_LIMIT_SELF_TEST
    if ! linux_memory_limit_run "$LIMIT_BYTES" sh -c \
        '[ "$TYPELISP_MEMORY_LIMIT_SELF_TEST" = present ] && [ "$PWD" = "$1" ]' \
        sh "$ROOT" \
        > "$_memory_stdout" 2> "$_memory_stderr"; then
        cat "$_memory_stderr" >&2 || true
        fail "Linux memory-limit backend rejected an under-limit command: $_memory_backend"
    fi
    if linux_memory_limit_run "$LIMIT_BYTES" awk "$ALLOCATE_AWK" \
        > "$_memory_stdout" 2> "$_memory_stderr"; then
        fail "Linux memory-limit backend accepted an over-limit command: $_memory_backend"
    fi
    if [ "$_memory_backend" = rss-watchdog ] \
        && ! grep -q 'memory limit exceeded: aggregate RSS' "$_memory_stderr"; then
        cat "$_memory_stderr" >&2 || true
        fail "RSS watchdog did not report its measured over-limit failure"
    fi
    echo "[linux-memory-limit] $_memory_backend pass/fail fixtures passed"
}

LINUX_MEMORY_LIMIT_BACKEND=
linux_memory_limit_select_backend
selected_backend=$LINUX_MEMORY_LIMIT_BACKEND
echo "[linux-memory-limit] auto-selected $selected_backend"
exercise_backend "$selected_backend"

# A usable systemd manager is host-dependent, but the portable fallback is a
# required path everywhere. Force it when auto-selection exercised systemd.
if [ "$selected_backend" != rss-watchdog ]; then
    LINUX_MEMORY_LIMIT_BACKEND=
    TYPELISP_LINUX_MEMORY_LIMIT_BACKEND=rss-watchdog
    export TYPELISP_LINUX_MEMORY_LIMIT_BACKEND
    linux_memory_limit_select_backend
    [ "$LINUX_MEMORY_LIMIT_BACKEND" = rss-watchdog ] \
        || fail "forced RSS watchdog selection returned $LINUX_MEMORY_LIMIT_BACKEND"
    exercise_backend rss-watchdog
fi

echo "Linux memory-limit helper self-tests passed"
