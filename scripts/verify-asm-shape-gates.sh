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

# Assert the line immediately after the FIRST match of `_regex` matches
# `_next`. Pins an instruction together with the branch that reads its flags:
# a bit test carrying the WRONG jump sense is still a valid-looking `testq`,
# assembles, and only shows up as inverted program behaviour.
assert_next_line_matches() {
    _file=$1
    _regex=$2
    _next=$3
    _label=$4
    if ! awk -v pat="$_regex" -v nxt="$_next" '
        found { exit ($0 ~ nxt) ? 0 : 1 }
        $0 ~ pat { found = 1 }
        END { if (!found) exit 2 }
    ' "$_file"; then
        fail "$_label expected /$_next/ on the line after /$_regex/"
    fi
}

# Count `jmp L` lines whose target `L:` is reached by scanning forward across
# nothing but label-definition lines -- exactly the shape the assembled-body
# peephole deletes, because execution falls through zero emitted bytes to the
# same label. Mirrors compiler-backend-drop-fallthrough-jumps: any other
# intervening line (instruction, directive, comment, blank) breaks the run, and
# a target never seen forward is a backward jump that must survive.
count_fallthrough_jmp() {
    awk '
        {
            if (pending) {
                if ($0 ~ /^[^[:blank:]:]+:$/) {
                    if (substr($0, 1, length($0) - 1) == target) {
                        n++
                        pending = 0
                    }
                    next
                }
                pending = 0
            }
            if ($0 ~ /^    jmp [^[:blank:]*%(,]+$/) {
                pending = 1
                target = substr($0, 9)
            }
        }
        END { print n + 0 }
    ' "$1"
}

# Count direct branch lines whose target label was already defined earlier.
# Tail-recursion lowering can leave a direct `jmp` or, after SSA construction
# and loop rotation, fold the back edge into a conditional branch. The focused
# backend peephole self-test separately pins that a literal backward `jmp` is
# retained; this end-to-end gate pins the compiler-generated backward control
# transfer without depending on which earlier optimizer pass spells it.
count_backward_branch() {
    awk '
        /^[^[:blank:]:]+:$/ { seen[substr($0, 1, length($0) - 1)] = 1; next }
        /^    j[a-z]+ [^[:blank:]*%(,]+$/ { if ($2 in seen) n++ }
        END { print n + 0 }
    ' "$1"
}

# Count compares that read back a frame slot an earlier line in the SAME basic
# block wrote from a register -- `movq %rV, N(%rsp)` ... `cmpq N(%rsp), %rX`.
# That is the exact give-away of a fused load the M6 family failed to claim:
# the value was materialised into a scratch, stored to its home, and then read
# straight back as the compare's memory operand, when the compare could have
# addressed the element itself. Slots are cleared at every label so only a
# straight-line write/read pair counts.
count_store_then_cmp_same_slot() {
    awk '
        /^[^[:blank:]:]+:$/ { delete stored; next }
        /^    movq %[a-z0-9]+, -?[0-9]+\(%rsp\)$/ { stored[$3] = 1; next }
        /^    cmpq -?[0-9]+\(%rsp\), %[a-z0-9]+$/ {
            slot = $2
            sub(/,$/, "", slot)
            if (slot in stored) n++
            next
        }
        END { print n + 0 }
    ' "$1"
}

assert_store_then_cmp_same_slot_eq() {
    _file=$1
    _want=$2
    _label=$3
    _got=$(count_store_then_cmp_same_slot "$_file")
    if [ "$_got" -ne "$_want" ]; then
        fail "$_label expected $_want store-then-compare-the-same-slot pair(s), got $_got"
    fi
}

# Count adjacent GP copy chains `movq SRC, TMP; movq TMP, %rax`. Constant
# quotient lowering must not route a live dividend through its own destination
# before seeding fixed %rax. A remainder still needs one mutable SRC copy, so
# callers assert the exact irreducible count rather than requiring zero.
count_adjacent_copy_chains_to_rax() {
    awk '
        {
            if ($0 ~ /^    movq %[a-z0-9]+, %[a-z0-9]+$/) {
                source = $2
                sub(/,$/, "", source)
                if (previous && source == previous_dst && $3 == "%rax") n++
                previous = 1
                previous_dst = $3
            } else {
                previous = 0
                previous_dst = ""
            }
        }
        END { print n + 0 }
    ' "$1"
}

assert_adjacent_copy_chains_to_rax_eq() {
    _file=$1
    _want=$2
    _label=$3
    _got=$(count_adjacent_copy_chains_to_rax "$_file")
    if [ "$_got" -ne "$_want" ]; then
        fail "$_label expected $_want adjacent dividend copy chain(s) into %rax, got $_got"
    fi
}

assert_no_fallthrough_jmp() {
    _file=$1
    _label=$2
    _got=$(count_fallthrough_jmp "$_file")
    if [ "$_got" -ne 0 ]; then
        fail "$_label kept $_got jmp(s) whose target is reached by falling through label definitions only"
    fi
}

# Count branch lines whose target label names a block that emits nothing but a
# single `jmp` -- the shape backend jump forwarding retires. A block's body is
# read across any run of adjacent label definitions (an emptied merge shares its
# successor's code), and a lone `jmp` back to the block's own label is a
# self-loop, which forwarding must refuse and which therefore does not count.
count_jump_into_jump_only_block() {
    awk '
        { line[NR] = $0 }
        /^[^[:blank:]:]+:$/ { at[substr($0, 1, length($0) - 1)] = NR }
        END {
            for (l in at) {
                i = at[l] + 1
                while (i <= NR && line[i] ~ /^[^[:blank:]:]+:$/) i++
                if (i > NR || line[i] !~ /^    jmp [^[:blank:]*%(,]+$/) continue
                target = substr(line[i], 9)
                if (target == l) continue
                j = i + 1
                if (j > NR || line[j] ~ /^[^[:blank:]:]+:$/ || line[j] ~ /^[[:space:]]*\./)
                    solo[l] = 1
            }
            for (k = 1; k <= NR; k++)
                if (line[k] ~ /^    j[a-z]+ [^[:blank:]*%(,]+$/) {
                    t = line[k]
                    sub(/^    j[a-z]+ /, "", t)
                    if (t in solo) n++
                }
            print n + 0
        }
    ' "$1"
}

assert_no_jump_into_jump_only_block() {
    _file=$1
    _label=$2
    _got=$(count_jump_into_jump_only_block "$_file")
    if [ "$_got" -ne 0 ]; then
        fail "$_label kept $_got branch(es) into a block that emits nothing but one jmp"
    fi
}

# Count `jmp L` whose only preceding lines back to `L:` are label definitions --
# an empty infinite loop, whose header and body labels collapse onto the same
# address. Jump forwarding must refuse these: every block in the run hands its
# jumps to another block in the same run, so there is no exit to name.
count_self_loop_jmp() {
    awk '
        /^[^[:blank:]:]+:$/ {
            run[++depth] = substr($0, 1, length($0) - 1)
            next
        }
        /^    jmp [^[:blank:]*%(,]+$/ {
            target = substr($0, 9)
            for (i = 1; i <= depth; i++)
                if (run[i] == target) { n++; break }
        }
        { depth = 0 }
        END { print n + 0 }
    ' "$1"
}

assert_self_loop_jmp_at_least() {
    _file=$1
    _want=$2
    _label=$3
    _got=$(count_self_loop_jmp "$_file")
    if [ "$_got" -lt "$_want" ]; then
        fail "$_label expected at least $_want self-loop jmp(s), got $_got"
    fi
}

assert_backward_branch_at_least() {
    _file=$1
    _want=$2
    _label=$3
    _got=$(count_backward_branch "$_file")
    if [ "$_got" -lt "$_want" ]; then
        fail "$_label expected at least $_want surviving backward branch(es), got $_got"
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
    # A body ends at the next `.globl` -- or at its own `.size`, which is what
    # bounds the LAST emitted function: nothing follows it but the hand-written
    # runtime prelude, which carries no `.globl` and would otherwise be read as
    # part of that body.
    if ! awk -v label="$_label:" '
        $0 == label { in_fn = 1; print; next }
        in_fn && /^\.globl[[:space:]]/ { exit 0 }
        in_fn && /^[[:space:]]*\.size[[:space:]]/ { exit 0 }
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
    _copy_pair=$(function_body "$_asm" _tl_divmagic_hoist_dividend_copy_pair)
    assert_not_contains "$_modsum" 'movabsq $1000000007' divmagic-modsum
    assert_regex_count_at_least "$_modsum" '^[[:space:]]+imulq \$1000000007, %r[a-z0-9]+, %r[a-z0-9]+$' 1 divmagic-modsum
    assert_fixed_count_eq "$_digitsum" 'movabsq $7378697629483820647' 1 divmagic-digitsum
    assert_not_contains "$_digitsum" 'movabsq $10' divmagic-digitsum
    assert_regex_count_at_least "$_digitsum" '^[[:space:]]+imulq \$10, %r[a-z0-9]+, %r[a-z0-9]+$' 1 divmagic-digitsum
    # The `/7` quotient consumes the live dividend directly through %rax. The
    # one surviving adjacent chain belongs to `%10`: its mutable SRC is the
    # remainder result and must preserve the dividend across one-operand imul.
    # Before #5615 both expansions produced a chain, so this exact count was 2.
    assert_adjacent_copy_chains_to_rax_eq \
        "$_copy_pair" 1 divmagic-dividend-copy-pair
}

check_hoist_priority() {
    _asm=$(compile_gate hoist_priority tests/integration/hoist_priority.tl)
    _spread=$(function_body "$_asm" _tl_hoist_priority_spread)
    _tie=$(function_body "$_asm" _tl_hoist_priority_tie)
    # `spread`: six one-site wide literals precede a three-site divmod magic in
    # program order, and the region cannot hold every constant. Awarding by
    # site count gives the magic a register, so its 64-bit load happens once in
    # the preheader instead of at all three sites. Awarding by program order --
    # the pre-A36 rule -- leaves three of these.
    assert_fixed_count_eq "$_spread" 'movabsq $-8543223828751151131' 1 hoist-priority-spread
    # The divisor still folds into the imm32 multiply at every site, so the
    # win is the magic load and not a changed divmod expansion.
    assert_regex_count_at_least "$_spread" \
        '^[[:space:]]+imulq \$1000000007, %r[a-z0-9]+, %r[a-z0-9]+$' 3 hoist-priority-spread
    # At least one wide literal must lose its register to the magic: the
    # in-place `movq $imm` spelling is the non-hoisted form.
    assert_regex_count_at_least "$_spread" '^[[:space:]]+movq \$26544357[0-9]+, %r' 1 hoist-priority-spread
    # `tie`: every key has two sites, so the counts are equal and the award
    # order falls back to program order. The first literal is hoisted (one
    # preheader `movabsq`), and the magic -- written last -- keeps both of its
    # in-place materialisations. A reversed or unstable tie-break would promote
    # the magic here and drop that count to one.
    assert_fixed_count_eq "$_tie" 'movabsq $3141592653589' 1 hoist-priority-tie
    assert_fixed_count_eq "$_tie" 'movabsq $-8543223828751151131' 2 hoist-priority-tie
}

check_lftr_counter_retire() {
    _asm=$(compile_gate lftr_counter_retire tests/integration/lftr_counter_retire.tl)
    # `walk` is a one-reference, call-free, loop-bearing leaf whose only site
    # sits in a loop-free `main`, which is the hot-loop-leaf band's loop-free
    # tier -- so since that band's reference clause was widened to one reference
    # the body is absorbed and `walk` has no label of its own. Read the loop
    # where it now lives. Every shape assertion below is unchanged and still
    # holds: `build-program` remains behind a call, so the length is still a
    # runtime descriptor load and the end address is still materialised by
    # scaling it. Pin the absorption too, so this stays honest if it reverses.
    assert_not_contains "$_asm" '_tl_lftr_counter_retire_walk:' lftr-counter-retire-absorbed
    _body=$(function_body "$_asm" main)
    # LFTR: induction turns `(array-ref prog i)` into a 16-byte-stride pointer
    # phi, after which `i` only feeds its own increment and the exit test. The
    # accumulator folds by register add/imul, so an `add $1` in this body could
    # only be that retired index. The exit test moves onto the pointer, which
    # keeps exactly one bump per iteration.
    assert_not_matches "$_body" '^[[:space:]]+addq \$1, %r[a-z0-9]+$' lftr-counter-retire
    assert_regex_count_eq "$_body" '^[[:space:]]+leaq 16\(%r[a-z0-9]+\), %r[a-z0-9]+$' 1 lftr-counter-retire
    assert_regex_count_eq "$_body" '^[[:space:]]+cmpq %r[a-z0-9]+, %r[a-z0-9]+$' 1 lftr-counter-retire
    # The end address is materialised once in the preheader by scaling the
    # length by the element stride (shift or imul, allocator's choice).
    assert_matches "$_body" '^[[:space:]]+(shlq \$4, %r[a-z0-9]+|imulq \$16, %r[a-z0-9]+, %r[a-z0-9]+)$' lftr-counter-retire
    # Retirement requires the counter to carry no bounds check: the loop must
    # reach LFTR already check-free, not versioned around one.
    assert_not_contains "$_body" 'call tl_oob_abort' lftr-counter-retire
}

check_fallthrough_jmp_chain() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "fallthrough_jmp_chain_$_suffix" \
            tests/integration/fallthrough_jmp_chain.tl "$_target")

        _drop=$(function_body "$_asm" _tl_fallthrough_jmp_chain_chain_drop_probe)
        _keep=$(function_body "$_asm" _tl_fallthrough_jmp_chain_chain_keep_probe)
        _main=$(function_body "$_asm" main)
        # The core property, over every compiled body this fixture emits: no
        # `jmp` may target a label execution would reach anyway by falling
        # through nothing but label definitions. Scoped to compiled bodies
        # because the hand-written runtime prelude assembly is emitted as literal
        # text and never passes through the per-function peephole.
        for _body in "$_drop" "$_keep" "$_main"; do
            assert_no_fallthrough_jmp "$_body" "fallthrough-jmp-chain-$_target"
        done

        # The then-only conditional is still three real blocks -- the loop was
        # not optimized away -- but the then arm's jump to the merge label is
        # gone, because only the empty else block's label separated them.
        assert_matches "$_drop" '^\.L[^ ]*_if_then\.[0-9.]+:$' "fallthrough-jmp-chain-drop-$_target"
        assert_matches "$_drop" '^\.L[^ ]*_if_else\.[0-9.]+:$' "fallthrough-jmp-chain-drop-$_target"
        assert_matches "$_drop" '^\.L[^ ]*_if_merge\.[0-9.]+:$' "fallthrough-jmp-chain-drop-$_target"
        assert_regex_count_eq "$_drop" \
            '^[[:space:]]+jmp \.L[^ ]*_if_merge\.[0-9.]+$' 0 \
            "fallthrough-jmp-chain-drop-$_target"
        # The self-recursive tail call in the same body remains a backward
        # control transfer. Tailrec + SSA may spell it as a conditional loop
        # branch instead of the backend's original direct jump.
        assert_backward_branch_at_least "$_drop" 1 "fallthrough-jmp-chain-drop-$_target"

        # Both arms carry work here, so the then arm's jump to the merge label
        # crosses the else arm's real instructions and must survive.
        assert_regex_count_eq "$_keep" \
            '^[[:space:]]+jmp \.L[^ ]*_if_merge\.[0-9.]+$' 1 \
            "fallthrough-jmp-chain-keep-$_target"
        assert_backward_branch_at_least "$_keep" 1 "fallthrough-jmp-chain-keep-$_target"
    done
}

check_wide_const_hoist() {
    _asm=$(compile_gate wide_const_hoist tests/integration/wide_const_hoist.tl)
    _leaf=$(function_body "$_asm" _tl_wide_const_hoist_wide_leaf)
    _call=$(function_body "$_asm" _tl_wide_const_hoist_wide_call)
    assert_fixed_count_eq "$_leaf" 'movabsq $2654435761' 1 wide-const-leaf
    assert_regex_count_at_least "$_leaf" '^[[:space:]]+(imulq|xorq) %r[a-z0-9]+, %r[a-z0-9]+$' 2 wide-const-leaf
    assert_fixed_count_eq "$_call" 'movq $2654435761' 2 wide-const-call-fallback
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
    # The call result lands directly in the loop Phi's register pair, and the
    # loop body reads both words back out of it. The old phi exclusion kept both
    # words in frame slots and reloaded them into rax:rdx every iteration.
    assert_matches "$_body" '^[[:space:]]+movq %rax, %(r8|r9)$' group-pair-phi-home
    assert_matches "$_body" '^[[:space:]]+movq %rdx, %(r8|r9)$' group-pair-phi-home
    assert_regex_count_at_least "$_body" '^[[:space:]]+movq %(r8|r9), %rax$' 2 group-pair-phi-home
    # The pair used to be copied on into a CALLEE-SAVED pair after every call,
    # because its coarse interval hull spans the loop's own `call mk` even
    # though the value is dead there: the phi is read at the top of the body and
    # REDEFINED by that call at the bottom, so no iteration carries it across
    # one. The segment-precise clobber-span test
    # (compiler-reg-greedy-var-spans-clobber?) sees the hole and leaves the pair
    # in its caller-saved home, retiring two prologue pushes, two epilogue pops
    # and four copies per iteration. The checksum fixture
    # (tests/integration/group_pair_phi_home.tl, exit 42) proves the carry. The
    # two former `movq %rax|%rdx, %r12-%r15/%rbx` assertions pinned that copy and
    # are retired with it; the pair-home and no-reload assertions above still
    # fail if the phi falls back to frame slots.
    assert_not_matches "$_body" '^[[:space:]]+movq [0-9]+\(%rsp\), %r(ax|dx)$' group-pair-phi-home
}

# Count the pushed callee-save homes of a function body, failing on an
# unbalanced or duplicated push/pop for any one register.
csr_pushed_count() {
    _body=$1
    _label=$2
    _saved=0
    for _reg in r12 r13 r14 r15 rbx rbp; do
        _pushes=$(count_fixed "$_body" "pushq %$_reg")
        _pops=$(count_fixed "$_body" "popq %$_reg")
        if [ "$_pushes" -ne "$_pops" ] || [ "$_pushes" -gt 1 ]; then
            fail "$_label unbalanced %$_reg save/restore: $_pushes push, $_pops pop"
        fi
        _saved=$((_saved + _pushes))
    done
    printf '%s' "$_saved"
}

# A push-mode function that names no frame slot reserves NO slot region: the
# pushes carry its callee-saves, and the only stack adjustment the frame model
# still owes is the 8-byte alignment pad an EVEN push count needs to keep the
# total displacement at D % 16 == 8. An odd push count already lands there, so
# it pays nothing at all -- prologue and epilogue both.
#
# The parity split is what keeps this forcing without pinning the allocator's
# register count: whichever parity the plan lands on, a reserved slot region
# reappears as a `subq $N` with N > 8 (pre-change: `subq $64` in churn3,
# `subq $56` in deeprec) and fails here.
assert_dead_slot_region() {
    _body=$1
    _saved=$2
    _label=$3
    if [ $((_saved % 2)) -eq 1 ]; then
        assert_regex_count_eq "$_body" '^[[:space:]]+subq \$[0-9]+, %rsp$' 0 "$_label"
        assert_regex_count_eq "$_body" '^[[:space:]]+addq \$[0-9]+, %rsp$' 0 "$_label"
    else
        assert_regex_count_eq "$_body" '^[[:space:]]+subq \$8, %rsp$' 1 "$_label"
        assert_regex_count_eq "$_body" '^[[:space:]]+subq \$[0-9]+, %rsp$' 1 "$_label"
    fi
}

check_csr_push_prologue() {
    _asm=$(compile_gate csr_push_prologue tests/integration/csr_push_prologue.tl)
    _body=$(function_body "$_asm" _tl_csr_push_prologue_churn3)
    _saved=$(csr_pushed_count "$_body" csr-push-prologue)
    if [ "$_saved" -lt 3 ]; then
        fail "csr-push-prologue expected at least 3 pushed CSR homes, got $_saved"
    fi
    assert_dead_slot_region "$_body" "$_saved" csr-push-prologue
    assert_not_matches "$_body" '^[[:space:]]+movq %r(12|13|14|15|bx|bp), -?[0-9]+\(%rsp\)$' csr-push-prologue
    # deeprec is the other parity: four pushed homes, so its alignment pad is
    # the one stack adjustment that survives. Both shapes together pin the
    # model rather than one function's register count.
    _deep=$(function_body "$_asm" _tl_csr_push_prologue_deeprec)
    _deep_saved=$(csr_pushed_count "$_deep" csr-push-prologue-deeprec)
    if [ "$_deep_saved" -lt 3 ]; then
        fail "csr-push-prologue-deeprec expected at least 3 pushed CSR homes, got $_deep_saved"
    fi
    assert_dead_slot_region "$_deep" "$_deep_saved" csr-push-prologue-deeprec
    assert_not_matches "$_deep" '^[[:space:]]+movq %r(12|13|14|15|bx|bp), -?[0-9]+\(%rsp\)$' csr-push-prologue-deeprec
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
    # GAP4's property is ONE len load and ONE data load surviving the
    # interleaved element stores; the destination registers are allocator
    # choices, not part of the property (the phi-web ordering rework moved
    # them without adding a load).
    assert_regex_count_eq "$_body" '^[[:space:]]+movq 8\(%rdi\), %r[a-z0-9]+$' 1 loadcse-forward
    assert_regex_count_eq "$_body" '^[[:space:]]+movq \(%rdi\), %r[a-z0-9]+$' 1 loadcse-forward
    _data_reg=$(sed -n 's/^[[:space:]]*movq (%rdi), \(%r[a-z0-9]*\)$/\1/p' "$_body" | head -n 1)
    assert_regex_count_at_least "$_body" "^[[:space:]]+movq %r[a-z0-9]+, 16\\($_data_reg\\)$" 1 loadcse-forward
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

check_alu_mem_operand_tie() {
    _asm=$(compile_gate alu_mem_operand_tie tests/integration/alu_mem_operand_tie.tl)
    _body=$(function_body "$_asm" _tl_alu_mem_operand_tie_fold_words)
    # GAP8-C: four commutative ops, each reading a single-use element load on the
    # LHS and the loop-carried accumulator on the RHS. The allocator ties each
    # destination to the ACCUMULATOR, so the commuted ALU fold's staging `mov`
    # self-elides and every op becomes one memory-operand ALU line. Both loop
    # clones fold -- the bounds-check-eliminated fast body and the checked slow
    # body -- so four ops over two clones is eight lines.
    assert_regex_count_eq "$_body" \
        '^[[:space:]]+(andq|orq|xorq|addq) \(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' 8 \
        alu-mem-operand-tie
    # No element load survives: the fold consumed all eight.
    assert_not_matches "$_body" \
        '^[[:space:]]+movq \(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r' alu-mem-operand-tie
    # The only register-to-register copies left are the seed's entry home and the
    # accumulator's move into the return register -- one each, outside both loops.
    # A destination tied to the load instead would add one staging copy per op.
    assert_regex_count_eq "$_body" \
        '^[[:space:]]+movq %r[a-z0-9]+, %r[a-z0-9]+$' 2 alu-mem-operand-tie
}

check_alu_mem_operand_sink() {
    _asm=$(compile_gate alu_mem_operand_sink tests/integration/alu_mem_operand_tie.tl)
    _body=$(function_body "$_asm" _tl_alu_mem_operand_tie_fold_nested)
    # `load_sink`: the same four commutative ops, written as ONE nested
    # expression. Source evaluation order lowers all four element reads first,
    # so without the pass only the innermost op's load is adjacent to its
    # consumer and only that one fold fires. Sunk, every pair lands in the slot
    # before ITS consumer and all four ops become one memory-operand ALU line --
    # in BOTH loop clones, the bounds-check-eliminated fast body and the checked
    # slow body whose loads cross three unrelated bounds checks to get there.
    assert_regex_count_eq "$_body"         '^[[:space:]]+(andq|orq|xorq) \(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' 8         alu-mem-operand-sink
    # No element load survives: the fold consumed all eight.
    assert_not_matches "$_body"         '^[[:space:]]+movq \(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r' alu-mem-operand-sink
    # The only register-to-register copies left are the seed's entry home and
    # the accumulator's move into the return register, one each and both
    # outside the loops.
    assert_regex_count_eq "$_body"         '^[[:space:]]+movq %r[a-z0-9]+, %r[a-z0-9]+$' 2 alu-mem-operand-sink
}

check_const_global_mask_unroll() {
    _asm=$(compile_gate         const_global_mask_unroll         tests/integration/const_global_mask_unroll.tl)
    _global=$(function_body "$_asm" _tl_const_global_mask_unroll_mask_sum)
    _literal=$(function_body "$_asm" _tl_const_global_mask_unroll_mask_sum_literal)
    # #5238: an immutable global mask must reach the same BCE-versioned x16
    # unrolled fast path as the literal spelling. Without the early
    # constant-global operand rewrite the global-mask loop emits __bce_fast but
    # no __unroll_body, because the two-iteration fixpoint cap is spent
    # creating the fast clone. The literal twin is the control: asserting both
    # turns a regression into an asymmetry instead of a silently slower binary.
    assert_contains "$_global" '__bce_fast__unroll_body' const-global-mask-unroll
    assert_contains "$_global" '__bce_fast__unroll_guard' const-global-mask-unroll
    assert_contains "$_literal" '__bce_fast__unroll_body' const-global-mask-unroll
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
    assert_regex_count_eq "$_body" '^[[:space:]]+movq \(%rdi\), %r[a-z0-9]+$' 1 licm-desc-hoist
    assert_contains "$_body" 'call tl_oob_abort' licm-desc-hoist
}

check_licm_memclean_promote() {
    _src=tests/integration/licm_memclean_global_promote.tl
    _asm=$(compile_gate licm_memclean_promote "$_src")
    _sym=_tl_licm_memclean_global_promote
    _promoted=$(function_body "$_asm" "${_sym}_promoted_scan")
    _pressured=$(function_body "$_asm" "${_sym}_pressured_scan")
    _writer=$(function_body "$_asm" "${_sym}_writer_scan")
    # All three loops read their cell TWICE per iteration around a surviving
    # direct call, so two occurrences means "still read per use" and one means
    # "promoted to a single preheader load". Pre-change every one of them is 2.
    #
    # ADMITTED: the callee is proven to write no memory and the loop's live-in
    # count is under opt-licm-global-promote-live-in-budget.
    assert_fixed_count_eq "$_promoted" "${_sym}_gcell_a(%rip)" 1 licm-memclean-promote
    assert_contains "$_promoted" "call ${_sym}_mix" licm-memclean-promote
    # REFUSED on pressure: same callee and cell shape, live-in over the budget,
    # so the copy would spill instead of taking a register.
    assert_fixed_count_eq "$_pressured" "${_sym}_gcell_b(%rip)" 2 licm-memclean-promote
    assert_contains "$_pressured" "call ${_sym}_mix" licm-memclean-promote
    # REFUSED on the proof: the callee set!s the cell, so it is not invariant at
    # any pressure. This is also the wrong-answer guard the fixture runs.
    assert_fixed_count_eq "$_writer" "${_sym}_gcell_c(%rip)" 2 licm-memclean-promote
    assert_contains "$_writer" "call ${_sym}_mix_writing" licm-memclean-promote
}

check_group_copy_direct() {
    _asm=$(compile_gate group_copy_direct tests/integration/group_copy_direct.tl)
    _body=$(function_body "$_asm" _tl_group_copy_direct_wrap)
    _xmm=$(awk '$1 == "movups" && $2 == "(%rdi)," &&
        $3 ~ /^%xmm([0-9]|1[0-5])$/ { print $3; exit }' "$_body")
    [ -n "$_xmm" ] || fail "group-copy-direct missing direct SIMD load"
    assert_contains "$_body" "movups $_xmm, 8(%rdx)" group-copy-direct
    _gp=$(awk '$1 == "movq" && $2 == "16(%rdi)," &&
        $3 ~ /^%r[a-z0-9]+$/ { print $3; exit }' "$_body")
    [ -n "$_gp" ] || fail "group-copy-direct missing direct scalar load"
    assert_contains "$_body" "movq $_gp, 24(%rdx)" group-copy-direct
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
    # M-A2 is a claim about the HANDLE: `xs` is copied out of %rdi into a
    # callee-saved register once at entry and every later use -- the direct
    # call's argument included -- reads that register instead of re-materialising
    # the handle from the frame.
    #
    # This used to be asserted as "no frame reference anywhere in the body",
    # which is a proxy, not the claim: it also fails when some UNRELATED value
    # takes a frame slot. The measured-plan inliner now prices call-carrying
    # callees, so it absorbs `probe` at this site and hoists the absorbed body's
    # own `xs[0]` into a spill slot -- a value that is not the handle and that
    # the handle contract says nothing about. The two assertions below state the
    # contract directly: the handle's callee-saved home is never reloaded from
    # the frame, and the call's handle argument is never sourced from it either.
    _home=$(sed -n \
        's/^[[:space:]]*movq %rdi, %\(r1[2-5]\|rbx\|rbp\)$/\1/p' \
        "$_body" | head -1)
    [ -n "$_home" ] || fail "handle-arg-csr could not read the handle's register home"
    assert_not_matches "$_body" \
        "^[[:space:]]+movq [-0-9]*\\((%rsp|%rbp)\\), %$_home\$" handle-arg-csr
    assert_not_matches "$_body" \
        '^[[:space:]]+movq [-0-9]*\((%rsp|%rbp)\), %rdi$' handle-arg-csr
}

check_shift_pin() {
    _asm=$(compile_gate param_shift_pin tests/integration/param_shift_pin.tl)
    _body=$(function_body "$_asm" _tl_param_shift_pin_shift_mix)
    assert_contains "$_body" 'shlq $2' shift-pin
    assert_not_matches "$_body" '^[[:space:]]+pushq %r(12|13|14|15|bx|bp)$' shift-pin
    assert_not_matches "$_body" '^[[:space:]]+popq %r(12|13|14|15|bx|bp)$' shift-pin
    assert_not_matches "$_body" '\(%rsp\)|\(%rbp\)' shift-pin
}

check_hashmap_get_leaf_caller_saved() {
    _asm=$(compile_gate hashmap_get_leaf_caller_saved benchmarks/hashmap_get/bench.tl)
    # The scalar read leaf no longer exists as a callee here: the inliner's
    # measured tier prices this caller's sites in sequence and takes BOTH of
    # its probe sites, which retires the last reference and lets the standalone
    # body go with it (hashmap_get -11.40%). So the gate asserts the absorption
    # first -- no call and no body -- and then re-states the leaf's own shape
    # where that shape now lives.
    if grep -q '_tl_bench_stdlib_hashmap_generated_i64_i64_get_value_or' "$_asm"; then
        fail "hashmap-get-leaf-caller-saved: get-value-or survives the inline tier in $_asm"
    fi
    _body=$(function_body "$_asm" main)
    # Both absorbed probes keep the slot-array data pointer in a register and
    # index it with computed addressing -- one `leaq (%r8,` per absorbed site.
    # That is the property the standalone leaf was pinned for, and copying the
    # body into the caller must not cost it.
    assert_regex_count_eq "$_body" '^[[:space:]]+leaq \(%r8,' 2 \
        hashmap-get-leaf-caller-saved
    # ...and the boundary the absorption retired stays retired.
    assert_not_contains "$_body" \
        'call _tl_bench_stdlib_hashmap_generated_i64_i64_get_value_or' \
        hashmap-get-leaf-caller-saved
}

check_hashmap_slot_value_update() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "hashmap_slot_update_$_suffix" \
            tests/integration/hashmap_slot_update_shape.tl "$_target")
        _scalar=$(function_body "$_asm" \
            _tl_hashmap_slot_update_shape_stdlib_hashmap_generated_i64_i64_set_occupied_value_bang)
        _general=$(function_body "$_asm" \
            _tl_hashmap_slot_update_shape_stdlib_hashmap_generated_String_i64_set_occupied_value_bang)

        # The scalar and general slots retain their 24- and 32-byte layouts.
        assert_contains "$_scalar" 'imulq $24' "hashmap-scalar-slot-stride-$_target"
        assert_contains "$_general" 'shlq $5' "hashmap-general-slot-stride-$_target"

        # Both paths guard on Occupied at state offset 0 and perform exactly one
        # payload write, to value offset 16. In particular, neither rewrites the
        # key at offset 8, the state, nor the general-family hash at offset 24.
        assert_contains "$_scalar" 'cmpq $2, (%rax)' "hashmap-scalar-update-state-$_target"
        assert_contains "$_general" 'cmpq $2, (%rax)' "hashmap-general-update-state-$_target"
        assert_regex_count_eq "$_scalar" \
            '^[[:space:]]+movq %r[a-z0-9]+, 16\(%rax\)$' 1 \
            "hashmap-scalar-update-value-$_target"
        assert_regex_count_eq "$_general" \
            '^[[:space:]]+movq %r[a-z0-9]+, 16\(%rax\)$' 1 \
            "hashmap-general-update-value-$_target"
        assert_not_matches "$_scalar" \
            '^[[:space:]]+movq %r[a-z0-9]+, (8|24)?\(%rax\)$' \
            "hashmap-scalar-update-sibling-$_target"
        assert_not_matches "$_general" \
            '^[[:space:]]+movq %r[a-z0-9]+, (8|24)?\(%rax\)$' \
            "hashmap-general-update-sibling-$_target"
        assert_not_contains "$_general" 'string_copy' \
            "hashmap-general-update-key-clone-$_target"
    done
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

check_frame_slot_repacking() {
    _linux_asm=$(compile_gate frame_slot_repacking_linux tests/integration/early_return.tl linux-x86_64)
    _windows_asm=$(compile_gate frame_slot_repacking_windows tests/integration/early_return.tl windows-x86_64)
    _linux_body=$(function_body "$_linux_asm" _tl_early_return_choose)
    _windows_body=$(function_body "$_windows_asm" _tl_early_return_choose)
    # The gate protects two properties: the repacked frame stays small, and the
    # two targets agree on it. A function that ends up needing no frame at all
    # satisfies both, so zero allocations is accepted as long as BOTH targets
    # reach it -- one target dropping the frame while the other keeps it is
    # exactly the layout drift this gate exists to catch.
    _linux_subs=$(count_regex "$_linux_body" '^[[:space:]]+subq \$[0-9]+, %rsp$')
    _windows_subs=$(count_regex "$_windows_body" '^[[:space:]]+subq \$[0-9]+, %rsp$')
    if [ "$_linux_subs" -ne "$_windows_subs" ]; then
        fail "frame-slot-repacking target drift: linux has $_linux_subs stack allocation(s), windows has $_windows_subs"
    fi
    if [ "$_linux_subs" -gt 1 ]; then
        fail "frame-slot-repacking expected at most one stack allocation, got $_linux_subs"
    fi
    if [ "$_linux_subs" -eq 1 ]; then
        _linux_frame=$(sed -n 's/^[[:space:]]*subq \$\([0-9][0-9]*\), %rsp$/\1/p' "$_linux_body")
        _windows_frame=$(sed -n 's/^[[:space:]]*subq \$\([0-9][0-9]*\), %rsp$/\1/p' "$_windows_body")
        if [ "$_linux_frame" -gt 24 ] || [ "$_windows_frame" -gt 24 ]; then
            fail "frame-slot-repacking expected frames <= 24 bytes, got linux=$_linux_frame windows=$_windows_frame"
        fi
        if [ "$_linux_frame" -ne "$_windows_frame" ]; then
            fail "frame-slot-repacking target layout drift: linux=$_linux_frame windows=$_windows_frame"
        fi
    fi
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

check_gep_copy_sib() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "gep_copy_sib_$_suffix" \
            tests/integration/gep_copy_sib_shape.tl "$_target")
        _take=$(function_body "$_asm" _tl_gep_copy_sib_shape_take)
        _put=$(function_body "$_asm" _tl_gep_copy_sib_shape_put)
        _take_const=$(function_body "$_asm" _tl_gep_copy_sib_shape_take_const)

        # The 32-byte element keeps its stride shift; only the element ADDRESS
        # register is gone.
        assert_contains "$_take" 'shlq $5' "gep-copy-sib-take-stride-$_target"
        assert_contains "$_put" 'shlq $5' "gep-copy-sib-put-stride-$_target"

        # Both 16-byte chunks address the element through the SIB operand, at
        # displacement 0 and 16, on the side the gep feeds.
        assert_regex_count_eq "$_take" \
            '^[[:space:]]+movups (16)?\(%r[a-z0-9]+,%r[a-z0-9]+,1\), %xmm[0-9]+$' 2 \
            "gep-copy-sib-take-chunks-$_target"
        assert_regex_count_eq "$_put" \
            '^[[:space:]]+movups %xmm[0-9]+, (16)?\(%r[a-z0-9]+,%r[a-z0-9]+,1\)$' 2 \
            "gep-copy-sib-put-chunks-$_target"

        # ...and the composed element address is gone from both.
        assert_not_matches "$_take" \
            '^[[:space:]]+leaq \(%r[a-z0-9]+,%r[a-z0-9]+,1\), %r[a-z0-9]+$' \
            "gep-copy-sib-take-no-addr-$_target"
        assert_not_matches "$_put" \
            '^[[:space:]]+leaq \(%r[a-z0-9]+,%r[a-z0-9]+,1\), %r[a-z0-9]+$' \
            "gep-copy-sib-put-no-addr-$_target"

        # The fold reads the operand homes in place: neither body stages the
        # base or the index through a frame slot to build the address.
        assert_not_matches "$_take" \
            '^[[:space:]]+leaq -?[0-9]*\((%rsp|%rbp)\), %r[a-z0-9]+$' \
            "gep-copy-sib-take-no-stage-$_target"
        assert_not_matches "$_put" \
            '^[[:space:]]+leaq -?[0-9]*\((%rsp|%rbp)\), %r[a-z0-9]+$' \
            "gep-copy-sib-put-no-stage-$_target"

        # CONSTANT index: no index register at all, so both chunks address the
        # element as disp(base) with the element offset (3 * 32 = 96) folded in.
        assert_regex_count_eq "$_take_const" \
            '^[[:space:]]+movups (96|112)\(%r[a-z0-9]+\), %xmm[0-9]+$' 2 \
            "gep-copy-const-chunks-$_target"

        # ...and the materialized element address is gone.
        assert_not_matches "$_take_const" \
            '^[[:space:]]+leaq 96\(%r[a-z0-9]+\), %r[a-z0-9]+$' \
            "gep-copy-const-no-addr-$_target"
    done
}

check_stdlib_math_sqrt() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "stdlib_math_sqrt_$_suffix" tests/integration/stdlib_math_ieee.tl "$_target")
        _f64=$(function_body "$_asm" tl_test_math_sqrt_f64)
        _f32=$(function_body "$_asm" tl_test_math_sqrt_f32)
        assert_contains "$_f64" 'sqrtsd' "stdlib-math-sqrt-f64-$_target"
        assert_contains "$_f32" 'sqrtss' "stdlib-math-sqrt-f32-$_target"
        assert_not_matches "$_f64" '^[[:space:]]+call ' "stdlib-math-sqrt-f64-$_target"
        assert_not_matches "$_f32" '^[[:space:]]+call ' "stdlib-math-sqrt-f32-$_target"
        assert_not_contains "$_asm" '__tl_float_sqrt' "stdlib-math-sqrt-private-$_target"
    done
}

check_mask_test_admission() {
    _asm=$(compile_gate bit_test_mask_admission \
        tests/integration/bit_test_mask_admission.tl)
    _set=$(function_body "$_asm" _tl_bit_test_mask_admission_parity_set)
    _clear=$(function_body "$_asm" _tl_bit_test_mask_admission_bit3_clear)
    _pair=$(function_body "$_asm" _tl_bit_test_mask_admission_pair_both_set)
    _mismatch=$(function_body "$_asm" \
        _tl_bit_test_mask_admission_mismatched_const)
    _le=$(function_body "$_asm" _tl_bit_test_mask_admission_mask_le)
    _dynamic=$(function_body "$_asm" _tl_bit_test_mask_admission_dynamic_mask)
    _high=$(function_body "$_asm" _tl_bit_test_mask_admission_bit63_set)
    # Single-bit mask-test admission: `(x & 1) == 1` compares against the MASK,
    # not zero, and before the admission widened it cost `andq $1` + `cmpq $1`
    # (three instructions once the mask has to be materialised, as it does in
    # the spmd_mask lane body). It is one `testq` now -- and the mapping is
    # INVERTED relative to the compare-against-zero rewrite, because `x & m`
    # is either 0 or m: equality with the mask means the bit is SET, which is
    # ZF CLEAR, so the FALSE arm is reached by `je`. Pinning the branch with
    # the test is the point: a `jne` here would be a silently inverted
    # program that still passes any instruction-count check.
    assert_regex_count_eq "$_set" '^[[:space:]]+testq [$]1, %r[a-z0-9]+$' 1 \
        mask-test-admission-set
    assert_next_line_matches "$_set" '^[[:space:]]+testq [$]1, %r[a-z0-9]+$' \
        '^[[:space:]]+je ' mask-test-admission-set
    assert_not_matches "$_set" '^[[:space:]]+andq [$]1, %r' \
        mask-test-admission-set
    assert_not_matches "$_set" '^[[:space:]]+cmpq [$]1, %r' \
        mask-test-admission-set
    # The other half of the inverted mapping: `(x & 8) != 8` means the bit is
    # CLEAR, which is ZF SET, so the FALSE arm is reached by `jne`.
    assert_regex_count_eq "$_clear" '^[[:space:]]+testq [$]8, %r[a-z0-9]+$' 1 \
        mask-test-admission-clear
    assert_next_line_matches "$_clear" '^[[:space:]]+testq [$]8, %r[a-z0-9]+$' \
        '^[[:space:]]+jne ' mask-test-admission-clear
    assert_not_matches "$_clear" '^[[:space:]]+andq [$]8, %r' \
        mask-test-admission-clear
    # Nearest refused neighbours, each still on the old mov+and+cmp path.
    # A multi-bit mask asks whether BOTH bits are set, which one `test` cannot
    # answer; admitting it here would be a miscompile, not a slowdown.
    assert_matches "$_pair" '^[[:space:]]+andq [$]3, %r' mask-test-admission-pair
    assert_matches "$_pair" '^[[:space:]]+cmpq [$]3, %r' mask-test-admission-pair
    assert_not_matches "$_pair" '^[[:space:]]+testq [$]3, %r' \
        mask-test-admission-pair
    # A comparison constant that is not the mask names no single bit.
    assert_matches "$_mismatch" '^[[:space:]]+andq [$]4, %r' \
        mask-test-admission-mismatch
    assert_matches "$_mismatch" '^[[:space:]]+cmpq [$]1, %r' \
        mask-test-admission-mismatch
    assert_not_matches "$_mismatch" '^[[:space:]]+testq [$]4, %r' \
        mask-test-admission-mismatch
    # Ordered compares against the mask are a constant fold, not a bit test.
    assert_matches "$_le" '^[[:space:]]+andq [$]1, %r' mask-test-admission-le
    assert_matches "$_le" '^[[:space:]]+cmpq [$]1, %r' mask-test-admission-le
    # A register mask names no bit at compile time.
    assert_matches "$_dynamic" \
        '^[[:space:]]+andq %r[a-z0-9]+, %r[a-z0-9]+$' \
        mask-test-admission-dynamic
    # `1 << 63` is stored negative as i64, so the `> 0` single-bit guard drops
    # it and the pair survives.
    assert_matches "$_high" '^[[:space:]]+andq %r[a-z0-9]+, %r[a-z0-9]+$' \
        mask-test-admission-high
    assert_matches "$_high" '^[[:space:]]+cmpq %r[a-z0-9]+, %r[a-z0-9]+$' \
        mask-test-admission-high
}

check_inline_alloc_unique_labels_link() {
    _name=inline_alloc_unique_labels
    _binary="$WORKDIR/$_name"
    _stdout="$WORKDIR/$_name.build.stdout"
    _stderr="$WORKDIR/$_name.build.stderr"
    echo "[asm-shape] standalone opt2 link $_name" >&2
    if ! "$COMPILER" build "$ROOT/src/compiler_backend_tests.tl" \
        --target linux-x86_64 \
        --opt-level 2 \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" \
        -o "$_binary" > "$_stdout" 2> "$_stderr"; then
        echo "build stdout:" >&2
        sed 's/^/  /' "$_stdout" >&2 || true
        echo "build stderr:" >&2
        sed 's/^/  /' "$_stderr" >&2 || true
        fail "$_name standalone build failed"
    fi
    [ -x "$_binary" ] || fail "$_name standalone build produced no executable"
}

check_load_widen_cast_fold() {
    _asm=$(compile_gate load_widen_cast_fold tests/integration/load_widen_cast_fold.tl)
    _classify=$(function_body "$_asm" _tl_load_widen_cast_fold_classify)
    _refused=$(function_body "$_asm" _tl_load_widen_cast_fold_refused)
    # M6-G: the byte is read eight times, so the M6-C compare fold declines and
    # the load survives -- but as ONE instruction landing in the cast's own
    # register. Exactly one byte load, and no register-to-register re-extension
    # anywhere in the function.
    assert_regex_count_eq "$_classify"         '^[[:space:]]+movzbq \(%r[a-z0-9]+,%r[a-z0-9]+,1\), %r[a-z0-9]+$' 1         load-widen-cast-fold
    assert_not_matches "$_classify"         '^[[:space:]]+movzbq %[a-z0-9]+l, %r' load-widen-cast-fold
    # Nearest refused neighbour: the element is stored back at u8 width, so no
    # widening cast follows the load and the pair the fold looks for is absent.
    # The load and the widening still both appear, and the fold has not touched
    # them.
    assert_matches "$_refused"         '^[[:space:]]+movzbq \(%r[a-z0-9]+,%r[a-z0-9]+,1\), %r[a-z0-9]+$'         load-widen-cast-fold-refused
    assert_contains "$_refused" 'movb ' load-widen-cast-fold-refused
}


# Count the block that starts at the FIRST `__unroll_body:` label and runs to
# the next label definition -- one unrolled group, whose line count IS the
# unroll factor for a body that emits one line per copy.
unroll_body_block() {
    _file=$1
    _out="$WORKDIR/$(basename "$_file").unroll_body"
    awk '
        started && /^[^[:blank:]]*:$/ { exit }
        started { print }
        !started && /__unroll_body:$/ { started = 1 }
    ' "$_file" > "$_out"
    printf '%s\n' "$_out"
}

check_mem_dest_rmw_fold() {
    _asm=$(compile_gate mem_dest_rmw_fold tests/integration/mem_dest_rmw_fold.tl)
    # GAP10: `a[i] = a[i] OP x` must become an x86 memory-DESTINATION ALU op.
    # Each kernel emits its merge in three places -- the four copies of the
    # unrolled fast body, the fast remainder, and the checked slow body -- so
    # six memory-destination lines and, decisively, ZERO memory-SOURCE lines:
    # a memory-source op is the old three-instruction round trip's middle
    # instruction, and its absence is what proves the load and the store-back
    # are both gone.
    for _kernel in merge_or merge_and merge_add merge_reg; do
        _body=$(function_body "$_asm" "_tl_mem_dest_rmw_fold_$_kernel")
        assert_regex_count_eq "$_body" \
            '^[[:space:]]+(orq|andq|addq) (%r[a-z0-9]+|\$-?[0-9]+), -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' \
            6 "mem-dest-rmw-$_kernel"
        assert_regex_count_eq "$_body" \
            '^[[:space:]]+(orq|andq|addq) -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' \
            0 "mem-dest-rmw-$_kernel-no-memory-source"
    done
    # The register-source kernel folds to ONE instruction per word: the other
    # operand is loop-invariant, so nothing is staged and no element is loaded.
    _reg=$(function_body "$_asm" _tl_mem_dest_rmw_fold_merge_reg)
    assert_not_matches "$_reg" \
        '^[[:space:]]+movq -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r' mem-dest-rmw-merge-reg
    # Refused neighbours: one-token edits of the admitted shape that must keep
    # the three-instruction round trip. Each keeps exactly the six memory-SOURCE
    # ALU ops the fold would have consumed and gains no memory destination.
    #   shifted    -- stores to a different element than it loaded
    #   reused     -- the loaded element has a second reader
    #   interposed -- another store lands between the load and the store-back
    for _kernel in merge_shifted merge_reused merge_interposed; do
        _body=$(function_body "$_asm" "_tl_mem_dest_rmw_fold_$_kernel")
        assert_regex_count_eq "$_body" \
            '^[[:space:]]+(orq|andq|addq) (%r[a-z0-9]+|\$-?[0-9]+), -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' \
            0 "mem-dest-rmw-$_kernel-refused"
        assert_regex_count_eq "$_body" \
            '^[[:space:]]+(orq|andq|addq) -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' \
            6 "mem-dest-rmw-$_kernel-still-emitted"
    done
    # Byte width: the same source shape at a width the fold refuses, because a
    # `q` op cannot agree with the load's zero-extension and the store's
    # truncation. The merge is still emitted, as `orb`.
    _bytes=$(function_body "$_asm" _tl_mem_dest_rmw_fold_merge_bytes)
    assert_regex_count_eq "$_bytes" \
        '^[[:space:]]+(orq|orb) (%r[a-z0-9]+b?|%[a-d]l|\$-?[0-9]+), -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,1\)$' \
        0 mem-dest-rmw-merge-bytes-refused
    assert_matches "$_bytes" '^[[:space:]]+orb ' mem-dest-rmw-merge-bytes-still-emitted
}

check_word_merge_unroll() {
    _asm=$(compile_gate word_merge_unroll tests/integration/mem_dest_rmw_fold.tl)
    # The word-merge unroll tier: a load-and-store body whose every access is a
    # 64-bit word through a 64-bit-element gep runs at K=4, not the class
    # default K=2. One group of the unrolled body therefore holds FOUR folded
    # merges and one counter step of 4.
    _or=$(function_body "$_asm" _tl_mem_dest_rmw_fold_merge_or)
    _or_group=$(unroll_body_block "$_or")
    assert_regex_count_eq "$_or_group" \
        '^[[:space:]]+orq %r[a-z0-9]+, -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' 4 \
        word-merge-unroll-k4
    assert_contains "$_or_group" 'addq $4,' word-merge-unroll-k4-step
    # The refusal that keeps the K=2 pin two-sided: the byte-wide twin is the
    # SAME loop written over `(Array u8)`. It is still the load-and-store class,
    # so it still unrolls -- at the class default of 2, with a counter step of
    # 2. Raising the class instead of adding a tier would move this one too.
    _bytes=$(function_body "$_asm" _tl_mem_dest_rmw_fold_merge_bytes)
    _bytes_group=$(unroll_body_block "$_bytes")
    assert_regex_count_eq "$_bytes_group" '^[[:space:]]+orb ' 2 word-merge-unroll-bytes-k2
    assert_contains "$_bytes_group" 'addq $2,' word-merge-unroll-bytes-k2-step
    # The container shape the K=2 constant was pinned for: a word payload
    # updated alongside a NARROW tag. Its word half still takes the
    # memory-destination fold -- that fold is per-instruction -- but ONE narrow
    # access is enough to refuse the tier, and the body stays at K=2. This is
    # where the two mechanisms are pinned as independent.
    _mixed=$(function_body "$_asm" _tl_mem_dest_rmw_fold_merge_mixed)
    _mixed_group=$(unroll_body_block "$_mixed")
    assert_contains "$_mixed_group" 'addq $2,' word-merge-unroll-mixed-k2-step
    assert_regex_count_eq "$_mixed_group" \
        '^[[:space:]]+orq \$1, -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' 2 \
        word-merge-unroll-mixed-k2
}

check_gep_load_cmp_spilled_stage() {
    _asm=$(compile_gate gep_load_cmp_spilled_stage         tests/integration/gep_load_cmp_spilled_stage.tl)
    _changed=$(function_body "$_asm"         _tl_gep_load_cmp_spilled_stage_changed_question)
    _refused=$(function_body "$_asm" _tl_gep_load_cmp_spilled_stage_refused)
    # M6-H: `changed?` spills both hoisted base-relative addresses AND the two
    # compared elements. Every one of its four compare sites (the two bounds-
    # eliminated clones and their versioned twins) must address the element
    # through the staged base instead of materialising it:
    #     movq SPILL(%rsp), %rT
    #     cmpq (%rT,%rIDX,8), %rOTHER
    # Before this packet only ONE site folded; the others stored the loaded
    # element to its home and compared against that home.
    assert_regex_count_at_least "$_changed"         '^[[:space:]]+cmpq \(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' 4         gep-load-cmp-spilled-stage
    # And no compare anywhere in the function reads back a slot the same block
    # had just written from a register. That pair is the defect itself; the
    # baseline emitted exactly one.
    assert_store_then_cmp_same_slot_eq "$_changed" 0         gep-load-cmp-spilled-stage
    # Nearest refused neighbour: `refused` reads each loaded element a SECOND
    # time to fold it into a sum, so the value is not single-use, the fold
    # cannot retire it, and its home stays load-bearing. No compare in it
    # addresses an element directly.
    assert_regex_count_eq "$_refused"         '^[[:space:]]+cmpq \(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' 0         gep-load-cmp-spilled-stage-refused
    # The elements are still loaded and still compared there -- the refusal is
    # a refusal to fold, not a refusal to emit.
    assert_matches "$_refused"         '^[[:space:]]+movq \(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$'         gep-load-cmp-spilled-stage-refused
}

# Backend jump-only block forwarding (#jump-forward). A run of if_merge blocks
# whose phi copies coalesce emits one `jmp` each; a branch into the head of the
# run used to walk the whole run. Forwarding names the run's exit directly. The
# blocks are still emitted -- only jump operands move -- so the merge labels
# must all still be there, and a jump-only SELF loop must keep its own jump.
check_jump_only_forward() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "jump_only_forward_$_suffix" \
            tests/integration/jump_only_forward.tl "$_target")

        _forward=$(function_body "$_asm" _tl_jump_only_forward_forward_probe)
        _diamond=$(function_body "$_asm" _tl_jump_only_forward_diamond_probe)
        _main=$(function_body "$_asm" main)

        # The core property over every compiled body: nothing branches into a
        # block that does nothing but jump. Three such branches survive in the
        # forward probe before the forwarding table exists.
        for _body in "$_forward" "$_diamond" "$_main"; do
            assert_no_jump_into_jump_only_block "$_body" \
                "jump-only-forward-$_target"
            assert_no_fallthrough_jmp "$_body" "jump-only-forward-$_target"
        done

        # Not vacuous: the merge run is still four real blocks, still reached by
        # branches. Forwarding retargets jumps; it never deletes a block.
        assert_regex_count_at_least "$_forward" \
            '^\.L[^ ]*_if_merge\.[0-9.]+:$' 4 "jump-only-forward-$_target"
        assert_regex_count_at_least "$_forward" \
            '^[[:space:]]+j[a-z]+ \.L[^ ]*_if_merge\.[0-9.]+$' 4 \
            "jump-only-forward-$_target"
        assert_backward_branch_at_least "$_forward" 1 \
            "jump-only-forward-$_target"

        # REFUSED: the diamond's merges carry values that differ per edge, so
        # they are not jump-only and the branches naming them stay put.
        assert_regex_count_at_least "$_diamond" \
            '^[[:space:]]+j[a-z]+ \.L[^ ]*_if_merge\.[0-9.]+$' 3 \
            "jump-only-forward-diamond-$_target"

        # REFUSED: the inlined empty infinite loop keeps its self-jump.
        assert_self_loop_jmp_at_least "$_main" 1 "jump-only-forward-spin-$_target"
    done
}

check_mem_dest_rmw_fold
check_word_merge_unroll
check_divmagic_hoist
check_hoist_priority
check_lftr_counter_retire
check_fallthrough_jmp_chain
check_jump_only_forward
check_wide_const_hoist
check_group_pair_home
check_group_pair_phi_home
check_csr_push_prologue
check_save_reload_elide
check_global_handle_cse
check_loadcse_forward
check_switch_dispatch_scavenge
check_cmp_fold_load
check_alu_mem_operand_tie
check_alu_mem_operand_sink
check_const_index_bounds
check_const_global_mask_unroll
check_rbp_sixth_csr
check_win64_rbp_eighth_csr
check_licm_desc_hoist
check_licm_memclean_promote
check_group_copy_direct
check_dead_result_store
check_param_csr_home
check_handle_arg_csr
check_shift_pin
check_hashmap_get_leaf_caller_saved
check_hashmap_slot_value_update
check_param_pin_interval
check_frame_slot_repacking
check_gep_value_direct
check_gep_copy_sib
check_load_widen_cast_fold
check_mask_test_admission
check_stdlib_math_sqrt
check_inline_alloc_unique_labels_link
check_gep_load_cmp_spilled_stage

echo "Assembly shape gates passed."
