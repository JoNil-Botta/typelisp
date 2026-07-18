#!/usr/bin/env sh
set -eu

# verify-asm-shape-gates.sh - opt2 assembly-shape regression gates.
#
# The native integration manifests prove the regalloc/backend campaign fixtures
# still execute correctly. These checks prove the optimizing shapes still fire:
# the slow-but-correct fallback assembly must not silently return while runtime
# exit-code tests stay green.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/asm-shape-gates"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

count_fixed() {
    _file=$1
    _snippet=$2
    grep -F "$_snippet" "$_file" 2>/dev/null | wc -l | tr -d '[:space:]'
}

count_regex() {
    _file=$1
    _regex=$2
    grep -E "$_regex" "$_file" 2>/dev/null | wc -l | tr -d '[:space:]'
}

assert_contains() {
    _file=$1
    _snippet=$2
    _label=$3
    if ! grep -F "$_snippet" "$_file" >/dev/null 2>&1; then
        fail "$_label missing snippet: $_snippet"
    fi
}

assert_not_contains() {
    _file=$1
    _snippet=$2
    _label=$3
    if grep -F "$_snippet" "$_file" >/dev/null 2>&1; then
        fail "$_label contained forbidden snippet: $_snippet"
    fi
}

assert_matches() {
    _file=$1
    _regex=$2
    _label=$3
    if ! grep -E "$_regex" "$_file" >/dev/null 2>&1; then
        fail "$_label missing regex: $_regex"
    fi
}

assert_not_matches() {
    _file=$1
    _regex=$2
    _label=$3
    if grep -E "$_regex" "$_file" >/dev/null 2>&1; then
        fail "$_label contained forbidden regex: $_regex"
    fi
}

assert_fixed_count_eq() {
    _file=$1
    _snippet=$2
    _want=$3
    _label=$4
    _got=$(count_fixed "$_file" "$_snippet")
    if [ "$_got" -ne "$_want" ]; then
        fail "$_label expected $_want occurrence(s) of '$_snippet', got $_got"
    fi
}

assert_regex_count_eq() {
    _file=$1
    _regex=$2
    _want=$3
    _label=$4
    _got=$(count_regex "$_file" "$_regex")
    if [ "$_got" -ne "$_want" ]; then
        fail "$_label expected $_want match(es) for /$_regex/, got $_got"
    fi
}

assert_regex_count_at_least() {
    _file=$1
    _regex=$2
    _want=$3
    _label=$4
    _got=$(count_regex "$_file" "$_regex")
    if [ "$_got" -lt "$_want" ]; then
        fail "$_label expected at least $_want match(es) for /$_regex/, got $_got"
    fi
}

compile_gate() {
    _name=$1
    _source=$2
    _target=${3:-linux-x86_64}
    _asm="$WORKDIR/$_name.s"
    _stdout="$WORKDIR/$_name.compile.stdout"
    _stderr="$WORKDIR/$_name.compile.stderr"
    echo "[asm-shape] compile $_name" >&2
    if ! "$COMPILER" compile "$ROOT/$_source" \
        --target "$_target" \
        --opt-level 2 \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" \
        -o "$_asm" > "$_stdout" 2> "$_stderr"; then
        echo "compile stdout:" >&2
        sed 's/^/  /' "$_stdout" >&2 || true
        echo "compile stderr:" >&2
        sed 's/^/  /' "$_stderr" >&2 || true
        fail "$_name compile failed"
    fi
    printf '%s\n' "$_asm"
}

extract_function() {
    _asm=$1
    _label=$2
    _out=$3
    if ! awk -v label="$_label:" '
        $0 == label { in_fn = 1; print; next }
        in_fn && /^\.globl[[:space:]]/ { exit 0 }
        in_fn { print }
        END { if (!in_fn) exit 2 }
    ' "$_asm" > "$_out"; then
        fail "missing function label $_label in $_asm"
    fi
}

function_body() {
    _asm=$1
    _label=$2
    _body="$WORKDIR/$(basename "$_asm" .s).$(printf '%s' "$_label" | tr -c 'A-Za-z0-9_' '_').body"
    extract_function "$_asm" "$_label" "$_body"
    printf '%s\n' "$_body"
}

check_divmagic_hoist() {
    _asm=$(compile_gate divmagic_hoist tests/integration/divmagic_hoist.tl)
    _modsum=$(function_body "$_asm" _tl_divmagic_hoist_modsum)
    _digitsum=$(function_body "$_asm" _tl_divmagic_hoist_digitsum)
    assert_not_contains "$_modsum" 'movabsq $1000000007' divmagic-modsum
    assert_regex_count_at_least "$_modsum" '^[[:space:]]+imulq \$1000000007, %r[a-z0-9]+, %r[a-z0-9]+$' 1 divmagic-modsum
    assert_fixed_count_eq "$_digitsum" 'movabsq $7378697629483820647' 1 divmagic-digitsum
    assert_not_contains "$_digitsum" 'movabsq $10' divmagic-digitsum
    assert_regex_count_at_least "$_digitsum" '^[[:space:]]+imulq \$10, %r[a-z0-9]+, %r[a-z0-9]+$' 1 divmagic-digitsum
}

