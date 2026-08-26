#!/usr/bin/env sh
set -eu

mkdir -p "$FIXTURE_TMP/root/surfaces"

cat > "$FIXTURE_TMP/root/surfaces/lib.tl" <<'EOF'
(module surfaces.lib)
(define shared-value : i64 9)
(defstruct Pair (left i64) (right i64))
EOF

cat > "$FIXTURE_TMP/root/surfaces/occupied.tl" <<'EOF'
(module surfaces.occupied)
EOF
