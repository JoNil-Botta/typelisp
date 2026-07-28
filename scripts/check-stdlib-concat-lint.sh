#!/usr/bin/env sh
set -eu

# check-stdlib-concat-lint.sh - keep runtime string concatenation out of stdlib.
# refs #5175, #5444

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-stdlib-concat-lint.sh

Lints every git-tracked stdlib TypeLisp source for deprecated runtime string
concatenation in deterministic bounded batches, then proves the gate rejects
an ordinary string.append call.
EOF
}

case "$#" in
    0) ;;
    1)
        case "$1" in
            -h | --help) usage; exit 0 ;;
            *) usage; exit 2 ;;
        esac
        ;;
    *)
        usage
        exit 2
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # Local-development fallback. CI supplies its freshly bootstrapped compiler
    # through TYPELISP_BIN when verify-stdlib.sh invokes this gate.
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

BATCH_SIZE=${TYPELISP_STDLIB_CONCAT_LINT_BATCH_SIZE:-32}
case "$BATCH_SIZE" in
    '' | *[!0-9]* | 0)
        echo "TYPELISP_STDLIB_CONCAT_LINT_BATCH_SIZE must be a positive integer" >&2
        exit 2
        ;;
esac

WORKDIR="$ROOT/target/stdlib-concat-lint"
FILES="$WORKDIR/files.txt"
CHUNK_DIR="$WORKDIR/chunks"
PROBE="stdlib/tests/.deprecated-string-concat-lint-probe.$$.tl"
PROBE_STDOUT="$WORKDIR/probe.stdout"
PROBE_STDERR="$WORKDIR/probe.stderr"

cleanup() {
    rm -f "$PROBE"
}
trap cleanup EXIT HUP INT TERM

rm -rf "$WORKDIR"
mkdir -p "$CHUNK_DIR"

# Use the reviewed repository set, not a filesystem walk: untracked editor or
# build artifacts must neither expand nor hide CI coverage. Git's pathspec
# matches nested stdlib/tests sources as well as top-level modules.
git ls-files -- 'stdlib/*.tl' | LC_ALL=C sort > "$FILES"

if [ ! -s "$FILES" ]; then
    echo "stdlib concat lint selected no tracked TypeLisp files" >&2
    exit 1
fi

if grep -v '^stdlib/.*\.tl$' "$FILES" >/dev/null 2>&1; then
    echo "stdlib concat lint selected a path outside stdlib/**/*.tl" >&2
    exit 1
fi

awk -v outdir="$CHUNK_DIR" -v size="$BATCH_SIZE" '
    {
        chunk = int((NR - 1) / size) + 1
        path = sprintf("%s/lint.%04d.txt", outdir, chunk)
        print $0 >> path
        if (NR % size == 0) close(path)
    }
' "$FILES"

run_concat_lint() {
    "$COMPILER" lint \
        --check \
        --deprecated-string-concat \
        --stdlib-root "$ROOT/stdlib" \
        "$@"
}

file_count=$(wc -l < "$FILES" | tr -d ' ')
batch_count=0
echo "[stdlib-concat-lint] checking $file_count tracked source(s) in batches of $BATCH_SIZE"

for chunk in "$CHUNK_DIR"/lint.*.txt; do
    [ -f "$chunk" ] || continue
    set --
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        set -- "$@" "$source"
    done < "$chunk"
    [ "$#" -gt 0 ] || continue
    batch_count=$((batch_count + 1))
    echo "[stdlib-concat-lint] batch $batch_count"
    run_concat_lint "$@"
done

if [ "$batch_count" -eq 0 ]; then
    echo "stdlib concat lint produced no non-empty batches" >&2
    exit 1
fi

# Exercise the complete command, not only the lint-core unit test. The probe
# lives under stdlib/ so a regression in rule selection, --check exit status,
# dotted-call recognition, or stdlib-root handling fails this owning gate.
cat > "$PROBE" <<'EOF'
(define (main) : String
  (string.append "left" "right"))
EOF

set +e
run_concat_lint "$PROBE" > "$PROBE_STDOUT" 2> "$PROBE_STDERR"
probe_status=$?
set -e

if [ "$probe_status" -eq 0 ]; then
    echo "stdlib concat lint regression: ordinary string.append unexpectedly passed" >&2
    exit 1
fi

if ! grep -F 'deprecated string concatenation primitive' "$PROBE_STDOUT" \
    >/dev/null 2>&1; then
    echo "stdlib concat lint regression returned the wrong diagnostic" >&2
    if [ -s "$PROBE_STDOUT" ]; then
        echo "stdout:" >&2
        sed 's/^/  /' "$PROBE_STDOUT" >&2
    fi
    if [ -s "$PROBE_STDERR" ]; then
        echo "stderr:" >&2
        sed 's/^/  /' "$PROBE_STDERR" >&2
    fi
    exit 1
fi

echo "stdlib deprecated-concat lint passed for $file_count tracked source(s) in $batch_count batch(es); rejection probe passed"