check_group_pair_home() {
    _asm=$(compile_gate group_pair_home tests/integration/group_pair_home.tl)
    _body=$(function_body "$_asm" _tl_group_pair_home_probe)
    assert_contains "$_body" 'call _tl_group_pair_home_mk' group-pair-home
    assert_matches "$_body" '^[[:space:]]+movq %rax, %(r8|r9)$' group-pair-home
    assert_matches "$_body" '^[[:space:]]+movq %rdx, %(r8|r9)$' group-pair-home
    assert_not_matches "$_body" '\(%rsp\)|\(%rbp\)' group-pair-home
}

check_group_pair_phi_home() {
    _asm=$(compile_gate group_pair_phi_home tests/integration/group_pair_phi_home.tl)
    _body=$(function_body "$_asm" _tl_group_pair_phi_home_probe)
    assert_contains "$_body" 'call _tl_group_pair_phi_home_mk' group-pair-phi-home
    # The call result uses a caller-saved pair, while the loop Phi itself is
    # carried in a CSR pair across the next call. The old phi exclusion kept
    # both words in frame slots and reloaded them into rax:rdx every iteration.
    assert_matches "$_body" '^[[:space:]]+movq %rax, %(r8|r9)$' group-pair-phi-home
    assert_matches "$_body" '^[[:space:]]+movq %rdx, %(r8|r9)$' group-pair-phi-home
    assert_matches "$_body" '^[[:space:]]+movq %rax, %r(12|13|14|15|bx)$' group-pair-phi-home
    assert_matches "$_body" '^[[:space:]]+movq %rdx, %r(12|13|14|15|bx)$' group-pair-phi-home
    assert_not_matches "$_body" '^[[:space:]]+movq [0-9]+\(%rsp\), %r(ax|dx)$' group-pair-phi-home
}

check_csr_push_prologue() {
    _asm=$(compile_gate csr_push_prologue tests/integration/csr_push_prologue.tl)
    _body=$(function_body "$_asm" _tl_csr_push_prologue_churn3)
    _saved=0
    for _reg in r12 r13 r14 r15 rbx rbp; do
        _pushes=$(count_fixed "$_body" "pushq %$_reg")
        _pops=$(count_fixed "$_body" "popq %$_reg")
        if [ "$_pushes" -ne "$_pops" ] || [ "$_pushes" -gt 1 ]; then
            fail "csr-push-prologue unbalanced %$_reg save/restore: $_pushes push, $_pops pop"
        fi
        _saved=$((_saved + _pushes))
    done
    if [ "$_saved" -lt 3 ]; then
        fail "csr-push-prologue expected at least 3 pushed CSR homes, got $_saved"
    fi
    assert_regex_count_eq "$_body" '^[[:space:]]+subq \$[0-9]+, %rsp$' 1 csr-push-prologue
    assert_not_matches "$_body" '^[[:space:]]+movq %r(12|13|14|15|bx|bp), -?[0-9]+\(%rsp\)$' csr-push-prologue
}

check_save_reload_elide() {
    _asm=$(compile_gate save_reload_elide tests/integration/save_reload_elide.tl)
    _body=$(function_body "$_asm" _tl_save_reload_elide_relay)
    assert_contains "$_body" 'call _tl_save_reload_elide_src' save-reload-elide
    assert_contains "$_body" 'xorl %r8d, %r8d' save-reload-elide
    assert_contains "$_body" 'movq %rax, %r9' save-reload-elide
    assert_contains "$_body" 'call _tl_save_reload_elide_sink7' save-reload-elide
    assert_not_matches "$_body" '^[[:space:]]+movq -?[0-9]+\(%rsp\), %r9$' save-reload-elide
}

check_global_handle_cse() {
    _asm=$(compile_gate global_handle_cse tests/integration/global_handle_cse.tl)
    _body=$(function_body "$_asm" _tl_global_handle_cse_probe)
    assert_fixed_count_eq "$_body" '_tl_global_handle_cse_gtab(%rip)' 1 global-handle-cse
    assert_contains "$_body" 'call tl_oob_abort' global-handle-cse
}

