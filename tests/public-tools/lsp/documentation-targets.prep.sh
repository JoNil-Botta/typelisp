#!/usr/bin/env sh
set -eu
mkdir -p "$FIXTURE_TMP/docs"
cat > "$FIXTURE_TMP/docs/dep.tl" <<'TL'
(module docs.dep)
(define extra : i64 0)
TL
cat > "$FIXTURE_TMP/docs/api.html" <<'HTML'
<!doctype html><title>Exact fixture API</title>
<a id="tl-pkg_2fapi_2etl.field.value.Left">Left.value</a>
<a id="tl-pkg_2fapi_2etl.field.value.Right">Right.value</a>
<a id="tl-pkg_2fapi_2etl.import-alias.dep">dep</a>
HTML
