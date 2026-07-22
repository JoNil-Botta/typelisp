#!/usr/bin/env sh

# lib-bootstrap-ctfe.sh - seed compatibility selection for CTFE macro builders.
#
# A published seed that predates CTFE `while` or the generic expression-list
# fold can still build the first compiler through bootstrap/stdlib/core_macros.tl.
# Newer seeds must use the normal iterative macros, so probe the actual
# capability instead of permanently pinning every bootstrap to the legacy path.

bootstrap_seed_ctfe_macro_builders_legacy_stdlib() {
    root=$1
    compiler=$2
    workdir=$3
    stdout="$workdir/seed-ctfe-builder-probe.stdout"
    stderr="$workdir/seed-ctfe-builder-probe.stderr"
    legacy_stdlib="$root/bootstrap/stdlib"
    probe_cwd="$workdir/seed-ctfe-builder-probe-cwd"
    mkdir -p "$probe_cwd"

    # The compiler gives a local ./stdlib precedence over --stdlib-root. Run
    # from a scratch directory so the legacy prelude actually wins.
    if (
        cd "$probe_cwd"
        "$compiler" check "$root/tests/bootstrap_ctfe_while_probe.tl" \
            --stdlib-root "$legacy_stdlib" \
            --stdlib-root "$root/stdlib" \
            --stdlib-root "$root/src"
    ) > "$stdout" 2> "$stderr"; then
        return 0
    fi

    if grep -qF "'while' is not supported in compile-time evaluation" \
        "$stdout" "$stderr"; then
        printf '%s\n' "$legacy_stdlib"
        return 0
    fi

    # A seed with CTFE locals/loops but without expr-list-fold-if reaches the
    # fallback declaration as an ordinary call. The probe contains no other
    # unsupported call, so this exact diagnostic safely selects the legacy
    # prelude for its stage0 -> stage1 transition.
    if grep -qF "'function call' is not supported in compile-time evaluation" \
        "$stdout" "$stderr"; then
        printf '%s\n' "$legacy_stdlib"
        return 0
    fi

    echo "[bootstrap] seed CTFE macro-builder capability probe failed unexpectedly" >&2
    echo "[bootstrap] stdout:" >&2
    sed 's/^/  /' "$stdout" >&2 || true
    echo "[bootstrap] stderr:" >&2
    sed 's/^/  /' "$stderr" >&2 || true
    return 1
}

# Print a temporary source-mirror path when the published seed still pins the
# prefixed stdlib.comptime variants.  An empty result means the seed already
# accepts the short qualified surface.  Unexpected probe failures stay fatal;
# only the exact old well-known-contract diagnostic enables the bridge.
bootstrap_seed_comptime_short_variant_bridge_root() {
    root=$1
    compiler=$2
    workdir=$3
    stdout="$workdir/seed-comptime-short-variant-probe.stdout"
    stderr="$workdir/seed-comptime-short-variant-probe.stderr"
    probe_cwd="$workdir/seed-comptime-short-variant-probe-cwd"
    mkdir -p "$probe_cwd"

    if (
        cd "$probe_cwd"
        "$compiler" check "$root/tests/bootstrap_comptime_short_variants_probe.tl" \
            --stdlib-root "$root/stdlib" \
            --stdlib-root "$root/src"
    ) > "$stdout" 2> "$stderr"; then
        return 0
    fi

    if ! grep -qF \
        'expected variant ExprBool at index 0' \
        "$stderr"; then
        echo "published-seed short comptime variant probe failed unexpectedly" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        sed 's/^/  /' "$stderr" >&2 || true
        return 1
    fi

    bridge_root="$workdir/comptime-short-variant-seed-bridge/source"
    "$root/scripts/prepare-comptime-short-variant-seed-bridge.sh" \
        "$bridge_root" >&2
    printf '%s\n' "$bridge_root"
}