check_loadcse_forward() {
    _asm=$(compile_gate loadcse_forward tests/integration/loadcse_forward.tl)
    _body=$(function_body "$_asm" _tl_loadcse_forward_poke_sum)
    assert_fixed_count_eq "$_body" 'movq 8(%rdi), %rax' 1 loadcse-forward
    assert_fixed_count_eq "$_body" 'movq (%rdi), %rdi' 1 loadcse-forward
    assert_regex_count_at_least "$_body" '^[[:space:]]+movq %r[a-z0-9]+, 16\(%rdi\)$' 1 loadcse-forward
}

check_switch_dispatch_scavenge() {
    _asm=$(compile_gate switch_dispatch_scavenge tests/integration/switch_dispatch_scavenge.tl)
    _body=$(function_body "$_asm" _tl_switch_dispatch_scavenge_run_switch)
    # Non-PIC Linux dispatches with the absolute indexed form: no table
    # register is borrowed even under the fixture's deliberate pressure.
    assert_regex_count_eq "$_body" '^[[:space:]]+jmp \*\.Lf.*_switch_table\(,%r[a-z0-9]+,8\)$' 1 switch-dispatch-scavenge
    assert_not_matches "$_body" '^[[:space:]]+jmp \*%r' switch-dispatch-scavenge
}

check_cmp_fold_load() {
    _asm=$(compile_gate cmp_fold_load tests/integration/cmp_fold_load.tl)
    _body=$(function_body "$_asm" _tl_cmp_fold_load_check)
    assert_contains "$_body" 'cmpq %rsi, 8(%rdi)' cmp-fold-load
    assert_not_matches "$_body" '^[[:space:]]+movq .*\(%r[^)]*\), %r' cmp-fold-load
    assert_not_contains "$_body" 'call tl_oob_abort' cmp-fold-load
}

check_const_index_bounds() {
    _asm=$(compile_gate const_index_bounds tests/integration/const_index_bounds.tl)
    _body=$(function_body "$_asm" _tl_const_index_bounds_get2)
    assert_contains "$_body" 'cmpq $2, %rax' const-index-bounds
    assert_not_matches "$_body" '^[[:space:]]+mov[lq][[:space:]]+\$2,' const-index-bounds
    assert_contains "$_body" 'call tl_oob_abort' const-index-bounds
}

check_rbp_sixth_csr() {
    _asm=$(compile_gate rbp_sixth_csr tests/integration/rbp_sixth_csr.tl)
    _body=$(function_body "$_asm" _tl_rbp_sixth_csr_churn6)
    assert_contains "$_body" 'pushq %rbp' rbp-sixth-csr
    assert_contains "$_body" 'popq %rbp' rbp-sixth-csr
    assert_not_matches "$_body" '\(%rbp\)' rbp-sixth-csr
}

check_win64_rbp_eighth_csr() {
    _asm=$(compile_gate \
        win64_rbp_eighth_csr \
        tests/integration/win64_rbp_eighth_csr.tl \
        windows-x86_64)
    _body=$(function_body "$_asm" _tl_win64_rbp_eighth_csr_churn8)
    assert_contains "$_body" 'pushq %rbp' win64-rbp-eighth-csr
    assert_contains "$_body" '.seh_pushreg %rbp' win64-rbp-eighth-csr
    assert_contains "$_body" '.seh_stackalloc ' win64-rbp-eighth-csr
    assert_contains "$_body" '.seh_endprologue' win64-rbp-eighth-csr
    assert_contains "$_body" 'popq %rbp' win64-rbp-eighth-csr
    assert_not_contains "$_body" '.seh_setframe' win64-rbp-eighth-csr
    assert_not_contains "$_body" 'movq %rsp, %rbp' win64-rbp-eighth-csr
    assert_not_matches "$_body" '\(%rbp\)' win64-rbp-eighth-csr
}

check_licm_desc_hoist() {
    _asm=$(compile_gate licm_desc_hoist tests/integration/licm_desc_hoist.tl)
    _body=$(function_body "$_asm" _tl_licm_desc_hoist_sum_loop)
    # The allocator may exchange the descriptor length and loop-bound homes;
    # LICM's contract is the single hoisted descriptor load, not a particular
    # physical register choice.
    assert_regex_count_eq "$_body" '^[[:space:]]+movq 8\(%rdi\), %r[a-z0-9]+$' 1 licm-desc-hoist
    assert_fixed_count_eq "$_body" 'movq (%rdi), %rdi' 1 licm-desc-hoist
    assert_contains "$_body" 'call tl_oob_abort' licm-desc-hoist
}

