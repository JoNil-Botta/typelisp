#!/usr/bin/env sh
set -eu

# Validate the explicit build inputs and prove every payload decodes exactly.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-embedded-stdlib-payload.sh" >&2
    exit 2
fi

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

WORKDIR=target/embedded-stdlib-payload-verify
NORMALIZED_MANIFEST="$WORKDIR/modules.txt"
mkdir -p "$WORKDIR"
awk '
function emit_input() {
    path = declaration
    sub(/^[^"]*"\.\.\/stdlib\//, "", path)
    sub(/".*$/, "", path)
    print path
    declaration = ""
    collecting = 0
}
/^\(include-str-comptime-lzss([ \t]|$)/ {
    declaration = $0
    collecting = 1
    if ($0 ~ /\)[ \t]*$/) {
        emit_input()
    }
    next
}
collecting {
    declaration = declaration " " $0
    if ($0 ~ /\)[ \t]*$/) {
        emit_input()
    }
}
' src/compiler_embedded_stdlib_payload_[a-f].tl > "$NORMALIZED_MANIFEST"

if [ ! -s "$NORMALIZED_MANIFEST" ]; then
    echo "embedded stdlib payload has no build inputs" >&2
    exit 1
fi
if [ "$(wc -l < "$NORMALIZED_MANIFEST" | tr -d ' ')" -ne 42 ]; then
    echo "embedded stdlib payload must declare exactly 42 build inputs" >&2
    exit 1
fi
if grep -n -v '^[A-Za-z0-9_][A-Za-z0-9_]*\.tl$' "$NORMALIZED_MANIFEST" \
    > "$WORKDIR/invalid-manifest-lines.txt"; then
    echo "embedded stdlib payload manifest has invalid module suffixes" >&2
    sed 's/^/  /' "$WORKDIR/invalid-manifest-lines.txt" >&2
    exit 1
fi
sort "$NORMALIZED_MANIFEST" | uniq -d > "$WORKDIR/duplicate-manifest-lines.txt"
if [ -s "$WORKDIR/duplicate-manifest-lines.txt" ]; then
    echo "embedded stdlib payload manifest has duplicate modules" >&2
    sed 's/^/  /' "$WORKDIR/duplicate-manifest-lines.txt" >&2
    exit 1
fi
while IFS= read -r suffix; do
    if [ ! -f "stdlib/$suffix" ]; then
        echo "embedded stdlib payload source is missing: stdlib/$suffix" >&2
        exit 1
    fi
done < "$NORMALIZED_MANIFEST"

"$COMPILER" check src/compiler_embedded_stdlib_payload.tl \
    --stdlib-root stdlib --stdlib-root src
set +e
"$COMPILER" run tools/embedded-stdlib-payload/verify.tl \
    --stdlib-root stdlib --stdlib-root src -- "$NORMALIZED_MANIFEST"
status=$?
set -e
if [ "$status" -ne 42 ]; then
    echo "embedded stdlib exact-source verifier exited $status, expected 42" >&2
    exit 1
fi

# Compile the same explicit build input twice, then change one source byte and
# require the emitted assembly to change without touching any checked-in file.
MUTATION_DIR="$WORKDIR/source-mutation"
mkdir -p "$MUTATION_DIR"
cat > "$MUTATION_DIR/main.tl" <<'EOF'
(include-str-comptime-lzss payload "payload.txt")
(define (main) : i64 (array-length payload))
EOF
printf 'payload-A\n' > "$MUTATION_DIR/payload.txt"
"$COMPILER" compile "$MUTATION_DIR/main.tl" -o "$MUTATION_DIR/a.s" \
    --stdlib-root stdlib --opt-level 0
"$COMPILER" compile "$MUTATION_DIR/main.tl" -o "$MUTATION_DIR/a-repeat.s" \
    --stdlib-root stdlib --opt-level 0
if ! cmp -s "$MUTATION_DIR/a.s" "$MUTATION_DIR/a-repeat.s"; then
    echo "embedded stdlib build payload is not deterministic" >&2
    exit 1
fi
printf 'payload-B\n' > "$MUTATION_DIR/payload.txt"
"$COMPILER" compile "$MUTATION_DIR/main.tl" -o "$MUTATION_DIR/b.s" \
    --stdlib-root stdlib --opt-level 0
if cmp -s "$MUTATION_DIR/a.s" "$MUTATION_DIR/b.s"; then
    echo "embedded stdlib build input mutation did not change compiler output" >&2
    exit 1
fi

echo "embedded stdlib build payload is complete and exact"
