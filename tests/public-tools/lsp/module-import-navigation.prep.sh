mkdir -p "$FIXTURE_TMP/feature"
printf '(module feature.util)\n;: Imported value documentation.\n(define value : i64 41)\n' > "$FIXTURE_TMP/feature/util.tl"
printf '(module feature.other)\n;: Other value documentation.\n(define value : i64 1)\n' > "$FIXTURE_TMP/feature/other.tl"
