#!/usr/bin/env sh
set -eu

# Exhaustive per-identity embedded stdlib TLCI route differential (#6609).
# The supplied profile compiler must contain embedded-stdlib-tlci and the
# runtime-gated identity records compiled with tlci-native-route-stress.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host

COMPILER=${1:-${TYPELISP_BIN:-}}
if [ -z "$COMPILER" ]; then
    echo "usage: $0 <identity-enabled-profile-compiler>" >&2
    exit 2
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
[ -x "$COMPILER" ] || {
    echo "tlci identity differential compiler is not executable: $COMPILER" >&2
    exit 1
}

MANIFEST="$ROOT/tools/embedded-stdlib-tlci/identity-fixtures.tsv"
WORKDIR="$ROOT/target/stdlib-tlci-identity-differential/$NL_HOST_OS"
EXPLICIT_CWD="$WORKDIR/explicit-cwd"
MODIFIED_ROOT="$WORKDIR/modified-root"
DEFAULT_DIR="$WORKDIR/default"
EXPLICIT_DIR="$WORKDIR/explicit"
SOURCE_DIR="$WORKDIR/source"
EXPECTED="$WORKDIR/expected-identities.txt"
EXPECTED_KINDS="$WORKDIR/expected-kinds.txt"
EXPECTED_FIXTURE_KINDS="$WORKDIR/expected-fixture-kinds.txt"
FIXTURES="$WORKDIR/fixtures.txt"
DEFAULT_BATCH="$WORKDIR/default.batch"
EXPLICIT_BATCH="$WORKDIR/explicit.batch"
SOURCE_BATCH="$WORKDIR/source.batch"

fail() {
    echo "[tlci-identity-differential] $*" >&2
    exit 1
}

