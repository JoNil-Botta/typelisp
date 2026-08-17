#!/usr/bin/env sh
set -eu

mkdir -p "$FIXTURE_TMP/root/refs" "$FIXTURE_TMP/invalid-root"

cat > "$FIXTURE_TMP/root/refs/shared.tl" <<'EOF'
(module refs.shared)
(define target-value : i64 40)
EOF

cat > "$FIXTURE_TMP/root/closed.tl" <<'EOF'
(module refs.closed)
(import refs.shared)
(define closed-use : i64 shared.target-value)
EOF

cat > "$FIXTURE_TMP/root/refs/noise.tl" <<'EOF'
(module refs.noise)
(define target-value : i64 99)
(define noise-use : i64 target-value)
EOF

cat > "$FIXTURE_TMP/root/main.tl" <<'EOF'
(module refs.main)
(define disk-only : i64 0)
EOF

cat > "$FIXTURE_TMP/invalid-root/invalid.tl" <<'EOF'
(module refs.invalid)
(define broken : i64 "not an integer")
EOF
