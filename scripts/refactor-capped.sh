#!/usr/bin/env sh
# refactor-capped.sh - run a command under the shared refactor memory budget.
#
# usage: scripts/refactor-capped.sh [--mem SIZE] [--timeout SECONDS] COMMAND [ARG ...]
#
# Refactor agents verify on a machine the owner's workers also use, and
# uncapped runs of experimental compilers twice filled RAM and swap until
# systemd-oomd killed the whole session. Every command that runs a typelisp
# compiler goes through this wrapper. COMMAND runs in its own scope inside
# tl-refactor.slice with MemoryMax=SIZE (default 12G) and no swap, and the
# slice is capped at 36G in total, so a runaway compiler is OOM-killed (exit
# 137, or 143 once systemd stops the rest of its scope) or timed out (exit
# 124) instead of the session.
#
# A top-level call first waits for one of TL_REFACTOR_SLOTS (default 3)
# machine-wide slots, so at most that many heavy commands run at once. A call
# made from inside a capped command skips the slot and only adds its own scope.
set -eu
mem=12G timeout=0
while :; do
    case "${1:-}" in
        --mem) mem=$2; shift 2 ;;
        --timeout) timeout=$2; shift 2 ;;
        *) break ;;
    esac
done
[ "$#" -gt 0 ] || { sed -n 4p "$0" >&2; exit 2; }
if [ "$timeout" -gt 0 ]; then
    set -- timeout --kill-after=10 "$timeout" "$@"
fi
run() {
    exec systemd-run --user --quiet --collect --slice=tl-refactor.slice --scope \
        -p MemoryMax="$mem" -p MemorySwapMax=0 "$@"
}
[ -z "${TL_REFACTOR_CAPPED:-}" ] || run "$@"
TL_REFACTOR_CAPPED=1
export TL_REFACTOR_CAPPED
systemctl --user set-property --runtime tl-refactor.slice MemoryMax=36G MemoryHigh=32G MemorySwapMax=0
slots=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/tl-refactor-slots
mkdir -p "$slots"
waiting=0
while :; do
    i=1
    while [ "$i" -le "${TL_REFACTOR_SLOTS:-3}" ]; do
        exec 9> "$slots/$i"
        if flock -n 9; then run "$@"; fi
        i=$((i + 1))
    done
    [ "$waiting" -eq 1 ] || echo "[refactor-capped] all ${TL_REFACTOR_SLOTS:-3} slots busy; waiting" >&2
    waiting=1
    sleep 5
done
