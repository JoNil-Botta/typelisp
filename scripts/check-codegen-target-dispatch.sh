#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

ALLOWLIST=${CODEGEN_TARGET_DISPATCH_ALLOWLIST:-scripts/codegen-target-dispatch-allowlist.tsv}
WORKDIR=${CODEGEN_TARGET_DISPATCH_DIR:-target/codegen-target-dispatch}
OBSERVED="$WORKDIR/observed.tsv"

if [ ! -f "$ALLOWLIST" ]; then
    echo "missing codegen target dispatch allowlist: $ALLOWLIST" >&2
    exit 1
fi

mkdir -p "$WORKDIR"

TOKEN_RE='CompilerLower(Linux|Windows)[[:alnum:]_]*|lower-mode-(linux|windows)-[[:alnum:]_?-]+|BackendTarget(Linux|Windows)|compiler-backend-target-(linux|windows)[?]|target-(linux|windows)|(linux|windows)-x86_64'

awk -v token_re="$TOKEN_RE" '
function scope_name(text) {
    sub(/[[:space:]].*/, "", text)
    sub(/\).*/, "", text)
    sub(/\[.*/, "", text)
    return text
}
FNR == 1 {
    scope = "<toplevel>"
}
{
    line = $0
    if (line ~ /^\(define[[:space:]]+\(/) {
        text = line
        sub(/^\(define[[:space:]]+\(/, "", text)
        scope = scope_name(text)
    } else if (line ~ /^\(define[[:space:]]+/) {
        text = line
        sub(/^\(define[[:space:]]+/, "", text)
        scope = scope_name(text)
    } else if (line ~ /^\(defenum[[:space:]]+/) {
        text = line
        sub(/^\(defenum[[:space:]]+/, "", text)
        scope = "enum:" scope_name(text)
    } else if (line ~ /^\(defstruct[[:space:]]+/) {
        text = line
        sub(/^\(defstruct[[:space:]]+/, "", text)
        scope = "type:" scope_name(text)
    } else if (line ~ /^\(deftype[[:space:]]+/) {
        text = line
        sub(/^\(deftype[[:space:]]+/, "", text)
        scope = "type:" scope_name(text)
    }

    if (line ~ /^[[:space:]]*;;/) {
        next
    }

    rest = line
    while (match(rest, token_re)) {
        token = substr(rest, RSTART, RLENGTH)
        printf "%s\t%s\t%s\t%d\n", FILENAME, scope, token, FNR
        rest = substr(rest, RSTART + RLENGTH)
    }
}
' src/compiler_lower.tl src/compiler_backend.tl | sort > "$OBSERVED"

awk -F '\t' -v allowlist="$ALLOWLIST" -v observed="$OBSERVED" '
BEGIN {
    valid_category["abi"] = 1
    valid_category["backend-mode"] = 1
    valid_category["entry"] = 1
    valid_category["object-format"] = 1
    valid_category["runtime"] = 1
    valid_category["target-cfg"] = 1
    valid_category["test-only"] = 1
    valid_category["transitional"] = 1
}
FILENAME == allowlist {
    if ($0 == "" || $0 ~ /^#/) {
        next
    }
    if (NF < 6) {
        printf "malformed target dispatch allowlist row %d: expected 6 tab-separated fields\n", FNR > "/dev/stderr"
        failed = 1
        next
    }
    if ($1 !~ /^src\/compiler_(lower|backend)\.tl$/) {
        printf "malformed target dispatch allowlist row %d: unsupported file `%s`\n", FNR, $1 > "/dev/stderr"
        failed = 1
    }
    if (!($3 in valid_category)) {
        printf "malformed target dispatch allowlist row %d: unknown category `%s`\n", FNR, $3 > "/dev/stderr"
        failed = 1
    }
    if ($5 !~ /^[1-9][0-9]*$/) {
        printf "malformed target dispatch allowlist row %d: count must be a positive integer\n", FNR > "/dev/stderr"
        failed = 1
    }
    key = $1 SUBSEP $2 SUBSEP $4
    if (key in seen_allow) {
        printf "duplicate target dispatch allowlist row %d for %s\t%s\t%s\n", FNR, $1, $2, $4 > "/dev/stderr"
        failed = 1
    }
    seen_allow[key] = 1
    allow_count += 1
    allow_file[allow_count] = $1
    allow_scope[allow_count] = $2
    allow_category[allow_count] = $3
    allow_regex[allow_count] = $4
    allow_expected[allow_count] = $5 + 0
    next
}
FILENAME == observed {
    observed_count += 1
    matched = 0
    matched_index = 0
    for (idx = 1; idx <= allow_count; idx += 1) {
        if ($1 == allow_file[idx] && $2 == allow_scope[idx] && $3 ~ ("^(" allow_regex[idx] ")$")) {
            matched += 1
            matched_index = idx
        }
    }
    if (matched == 1) {
        actual[matched_index] += 1
    } else if (matched == 0) {
        printf "unclassified target dispatch: %s:%s scope=%s token=%s\n", $1, $4, $2, $3 > "/dev/stderr"
        failed = 1
    } else {
        printf "ambiguous target dispatch allowlist match: %s:%s scope=%s token=%s matched %d rows\n", $1, $4, $2, $3, matched > "/dev/stderr"
        failed = 1
    }
    next
}
END {
    if (allow_count == 0) {
        print "target dispatch allowlist is empty" > "/dev/stderr"
        failed = 1
    }
    for (idx = 1; idx <= allow_count; idx += 1) {
        count = actual[idx] + 0
        if (count != allow_expected[idx]) {
            printf "target dispatch allowlist count mismatch: %s scope=%s category=%s regex=%s expected=%d observed=%d\n", allow_file[idx], allow_scope[idx], allow_category[idx], allow_regex[idx], allow_expected[idx], count > "/dev/stderr"
            failed = 1
        }
    }
    if (failed) {
        print "codegen target dispatch allowlist check failed" > "/dev/stderr"
        exit 1
    }
    printf "codegen target dispatch allowlist covers %d occurrences across %d classified rows\n", observed_count, allow_count
}
' "$ALLOWLIST" "$OBSERVED"
