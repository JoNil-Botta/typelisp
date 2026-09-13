#!/usr/bin/env sh
set -eu

# A declaration-only marker must not affect generated code on either target.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

TMP_ROOT=${TMPDIR:-/tmp}
WORKDIR=$(mktemp -d "$TMP_ROOT/typelisp-must-use-abi.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM

for TARGET in linux-x86_64 windows-x86_64; do
    for OPT_LEVEL in 0 2; do
        "$COMPILER" compile tools/must-use-abi-unmarked.tl \
            -o "$WORKDIR/unmarked-$TARGET-$OPT_LEVEL.s" \
            --target "$TARGET" --opt-level "$OPT_LEVEL" --stdlib-root stdlib \
            > "$WORKDIR/unmarked-$TARGET-$OPT_LEVEL.log"
        "$COMPILER" compile tools/must-use-abi-marked.tl \
            -o "$WORKDIR/marked-$TARGET-$OPT_LEVEL.s" \
            --target "$TARGET" --opt-level "$OPT_LEVEL" --stdlib-root stdlib \
            > "$WORKDIR/marked-$TARGET-$OPT_LEVEL.log"
        # The files' source-module names are the only permitted symbol difference.
        sed 's/must_use_abi_unmarked/must_use_abi_marked/g' \
            "$WORKDIR/unmarked-$TARGET-$OPT_LEVEL.s" \
            > "$WORKDIR/normalized-$TARGET-$OPT_LEVEL.s"
        if ! cmp -s "$WORKDIR/normalized-$TARGET-$OPT_LEVEL.s" \
            "$WORKDIR/marked-$TARGET-$OPT_LEVEL.s"; then
            diff -u "$WORKDIR/normalized-$TARGET-$OPT_LEVEL.s" \
                "$WORKDIR/marked-$TARGET-$OPT_LEVEL.s" >&2 || :
            echo "must-use altered $TARGET opt$OPT_LEVEL assembly" >&2
            exit 1
        fi
        echo "must-use $TARGET opt$OPT_LEVEL assembly unchanged"
    done
done

for SOURCE in tools/must-use-abi-unmarked.tl tools/must-use-abi-marked.tl; do
    set +e
    "$COMPILER" run "$SOURCE" --stdlib-root stdlib \
        > "$WORKDIR/runtime.out" 2> "$WORKDIR/runtime.err"
    STATUS=$?
    set -e
    if [ "$STATUS" -ne 7 ]; then
        echo "$SOURCE returned $STATUS, expected 7 from the pinned layout" >&2
        cat "$WORKDIR/runtime.err" >&2
        exit 1
    fi
done
echo "marked and unmarked aggregate layout/runtime unchanged"

"$COMPILER" check tools/must-use-generated.tl --stdlib-root stdlib \
    > "$WORKDIR/generated.out" 2> "$WORKDIR/generated.err"
echo "must-use aggregate emitted by a macro compiles"

if "$COMPILER" check tools/must-use-invalid-local.tl --stdlib-root stdlib \
    > "$WORKDIR/invalid-local.out" 2> "$WORKDIR/invalid-local.err"; then
    echo "local :must-use unexpectedly accepted" >&2
    exit 1
fi
if ! grep -F 'typecheck: unbound name :must-use' \
    "$WORKDIR/invalid-local.err" >/dev/null; then
    echo "local :must-use did not produce the expected diagnostic" >&2
    cat "$WORKDIR/invalid-local.err" >&2
    exit 1
fi
echo "must-use outside an aggregate remains unbound"
