#!/usr/bin/env sh
set -eu

printf '(define imported : i64 true)\n' > "$FIXTURE_TMP/lib.tl"
