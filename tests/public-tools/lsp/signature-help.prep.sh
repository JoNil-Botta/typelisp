mkdir -p "$FIXTURE_TMP/feature"
printf '(module feature.sig)\n;: Imported combine documentation.\n(define (combine [left : i64] [right : i64]) : i64 (+ left right))\n' > "$FIXTURE_TMP/feature/sig.tl"
