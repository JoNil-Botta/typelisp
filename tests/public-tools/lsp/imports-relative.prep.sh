#!/usr/bin/env sh
set -eu

printf '(define imported : i64 41)\n' > "$FIXTURE_TMP/lib.tl"
