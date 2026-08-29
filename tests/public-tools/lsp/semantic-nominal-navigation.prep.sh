mkdir -p "$FIXTURE_TMP/provider"
printf '(module provider.nominal)\n;: Imported box documentation.\n(defstruct ImportedBox\n  (value i64))\n;: Imported choice documentation.\n(defenum ImportedChoice\n  (ImportedNone)\n  (ImportedSome ImportedBox))\n' > "$FIXTURE_TMP/provider/nominal.tl"
