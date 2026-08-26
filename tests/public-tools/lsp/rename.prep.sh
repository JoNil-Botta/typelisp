#!/usr/bin/env sh
set -eu

mkdir -p "$FIXTURE_TMP/root/refactor"

cat > "$FIXTURE_TMP/root/refactor/shared.tl" <<'EOF'
(module refactor.shared)
(define other-value : i64 2)
(define target-value : i64 40)
EOF

cat > "$FIXTURE_TMP/root/closed.tl" <<'EOF'
(module refactor.closed)
(import refactor.shared)
(define closed-use : i64 shared.target-value)
EOF
