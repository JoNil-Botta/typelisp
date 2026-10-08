#!/usr/bin/env sh
set -eu

# verify-linux-shared-object-code-model.sh - gate for the Linux shared-object
# code model (#8257).
#
# Every Linux row of tests/integration/native.manifest, at its default level,
# is staged like scripts/verify-integration.sh stages it and compiled in one
# `compile --batch` run with TYPELISP_BACKEND_CODE_MODEL=shared-object. Each
# object is assembled and linked with both `cc -shared` and `ld -shared`, and
# readelf must show:
#   - no R_X86_64_TPOFF32 (local-exec TLS) relocation in the object;
#   - no TEXTREL in the DSO, and DF_STATIC_TLS set;
#   - no dynamic symbol the DSO defines: nothing TypeLisp is exported.
# Then tests/shared-object/worker.tl is linked with shim.c into a DSO that
# driver.c dlopens and calls from two threads at once.
#
# The executable code model is untouched by the variable; the integration and
# fixpoint gates cover its output.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "the shared-object code model gate runs on Linux only" >&2
        exit 1
        ;;
esac

. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_require_compiler
. "$ROOT/scripts/lib-integration-deps.sh"

for tool in as cc ld readelf; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "shared-object code model gate needs $tool" >&2
        exit 1
    fi
done

WORKDIR="$ROOT/target/shared-object-code-model"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/cases"

# The integration runner records copies in a plan; this gate copies at once.
stage_plan_copy() {
    mkdir -p "$(dirname -- "$2")"
    cp "$1" "$2"
}

NORMALIZED="$WORKDIR/manifest.normalized"
awk -v host=linux -f "$ROOT/scripts/expand-integration-manifest.awk" \
    "$ROOT/tests/integration/native.manifest" > "$NORMALIZED"

BATCH="$WORKDIR/batch.txt"
NAMES="$WORKDIR/names.txt"
: > "$BATCH"
: > "$NAMES"
while IFS='|' read -r name source _want _stdout _args deps extra _suite || [ -n "$name" ]; do
    case "$name" in
        "" | \#*) continue ;;
    esac
    # A row run at an explicit level repeats a source the default row covers.
    case "${extra:-}" in
        opt-level:*) continue ;;
    esac
    stage=0
    case "${extra:-}" in
        stage-stdlib | stage-stdlib+*) stage=1 ;;
    esac
    case_dir="$WORKDIR/cases/$name"
    stage_plan_copy "$ROOT/$source" "$case_dir/$name.tl"
    case "$deps" in
        "" | -) ;;
        *)
            for dep in $deps; do
                copy_dep "$dep" "$(dirname -- "$ROOT/$source")" "$case_dir" "$stage"
            done
            ;;
    esac
    printf '%s|%s\n' "$case_dir/$name.tl" "$case_dir/$name.s" >> "$BATCH"
    printf '%s\n' "$name" >> "$NAMES"
done < "$NORMALIZED"

echo "[shared-object] compile $(wc -l < "$NAMES" | tr -d ' ') programs with the shared-object code model"
if ! TYPELISP_BACKEND_CODE_MODEL=shared-object "$COMPILER" compile --batch "$BATCH" \
    --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" \
    > "$WORKDIR/compile.stdout" 2> "$WORKDIR/compile.stderr"; then
    echo "shared-object compile failed" >&2
    sed 's/^/  /' "$WORKDIR/compile.stderr" | head -40 >&2
    exit 1
fi

FAILURES="$WORKDIR/failures.txt"
: > "$FAILURES"
fail() {
    printf '%s: %s\n' "$1" "$2" >> "$FAILURES"
}

while read -r name; do
    dir="$WORKDIR/cases/$name"
    if ! as "$dir/$name.s" -o "$dir/$name.o" 2> "$dir/as.stderr"; then
        fail "$name" "assembly failed: $(head -1 "$dir/as.stderr")"
        continue
    fi
    if readelf -rW "$dir/$name.o" | grep -q 'R_X86_64_TPOFF32'; then
        fail "$name" "object has a local-exec TLS relocation"
    fi
    if ! cc -shared -o "$dir/cc.so" "$dir/$name.o" 2> "$dir/cc.stderr"; then
        fail "$name" "cc -shared failed: $(grep -v ': warning:' "$dir/cc.stderr" | head -1)"
        continue
    fi
    if ! ld -shared -o "$dir/ld.so" "$dir/$name.o" 2> "$dir/ld.stderr"; then
        fail "$name" "ld -shared failed: $(head -1 "$dir/ld.stderr")"
        continue
    fi
    for so in cc ld; do
        if readelf -d "$dir/$so.so" | grep -q 'TEXTREL'; then
            fail "$name" "$so DSO has text relocations"
        fi
        if ! readelf -d "$dir/$so.so" | grep -q 'STATIC_TLS'; then
            fail "$name" "$so DSO lacks DF_STATIC_TLS"
        fi
        exported=$(readelf --dyn-syms -W "$dir/$so.so" | awk 'NR > 3 && $7 != "UND" { print $8 }' | head -3)
        if [ -n "$exported" ]; then
            fail "$name" "$so DSO exports $(printf '%s' "$exported" | tr '\n' ' ')"
        fi
    done
    rm -f "$dir/$name.s" "$dir/$name.o" "$dir/cc.so" "$dir/ld.so"
done < "$NAMES"

if [ -s "$FAILURES" ]; then
    echo "shared-object code model failures:" >&2
    sed 's/^/  /' "$FAILURES" >&2
    exit 1
fi
echo "[shared-object] $(wc -l < "$NAMES" | tr -d ' ') programs link as DSOs with no text relocation, local-exec TLS or export"

DL="$WORKDIR/dlopen"
mkdir -p "$DL"
if ! TYPELISP_BACKEND_CODE_MODEL=shared-object "$COMPILER" compile \
    "$ROOT/tests/shared-object/worker.tl" -o "$DL/worker.s" \
    --stdlib-root "$ROOT/stdlib" > "$DL/compile.stdout" 2> "$DL/compile.stderr"; then
    echo "shared-object worker compile failed" >&2
    sed 's/^/  /' "$DL/compile.stderr" >&2
    exit 1
fi
as "$DL/worker.s" -o "$DL/worker.o"
cc -fPIC -c "$ROOT/tests/shared-object/shim.c" -o "$DL/shim.o"
cc -shared -o "$DL/libworker.so" "$DL/worker.o" "$DL/shim.o" -lpthread
cc "$ROOT/tests/shared-object/driver.c" -o "$DL/driver" -ldl -lpthread
exported=$(readelf --dyn-syms -W "$DL/libworker.so" | awk 'NR > 3 && $7 != "UND" { print $8 }')
if [ "$exported" != "typelisp_test_work" ]; then
    echo "shared-object worker DSO must export only typelisp_test_work, exports: $exported" >&2
    exit 1
fi
if ! "$DL/driver" "$DL/libworker.so" > "$DL/driver.stdout" 2> "$DL/driver.stderr"; then
    echo "shared-object dlopen test failed" >&2
    sed 's/^/  /' "$DL/driver.stderr" >&2
    exit 1
fi
echo "[shared-object] dlopen test: two threads allocate through the DSO's arenas"
