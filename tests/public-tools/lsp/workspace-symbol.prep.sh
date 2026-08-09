#!/usr/bin/env sh
set -eu

mkdir -p "$FIXTURE_TMP/root-a" "$FIXTURE_TMP/root-b/nested"

cat > "$FIXTURE_TMP/root-a/a.tl" <<'EOF'
(module alpha.mod)
(define (target) : i64 1)
(define (targetPrefix) : i64 2)
(define (mytarget) : i64 3)
(defstruct Pair (left i64) (right i64))
EOF

cat > "$FIXTURE_TMP/root-b/nested/b.tl" <<'EOF'
(define target : i64 4)
(define (other) : i64 5)
EOF
