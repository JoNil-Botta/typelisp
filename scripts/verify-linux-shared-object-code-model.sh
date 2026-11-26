#!/usr/bin/env sh
set -eu

# verify-linux-shared-object-code-model.sh - gate for the Linux shared-object
# code model (#8257).
#
# Every Linux row of tests/integration/manifest.d/*.manifest, at its default level,
# is staged like scripts/verify-integration.sh stages it and compiled in one
# `compile --batch` run with TYPELISP_BACKEND_CODE_MODEL=shared-object. Each
# object is assembled and linked with both `cc -shared` and `ld -shared`, and
# readelf must show:
#   - no R_X86_64_TPOFF32 (local-exec TLS) relocation in the object;
#   - no TEXTREL in the DSO, and DF_STATIC_TLS set;
#   - no dynamic symbol the DSO defines: nothing TypeLisp is exported.
# Then tests/shared-object/worker.tl is linked with a C shim into a DSO that a
# C driver dlopens and calls from two threads at once; this script writes both.
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
. "$ROOT/scripts/lib-manifest.sh"
BOUNDED_POOL_LABEL=shared-object
. "$ROOT/scripts/lib-bounded-pool.sh"

SHARED_OBJECT_WORKERS=${TYPELISP_SHARED_OBJECT_WORKERS:-4}
case "$SHARED_OBJECT_WORKERS" in
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16) ;;
    *)
        echo "invalid TYPELISP_SHARED_OBJECT_WORKERS: $SHARED_OBJECT_WORKERS (expected 1-16)" >&2
        exit 2
        ;;
esac
SHARED_OBJECT_COMPILE_WORKERS=${TYPELISP_SHARED_OBJECT_COMPILE_WORKERS:-2}
case "$SHARED_OBJECT_COMPILE_WORKERS" in
    1 | 2 | 3 | 4) ;;
    *)
        echo "invalid TYPELISP_SHARED_OBJECT_COMPILE_WORKERS: $SHARED_OBJECT_COMPILE_WORKERS (expected 1-4)" >&2
        exit 2
        ;;
esac

for tool in as cc ld readelf; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "shared-object code model gate needs $tool" >&2
        exit 1
    fi
done

WORKDIR="$ROOT/target/shared-object-code-model"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/cases" "$WORKDIR/generated"

# Generate wide_struct_literal_decls.tl inside WORKDIR so this gate has no
# ordering dependency on stage2-native-integration-corpus and never mutates the
# repository working tree.
GENERATED_WIDE_DECLS="$WORKDIR/generated/wide_struct_literal_decls.tl"
awk -f "$ROOT/tests/integration/wide_struct_literal_decls.awk" > "$GENERATED_WIDE_DECLS"

# The integration runner records copies in a plan; this gate copies at once.
stage_plan_copy() {
    mkdir -p "$(dirname -- "$2")"
    cp "$1" "$2"
}

COMBINED_MANIFEST="$WORKDIR/manifest.combined"
manifest_concat_dir "$ROOT/tests/integration/manifest.d" > "$COMBINED_MANIFEST"
NORMALIZED="$WORKDIR/manifest.normalized"
awk -v host=linux -f "$ROOT/scripts/expand-integration-manifest.awk" \
    "$COMBINED_MANIFEST" > "$NORMALIZED"

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
                if [ "$dep" = "wide_struct_literal_decls.tl" ]; then
                    stage_plan_copy "$GENERATED_WIDE_DECLS" "$case_dir/$dep"
                else
                    copy_dep "$dep" "$(dirname -- "$ROOT/$source")" "$case_dir" "$stage"
                fi
            done
            ;;
    esac
    printf '%s|%s\n' "$case_dir/$name.tl" "$case_dir/$name.s" >> "$BATCH"
    printf '%s\n' "$name" >> "$NAMES"
done < "$NORMALIZED"

echo "[shared-object] compile $(wc -l < "$NAMES" | tr -d ' ') programs with the shared-object code model"
COMPILE_POOL_DIR="$WORKDIR/compile-pool"
COMPILE_CHUNKS_DIR="$WORKDIR/compile-chunks"
COMPILE_QUEUE="$WORKDIR/compile.queue"
mkdir -p "$COMPILE_CHUNKS_DIR"
: > "$COMPILE_QUEUE"

COMPILE_CHUNK_COUNT=16
awk -v buckets="$COMPILE_CHUNK_COUNT" -v dir="$COMPILE_CHUNKS_DIR" -v queue="$COMPILE_QUEUE" '
    {
        bucket = ((NR - 1) % buckets) + 1
        job = sprintf("batch-%03d", bucket)
        if (!seen[bucket]++) {
            order[++n] = job
        }
        print >> (dir "/" job ".txt")
        close(dir "/" job ".txt")
    }
    END {
        for (i = 1; i <= n; i++) {
            print order[i] "|1" >> queue
        }
    }
