#!/usr/bin/env sh
set -eu

printf '(module plain)\n(define answer : i64 42)\n' > "$FIXTURE_TMP/plain.tl"
