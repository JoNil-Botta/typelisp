#!/usr/bin/env sh
set -eu
printf '(define (main) : i32 42)\n' > "$FIXTURE_TMP/params.tl"
