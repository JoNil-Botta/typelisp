#!/usr/bin/env sh
# refactor-check-cfgs.sh - typecheck src/main.tl under every compiler build mode.
#
# usage: scripts/refactor-check-cfgs.sh <checker-compiler>
#
# A refactor of compiler sources can be correct in the default build and still
# break a build mode that only CI or a profiling run enables: cfg-gated code
# keeps its own uses of values, and the default check never sees them. This
# checks src/main.tl for both targets under each cfg set a build mode uses.
# The run holds a scripts/refactor-capped.sh slot and each check is capped at
# 4G and 10 minutes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -n "${TL_REFACTOR_CAPPED:-}" ] || exec "$ROOT/scripts/refactor-capped.sh" "$0" "$@"
cd "$ROOT"
[ "$#" -eq 1 ] || { echo "usage: $0 <checker-compiler>" >&2; exit 2; }
CHECKER=$1
fail=0
check() { # target cfgs...
    target=$1
    shift
    set -- $(for c in "$@"; do printf -- '--cfg %s ' "$c"; done)
    if scripts/refactor-capped.sh --mem 4G --timeout 600 "$CHECKER" check src/main.tl --target "$target" --stdlib-root stdlib --stdlib-root src "$@" \
        > target/refactor-check-cfgs.out 2>&1; then
        echo "[refactor-check-cfgs] ok   $target $*"
    else
        echo "[refactor-check-cfgs] FAIL $target $*" >&2
        head -20 target/refactor-check-cfgs.out >&2
        fail=1
    fi
}
mkdir -p target
for target in linux-x86_64 windows-x86_64; do
    check "$target"
    check "$target" test
    check "$target" compile-profile
    check "$target" compile-profile compile-profile-summary compile-startup-profile
    check "$target" embedded-stdlib-tlci compiler-build-identity
    check "$target" embedded-stdlib-tlci tlci-native-route-stress dependency-tlci-verification tlci-bootstrap-mutation-witness
    check "$target" compiler-surface-producer compiler-surface-selftest
    check "$target" compiler-backtrace compiler-arena-debug
done
exit "$fail"
