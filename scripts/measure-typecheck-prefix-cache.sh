#!/usr/bin/env sh
set -eu

# measure-typecheck-prefix-cache.sh - report typecheck prefix-cache stats.
#
# The script exercises the batch-shaped workloads that should benefit from the
# in-process prefix snapshot cache:
#   1. repeated stdlib-import compile batch
#   2. one selfhost compile-manifest batch chunk
#   3. repeated doctest typecheck batch

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR=${TYPELISP_PREFIX_CACHE_WORKDIR:-target/typecheck-prefix-cache}
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

now_ms() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print(time.time_ns() // 1000000)'
    else
        printf '%s000\n' "$(date +%s)"
    fi
}

run_report() {
    label=$1
    shift
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    start_ms=$(now_ms)
    if "$@" > "$stdout" 2> "$stderr"; then
        status=0
    else
        status=$?
    fi
    end_ms=$(now_ms)
    elapsed_ms=$((end_ms - start_ms))
    if [ "$status" -ne 0 ]; then
        echo "[prefix-cache] $label failed with status $status" >&2
        sed 's/^/  stdout: /' "$stdout" >&2 || true
        sed 's/^/  stderr: /' "$stderr" >&2 || true
        exit "$status"
    fi
    stats=$(grep '^typecheck-prefix-cache|' "$stderr" | tail -n 1 || true)
    if [ -z "$stats" ]; then
        echo "[prefix-cache] $label did not emit typecheck prefix-cache stats" >&2
        sed 's/^/  stdout: /' "$stdout" >&2 || true
        sed 's/^/  stderr: /' "$stderr" >&2 || true
        exit 1
    fi
    echo "[prefix-cache] $label elapsed_ms=$elapsed_ms $stats"
}

write_stdlib_import_batch() {
    batch="$WORKDIR/repeated-stdlib-import.txt"
    outdir="$WORKDIR/repeated-stdlib-asm"
    mkdir -p "$outdir"
    : > "$batch"
    i=1
    while [ "$i" -le "${TYPELISP_PREFIX_CACHE_STDLIB_IMPORT_COUNT:-12}" ]; do
        path="$WORKDIR/repeated-stdlib-import-$i.tl"
        cat > "$path" <<EOF_INNER
(import "stdlib/string.tl")

(define (main) : i64
  (string-length "prefix-cache"))
EOF_INNER
        echo "$path|$outdir/repeated-stdlib-import-$i.s" >> "$batch"
        i=$((i + 1))
    done
    printf '%s\n' "$batch"
}

write_selfhost_compile_batch() {
    batch="$WORKDIR/selfhost-compile-batch.txt"
    outdir="$WORKDIR/selfhost-asm"
    mkdir -p "$outdir"
    awk -F'|' -v outdir="$outdir" '
        /^case\|/ && $6 == "direct" && $3 ~ /^src\// && $3 != "src/main.tl" {
            print $3 "|" outdir "/" $2 ".s"
            count++
            if (count >= 8) {
                exit
            }
        }
    ' src/compile_manifest.txt > "$batch"
    if [ ! -s "$batch" ]; then
        echo "selfhost compile batch is empty" >&2
        exit 1
    fi
    printf '%s\n' "$batch"
}

write_doctest_batch() {
    list="$WORKDIR/doctest-batch.txt"
    : > "$list"
    i=1
    while [ "$i" -le "${TYPELISP_PREFIX_CACHE_DOCTEST_COUNT:-8}" ]; do
        path="$WORKDIR/doctest-prefix-cache-$i.tl"
        cat > "$path" <<EOF_INNER
;# Prefix cache doctest $i
;# \`\`\`typelisp
;# (import "stdlib/string.tl")
;# (define (main) : i64 (string-length "prefix-cache"))
;# \`\`\`

(define doctest_prefix_cache_$i : i64 $i)
EOF_INNER
        echo "$path" >> "$list"
        i=$((i + 1))
    done
    printf '%s\n' "$list"
}

stdlib_batch=$(write_stdlib_import_batch)
selfhost_batch=$(write_selfhost_compile_batch)
doctest_batch=$(write_doctest_batch)

run_report \
    repeated-stdlib-import \
    "$COMPILER" compile --batch "$stdlib_batch" \
    --stdlib-root "$ROOT/stdlib" \
    --prefix-cache-stats

run_report \
    selfhost-compile-manifest-chunk \
    "$COMPILER" compile --batch "$selfhost_batch" \
    --stdlib-root "$ROOT/stdlib" \
    --prefix-cache-stats

run_report \
    doctest-batch \
    "$COMPILER" doc --test --batch "$doctest_batch" \
    --stdlib-root "$ROOT/stdlib" \
    --prefix-cache-stats
