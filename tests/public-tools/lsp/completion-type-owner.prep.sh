mkdir -p "$FIXTURE_TMP/feature"
printf '(module feature.types)\n(defstruct A (alpha i64))\n(defstruct AB (beta i64))\n' > "$FIXTURE_TMP/feature/types.tl"
