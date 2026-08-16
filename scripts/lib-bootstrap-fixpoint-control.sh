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

# Require one exact route record for the selected same-commit TLCI mutation
# witness. Reject duplicate or contradictory records so a broad aggregate
# counter cannot make the handoff check pass accidentally.
bootstrap_tlci_require_route() {
    _btr_file=$1
    _btr_identity=$2
    _btr_route=$3
    _btr_result=$4
    _btr_prefix="tlci-bootstrap-mutation-route|identity=$_btr_identity|"
    _btr_expected="${_btr_prefix}route=$_btr_route|result=$_btr_result"
    _btr_count=$(grep -Fxc "$_btr_expected" "$_btr_file" 2>/dev/null || true)
    _btr_total=$(grep -Fc "$_btr_prefix" "$_btr_file" 2>/dev/null || true)
    if [ "$_btr_count" -ne 1 ] || [ "$_btr_total" -ne 1 ]; then
        echo "bootstrap tlci mutation route mismatch in $_btr_file" >&2
        echo "  expected exactly: $_btr_expected" >&2
        grep -F "$_btr_prefix" "$_btr_file" | sed 's/^/  observed: /' >&2 || true
        return 1
    fi
}

bootstrap_tlci_require_same_artifact() {
    _bta_left=$1
    _bta_right=$2
    _bta_label=$3
    if ! cmp -s "$_bta_left" "$_bta_right"; then
        echo "bootstrap tlci mutation $_bta_label did not converge" >&2
        return 1
    fi
}

bootstrap_tlci_require_identity() {
    _bti_actual=$1
    _bti_expected=$2
    _bti_label=$3
    if [ "$_bti_actual" != "$_bti_expected" ]; then
        echo "bootstrap tlci mutation $_bti_label identity mismatch:" \
            "expected $_bti_expected, got $_bti_actual" >&2
        return 1
    fi
}
