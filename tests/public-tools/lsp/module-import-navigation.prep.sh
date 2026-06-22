mkdir -p "$FIXTURE_TMP/feature"
printf '(module feature.util)\n(define value : i64 41)\n' > "$FIXTURE_TMP/feature/util.tl"
