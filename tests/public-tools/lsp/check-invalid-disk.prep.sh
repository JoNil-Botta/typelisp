#!/usr/bin/env sh
set -eu

printf '(define (main) : i64\n' > "$FIXTURE_TMP/bad.tl"
