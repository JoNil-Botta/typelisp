#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORKDIR="$ROOT/target/integration-manifest-validator-self-test"
CATALOG="$WORKDIR/catalog.txt"
MANIFEST="$WORKDIR/manifest.txt"
KNOWN="$WORKDIR/known.txt"
STDERR="$WORKDIR/stderr.txt"
VALIDATOR="$ROOT/scripts/validate-integration-manifest.awk"

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cat > "$CATALOG" <<'EOF'
tests/integration/good.tl
tests/integration/helper.tl
tests/integration/nested/provider.tl
src/tests/compiler_frontend_smoke_suite.tl
src/tests/compiler_codegen_smoke_suite.tl
src/tests/compiler_symbols_smoke.tl
src/tests/compiler_typecheck_reverse_mixed_smoke.tl
stdlib/string.tl
EOF

expect_failure() {
    _label=$1
    _expected=$2
    shift 2
    printf '%s\n' "$@" > "$MANIFEST"
    : > "$KNOWN"
    if awk -v root="$ROOT" -v catalog="$CATALOG" -v known_out="$KNOWN" \
        -f "$VALIDATOR" "$CATALOG" "$MANIFEST" 2> "$STDERR"; then
        echo "manifest validator self-test unexpectedly passed: $_label" >&2
        exit 1
    fi
    if ! grep -F "$_expected" "$STDERR" >/dev/null; then
        echo "manifest validator self-test produced the wrong diagnostic: $_label" >&2
        cat "$STDERR" >&2
        exit 1
    fi
}

printf '%s\n' 'good|tests/integration/good.tl|0|-|-|helper.tl' > "$MANIFEST"
: > "$KNOWN"
awk -v root="$ROOT" -v catalog="$CATALOG" -v known_out="$KNOWN" \
    -f "$VALIDATOR" "$CATALOG" "$MANIFEST"
grep -Fx good "$KNOWN" >/dev/null
grep -Fx helper "$KNOWN" >/dev/null

printf '%s\n' 'nested|tests/integration/good.tl|0|-|-|nested/provider.tl' > "$MANIFEST"
: > "$KNOWN"
awk -v root="$ROOT" -v catalog="$CATALOG" -v known_out="$KNOWN" \
    -f "$VALIDATOR" "$CATALOG" "$MANIFEST"
grep -Fx good "$KNOWN" >/dev/null
grep -Fx nested/provider "$KNOWN" >/dev/null

expect_failure field-count 'manifest line 1 must have 6 fields' \
    'bad|tests/integration/good.tl|0|-|-'
expect_failure bad-case-name 'invalid case name: bad-name' \
    'bad-name|tests/integration/good.tl|0|-|-|-'
expect_failure bad-source-name 'invalid source path for bad_source: tests/integration/good.txt' \
    'bad_source|tests/integration/good.txt|0|-|-|-'
expect_failure missing-dependency 'names missing dependency for missing_dep: absent.tl' \
    'missing_dep|tests/integration/good.tl|0|-|-|absent.tl'
expect_failure duplicate 'manifest line 2 duplicates integration case duplicate' \
    'duplicate|tests/integration/good.tl|0|-|-|-' \
    'duplicate|tests/integration/good.tl|0|-|-|-'
expect_failure unsafe-source 'unsafe source path for unsafe_source: ../good.tl' \
    'unsafe_source|../good.tl|0|-|-|-'
expect_failure unsafe-dependency 'unsafe dependency path for unsafe_dep: ../helper.tl' \
    'unsafe_dep|tests/integration/good.tl|0|-|-|../helper.tl'
expect_failure invalid-extra 'invalid extra field for bad_extra: stage-everything' \
    'bad_extra|tests/integration/good.tl|0|-|-|-|stage-everything'
expect_failure missing-suite-member 'names missing suite member for bad_suite: absent_smoke.tl' \
    'bad_suite|src/tests/compiler_frontend_smoke_suite.tl|42|-|-|-||suite-members:absent_smoke.tl'
expect_failure suite-member-without-main 'suite member has no main for bad_suite: src/tests/compiler_typecheck_reverse_mixed_smoke.tl' \
    'bad_suite|src/tests/compiler_frontend_smoke_suite.tl|42|-|-|-||suite-members:compiler_typecheck_reverse_mixed_smoke.tl'
expect_failure suite-source-omits-member 'suite source does not name member for bad_suite: src/tests/compiler_symbols_smoke.tl' \
    'bad_suite|src/tests/compiler_codegen_smoke_suite.tl|42|-|-|-||suite-members:compiler_symbols_smoke.tl'
expect_failure duplicate-suite-member 'manifest line 2 duplicates suite member src/tests/compiler_symbols_smoke.tl' \
    'suite_one|src/tests/compiler_frontend_smoke_suite.tl|42|-|-|-||suite-members:compiler_symbols_smoke.tl' \
    'suite_two|src/tests/compiler_frontend_smoke_suite.tl|42|-|-|-||suite-members:compiler_symbols_smoke.tl'
expect_failure suite-member-is-source 'suite member is also a manifest source: src/tests/compiler_symbols_smoke.tl' \
    'suite|src/tests/compiler_frontend_smoke_suite.tl|42|-|-|-||suite-members:compiler_symbols_smoke.tl' \
    'standalone|src/tests/compiler_symbols_smoke.tl|42|-|-|-'

printf '%s\n' 'suite|src/tests/compiler_frontend_smoke_suite.tl|42|-|-|-|stage-stdlib|suite-members:compiler_symbols_smoke.tl' > "$MANIFEST"
: > "$KNOWN"
awk -v root="$ROOT" -v catalog="$CATALOG" -v known_out="$KNOWN" \
    -f "$VALIDATOR" "$CATALOG" "$MANIFEST"

printf '%s\n' 'staged|tests/integration/good.tl|0|-|-|stdlib/string.tl|stage-stdlib' > "$MANIFEST"
: > "$KNOWN"
awk -v root="$ROOT" -v catalog="$CATALOG" -v known_out="$KNOWN" \
    -f "$VALIDATOR" "$CATALOG" "$MANIFEST"
grep -Fx good "$KNOWN" >/dev/null

echo "integration manifest validator self-tests passed"
