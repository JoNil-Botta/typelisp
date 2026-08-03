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
# prefixed stdlib.comptime variants or cannot yet accept the appended TypeInfo
# Slice variant. An empty result means the seed already accepts the short
# qualified surface and the current comptime enum ABI. Unexpected probe
# failures stay fatal; only these exact old well-known-contract diagnostics
# enable the bridge.
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

    if ! grep -qF 'expected variant ExprBool at index 0' "$stderr" && \
        ! grep -qF \
        'stdlib well-known type mismatch for stdlib.comptime.TypeInfo: unexpected extra variant' \
        "$stderr"; then
        echo "published-seed short comptime variant probe failed unexpectedly" >&2
        sed 's/^/  /' "$stdout" >&2 || true
        sed 's/^/  /' "$stderr" >&2 || true
        return 1
    fi

    bridge_root="$workdir/comptime-short-variant-seed-bridge/source"
    if grep -qF \
        'stdlib well-known type mismatch for stdlib.comptime.TypeInfo: unexpected extra variant' \
        "$stderr"; then
        COMPTIME_SHORT_VARIANT_SEED_BRIDGE_LEGACY=0 \
            "$root/scripts/prepare-comptime-short-variant-seed-bridge.sh" \
            "$bridge_root" >&2
    else
        "$root/scripts/prepare-comptime-short-variant-seed-bridge.sh" \
            "$bridge_root" >&2
    fi
    printf '%s\n' "$bridge_root"
}

# Print a temporary source mirror when the currently published compiler
# predates the dotted-import cutover and therefore cannot compile the current
# import graph: its generated name map is too small, and its reference
# classifier resolves generated nominal fields in the importer instead of the
# nominal owner's module. The seed's producer revision decides this, not a
# single pinned commit, so a moving stage0-latest built from any pre-cutover
# main is bridged just like the original pinned producer 38fab957b. A seed
# whose sources already carry the cutover fixes compiles current sources
# natively and gets no bridge.
bootstrap_seed_dotted_import_bridge_root() {
    root=$1
    compiler=$2
    workdir=$3
    producer_id=$("$compiler" --producer-identity 2>/dev/null || true)

    # Only a seed whose producer revision resolves to a commit can be
    # inspected; anything else is assumed to support current sources.
    if ! printf '%s' "$producer_id" | grep -qE '^[0-9a-f]{40}$'; then
        return 0
    fi
    if ! git -C "$root" cat-file -e "$producer_id^{commit}" 2>/dev/null; then
        git -C "$root" fetch --no-tags --depth=1 origin "$producer_id" 2>/dev/null || return 0
    fi

    # A producer whose sources carry the nominal-owner classifier fix (which
    # landed together with the generated-name capacity bump) compiles the
    # dotted-import graph natively and needs no bridge.
    if git -C "$root" grep -q "tc-context-with-nominal-owner-module-id" \
        "$producer_id" -- src/compiler_lower.tl 2>/dev/null; then
        return 0
    fi

    bridge_root="$workdir/dotted-import-seed-bridge/source"
    if ! "$root/scripts/prepare-dotted-import-seed-bridge.sh" \
        "$compiler" "$bridge_root" >&2; then
        echo "[bootstrap] failed to prepare the dotted-import seed bridge" >&2
        return 1
    fi
    printf '%s\n' "$bridge_root"
}

# A seed compiler's backend runtime is baked into the seed binary. When source
# introduces a new runtime entry point, the first generated compiler therefore
# needs a one-generation compatibility definition. Newer compilers emit the
# real small-root implementation themselves, so the shim is appended only when
# generated assembly has a reference but no definition.
bootstrap_seed_runtime_small_arena_compat() {
    assembly=$1
    if grep -q '^tl_arena_make_small:' "$assembly"; then
        return 0
    fi
    echo "[bootstrap] seed runtime lacks tl_arena_make_small; adding stage1 compatibility trampoline"
    printf '%s\n' \
        '' \
        '    .text' \
        '    .globl tl_arena_make_small' \
        'tl_arena_make_small:' \
        '    jmp tl_arena_make' >> "$assembly"
}
