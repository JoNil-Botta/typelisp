# Deterministic x86 assembly census for one already-extracted function body.
# Output columns are consumed by scripts/measure-ispc-spmd.sh.

function remember_register(reg, lower) {
    lower = tolower(reg)
    all_registers[lower] = 1
    if (lower ~ /^%(r(ax|bx|cx|dx|si|di|sp|bp)|r(8|9|1[0-5])|e(ax|bx|cx|dx|si|di|sp|bp)|r(8|9|1[0-5])d)$/)
        gpr_registers[lower] = 1
    else if (lower ~ /^%[xyz]mm[0-9]+$/)
        vector_registers[lower] = 1
    else if (lower ~ /^%k[0-7]$/)
        mask_registers[lower] = 1
}

function count_set(values, key, count) {
    count = 0
    for (key in values) count++
    return count
}

{
    line = $0
    rest = line
    while (match(rest, /%[A-Za-z][A-Za-z0-9]*/)) {
        remember_register(substr(rest, RSTART, RLENGTH))
        rest = substr(rest, RSTART + RLENGTH)
    }

    if (line !~ /^[[:space:]]+[A-Za-z][A-Za-z0-9.]*/) next
    instruction_count++
    mnemonic = line
    sub(/^[[:space:]]+/, "", mnemonic)
    sub(/[[:space:]].*$/, "", mnemonic)
    mnemonic = tolower(mnemonic)

    if (mnemonic ~ /^j[a-z0-9]*$/) branch_count++
    if (mnemonic ~ /^call/) call_count++
    if (mnemonic ~ /gather/) gather_count++
    if (mnemonic ~ /scatter/) scatter_count++
    if (line ~ /%xmm[0-9]+/) xmm_instruction_count++
    if (line ~ /%ymm[0-9]+/) ymm_instruction_count++
    if (line ~ /%zmm[0-9]+/) zmm_instruction_count++
    if (line ~ /\(%(rsp|rbp)\)/) {
        stack_access_count++
        if (mnemonic ~ /^(v?mov|push|pop)/) spill_candidate_count++
    }
}

END {
    printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
        instruction_count + 0, branch_count + 0, call_count + 0, \
        spill_candidate_count + 0, count_set(gpr_registers), \
        count_set(vector_registers), count_set(mask_registers), \
        xmm_instruction_count + 0, ymm_instruction_count + 0, \
        zmm_instruction_count + 0, gather_count + 0, scatter_count + 0, \
        stack_access_count + 0
}
