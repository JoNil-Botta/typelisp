#!/usr/bin/env sh
set -eu

# The native coordinator owns policy, configuration discovery and fixtures.
# This wrapper only selects the existing compiler, bounds the job and links tools.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

if [ "${1:-}" != --bounded ]; then
    [ "$#" -eq 0 ] || fail "usage: scripts/verify-core-ir-dependencies.sh"
    if [ -n "${TYPELISP_BIN:-}" ]; then
        COMPILER=$TYPELISP_BIN
    else
        . "$ROOT/scripts/lib-stage0.sh"
        COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
    fi
    [ -x "$COMPILER" ] || fail "dependency boundary compiler is not executable: $COMPILER"
    mkdir -p target/exp/core-ir-dependency-boundary
    WORKDIR=$(mktemp -d target/exp/core-ir-dependency-boundary/run.XXXXXX)
    LIMIT_MIB=6144
    [ "$NL_HOST_OS" != windows ] || LIMIT_MIB=4096
    exec scripts/run-memory-bounded.sh \
        --limit-mib "$LIMIT_MIB" --timeout-seconds 1800 \
        --report "$WORKDIR/resources.txt" --working-directory "$ROOT" \
        -- sh scripts/verify-core-ir-dependencies.sh --bounded "$COMPILER" "$WORKDIR"
fi

[ "$#" -eq 3 ] || fail "dependency boundary: invalid bounded invocation"
COMPILER=$2
WORKDIR=$3
configure_toolchain

build_tool() {
    tool=$1
    shift
    "$COMPILER" compile "tools/compiler-dependency-boundary/$tool.tl" \
        -o "$WORKDIR/$tool.s" --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) --opt-level 2 \
        --stdlib-root stdlib --stdlib-root src "$@"
    assemble_and_link "$tool" "$WORKDIR/$tool.s" \
        "$WORKDIR/$tool.$NL_OBJ_EXT" "$WORKDIR/$tool$NL_BIN_EXT"
}

build_tool inspect --cfg compiler-dependency-audit
build_tool check
build_tool smoke
build_tool fact_fixture

"$WORKDIR/smoke$NL_BIN_EXT" "$WORKDIR/check$NL_BIN_EXT" \
    "$WORKDIR/inspect$NL_BIN_EXT" "$WORKDIR/source-fixtures" \
    tools/compiler-dependency-boundary/fixtures.json
"$WORKDIR/smoke$NL_BIN_EXT" "$WORKDIR/check$NL_BIN_EXT" \
    "$WORKDIR/fact_fixture$NL_BIN_EXT" "$WORKDIR/protocol-fixtures" \
    tools/compiler-dependency-boundary/protocol-fixtures.json
"$WORKDIR/check$NL_BIN_EXT" "$WORKDIR/inspect$NL_BIN_EXT" \
    src/compiler_ir_types.tl tools/compiler-dependency-boundary/policy.json
