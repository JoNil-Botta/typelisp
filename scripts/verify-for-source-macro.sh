#!/usr/bin/env sh
set -eu

# Prove scalar for is an ordinary source transformer: no native identity hooks
# remain, and an exact body copy still works after changing only its name.

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

native_type='MacroCore''For'
native_helper='macro-core-''for'
if git grep -n -E "$native_type|$native_helper" -- src stdlib tests >/dev/null 2>&1; then
    echo "native scalar-for planner residue remains" >&2
    git grep -n -E "$native_type|$native_helper" -- src stdlib tests >&2 || true
    exit 1
fi

WORKDIR="$ROOT/target/for-source-macro-verify"
MUTATION_ROOT="$WORKDIR/stdlib-root"
rm -rf "$WORKDIR"
mkdir -p "$MUTATION_ROOT"

# The first declaration is the real feature-gated source body; the later seed
# compatibility stub deliberately keeps its original name.
sed '0,/(defmacro (for /s//(defmacro (for-copy /' \
    stdlib/core_macros.tl > "$MUTATION_ROOT/for_copy_macros.tl"

if ! grep -F '(defmacro (for-copy ' "$MUTATION_ROOT/for_copy_macros.tl" >/dev/null; then
    echo "failed to create renamed scalar-for mutation" >&2
    exit 1
fi

cat > "$WORKDIR/copied-for.tl" <<'EOF'
(import stdlib.iterator)
(import for_copy_macros as copied)

(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (copied.for-copy [item (iterator.range 0 3)]
        (set! total (+ total item)))
      (+ total 39))))
EOF

set +e
"$COMPILER" run "$WORKDIR/copied-for.tl" \
    --stdlib-root "$MUTATION_ROOT" \
    --stdlib-root "$ROOT/stdlib"
status=$?
set -e

if [ "$status" -ne 42 ]; then
    echo "renamed scalar-for body returned $status, expected 42" >&2
    exit 1
fi

echo "scalar for ordinary-source mutation guard passed"
