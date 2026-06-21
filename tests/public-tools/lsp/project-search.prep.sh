#!/usr/bin/env sh
set -eu

printf '(define (target) : i64 1)\n' > "$FIXTURE_TMP/search_hit.tl"
printf '(define (other) : i64 2)\n' > "$FIXTURE_TMP/search_miss.tl"
printf '(define (target) : i64 3)\n' > "$FIXTURE_TMP/ignored.txt"
