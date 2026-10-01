#!/usr/bin/env sh
set -eu

# A directory named with the two UTF-8 bytes of U+00E5, which clients send as
# %C3%A5 in file URIs (#8376).
dir="$FIXTURE_TMP/$(printf '\303\245')"
mkdir -p "$dir"
printf '(define imported : i64 true)\n' > "$dir/lib.tl"
