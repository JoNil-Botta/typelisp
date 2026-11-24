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
BOUNDED_POOL_LABEL=core-ir-deps
. "$ROOT/scripts/lib-bounded-pool.sh"

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

BUILD_POOL="$WORKDIR/build-pool"
BUILD_QUEUE="$WORKDIR/build-pool.queue"
cat > "$BUILD_QUEUE" <<'EOF'
inspect|1024
check|256
smoke|256
fact_fixture|256
EOF

bounded_pool_run_job() {
    case "$1" in
        inspect) build_tool inspect --cfg compiler-dependency-audit ;;
        check) build_tool check ;;
        smoke) build_tool smoke ;;
        fact_fixture) build_tool fact_fixture ;;
        *) fail "dependency boundary: unknown build job: $1" ;;
    esac
}

# inspect peaks near 920 MiB while check/smoke/fact_fixture are small; a 1536
# MiB budget overlaps inspect with the lightweight tools cleanly.
bounded_pool_init "$BUILD_POOL" 1536 "$BUILD_QUEUE" || exit 1
bounded_pool_start "$BUILD_POOL" 3
bounded_pool_join "$BUILD_POOL" || exit 1

SMOKE_POOL="$WORKDIR/smoke-pool"
SMOKE_QUEUE="$WORKDIR/smoke-pool.queue"
cat > "$SMOKE_QUEUE" <<'EOF'
source-fixtures|1
protocol-fixtures|1
EOF

bounded_pool_run_job() {
    case "$1" in
        source-fixtures)
            "$WORKDIR/smoke$NL_BIN_EXT" "$WORKDIR/check$NL_BIN_EXT" \
                "$WORKDIR/inspect$NL_BIN_EXT" "$WORKDIR/source-fixtures" \
                tools/compiler-dependency-boundary/fixtures.json \
                > "$WORKDIR/source-fixtures.stdout" 2> "$WORKDIR/source-fixtures.stderr"
            ;;
        protocol-fixtures)
            "$WORKDIR/smoke$NL_BIN_EXT" "$WORKDIR/check$NL_BIN_EXT" \
                "$WORKDIR/fact_fixture$NL_BIN_EXT" "$WORKDIR/protocol-fixtures" \
                tools/compiler-dependency-boundary/protocol-fixtures.json \
                > "$WORKDIR/protocol-fixtures.stdout" 2> "$WORKDIR/protocol-fixtures.stderr"
            ;;
        *) fail "dependency boundary: unknown smoke job: $1" ;;
    esac
}

bounded_pool_init "$SMOKE_POOL" 2 "$SMOKE_QUEUE" || exit 1
bounded_pool_start "$SMOKE_POOL" 2
smoke_status=0
bounded_pool_join "$SMOKE_POOL" || smoke_status=$?
for suite in source-fixtures protocol-fixtures; do
    [ ! -s "$WORKDIR/$suite.stdout" ] || cat "$WORKDIR/$suite.stdout"
    [ ! -s "$WORKDIR/$suite.stderr" ] || cat "$WORKDIR/$suite.stderr" >&2
done
[ "$smoke_status" -eq 0 ] || exit "$smoke_status"

"$WORKDIR/check$NL_BIN_EXT" "$WORKDIR/inspect$NL_BIN_EXT" \
    src/compiler_ir_types.tl tools/compiler-dependency-boundary/policy.json
