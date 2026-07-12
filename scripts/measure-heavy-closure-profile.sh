#!/usr/bin/env sh
set -eu

# Cold, serial measurements for the six build-invariance compiler closures.
# Set TYPELISP_PROFILE_INSTRUCTIONS=1 for deterministic Callgrind counts.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "${1:-}" = --list ]; then
    printf '%s\n' \
        'compiler_typecheck_smoke|src/tests/compiler_typecheck_smoke.tl' \
        'compiler_lower_smoke|src/tests/compiler_lower_smoke.tl' \
        'compiler_backend_smoke|src/tests/compiler_backend_smoke.tl' \
        'doc_test_smoke|src/tests/doc_test_smoke.tl' \
        'compiler_driver_pic_smoke|src/tests/compiler_driver_pic_smoke.tl' \
        'compiler_driver_state_smoke|src/tests/compiler_driver_state_smoke.tl'
    exit 0
fi

COMPILER=${1:-${TYPELISP_BIN:-}}
if [ -z "$COMPILER" ]; then
    echo "usage: $0 /path/to/summary-enabled-typelisp" >&2
    exit 2
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

WORKDIR=${TYPELISP_PROFILE_WORKDIR:-$ROOT/target/heavy-closure-profile}
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

INSTRUCTIONS=${TYPELISP_PROFILE_INSTRUCTIONS:-0}
if [ "$INSTRUCTIONS" = 1 ] && ! command -v valgrind >/dev/null 2>&1; then
    echo "valgrind is required for TYPELISP_PROFILE_INSTRUCTIONS=1" >&2
    exit 2
fi

printf 'source\twall_seconds\tpeak_rss_kb\tinstructions\tstatus\n'
while IFS='|' read -r label source; do
    [ -n "$label" ] || continue
    asm="$WORKDIR/$label.s"
    stdout="$WORKDIR/$label.stdout"
    stderr="$WORKDIR/$label.stderr"
    timing="$WORKDIR/$label.time"
    callgrind="$WORKDIR/$label.callgrind"
    status=0
    if [ "$INSTRUCTIONS" = 1 ]; then
        /usr/bin/time -f '%e\t%M' -o "$timing" \
            valgrind --quiet --tool=callgrind --callgrind-out-file="$callgrind" \
            "$COMPILER" compile "$source" -o "$asm" \
                --target linux-x86_64 --stdlib-root stdlib --stdlib-root src \
                --opt-level 2 >"$stdout" 2>"$stderr" || status=$?
        count=$(awk '/^summary:/ { print $2; exit }' "$callgrind")
        count=${count:--}
    else
        /usr/bin/time -f '%e\t%M' -o "$timing" \
            "$COMPILER" compile "$source" -o "$asm" \
                --target linux-x86_64 --stdlib-root stdlib --stdlib-root src \
                --opt-level 2 >"$stdout" 2>"$stderr" || status=$?
        count=-
    fi
    metrics=$(cat "$timing")
    printf '%s\t%s\t%s\t%s\n' "$label" "$metrics" "$count" "$status"
done <<'EOF'
compiler_typecheck_smoke|src/tests/compiler_typecheck_smoke.tl
compiler_lower_smoke|src/tests/compiler_lower_smoke.tl
compiler_backend_smoke|src/tests/compiler_backend_smoke.tl
doc_test_smoke|src/tests/doc_test_smoke.tl
compiler_driver_pic_smoke|src/tests/compiler_driver_pic_smoke.tl
compiler_driver_state_smoke|src/tests/compiler_driver_state_smoke.tl
EOF
