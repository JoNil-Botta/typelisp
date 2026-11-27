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
expect_failure backend-mode-with-opt-level 'cannot combine opt-level and backend-mode for bad_combo: opt-level:1+backend-mode:scalar' \
    'bad_combo|tests/integration/good.tl|0|-|-|-|opt-level:1+backend-mode:scalar'
expect_failure backend-mode-with-stage-stdlib 'cannot combine backend-mode:scalar with stage-stdlib for bad_stage: backend-mode:scalar+stage-stdlib' \
    'bad_stage|tests/integration/good.tl|0|-|-|-|backend-mode:scalar+stage-stdlib'
expect_failure backend-mode-with-stage-stdlib-stderr 'cannot combine backend-mode:scalar with stage-stdlib for bad_stage_err: backend-mode:scalar+stage-stdlib+expected-stderr:boom' \
    'bad_stage_err|tests/integration/good.tl|0|-|-|-|backend-mode:scalar+stage-stdlib+expected-stderr:boom'
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

printf '%s\n' 'staged_stderr|tests/integration/good.tl|0|-|-|stdlib/string.tl|stage-stdlib+expected-stderr:debug\\n' > "$MANIFEST"
: > "$KNOWN"
awk -v root="$ROOT" -v catalog="$CATALOG" -v known_out="$KNOWN" \
    -f "$VALIDATOR" "$CATALOG" "$MANIFEST"
grep -Fx good "$KNOWN" >/dev/null

# Exercise scripts/lib-manifest.sh fragment concatenation, LC_ALL=C ordering,
# CRLF stripping, stray/empty rejection, and cross-fragment uniqueness checks.
. "$ROOT/scripts/lib-manifest.sh"
EXPANDER="$ROOT/scripts/expand-integration-manifest.awk"

expect_manifest_dir_failure() {
    _label=$1
    _dir=$2
    _expected=$3
    if manifest_concat_dir "$_dir" > "$WORKDIR/out.manifest" 2> "$STDERR"; then
        echo "manifest directory self-test unexpectedly passed: $_label" >&2
        exit 1
    fi
    if [ -s "$WORKDIR/out.manifest" ]; then
        echo "manifest directory self-test emitted stdout on failure: $_label" >&2
        exit 1
    fi
    if ! grep -F "$_expected" "$STDERR" >/dev/null; then
        echo "manifest directory self-test produced wrong diagnostic: $_label" >&2
        cat "$STDERR" >&2
        exit 1
    fi
}

expect_manifest_dir_failure missing-dir "$WORKDIR/does-not-exist" "manifest directory does not exist"

mkdir -p "$WORKDIR/empty.d"
expect_manifest_dir_failure empty-dir "$WORKDIR/empty.d" "manifest directory is empty"

mkdir -p "$WORKDIR/stray.d"
printf 'good|all|-|tests/integration/good.tl|0|-|-|-|-\n' > "$WORKDIR/stray.d/a.manifest"
printf 'stray\n' > "$WORKDIR/stray.d/README.txt"
expect_manifest_dir_failure stray-file "$WORKDIR/stray.d" "unexpected non-.manifest entry"

mkdir -p "$WORKDIR/nested.d/sub"
printf 'good|all|-|tests/integration/good.tl|0|-|-|-|-\n' > "$WORKDIR/nested.d/a.manifest"
printf 'good2|all|-|tests/integration/good.tl|0|-|-|-|-\n' > "$WORKDIR/nested.d/sub/b.manifest"
expect_manifest_dir_failure nested-dir "$WORKDIR/nested.d" "unexpected non-.manifest entry"

mkdir -p "$WORKDIR/dot.d"
printf 'good|all|-|tests/integration/good.tl|0|-|-|-|-\n' > "$WORKDIR/dot.d/.manifest"
expect_manifest_dir_failure dot-manifest "$WORKDIR/dot.d" "invalid manifest filename"

case "$(uname -s)" in
    Linux*)
        mkdir -p "$WORKDIR/symlink.d"
        ln -s "$WORKDIR/stray.d/a.manifest" "$WORKDIR/symlink.d/link.manifest"
        expect_manifest_dir_failure symlink-entry "$WORKDIR/symlink.d" "non-regular entry"
        ;;
esac

# Ordered concatenation, CRLF stripping, and missing trailing newline safety.
mkdir -p "$WORKDIR/ordered.d"
printf 'second|all|-|tests/integration/good.tl|0|-|-|helper.tl|-\r\n' > "$WORKDIR/ordered.d/b.manifest"
printf 'first|all|-|tests/integration/good.tl|0|-|-|-|-' > "$WORKDIR/ordered.d/a.manifest"
manifest_concat_dir "$WORKDIR/ordered.d" > "$WORKDIR/ordered.combined"
printf 'first|all|-|tests/integration/good.tl|0|-|-|-|-\nsecond|all|-|tests/integration/good.tl|0|-|-|helper.tl|-\n' > "$WORKDIR/ordered.expected"
cmp "$WORKDIR/ordered.combined" "$WORKDIR/ordered.expected"
awk -v host=linux -f "$EXPANDER" "$WORKDIR/ordered.combined" > "$WORKDIR/ordered.expanded"
: > "$KNOWN"
awk -v root="$ROOT" -v catalog="$CATALOG" -v known_out="$KNOWN" \
    -f "$VALIDATOR" "$CATALOG" "$WORKDIR/ordered.expanded"
grep -Fx good "$KNOWN" >/dev/null
grep -Fx helper "$KNOWN" >/dev/null

# Cross-fragment duplicate expanded name is rejected.
mkdir -p "$WORKDIR/dup.d"
printf 'dup|all|-,0|tests/integration/good.tl|0|-|-|-|-\n' > "$WORKDIR/dup.d/a.manifest"
printf 'dup_opt0|all|-|tests/integration/good.tl|0|-|-|-|-\n' > "$WORKDIR/dup.d/b.manifest"
manifest_concat_dir "$WORKDIR/dup.d" > "$WORKDIR/dup.combined"
if awk -v host=linux -f "$EXPANDER" "$WORKDIR/dup.combined" > /dev/null 2> "$STDERR"; then
    echo "manifest directory self-test accepted cross-fragment duplicate expanded row" >&2
    exit 1
fi
grep -F "duplicate expanded row dup_opt0" "$STDERR" >/dev/null

# Cross-fragment duplicate suite member is rejected.
mkdir -p "$WORKDIR/dup-suite.d"
printf 'suite_a|all|-|src/tests/compiler_frontend_smoke_suite.tl|42|-|-|-|-|suite-members:compiler_symbols_smoke.tl\n' > "$WORKDIR/dup-suite.d/a.manifest"
printf 'suite_b|all|-|src/tests/compiler_frontend_smoke_suite.tl|42|-|-|-|-|suite-members:compiler_symbols_smoke.tl\n' > "$WORKDIR/dup-suite.d/b.manifest"
manifest_concat_dir "$WORKDIR/dup-suite.d" > "$WORKDIR/dup-suite.combined"
awk -v host=linux -f "$EXPANDER" "$WORKDIR/dup-suite.combined" > "$WORKDIR/dup-suite.expanded"
if awk -v root="$ROOT" -v catalog="$CATALOG" -v known_out="$KNOWN" \
    -f "$VALIDATOR" "$CATALOG" "$WORKDIR/dup-suite.expanded" 2> "$STDERR"; then
    echo "manifest directory self-test accepted cross-fragment duplicate suite member" >&2
    exit 1
fi
grep -F "duplicates suite member src/tests/compiler_symbols_smoke.tl" "$STDERR" >/dev/null

echo "integration manifest validator self-tests passed"
