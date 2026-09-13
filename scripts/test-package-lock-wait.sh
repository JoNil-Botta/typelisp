#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
. "$ROOT/scripts/lib-package-lock-test-wait.sh"

# A real writer publishes and exits between the first filesystem observation
# and kill -0. Synchronize that boundary instead of relying on scheduler timing.
for kind in text stage; do
    (
        case_dir="$WORKDIR/$kind"
        mkdir -p "$case_dir"
        printf 'old\n' > "$case_dir/typelisp.lock"
        (
            while [ ! -f "$case_dir/release" ]; do sleep 0.01; done
            if [ "$kind" = text ]; then
                printf 'winner\n' > "$case_dir/typelisp.lock"
            else
                printf 'winner\n' > "$case_dir/typelisp.lock.stage.writer"
            fi
        ) &
        writer=$!
        kill() {
            touch "$case_dir/release"
            if wait "$writer"; then writer_status=0; else writer_status=$?; fi
            command kill "$@"
        }
        if [ "$kind" = text ]; then
            wait_for_package_lock_text "$case_dir/typelisp.lock" winner "$writer" race-text
        else
            wait_for_package_lock_stage "$case_dir" "$writer" race-stage
        fi
        [ "$writer_status" = 0 ]
    ) || fail "$kind publication/exit race was rejected"
done

# Termination without the requested publication must still fail and expose
# both captures. A wrong lock value cannot satisfy the success predicate.
printf 'wrong\n' > "$WORKDIR/wrong.lock"
printf 'child stdout marker\n' > "$WORKDIR/dead.out"
printf 'child stderr marker\n' > "$WORKDIR/dead.err"
(exit 7) &
dead=$!
if wait "$dead"; then fail 'negative writer unexpectedly succeeded'; fi
for kind in text stage; do
    mkdir -p "$WORKDIR/empty"
    if (
        if [ "$kind" = text ]; then
            wait_for_package_lock_text "$WORKDIR/wrong.lock" winner "$dead" dead
        else
            wait_for_package_lock_stage "$WORKDIR/empty" "$dead" dead
        fi
    ) > "$WORKDIR/dead-$kind.log" 2>&1; then
        fail "$kind accepted a terminated writer without expected output"
    fi
    grep -F 'exited before' "$WORKDIR/dead-$kind.log" >/dev/null
    grep -F 'child stdout marker' "$WORKDIR/dead-$kind.log" >/dev/null
    grep -F 'child stderr marker' "$WORKDIR/dead-$kind.log" >/dev/null
done

# Exercise the unchanged 600 x 0.1s timeout without spending a minute per case.
# Only the clock and process-liveness observations are replaced here.
for kind in text stage; do
    if (
        kill() { return 0; }
        sleep() {
            [ "$1" = 0.1 ] || fail 'poll interval changed'
            printf '.\n' >> "$WORKDIR/ticks-$kind"
        }
        if [ "$kind" = text ]; then
            wait_for_package_lock_text "$WORKDIR/wrong.lock" winner 999999 live
        else
            wait_for_package_lock_stage "$WORKDIR/empty" 999999 live
        fi
    ) > "$WORKDIR/timeout-$kind.log" 2>&1; then
        fail "$kind accepted a live writer without expected output"
    fi
    [ "$(wc -l < "$WORKDIR/ticks-$kind" | tr -d ' ')" = 600 ] || fail 'poll count changed'
    grep -F 'within 60s' "$WORKDIR/timeout-$kind.log" >/dev/null
done

# Observing committed bytes does not certify child success: the caller's
# independent wait/status assertion remains required even after readiness.
printf 'winner\n' > "$WORKDIR/committed.lock"
(exit 7) &
nonzero=$!
wait_for_package_lock_text "$WORKDIR/committed.lock" winner "$nonzero" committed
if wait "$nonzero"; then
    fail 'readiness hid a nonzero child exit'
else
    [ "$?" = 7 ] || fail 'unexpected child exit status'
fi

echo 'Package-lock writer observation self-tests passed.'