batch_path() {
    if [ "$NL_HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

[ -f "$MANIFEST" ] || fail "fixture manifest is missing: $MANIFEST"

if ! awk -F '\t' '
    /^#/ || NF == 0 { next }
    NF != 8 { bad = 1; next }
    $1 !~ /^stdlib\.[^/]+\/[^/]+$/ { bad = 1 }
    $2 !~ /^[0-9]+$/ { bad = 1 }
    $3 != "fixed" && $3 != "variadic" { bad = 1 }
    $4 != "expr" && $4 != "module" && $4 != "decls" { bad = 1 }
    $5 !~ /^(tests\/integration|stdlib\/tests)\/[^/]+\.tl$/ { bad = 1 }
    $6 != "ok" { bad = 1 }
    $7 != "default" { bad = 1 }
    $8 != "assembly" { bad = 1 }
    seen[$1]++ { duplicate = 1 }
    END { exit bad || duplicate }
' "$MANIFEST"; then
    fail "fixture manifest has a malformed or duplicate identity row"
fi

rm -rf "$WORKDIR"
mkdir -p \
    "$EXPLICIT_CWD" "$MODIFIED_ROOT/stdlib" \
    "$DEFAULT_DIR" "$EXPLICIT_DIR" "$SOURCE_DIR"

awk -F '\t' '!/^#/ && NF { print $1 }' "$MANIFEST" | sort > "$EXPECTED"
awk -F '\t' '!/^#/ && NF { print $1 "\t" $4 }' "$MANIFEST" | sort \
    > "$EXPECTED_KINDS"
awk -F '\t' '!/^#/ && NF && !seen[$5]++ { print $5 }' "$MANIFEST" \
    > "$FIXTURES"
awk -F '\t' '
    NR == FNR { ordinal[$1] = NR - 1; next }
    !/^#/ && NF { print ordinal[$5] "\t" $1 "\t" $4 }
' "$FIXTURES" "$MANIFEST" > "$EXPECTED_FIXTURE_KINDS"

IDENTITY_COUNT=$(wc -l < "$EXPECTED" | tr -d ' ')
FIXTURE_COUNT=$(wc -l < "$FIXTURES" | tr -d ' ')
[ "$IDENTITY_COUNT" -gt 0 ] || fail "fixture manifest is empty"

while IFS= read -r fixture; do
    [ -f "$ROOT/$fixture" ] || fail "fixture is missing: $fixture"
done < "$FIXTURES"

for source_file in "$ROOT"/stdlib/*.tl; do
    {
        sed -n '1,$p' "$source_file"
        echo ";; tlci-identity-differential-source-control"
    } > "$MODIFIED_ROOT/stdlib/$(basename "$source_file")"
done

: > "$DEFAULT_BATCH"
: > "$EXPLICIT_BATCH"
: > "$SOURCE_BATCH"
index=0
while IFS= read -r fixture; do
    source="$ROOT/$fixture"
    printf '%s|%s\n' \
        "$(batch_path "$source")" \
        "$(batch_path "$DEFAULT_DIR/$index.s")" >> "$DEFAULT_BATCH"
    printf '%s|%s\n' \
        "$(batch_path "$source")" \
        "$(batch_path "$EXPLICIT_DIR/$index.s")" >> "$EXPLICIT_BATCH"
    printf '%s|%s\n' \
        "$(batch_path "$source")" \
        "$(batch_path "$SOURCE_DIR/$index.s")" >> "$SOURCE_BATCH"
    index=$((index + 1))
done < "$FIXTURES"

TYPELISP_TLCI_IDENTITY_DIFFERENTIAL=1
export TYPELISP_TLCI_IDENTITY_DIFFERENTIAL

echo "[tlci-identity-differential] default trusted route ($FIXTURE_COUNT fixtures)"
if ! (
    cd "$ROOT"
    "$COMPILER" compile --batch "$DEFAULT_BATCH" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args)
) > "$WORKDIR/default.stdout" 2> "$WORKDIR/default.stderr"; then
    fail "default trusted batch failed; see $WORKDIR/default.stderr"
fi

echo "[tlci-identity-differential] byte-identical explicit root"
if ! (
    cd "$ROOT"
    "$COMPILER" compile --batch "$EXPLICIT_BATCH" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$WORKDIR/explicit.stdout" 2> "$WORKDIR/explicit.stderr"; then
    fail "byte-identical explicit-root batch failed; see $WORKDIR/explicit.stderr"
fi

echo "[tlci-identity-differential] comment-modified forced-source root"
if ! (
    cd "$MODIFIED_ROOT"
    "$COMPILER" compile --batch "$SOURCE_BATCH" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$WORKDIR/source.stdout" 2> "$WORKDIR/source.stderr"; then
    fail "forced-source batch failed; see $WORKDIR/source.stderr"
fi

index=0
while [ "$index" -lt "$FIXTURE_COUNT" ]; do
    cmp -s "$DEFAULT_DIR/$index.s" "$EXPLICIT_DIR/$index.s" ||
        fail "byte-identical explicit root changed assembly for fixture row $index"
    # Expr output and canonical Module/Decls identity/content/splice order all
    # feed the same deterministic backend stream, so exact assembly comparison
    # covers every declared result kind without a route-specific serializer.
    cmp -s "$DEFAULT_DIR/$index.s" "$SOURCE_DIR/$index.s" ||
        fail "native/source expansion changed assembly for fixture row $index"
    index=$((index + 1))
done

route_identities() {
    _route=$1
    _input=$2
    awk -F '|' -v route="$_route" '
        $1 == "tlci-identity-route" && $2 == route {
            if (route != "source") { print $4; next }
            slash = index($4, "/")
            if (slash > 0 && $5 == substr($4, 1, slash - 1)) print $4
        }
    ' \
        "$_input" | sort -u
}

route_kinds() {
    _route=$1
    _input=$2
    awk -F '|' -v route="$_route" '
        $1 == "tlci-identity-route" && $2 == route {
            if (route != "source") { print $4 "\t" $3; next }
            slash = index($4, "/")
            if (slash > 0 && $5 == substr($4, 1, slash - 1))
                print $4 "\t" $3
        }
    ' \
        "$_input" | sort -u
}

verify_fixture_routes() {
    _label=$1
    _route=$2
    _input=$3
    _missing="$WORKDIR/$_label-missing-fixture-routes.txt"
    awk -F '|' -v route="$_route" '
        NR == FNR {
            split($0, fields, "\t")
            expected[fields[1] SUBSEP fields[2] SUBSEP fields[3]] = $0
            next
        }
        $1 == "compile-batch-profile" && $3 == "entry-start" {
            ordinal = $2
            next
        }
        $1 == "tlci-identity-route" && $2 == route {
            if (route == "source") {
                slash = index($4, "/")
                if (slash == 0 || $5 != substr($4, 1, slash - 1)) next
            }
            delete expected[ordinal SUBSEP $4 SUBSEP $3]
        }
        END {
            for (key in expected) print expected[key]
        }
    ' "$EXPECTED_FIXTURE_KINDS" "$_input" > "$_missing"
    [ ! -s "$_missing" ] ||
        fail "$_label did not execute every identity in its reviewed fixture; see $_missing"
}

profile_sum() {
    _counter=$1
    _input=$2
    awk -F '|' -v phase="typecheck.macro.$_counter" \
        '$1 == "compile-profile" && $2 == phase { total += $3 } \
         END { print total + 0 }' "$_input"
}

verify_native_log() {
    _label=$1
    _input=$2
    route_identities native "$_input" > "$WORKDIR/$_label-native.txt"
    cmp -s "$EXPECTED" "$WORKDIR/$_label-native.txt" ||
        fail "$_label native identity set is not inventory-exact"
    route_kinds native "$_input" > "$WORKDIR/$_label-native-kinds.txt"
    cmp -s "$EXPECTED_KINDS" "$WORKDIR/$_label-native-kinds.txt" ||
        fail "$_label native result-kind evidence differs from the manifest"
    verify_fixture_routes "$_label" native "$_input"
    if grep -F 'tlci-identity-route|native|shell|' "$_input" >/dev/null; then
        fail "$_label learned a catalog shell"
    fi
    # Later generated-declaration walks can interpret a source macro with the
    # same display identity after the catalog-owned primary walk has finished.
    # Exact native evidence above proves the declared catalog body ran; the
    # zero fallback counter below distinguishes those later walks from a hidden
    # shell/fallback in the catalog route itself.
    [ "$(profile_sum stdlib_tlci_catalog_misses "$_input")" -eq 0 ] ||
        fail "$_label reported an embedded catalog miss"
    [ "$(profile_sum stdlib_tlci_load_failures "$_input")" -eq 0 ] ||
        fail "$_label reported an embedded catalog load failure"
    [ "$(profile_sum stdlib_tlci_interpreted_fallbacks "$_input")" -eq 0 ] ||
        fail "$_label reported an embedded interpreted fallback"
}

verify_native_log default "$WORKDIR/default.stderr"
verify_native_log explicit "$WORKDIR/explicit.stderr"

if route_identities native "$WORKDIR/source.stderr" | grep . >/dev/null; then
    fail "modified root unexpectedly dispatched a native catalog identity"
fi
route_identities source "$WORKDIR/source.stderr" > "$WORKDIR/source-identities.txt"
comm -12 "$EXPECTED" "$WORKDIR/source-identities.txt" \
    > "$WORKDIR/source-catalog-identities.txt"
cmp -s "$EXPECTED" "$WORKDIR/source-catalog-identities.txt" ||
    fail "forced-source identity set is not inventory-exact"
route_kinds source "$WORKDIR/source.stderr" \
    > "$WORKDIR/source-all-kinds.txt"
awk 'NR == FNR { expected[$1] = 1; next } expected[$1]' \
    "$EXPECTED" "$WORKDIR/source-all-kinds.txt" \
    > "$WORKDIR/source-catalog-kinds.txt"
cmp -s "$EXPECTED_KINDS" "$WORKDIR/source-catalog-kinds.txt" ||
    fail "forced-source result-kind evidence differs from the manifest"
verify_fixture_routes source source "$WORKDIR/source.stderr"

[ "$(profile_sum stdlib_tlci_catalog_hits "$WORKDIR/source.stderr")" -eq 0 ] ||
    fail "modified root reported embedded catalog hits"
[ "$(profile_sum stdlib_tlci_native_dispatches "$WORKDIR/source.stderr")" -eq 0 ] ||
    fail "modified root reported native dispatches"
SOURCE_INTERPRETED=$(profile_sum stdlib_source_interpreted "$WORKDIR/source.stderr")
[ "$SOURCE_INTERPRETED" -ge "$IDENTITY_COUNT" ] ||
    fail "forced-source route interpreted $SOURCE_INTERPRETED stdlib macros, expected at least $IDENTITY_COUNT"

# The checked identity rows are successful semantic witnesses. Keep the
# authored-error control in this same route corpus so a native entry that
# reports an error after staging state cannot pass by merely matching the
# success assembly. Low-level malformed request/handle, abort, and fuel
# no-commit controls are exercised by the embedded verifier and comptime host
# smoke in the enclosing required compile-profile gate.
FAILURE_DIR="$WORKDIR/failures"
mkdir -p "$FAILURE_DIR"
generate_failure_source() {
    _case=$1
    _output=$2
    case "$_case" in
        unmatched-open)
            _body='(format.format "a{")'
            ;;
        too-many-arguments)
            _body='(format.format "{}" one two)'
            ;;
        *) fail "unknown failure control: $_case" ;;
    esac
    {
        echo '(import stdlib.format)'
        echo '(import stdlib.io)'
        echo '(define one : i64 1)'
        echo '(define two : i64 2)'
        echo '(define (main) : i64'
        printf '  (begin (io.print-format "{}" %s) 0))\n' "$_body"
    } > "$_output"
}

filter_diagnostic() {
    grep -v -E '^(compile-profile|compile-batch-profile|tlci-identity-route)' "$1" |
        sed '/^[[:space:]]*$/d' > "$2"
}

for failure_case in unmatched-open too-many-arguments; do
    failure_source="$FAILURE_DIR/$failure_case.tl"
    generate_failure_source "$failure_case" "$failure_source"
    set +e
    (
        cd "$ROOT"
        "$COMPILER" check "$failure_source"
    ) > "$FAILURE_DIR/$failure_case.native.stdout" \
        2> "$FAILURE_DIR/$failure_case.native.stderr"
    native_status=$?
    (
        cd "$MODIFIED_ROOT"
        "$COMPILER" check "$failure_source" --stdlib-root stdlib
    ) > "$FAILURE_DIR/$failure_case.source.stdout" \
        2> "$FAILURE_DIR/$failure_case.source.stderr"
    source_status=$?
    set -e
    [ "$native_status" -ne 0 ] && [ "$source_status" -ne 0 ] ||
        fail "$failure_case did not fail on both routes: native=$native_status source=$source_status"
    grep -F 'tlci-identity-route|native|error|stdlib.format/' \
        "$FAILURE_DIR/$failure_case.native.stderr" >/dev/null ||
        fail "$failure_case did not reach a native format error result"
    if route_identities native \
        "$FAILURE_DIR/$failure_case.source.stderr" | grep . >/dev/null; then
        fail "$failure_case source control unexpectedly dispatched natively"
    fi
    filter_diagnostic "$FAILURE_DIR/$failure_case.native.stderr" \
        "$FAILURE_DIR/$failure_case.native.diag"
    filter_diagnostic "$FAILURE_DIR/$failure_case.source.stderr" \
        "$FAILURE_DIR/$failure_case.source.diag"
    cmp -s "$FAILURE_DIR/$failure_case.native.diag" \
        "$FAILURE_DIR/$failure_case.source.diag" ||
        fail "$failure_case native/source diagnostics differ"
done

echo "tlci identity differential passed for $IDENTITY_COUNT identities across $FIXTURE_COUNT fixtures plus failure controls"