' "$BATCH"

bounded_pool_run_job() {
    _job=$1
    TYPELISP_BACKEND_CODE_MODEL=shared-object "$COMPILER" compile \
        --batch "$COMPILE_CHUNKS_DIR/$_job.txt" \
        --stdlib-root "$ROOT/stdlib" --stdlib-root "$ROOT/src" \
        > "$COMPILE_CHUNKS_DIR/$_job.stdout" 2> "$COMPILE_CHUNKS_DIR/$_job.stderr"
}

bounded_pool_init "$COMPILE_POOL_DIR" "$SHARED_OBJECT_COMPILE_WORKERS" "$COMPILE_QUEUE" || exit 1
bounded_pool_start "$COMPILE_POOL_DIR" "$SHARED_OBJECT_COMPILE_WORKERS"
compile_status=0
bounded_pool_join "$COMPILE_POOL_DIR" || compile_status=$?
: > "$WORKDIR/compile.stdout"
: > "$WORKDIR/compile.stderr"
for chunk_out in "$COMPILE_CHUNKS_DIR"/batch-*.stdout; do
    [ -f "$chunk_out" ] || continue
    cat "$chunk_out" >> "$WORKDIR/compile.stdout"
done
for chunk_err in "$COMPILE_CHUNKS_DIR"/batch-*.stderr; do
    [ -f "$chunk_err" ] || continue
    cat "$chunk_err" >> "$WORKDIR/compile.stderr"
done
if [ "$compile_status" -ne 0 ]; then
    echo "shared-object compile failed" >&2
    sed 's/^/  /' "$WORKDIR/compile.stderr" | head -40 >&2
    exit 1
fi

FAILURES="$WORKDIR/failures.txt"
: > "$FAILURES"

POOL_DIR="$WORKDIR/pool"
POOL_CHUNKS_DIR="$WORKDIR/pool-chunks"
POOL_QUEUE="$WORKDIR/pool.queue"
mkdir -p "$POOL_CHUNKS_DIR"
: > "$POOL_QUEUE"

CHUNK_SIZE=24
awk -v size="$CHUNK_SIZE" -v dir="$POOL_CHUNKS_DIR" -v queue="$POOL_QUEUE" '
    {
        job = sprintf("chunk-%03d", int((NR - 1) / size) + 1)
        if (job != last) {
            if (last != "") close(dir "/" last ".names")
            print job "|1" >> queue
            last = job
        }
        print > (dir "/" job ".names")
    }
' "$NAMES"

chunk_fail() {
    printf '%s: %s\n' "$2" "$3" >> "$1"
}

bounded_pool_run_job() {
    _job=$1
    _chunk_names="$POOL_CHUNKS_DIR/$_job.names"
    _chunk_failures="$POOL_CHUNKS_DIR/$_job.failures"
    : > "$_chunk_failures"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        dir="$WORKDIR/cases/$name"
        if ! as "$dir/$name.s" -o "$dir/$name.o" 2> "$dir/as.stderr"; then
            chunk_fail "$_chunk_failures" "$name" "assembly failed: $(head -1 "$dir/as.stderr")"
            continue
        fi
        if readelf -rW "$dir/$name.o" | grep -q 'R_X86_64_TPOFF32'; then
            chunk_fail "$_chunk_failures" "$name" "object has a local-exec TLS relocation"
        fi
        if ! cc -shared -o "$dir/cc.so" "$dir/$name.o" 2> "$dir/cc.stderr"; then
            chunk_fail "$_chunk_failures" "$name" "cc -shared failed: $(grep -v ': warning:' "$dir/cc.stderr" | head -1)"
            continue
        fi
        if ! ld -shared -o "$dir/ld.so" "$dir/$name.o" 2> "$dir/ld.stderr"; then
            chunk_fail "$_chunk_failures" "$name" "ld -shared failed: $(head -1 "$dir/ld.stderr")"
            continue
        fi
        for so in cc ld; do
            _dyn=$(readelf -d "$dir/$so.so")
            case "$_dyn" in
                *TEXTREL*)
                    chunk_fail "$_chunk_failures" "$name" "$so DSO has text relocations"
                    ;;
            esac
            case "$_dyn" in
                *STATIC_TLS*) ;;
                *)
                    chunk_fail "$_chunk_failures" "$name" "$so DSO lacks DF_STATIC_TLS"
                    ;;
            esac
            exported=$(readelf --dyn-syms -W "$dir/$so.so" | awk 'NR > 3 && $7 != "UND" { print $8 }' | head -3)
            if [ -n "$exported" ]; then
                chunk_fail "$_chunk_failures" "$name" "$so DSO exports $(printf '%s' "$exported" | tr '\n' ' ')"
            fi
        done
        rm -f "$dir/$name.s" "$dir/$name.o" "$dir/cc.so" "$dir/ld.so"
    done < "$_chunk_names"
    return 0
}