check_group_copy_direct() {
    _asm=$(compile_gate group_copy_direct tests/integration/group_copy_direct.tl)
    _body=$(function_body "$_asm" _tl_group_copy_direct_wrap)
    assert_contains "$_body" 'movups (%rdi), %xmm2' group-copy-direct
    assert_contains "$_body" 'movups %xmm2, 8(%rdx)' group-copy-direct
    assert_contains "$_body" 'movq 16(%rdi), %r8' group-copy-direct
    assert_contains "$_body" 'movq %r8, 24(%rdx)' group-copy-direct
    assert_not_matches "$_body" '^[[:space:]]+movq %r(di|dx), %r(9|10|11)$' group-copy-direct
}

check_dead_result_store() {
    _asm=$(compile_gate dead_result_store tests/integration/dead_result_store.tl)
    _body=$(function_body "$_asm" main)
    assert_contains "$_body" 'call _tl_dead_result_store_poke' dead-result-store
    assert_not_matches "$_body" '^[[:space:]]+movq %rax, -?[0-9]+\(%rsp\)$' dead-result-store
    assert_not_matches "$_body" '^[[:space:]]+movq %rax, -?[0-9]+\(%rbp\)$' dead-result-store
}

check_param_csr_home() {
    _asm=$(compile_gate param_csr_home tests/integration/param_csr_home.tl)
    _body=$(function_body "$_asm" _tl_param_csr_home_param_loop)
    assert_contains "$_body" 'call _tl_param_csr_home_bump' param-csr-home
    assert_matches "$_body" '^[[:space:]]+movq %rsi, %r(12|13|14|15|bx|bp)$' param-csr-home
    assert_not_matches "$_body" '\(%rsp\)|\(%rbp\)' param-csr-home
}

check_handle_arg_csr() {
    _asm=$(compile_gate handle_arg_csr tests/integration/handle_arg_csr.tl)
    _body=$(function_body "$_asm" _tl_handle_arg_csr_sum_args)
    assert_contains "$_body" 'call _tl_handle_arg_csr_probe' handle-arg-csr
    assert_matches "$_body" '^[[:space:]]+movq %rdi, %r(12|13|14|15|bx|bp)$' handle-arg-csr
    assert_not_matches "$_body" '\(%rsp\)|\(%rbp\)' handle-arg-csr
}

check_shift_pin() {
    _asm=$(compile_gate param_shift_pin tests/integration/param_shift_pin.tl)
    _body=$(function_body "$_asm" _tl_param_shift_pin_shift_mix)
    assert_contains "$_body" 'shlq $2' shift-pin
    assert_not_matches "$_body" '^[[:space:]]+pushq %r(12|13|14|15|bx|bp)$' shift-pin
    assert_not_matches "$_body" '^[[:space:]]+popq %r(12|13|14|15|bx|bp)$' shift-pin
    assert_not_matches "$_body" '\(%rsp\)|\(%rbp\)' shift-pin
}

check_param_pin_interval() {
    _asm=$(compile_gate param_pin_interval tests/integration/param_pin_interval.tl)
    _dead=$(function_body "$_asm" _tl_param_pin_interval_dead_early)
    _div=$(function_body "$_asm" _tl_param_pin_interval_div_arm)
    assert_contains "$_dead" 'call _tl_param_pin_interval_bump' param-pin-dead-early
    assert_not_matches "$_dead" '\(%rsp\)|\(%rbp\)' param-pin-dead-early
    assert_contains "$_div" 'cqto' param-pin-div-arm
    assert_contains "$_div" 'idivq' param-pin-div-arm
    assert_not_matches "$_div" '\(%rsp\)|\(%rbp\)' param-pin-div-arm
}

check_gep_value_direct() {
    _asm=$(compile_gate gep_value_direct tests/integration/gep_value_direct.tl)
    _label=$(grep -E '^_tl_.*stdlib_string_append:$' "$_asm" | sed -n '1s/:$//p')
    if [ -z "$_label" ]; then
        fail "gep-value-direct missing string.append function"
    fi
    _body=$(function_body "$_asm" "$_label")
    assert_matches "$_body" '^[[:space:]]+leaq \(%r[a-z0-9]+,%r[a-z0-9]+,1\), %rdi$' gep-value-direct
    assert_not_matches "$_body" '^[[:space:]]+addq .*%rdi$' gep-value-direct
    assert_fixed_count_eq "$_body" 'call tl_memcpy' 2 gep-value-direct
}

check_divmagic_hoist
check_group_pair_home
check_group_pair_phi_home
check_csr_push_prologue
check_save_reload_elide
check_global_handle_cse
check_loadcse_forward
check_switch_dispatch_scavenge
check_cmp_fold_load
check_const_index_bounds
check_rbp_sixth_csr
check_win64_rbp_eighth_csr
check_licm_desc_hoist
check_group_copy_direct
check_dead_result_store
check_param_csr_home
check_handle_arg_csr
check_shift_pin
check_param_pin_interval
check_gep_value_direct

echo "Assembly shape gates passed."
