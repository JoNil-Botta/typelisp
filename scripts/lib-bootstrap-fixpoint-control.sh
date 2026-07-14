#!/usr/bin/env sh

# Shared adaptive bootstrap fixpoint control flow.
#
# Callers provide STAGE2_ASM/STAGE3_ASM/STAGE3_BIN and the stage4 equivalents,
# plus a bootstrap_build_stage4 function. On success this sets
# BOOTSTRAP_COMPILER_BIN and BOOTSTRAP_COMPILER_STAGE to the newest compiler
# that participated in the proven assembly fixpoint.

bootstrap_report_stage3_stage4_mismatch() {
    echo "bootstrap fixpoint mismatch: stage3.s and stage4.s differ" >&2
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$STAGE3_ASM" "$STAGE4_ASM" >&2 || true
    fi
    wc -l "$STAGE3_ASM" "$STAGE4_ASM" >&2 || true
    if command -v diff >/dev/null 2>&1; then
        diff -u "$STAGE3_ASM" "$STAGE4_ASM" | sed -n '1,200p' >&2 || true
    else
        cmp -l "$STAGE3_ASM" "$STAGE4_ASM" | sed -n '1,80p' >&2 || true
    fi
}

bootstrap_resolve_fixpoint() {
    echo "[bootstrap] compare stage2.s and stage3.s"
    if cmp -s "$STAGE2_ASM" "$STAGE3_ASM"; then
        wc -l "$STAGE2_ASM" "$STAGE3_ASM"
        BOOTSTRAP_COMPILER_BIN=$STAGE3_BIN
        BOOTSTRAP_COMPILER_STAGE=stage3
        echo "[bootstrap] stage2.s and stage3.s are identical; skipping stage4"
        return 0
    fi

    echo "[bootstrap] stage2.s and stage3.s differ; building stage4"
    bootstrap_build_stage4

    echo "[bootstrap] compare stage3.s and stage4.s"
    if ! cmp -s "$STAGE3_ASM" "$STAGE4_ASM"; then
        bootstrap_report_stage3_stage4_mismatch
        return 1
    fi

    wc -l "$STAGE3_ASM" "$STAGE4_ASM"
    BOOTSTRAP_COMPILER_BIN=$STAGE4_BIN
    BOOTSTRAP_COMPILER_STAGE=stage4
    return 0
}
