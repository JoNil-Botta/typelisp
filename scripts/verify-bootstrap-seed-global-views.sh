#!/usr/bin/env sh
set -eu

# verify-bootstrap-seed-global-views.sh - self-tests for the seed global
# shared-view capability probe in lib-bootstrap-ctfe.sh.
#
# The probe decides whether the published seed still needs the legacy
# `stage0-seed-bootstrap` shared-view spelling. That decision is not a local
# detail: handing the cfg to a seed that already enforces the
# move-out-of-global rule makes the seed reject the legacy direct read the cfg
# selects, which broke every stage0 publication run while per-PR CI stayed
# green, because only the publication flow passed the cfg unconditionally
# (#6385). Production takes whichever single branch the current seed selects,
# so a real bootstrap can never cover the other two. Stub compilers drive all
# three here: this gate needs no compiler, no toolchain, and no network.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-bootstrap-ctfe.sh"

if [ "$#" -ne 0 ]; then
    echo "usage: scripts/verify-bootstrap-seed-global-views.sh" >&2
    exit 2
fi

WORKDIR="$ROOT/target/bootstrap-seed-global-views-self-test"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

STDOUT="$WORKDIR/helper.stdout"
STDERR="$WORKDIR/helper.stderr"

fail() {
    echo "seed global shared-view self-test: $*" >&2
    sed 's/^/  stdout| /' "$STDOUT" >&2 || true
    sed 's/^/  stderr| /' "$STDERR" >&2 || true
    exit 1
}

assert_contains() {
    _file=$1
    _needle=$2
    grep -F "$_needle" "$_file" > /dev/null ||
        fail "expected '$_needle' in $_file"
}

# A stub answers `check` the way one seed generation would, and records its own
# argv beside itself so the probe's CLI contract is covered too, not only the
# branch the stub selects.
write_stub() {
    _stub=$1
    _out_text=$2
    _err_text=$3
    _status=$4
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'printf "%s\n" "$*" > "$0.argv"'
        [ -z "$_out_text" ] || printf "%s\n" "echo '$_out_text'"
        [ -z "$_err_text" ] || printf "%s\n" "echo '$_err_text' >&2"
        printf 'exit %s\n' "$_status"
    } > "$_stub"
    chmod +x "$_stub"
}

# A seed that accepts the real unsafe view must not be handed the legacy cfg.
MODERN_DIR="$WORKDIR/modern"
MODERN_STUB="$WORKDIR/modern-seed"
mkdir -p "$MODERN_DIR"
write_stub "$MODERN_STUB" "" "" 0
SEED_REQUIRES_LEGACY_GLOBAL_VIEWS=unset
bootstrap_resolve_seed_global_views "$MODERN_STUB" "$MODERN_DIR" \
    > "$STDOUT" 2> "$STDERR" ||
    fail "a seed that accepts explicit global shared views was rejected"
[ "$SEED_REQUIRES_LEGACY_GLOBAL_VIEWS" = 0 ] ||
    fail "a modern seed still asked for the legacy cfg: '$SEED_REQUIRES_LEGACY_GLOBAL_VIEWS'"
assert_contains "$STDOUT" "seed supports explicit global shared views"
if [ -s "$STDERR" ]; then
    fail "the success path wrote diagnostics"
fi

# The probe must ask about the modern spelling; a probe that lost its
# ptr-addr-of would report every seed as modern.
PROBE_SOURCE="$MODERN_DIR/seed-global-view-probe.tl"
[ -f "$PROBE_SOURCE" ] || fail "the probe wrote no source file"
assert_contains "$PROBE_SOURCE" "(ptr-read (ptr-addr-of seed-global-view-probe))"
assert_contains "$MODERN_STUB.argv" "check $PROBE_SOURCE"

# A pre-cutover seed reports the well-known diagnostic and keeps the cfg.
LEGACY_DIR="$WORKDIR/legacy"
LEGACY_STUB="$WORKDIR/legacy-seed"
mkdir -p "$LEGACY_DIR"
write_stub "$LEGACY_STUB" "" \
    "error: ptr-addr-of requires a local or parameter name" 1
SEED_REQUIRES_LEGACY_GLOBAL_VIEWS=unset
bootstrap_resolve_seed_global_views "$LEGACY_STUB" "$LEGACY_DIR" \
    > "$STDOUT" 2> "$STDERR" ||
    fail "the well-known legacy diagnostic was treated as a probe failure"
[ "$SEED_REQUIRES_LEGACY_GLOBAL_VIEWS" = 1 ] ||
    fail "a legacy seed did not ask for the cfg: '$SEED_REQUIRES_LEGACY_GLOBAL_VIEWS'"
assert_contains "$STDOUT" "seed requires legacy global shared views"

# Any other failure is fail-closed. Guessing a capability here is what shipped
# a broken publication flow, so the helper must abort and print both captured
# streams for the operator.
UNRELATED_DIR="$WORKDIR/unrelated"
UNRELATED_STUB="$WORKDIR/unrelated-seed"
mkdir -p "$UNRELATED_DIR"
write_stub "$UNRELATED_STUB" \
    "probe stdout noise" \
    "error[E0200]: typecheck: cannot move out of global seed-global-view-probe" 1
SEED_REQUIRES_LEGACY_GLOBAL_VIEWS=unset
set +e
bootstrap_resolve_seed_global_views "$UNRELATED_STUB" "$UNRELATED_DIR" \
    > "$STDOUT" 2> "$STDERR"
status=$?
set -e
[ "$status" -ne 0 ] ||
    fail "an unrelated probe failure was accepted as a capability answer"
assert_contains "$STDERR" "global shared-view capability probe failed unexpectedly"
assert_contains "$STDERR" "  probe stdout noise"
assert_contains "$STDERR" "  error[E0200]: typecheck: cannot move out of global"

echo "bootstrap seed global shared-view probe self-tests passed"