bounded_pool_init "$POOL_DIR" "$SHARED_OBJECT_WORKERS" "$POOL_QUEUE" || exit 1
bounded_pool_start "$POOL_DIR" "$SHARED_OBJECT_WORKERS"
bounded_pool_join "$POOL_DIR" || exit 1

for chunk_fail_file in "$POOL_CHUNKS_DIR"/chunk-*.failures; do
    [ -f "$chunk_fail_file" ] || continue
    cat "$chunk_fail_file" >> "$FAILURES"
done

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
# The C halves of the test are written here: TypeLisp is the implementation
# language, and C fixtures live in scripts (scripts/check-implementation-languages.sh).
cat > "$DL/shim.c" <<'SHIM_C'
/* shim.c - the export of the shared-object dlopen test (#8257). Every TypeLisp symbol in the DSO is hidden, so this shim, linked
 * into the same DSO, is its one default-visibility entry. It runs the
 * program's global initializers once, then calls the TypeLisp function.
 * #8194's export and lifecycle children replace this with the real contract. */
#include <pthread.h>

extern void tl_shared_object_init(void);
extern long _tl_worker_work(long seed);

static pthread_once_t typelisp_once = PTHREAD_ONCE_INIT;

static void typelisp_init(void) { tl_shared_object_init(); }

__attribute__((visibility("default"))) long typelisp_test_work(long seed) {
    pthread_once(&typelisp_once, typelisp_init);
    return _tl_worker_work(seed);
}
SHIM_C
cat > "$DL/driver.c" <<'DRIVER_C'
/* driver.c - host of the shared-object dlopen test (#8257). It loads the DSO
 * built from worker.tl and shim.c, then calls the
 * test export from two threads at once, repeatedly. Each thread allocates
 * through its own TypeLisp arena in the TLS block the dynamic loader gave the
 * DSO. Every result must match the value computed here; exits 0 when all do. */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>

typedef long (*work_fn)(long);

static work_fn work;

static long digits(long value) {
    long count = 1;
    while (value >= 10) {
        value /= 10;
        count++;
    }
    return count;
}

static long expected(long seed) {
    long total = 0;
    for (long i = 0; i < 2000; i++) {
        total += digits(seed + i) + 4;
    }
    return total;
}

static void *run(void *arg) {
    long seed = (long)arg;
    long want = expected(seed);
    for (int round = 0; round < 50; round++) {
        if (work(seed) != want) {
            return (void *)1;
        }
    }
    return (void *)0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: driver LIBRARY\n");
        return 2;
    }
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    work = (work_fn)dlsym(library, "typelisp_test_work");
    if (work == NULL) {
        fprintf(stderr, "dlsym: %s\n", dlerror());
        return 1;
    }
    pthread_t threads[2];
    for (long t = 0; t < 2; t++) {
        if (pthread_create(&threads[t], NULL, run, (void *)(995 + t * 9000)) != 0) {
            return 1;
        }
    }
    int failed = 0;
    for (int t = 0; t < 2; t++) {
        void *result;
        pthread_join(threads[t], &result);
        failed |= result != (void *)0;
    }
    if (failed) {
        fprintf(stderr, "shared-object worker returned a wrong result\n");
        return 1;
    }
    printf("ok\n");
    return 0;
}
DRIVER_C
as "$DL/worker.s" -o "$DL/worker.o"
cc -fPIC -c "$DL/shim.c" -o "$DL/shim.o"
cc -shared -o "$DL/libworker.so" "$DL/worker.o" "$DL/shim.o" -lpthread
cc "$DL/driver.c" -o "$DL/driver" -ldl -lpthread
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

# A --no-entry library object is sectioned: each literal unit gets its own
# quoted `.rodata.<label>` section, whose relocated descriptors must still move
# out of read-only data.
LIB="$WORKDIR/library"
mkdir -p "$LIB"
if ! TYPELISP_BACKEND_CODE_MODEL=shared-object "$COMPILER" compile \
    "$ROOT/tests/shared-object/library.tl" --no-entry -o "$LIB/library.s" \
    --stdlib-root "$ROOT/stdlib" > "$LIB/compile.stdout" 2> "$LIB/compile.stderr"; then
    echo "shared-object library compile failed" >&2
    sed 's/^/  /' "$LIB/compile.stderr" >&2
    exit 1
fi
if ! grep -q '^\.section "\.rodata\.' "$LIB/library.s"; then
    echo "shared-object library object has no sectioned literal" >&2
    exit 1
fi
as "$LIB/library.s" -o "$LIB/library.o"
ld -shared -o "$LIB/library.so" "$LIB/library.o"
case "$(readelf -d "$LIB/library.so")" in
    *TEXTREL*)
        echo "shared-object library DSO has text relocations" >&2
        exit 1
        ;;
esac
echo "[shared-object] --no-entry library DSO has no text relocation"
