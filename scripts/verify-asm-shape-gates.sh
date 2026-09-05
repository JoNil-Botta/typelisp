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

# ABT-1: the located abort tail's SECOND staging push is taken after %rsp has
# already moved, so its operand must not be a memory read -- that is the exact
# condition under which compiler-backend-text-max-rsp-dip may ignore the tail's
# dip, and it is what keeps a red-zone slot the FIRST push clobbers harmless.
# The bounds tail's index is a register or an imm32, the shift tail's width is
# an immediate, and the div tail's saves are registers (normalized through
# %r11), so no tail may spell that push against memory. The first push may:
# it happens while %rsp is still the body's own.
assert_abort_tail_staging_push_not_memory() {
    _file=$1
    _label=$2
    _bad=$(awk '
        /^[[:space:]]+leaq \.L_tl_abort_site_/ {
            if (prev ~ /^[[:space:]]+pushq [-0-9]*\(%/) print prev
        }
        { prev = $0 }
    ' "$_file")
    if [ -n "$_bad" ]; then
        fail "$_label staging push before the descriptor reads memory: $_bad"
    fi
}

# INL-7: an upper bound rather than an exact count, for a claim about a whole
# benchmark function's frame traffic. The number the gate cares about is the one
# the refused import would add; pinning the exact count would make every
# unrelated allocator change land on this gate instead of on its own.
assert_regex_count_at_most() {
    _file=$1
    _regex=$2
    _want=$3
    _label=$4
    _got=$(count_regex "$_file" "$_regex")
    if [ "$_got" -gt "$_want" ]; then
        fail "$_label expected at most $_want match(es) for /$_regex/, got $_got"
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

# DCE-2 shapes. Two things the level-2 pipeline's final slot exists to keep out
# of the emitted body, both read off a normalized register name so a 32-bit
# materialization (`movl $1, %esi`) and its 64-bit test (`testq %rsi, %rsi`)
# are seen as the same register.
#
#   count_literal_then_test  -- a register loaded with a literal and TESTED on
#                               the next line: a branch on a constant that
#                               reached the backend.
#   count_literal_then_redef -- a register loaded with a literal and REDEFINED
#                               on the next line: the literal Mov was dead when
#                               it was emitted.
asm_shape_reg_norm_awk() {
    cat <<'AWK'
function norm(r,   n) {
    n = r
    sub(/^%/, "", n)
    if (n ~ /^e[a-z][a-z]$/) { sub(/^e/, "r", n); return n }
    if (n ~ /^r[0-9]+[bwd]$/) { sub(/[bwd]$/, "", n); return n }
    if (n ~ /^[a-z][a-z]l$/ && n != "rsl") { sub(/l$/, "x", n); sub(/^/, "r", n); return n }
    return n
}
function literal_dst(line,   parts) {
    if (line ~ /^mov[lq][ \t]+\$-?[0-9]+,[ \t]*%[a-z0-9]+$/) {
        split(line, parts, /,[ \t]*/)
        return norm(parts[2])
    }
    if (line ~ /^xor[lq][ \t]+%[a-z0-9]+,[ \t]*%[a-z0-9]+$/) {
        split(line, parts, /[ \t,]+/)
        if (norm(parts[2]) == norm(parts[3])) return norm(parts[2])
    }
    return ""
}
function redef_dst(line,   parts) {
    if (line ~ /^mov[lq][ \t]+\$-?[0-9]+,[ \t]*%[a-z0-9]+$/) {
        split(line, parts, /,[ \t]*/)
        return norm(parts[2])
    }
    if (line ~ /^xor[lq][ \t]+%[a-z0-9]+,[ \t]*%[a-z0-9]+$/) {
        split(line, parts, /[ \t,]+/)
        if (norm(parts[2]) == norm(parts[3])) return norm(parts[2])
    }
    return ""
}
function test_reg(line,   parts) {
    if (line ~ /^test[bwlq][ \t]+%[a-z0-9]+,[ \t]*%[a-z0-9]+$/) {
        split(line, parts, /[ \t,]+/)
        if (norm(parts[2]) == norm(parts[3])) return norm(parts[2])
    }
    return ""
}
AWK
}

count_literal_then_test() {
    {
        asm_shape_reg_norm_awk
        cat <<'AWK'
{
    line = $0
    sub(/^[ \t]+/, "", line)
    sub(/[ \t]+$/, "", line)
    if (pending != "" && test_reg(line) == pending) count++
    pending = literal_dst(line)
}
END { print count + 0 }
AWK
    } > "$WORKDIR/asm-shape-literal-then-test.awk"
    awk -f "$WORKDIR/asm-shape-literal-then-test.awk" "$1"
}

count_literal_then_redef() {
    {
        asm_shape_reg_norm_awk
        cat <<'AWK'
{
    line = $0
    sub(/^[ \t]+/, "", line)
    sub(/[ \t]+$/, "", line)
    if (pending != "" && redef_dst(line) == pending) count++
    pending = literal_dst(line)
}
END { print count + 0 }
AWK
    } > "$WORKDIR/asm-shape-literal-then-redef.awk"
    awk -f "$WORKDIR/asm-shape-literal-then-redef.awk" "$1"
}

assert_no_literal_then_test() {
    _got=$(count_literal_then_test "$1")
    if [ "$_got" -ne 0 ]; then
        fail "$2 tests a register that was just loaded with a literal ($_got time(s))"
    fi
}

assert_no_literal_then_redef() {
    _got=$(count_literal_then_redef "$1")
    if [ "$_got" -ne 0 ]; then
        fail "$2 redefines a register that was just loaded with a literal ($_got time(s))"
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

# SROA-2. The lattice-join fixture is the shape the aggregate word split exists
# for: a clone of a four-word enum out of a dense array, a join that rebuilds it
# per match arm, and an equality that reads both back. Before the split every
# one of those temporaries was a frame buffer, so the join function moved 32
# bytes with `movups` and every comparison read a `(%rsp)` slot back. After it
# the whole value lives in registers: the function reserves no stack at all, the
# tag test is a register test, and the equality's payload compares are
# register-to-register.
# UNR-1. The word-then-tail piece copy, all three claims in one body: the
# helper is inlined into `copy-fill!`, its length comes from a String
# descriptor and its two loops are the word loop and the byte remainder.
check_short_trip_copy() {
    _asm=$(compile_gate short_trip_copy tests/integration/short_trip_copy.tl)
    _fill=$(function_body "$_asm" _tl_short_trip_copy_copy_fill_bang)
    # The piece length is a container length, so the lattice signs it and the
    # `/ 8` is ONE logical shift. The give-away of the five-instruction signed
    # form is the `sarq $63` sign broadcast; the fixture's other arithmetic is
    # MASKED rather than divided, so no other divide may put one here either.
    assert_matches "$_fill" '^[[:space:]]+shrq \$3, %r' short-trip-copy-divide
    assert_not_matches "$_fill" '^[[:space:]]+sarq \$63, %r' short-trip-copy-divide
    # The word loop's bound is that `n / 8`, non-negative for the same reason,
    # so its unroll guard drops the `bound - K <= bound` wrap compare and its
    # literal-zero seed reads as `ngroup > 0`: `lea; test; jg`, not
    # `lea; cmp; jle; test; jg`.
    # (assert_next_line_matches hands its patterns to awk -v, which eats a
    # single backslash: bracket the metacharacters instead of escaping.)
    assert_next_line_matches "$_fill" '^[[:space:]]+leaq -4[(]%r[a-z0-9]+[)], %r' \
        '^[[:space:]]+testq %r[a-z0-9]+, %r' short-trip-copy-guard
    assert_not_matches "$_fill" '^[[:space:]]+leaq -2\(%r[a-z0-9]+\), %r' \
        short-trip-copy-guard
    # ...and the byte tail runs `n mod 8` times, so it is not versioned at all:
    # ONE guard in the whole body (the word loop's) and ONE byte copy, the
    # remainder loop's own.
    assert_regex_count_eq "$_fill" '__unroll_guard:$' 1 short-trip-copy-tail
    assert_regex_count_eq "$_fill" '^[[:space:]]+movzbq ' 1 short-trip-copy-tail
}

check_lattice_join_split() {
    _asm=$(compile_gate lattice_join_split tests/integration/lattice_join_split.tl)
    _bind=$(function_body "$_asm" _tl_lattice_join_split_lat_bind)
    # No stack temporary for the enum: no frame, no wide copy, no word store or
    # compare against a frame slot anywhere between the tag test and the
    # compare.
    assert_not_matches "$_bind" '^[[:space:]]+subq \$[0-9]+, %rsp$' lattice-join-split
    assert_not_contains "$_bind" 'movups' lattice-join-split
    assert_not_matches "$_bind" '^[[:space:]]+movq %[a-z0-9]+, -?[0-9]+\(%rsp\)$' \
        lattice-join-split
    assert_not_matches "$_bind" '^[[:space:]]+cmpq -?[0-9]+\(%rsp\), %' \
        lattice-join-split
    # The equality's match is ONE tag compare against a register, and its three
    # payload comparisons are register-to-register.
    assert_matches "$_bind" '^[[:space:]]+cmpq \$1, %[a-z0-9]+$' lattice-join-split
    assert_regex_count_at_least "$_bind" \
        '^[[:space:]]+cmpq %r[a-z0-9]+, %r[a-z0-9]+$' 3 lattice-join-split
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

# Backend block layout (#block-layout). Two rewrites over an emitted function's
# assembly, and the refusal that keeps everything else in IR order.
check_block_layout() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "block_layout_$_suffix"             tests/integration/block_layout.tl "$_target")

        _sink=$(function_body "$_asm" _tl_block_layout_sink_probe)
        _dup=$(function_body "$_asm" _tl_block_layout_dup_probe)
        _keep=$(function_body "$_asm" _tl_block_layout_keep_probe)

        for _body in "$_sink" "$_dup" "$_keep"; do
            assert_no_fallthrough_jmp "$_body" "block-layout-$_target"
        done

        # SINK. The checked read's `-1` arm is predicted cold -- `i < 0` false,
        # and `i >= n` bailing to the same arm inherits that -- so it is laid
        # out behind the body: the load falls straight into the join and the
        # arm is the side that pays a jump back.
        # (assert_next_line_matches hands its patterns to awk -v, which eats a
        # single backslash: bracket the metacharacters instead of escaping.)
        assert_next_line_matches "$_sink"             '^[[:space:]]+movzbq .*, %r[a-z0-9]+$'             '^[.]L.*_if_merge[.][0-9.]+' "block-layout-sink-$_target"
        assert_next_line_matches "$_sink"             '^[[:space:]]+movq [$]-1, %r[a-z0-9]+$'             '^[[:space:]]+jmp [.]L.*_if_merge[.][0-9]'             "block-layout-sink-$_target"
        # Not vacuous: the arm is still a real block reached by real branches.
        assert_regex_count_at_least "$_sink"             '^[[:space:]]+j[a-z]+ \.L[^ ]*_if_else\.[0-9.]+$' 2             "block-layout-sink-$_target"

        # DUP. The loop's exit block is three instructions ending in an
        # unconditional jump, so the arm that skipped the loop absorbs it
        # instead of jumping to it -- and the block stays where it is for the
        # loop's own edge.
        assert_regex_count_eq "$_dup"             '^[[:space:]]+jmp \.L[^ ]*_while_exit\.[0-9.]+$' 0             "block-layout-dup-$_target"
        assert_matches "$_dup" '^\.L[^ ]*_while_exit\.[0-9.]+:$'             "block-layout-dup-$_target"
        assert_regex_count_eq "$_dup"             '^[[:space:]]+leaq \(,%r[a-z0-9]+,2\), %r[a-z0-9]+$' 2             "block-layout-dup-$_target"

        # REFUSED. Both arms carry work and the branch compares two registers,
        # which the opcode heuristics say nothing about: the else arm keeps its
        # place between the then arm and the merge, and the then arm keeps the
        # jump across it.
        assert_regex_count_eq "$_keep"             '^[[:space:]]+jmp \.L[^ ]*_if_merge\.[0-9.]+$' 1             "block-layout-keep-$_target"
        assert_matches "$_keep" '^\.L[^ ]*_if_else\.[0-9.]+:$'             "block-layout-keep-$_target"
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

# RG-1 fix B: every callee-saved register the prologue pushes must be NAMED by
# the body. A register that is pushed and popped and appears nowhere between is
# two instructions on every call of the function for nothing -- cg-map-probe
# pays 2.63M Ir per callgraph_scc run that way, and the probe fixture below is
# its shape.
#
# The check reads the pushes out of the prologue and then asks whether the
# register occurs anywhere else in the body, at ANY width: a `%rbx` a function
# only ever names as `%ebx` is used, and trimming its save would clobber the
# caller's. A frame reference `K(%rbp)` is not a use of %rbp, which is why the
# %rbp scan drops the occurrences that follow a '('.
#
# Pre-change both `insert!` and `lookup` push %r15 and name it nowhere, so the
# assertion is proven forcing.
# The callee-saved registers a function's PROLOGUE pushes: the pushq run
# before the first inner label. An abort site marshals its arguments with its
# own pushq/popq pair, so counting pushes over the whole body would read one of
# those as a second prologue save.
prologue_pushed_csrs() {
    awk '
        NR == 1 { next }
        /:[[:space:]]*$/ { exit }
        /^[[:space:]]+pushq %(r1[2-5]|rbx|rbp)$/ {
            sub(/^[[:space:]]+pushq %/, "")
            print
        }
    ' "$1"
}

assert_pushed_csrs_named() {
    _body=$1
    _label=$2
    for _reg in $(prologue_pushed_csrs "$_body"); do
        case $_reg in
            rbx) _pat='%rbx|%ebx|%bx|%bl' ;;
            rbp) _pat='%rbp|%ebp|%bp|%bpl' ;;
            *) _pat="%$_reg" ;;
        esac
        # Every line naming the register at any width, with the frame operands
        # blanked (a `K(%rbp)` base is not a use of the value register) and the
        # restores dropped, less the one prologue push.
        _mentions=$(sed 's/[-0-9]*(%r[bs]p[^)]*)/FRAME/g' "$_body" \
            | grep -E "$_pat" \
            | grep -v -c -E "^[[:space:]]+popq %$_reg\$" || true)
        if [ "$_mentions" -le 1 ]; then
            fail "$_label pushes %$_reg and never names it"
        fi
    done
}

check_csr_unused_save() {
    _asm=$(compile_gate csr_unused_save tests/integration/csr_unused_save.tl)
    for _fn in _tl_csr_unused_save_insert_bang _tl_csr_unused_save_lookup; do
        _body=$(function_body "$_asm" "$_fn")
        _saved=$(prologue_pushed_csrs "$_body" | wc -l | tr -d '[:space:]')
        if [ "$_saved" -lt 1 ]; then
            fail "csr-unused-save $_fn expected at least one pushed CSR home, got $_saved"
        fi
        assert_pushed_csrs_named "$_body" "csr-unused-save-$_fn"
    done
}

# RG-1 fix B on a CALL-CARRYING loop: the census-shaped walk. Both arms of the
# inner scan call, so the loop's carried values are callee-saved-only
# candidates and the function runs with a full callee-saved run pushed -- the
# shape where an unnamed save costs two instructions on every one of the
# function's calls. The gate pins that the run is there, that every register in
# it is named by the body, and that the prologue's total displacement still
# leaves the body's calls 16-byte aligned after the trim has had its say.
check_csr_census_loop() {
    _asm=$(compile_gate csr_census_loop tests/integration/csr_census_loop.tl)
    _body=$(function_body "$_asm" _tl_csr_census_loop_ccl_census_blocks)
    _saved=$(prologue_pushed_csrs "$_body" | wc -l | tr -d '[:space:]')
    if [ "$_saved" -lt 4 ]; then
        fail "csr-census-loop expected at least 4 pushed CSR homes, got $_saved"
    fi
    assert_pushed_csrs_named "$_body" csr-census-loop
    assert_call_alignment "$_body" "$_saved" csr-census-loop
    # The inner scan's two arms both call, so the loop is genuinely
    # call-carrying: without a call in the body the shape proves nothing. The
    # arms' own `ccl-bump` is inlined into the walk (as cg-census-blocks inlines
    # cg-census-bump-map), and what survives is its probe -- the same call the
    # benchmark's loop carries.
    assert_contains "$_body" 'call _tl_csr_census_loop_ccl_probe' csr-census-loop
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

# The prologue's total %rsp displacement D = 8*pushes + sub must satisfy
# D % 16 == 8 for a function that makes a returning call: the caller left %rsp
# 16-aligned at its `call`, the return address made it 8, and the callee's own
# calls have to land back on 0. Reading the number out of the emitted `subq`
# pins the invariant instead of one particular frame size.
assert_call_alignment() {
    _body=$1
    _pushes=$2
    _label=$3
    _sub=$(sed -n 's/^[[:space:]]*subq \$\([0-9][0-9]*\), %rsp$/\1/p' "$_body" | sed -n 1p)
    if [ -z "$_sub" ]; then
        fail "$_label expected a prologue stack adjustment and found none"
    fi
    if [ $(( (8 * _pushes + _sub) % 16 )) -ne 8 ]; then
        fail "$_label misaligned prologue: $_pushes pushes + subq \$$_sub"
    fi
}

# W1-frame: the frame adjust and the even-push alignment pad follow what the
# function actually needs. `dfb-forward` transfers only by a tail `jmp` and
# names no frame slot, so it owes nothing; `tl_dfb_abort_only` pushes an EVEN
# callee-saved run and its only `call` is the never-taken `tl_oob_abort` edge,
# so the pushes stay and the pad goes; `dfb-returning` makes an ordinary
# returning call and must keep both. Pre-change all three carried a
# `subq`/`addq` pair, so the first two assertions are proven forcing.
check_dead_frame_boundary() {
    _asm=$(compile_gate dead_frame_boundary tests/integration/dead_frame_boundary.tl)

    _fwd=$(function_body "$_asm" tl_dfb_forward)
    assert_contains "$_fwd" 'jmp _tl_dead_frame_boundary_dfb_sink' dead-frame-tail-forward
    assert_not_matches "$_fwd" '^[[:space:]]+call ' dead-frame-tail-forward
    assert_regex_count_eq "$_fwd" '^[[:space:]]+subq \$[0-9]+, %rsp$' 0 dead-frame-tail-forward
    assert_regex_count_eq "$_fwd" '^[[:space:]]+addq \$[0-9]+, %rsp$' 0 dead-frame-tail-forward

    _abort=$(function_body "$_asm" tl_dfb_abort_only)
    _abort_pushes=$(csr_pushed_count "$_abort" dead-frame-abort-only)
    if [ "$_abort_pushes" -lt 2 ] || [ $((_abort_pushes % 2)) -ne 0 ]; then
        fail "dead-frame-abort-only expected an even, non-empty CSR push run, got $_abort_pushes"
    fi
    assert_contains "$_abort" 'call tl_oob_abort' dead-frame-abort-only
    assert_regex_count_eq "$_abort" '^[[:space:]]+call ' 1 dead-frame-abort-only
    assert_regex_count_eq "$_abort" '^[[:space:]]+subq \$[0-9]+, %rsp$' 0 dead-frame-abort-only
    assert_regex_count_eq "$_abort" '^[[:space:]]+addq \$[0-9]+, %rsp$' 0 dead-frame-abort-only

    _ret=$(function_body "$_asm" _tl_dead_frame_boundary_dfb_returning)
    _ret_pushes=$(csr_pushed_count "$_ret" dead-frame-returning)
    assert_contains "$_ret" 'call _tl_dead_frame_boundary_dfb_probe' dead-frame-returning
    assert_call_alignment "$_ret" "$_ret_pushes" dead-frame-returning
}

# Win64 reserves 32 bytes of shadow space for EVERY call-shaped instruction,
# the `tl_oob_abort` edge and the tail target included
# (compiler-backend-outgoing-frame-space). That outgoing area is a genuine
# frame consumer, so none of the three functions above may lose its stack
# adjustment on this target -- and each one that makes a call must still land
# on D % 16 == 8. This is the per-target half of the W1-frame contract: the
# Linux gate above proves the adjust goes, this one proves Windows keeps it.
# The end-to-end half of the abort-only case: build the safety fixture at opt2
# and let the bounds check actually FIRE. `probe` reaches `tl_oob_abort_at`
# from a frame with an even push run and NO stack adjustment, i.e. with
# `%rsp % 16 == 0` where the SysV convention would have left 8. The located
# abort splitter (pushq/pushq/lea/popq/popq/call) then runs below that %rsp and
# has to render the site and exit 134 all the same. The safety corpus runs the
# same fixture, but only at its default optimisation level, where every local
# is a frame slot and the frameless shape cannot occur -- so this is the gate
# that proves the abort path itself.
check_dead_frame_abort_only_trap() {
    _src=tests/safety/dead_frame_abort_only_trap.tl
    _asm=$(compile_gate dead_frame_abort_only_trap "$_src")
    _probe=$(function_body "$_asm" _tl_dead_frame_abort_only_trap_probe)
    _pushes=$(csr_pushed_count "$_probe" dead-frame-abort-trap)
    if [ "$_pushes" -lt 2 ] || [ $((_pushes % 2)) -ne 0 ]; then
        fail "dead-frame-abort-trap expected an even, non-empty CSR push run, got $_pushes"
    fi
    assert_contains "$_probe" 'call tl_oob_abort_at' dead-frame-abort-trap
    assert_regex_count_eq "$_probe" '^[[:space:]]+subq \$[0-9]+, %rsp$' 0 dead-frame-abort-trap
    assert_regex_count_eq "$_probe" '^[[:space:]]+addq \$[0-9]+, %rsp$' 0 dead-frame-abort-trap

    _binary="$WORKDIR/dead_frame_abort_only_trap.bin"
    _build_out="$WORKDIR/dead_frame_abort_only_trap.build.stdout"
    _build_err="$WORKDIR/dead_frame_abort_only_trap.build.stderr"
    echo "[asm-shape] standalone opt2 trap run dead_frame_abort_only_trap" >&2
    if ! "$COMPILER" build "$ROOT/$_src" \
        --target linux-x86_64 \
        --opt-level 2 \
        --stdlib-root "$ROOT/stdlib" \
        --stdlib-root "$ROOT/src" \
        -o "$_binary" > "$_build_out" 2> "$_build_err"; then
        sed 's/^/  /' "$_build_out" >&2 || true
        sed 's/^/  /' "$_build_err" >&2 || true
        fail "dead-frame-abort-trap standalone build failed"
    fi
    _run_out="$WORKDIR/dead_frame_abort_only_trap.run.stdout"
    _run_err="$WORKDIR/dead_frame_abort_only_trap.run.stderr"
    _got=0
    "$_binary" > "$_run_out" 2> "$_run_err" || _got=$?
    if [ "$_got" -ne 134 ]; then
        sed 's/^/  /' "$_run_err" >&2 || true
        fail "dead-frame-abort-trap expected exit 134, got $_got"
    fi
    assert_contains "$_run_err" 'array index out of bounds: index=7 length=4' \
        dead-frame-abort-trap
}

check_dead_frame_boundary_win64() {
    _asm=$(compile_gate \
        dead_frame_boundary_win64 \
        tests/integration/dead_frame_boundary.tl \
        windows-x86_64)

    _fwd=$(function_body "$_asm" tl_dfb_forward)
    assert_contains "$_fwd" 'jmp _tl_dead_frame_boundary_dfb_sink' dead-frame-win64-tail-forward
    assert_call_alignment "$_fwd" 0 dead-frame-win64-tail-forward
    assert_contains "$_fwd" '.seh_stackalloc ' dead-frame-win64-tail-forward

    _abort=$(function_body "$_asm" tl_dfb_abort_only)
    assert_contains "$_abort" 'call tl_oob_abort' dead-frame-win64-abort-only
    assert_contains "$_abort" '.seh_stackalloc ' dead-frame-win64-abort-only

    _ret=$(function_body "$_asm" _tl_dead_frame_boundary_dfb_returning)
    _ret_pushes=$(csr_pushed_count "$_ret" dead-frame-win64-returning)
    assert_contains "$_ret" 'call _tl_dead_frame_boundary_dfb_probe' dead-frame-win64-returning
    assert_call_alignment "$_ret" "$_ret_pushes" dead-frame-win64-returning
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

# M6-I: a scalar global read folds into the compare's rip-relative memory
# operand. The read is `movq g(%rip), %rN` on both targets, so the fold and its
# spelling are target-independent and both are checked on both targets.
check_global_cmp_mem_fold() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "global_cmp_mem_fold_$_suffix" \
            tests/integration/global_cmp_mem_fold.tl "$_target")
        _lhs=$(function_body "$_asm" _tl_global_cmp_mem_fold_probe_lhs)
        _rhs=$(function_body "$_asm" _tl_global_cmp_mem_fold_probe_rhs)
        _refused=$(function_body "$_asm" _tl_global_cmp_mem_fold_probe_refused)

        # The cell is the compare's DESTINATION operand and nothing stages it
        # into a register first. Pre-change this body carried
        # `movq gcmp_gen(%rip), %r9 ; cmpq %rdi, %r9`, so both halves are
        # proven forcing.
        assert_regex_count_eq "$_lhs" \
            '^[[:space:]]+cmpq %r[a-z0-9]+, _tl_global_cmp_mem_fold_gcmp_gen\(%rip\)$' 1 \
            "global-cmp-mem-fold-lhs-$_target"
        assert_not_matches "$_lhs" \
            '^[[:space:]]+movq _tl_global_cmp_mem_fold_gcmp_gen\(%rip\), %r' \
            "global-cmp-mem-fold-lhs-$_target"
        # The flags the jcc reads are this compare's, with the sense the
        # unfolded form had: an equality test that jumps away when unequal.
        assert_next_line_matches "$_lhs" \
            'cmpq %r[a-z0-9]+, _tl_global_cmp_mem_fold_gcmp_gen[(]%rip[)]' \
            '^[[:space:]]+jne ' "global-cmp-mem-fold-lhs-$_target"

        # The mirror: the cell takes the AT&T SOURCE slot. The compare is
        # ORDERED, so a fold that exchanged the operands without swapping the
        # condition would invert the branch -- which is what the jcc pins.
        assert_regex_count_eq "$_rhs" \
            '^[[:space:]]+cmpq _tl_global_cmp_mem_fold_gcmp_limit\(%rip\), %r[a-z0-9]+$' 1 \
            "global-cmp-mem-fold-rhs-$_target"
        assert_not_matches "$_rhs" \
            '^[[:space:]]+movq _tl_global_cmp_mem_fold_gcmp_limit\(%rip\), %r' \
            "global-cmp-mem-fold-rhs-$_target"
        assert_next_line_matches "$_rhs" \
            'cmpq _tl_global_cmp_mem_fold_gcmp_limit[(]%rip[)], %r[a-z0-9]+' \
            '^[[:space:]]+jge ' "global-cmp-mem-fold-rhs-$_target"

        # Nearest refused neighbour: the read is bound to a local that is read
        # a second time, so the value must survive in a register and no
        # compare addresses the cell.
        assert_matches "$_refused" \
            '^[[:space:]]+movq _tl_global_cmp_mem_fold_gcmp_gen\(%rip\), %r' \
            "global-cmp-mem-fold-refused-$_target"
        assert_not_matches "$_refused" \
            '^[[:space:]]+cmpq .*_tl_global_cmp_mem_fold_gcmp_gen\(%rip\)' \
            "global-cmp-mem-fold-refused-$_target"
    done
}

# INL-6. The read-modify-write fold, asserted at the folded instruction rather
# than over a whole function body: the line before it must not load the cell and
# the line after must not store it, which is what "the triple collapsed to one
# memory-operand instruction" means locally. Reads of the same cell elsewhere in
# the file -- `main` printing it -- are not the claim and must not fail it.
assert_fold_triple_collapsed() {
    _file=$1
    _cell=$2
    _label=$3
    _bad=$(awk -v cell="_tl_rmw_mem_operand_fold_rmw_$_cell" '
        $0 ~ ("^[[:space:]]+(addq|subq|orq|andq|xorq) ([$][0-9-]+|%r[a-z0-9]+), " cell "\\(%rip\\)$") {
            if (prev ~ ("^[[:space:]]+movq " cell "\\(%rip\\), %r")) n++
            pending = 1
            prev = $0
            next
        }
        pending == 1 {
            if ($0 ~ ("^[[:space:]]+movq %r[a-z0-9]+, " cell "\\(%rip\\)$")) n++
            pending = 0
        }
        { prev = $0 }
        END { print n+0 }
    ' "$_file")
    if [ "$_bad" -ne 0 ]; then
        fail "$_label rmw_$_cell fold kept $_bad staging instruction(s) around it"
    fi
}

check_rmw_mem_operand_fold() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "rmw_mem_operand_fold_$_suffix" \
            tests/integration/rmw_mem_operand_fold.tl "$_target")
        # INL-5 for `rmw-bump-and-read`, INL-6 for `rmw-bump`: both are short
        # bodies whose only unwhitelisted instruction was the global-cell
        # `Store`, and both whitelists carry it now -- the single-block one
        # since INL-5 and the multiblock one since INL-6 -- so each is taken at
        # its single site and no out-of-line body survives to extract. The
        # claims below are about the FOLD, not about a function boundary: each
        # of the five cells is updated in exactly one place in the program and
        # `rmw-hits` in one more, so asserting them over the whole assembly
        # pins the same thing wherever the copies land.
        _bump=$_asm
        _read=$_asm

        # RMW-2: five `g = g op k` updates, five different ops, both operand
        # forms -- two immediates and three registers. Each was
        # `movq g(%rip),%rX ; op src,%rX ; movq %rX,g(%rip)` before the fold and
        # is ONE memory-operand instruction after it.
        # INL-6: named cell by cell rather than by prefix. With the bodies
        # absorbed the scan is over the whole assembly, where the prefix would
        # also match `rmw-hits` -- the read-after-write neighbour the block
        # below owns -- so each of the five updates is asserted on its own cell,
        # which is a stricter claim than the count ever was.
        for _cell in add sub or and xor; do
            assert_regex_count_eq "$_bump" \
                "^[[:space:]]+(addq|subq|orq|andq|xorq) ([$][0-9-]+|%r[a-z0-9]+), _tl_rmw_mem_operand_fold_rmw_$_cell\\(%rip\\)$" 1 \
                "rmw-mem-operand-fold-$_target"
        done
        # Nothing stages a cell into a register first: the load the fold
        # consumed is gone and so is the store that closed the triple. INL-6:
        # asserted AROUND the folded instruction rather than over the file,
        # because the body now lives in `main`, which legitimately reads all
        # five cells once at the end to print them. Neighbour lines are the
        # local reading of the same claim -- an unfolded triple is a load, the
        # op, and a store in three adjacent lines.
        for _cell in add sub or and xor; do
            assert_fold_triple_collapsed "$_bump" "$_cell" \
                "rmw-mem-operand-fold-$_target"
        done

        # The read-after-write neighbour. The update still folds -- the emitter
        # answers the read with a RELOAD rather than by keeping the register, so
        # the register dies at the store exactly as in the loop above -- and the
        # reload that follows reads back the cell the folded instruction wrote.
        # That ordering is the fold's correctness in one line: the memory write
        # must happen at the folded instruction, not later.
        assert_regex_count_eq "$_read" \
            '^[[:space:]]+addq %r[a-z0-9]+, _tl_rmw_mem_operand_fold_rmw_hits\(%rip\)$' 1 \
            "rmw-mem-operand-fold-read-$_target"
        assert_next_line_matches "$_read" \
            'addq %r[a-z0-9]+, _tl_rmw_mem_operand_fold_rmw_hits[(]%rip[)]' \
            '^[[:space:]]+movq _tl_rmw_mem_operand_fold_rmw_hits[(]%rip[)], %r' \
            "rmw-mem-operand-fold-read-$_target"
    done
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
    # The register-to-register copies left are the seed's entry home, the
    # accumulator's move into the return register, and the two the CHECKED
    # clone's preheader spends on `bounds_group`'s bound: that clone still runs
    # four checks of one index against four lengths, so the pass builds
    # `min(len_a, len_b, len_c, len_d)` there once as three compare/`cmov`
    # pairs, each staging its running minimum with one `movq`. The first of the
    # three lost a SECOND copy to SS-P5(b): its comparison feeds the select
    # directly, so the mask never materialises and the compare no longer stages
    # its LHS into the mask's home. The other two still materialise -- their
    # comparison reads the running minimum out of its SPILL SLOT, and the
    # flags path admits only register-homed or immediate operands. All four
    # sit outside both loops. A destination tied to the load instead would add
    # one staging copy per op INSIDE them, which is what the count guards and
    # what the two assertions above pin independently.
    assert_regex_count_eq "$_body" \
        '^[[:space:]]+movq %r[a-z0-9]+, %r[a-z0-9]+$' 4 alu-mem-operand-tie
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
    # The register-to-register copies left are the seed's entry home, the
    # accumulator's move into the return register, and the two the CHECKED
    # clone's preheader spends on `bounds_group`'s bound, exactly as in
    # `check_alu_mem_operand_tie` above: four checks of one index against four
    # lengths become one `min(len_a, len_b, len_c, len_d)` built there as three
    # compare/`cmov` pairs, each staging its running minimum with one `movq`,
    # of which the first also lost the mask-materialising copy to SS-P5(b).
    # All four are outside the loops; a wrong tie would put one staging copy per
    # op INSIDE them, which is what the two assertions above pin independently.
    assert_regex_count_eq "$_body"         '^[[:space:]]+movq %r[a-z0-9]+, %r[a-z0-9]+$' 4 alu-mem-operand-sink
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

check_checked_depth0_site() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "checked_depth0_site_$_suffix" \
            tests/integration/checked_depth0_site.tl "$_target")
        _probe=$(function_body "$_asm" _tl_checked_depth0_site_probe)

        # CB-2(c): the hash leaf's site is `probe`'s ENTRY block -- loop depth
        # zero -- and every static band refuses it there. Before CB-2 so did the
        # measured tier, on a site-depth clause that stood in for a plan model
        # which priced an allocation once per invocation. The plan now weights
        # each spill and carrier slot by the census depth weight of the blocks
        # it is touched in, the floor stands down where the composite frequency
        # already carries the evidence (`main` reaches `probe` through a loop),
        # and the verdict keeps this site: the call is gone and the leaf's own
        # body -- its FNV seed and its word loop -- is inside the caller.
        assert_not_matches "$_probe" \
            '^[[:space:]]+call _tl_checked_depth0_site_hash_words$' \
            "checked-depth0-site-$_target"
        assert_matches "$_probe" '^[[:space:]]+movq \$2166136261, %r' \
            "checked-depth0-site-$_target"
        assert_matches "$_probe" '^\.L[A-Za-z0-9_]+_inl\.' \
            "checked-depth0-site-$_target"

        # The tier COPIES a body into one site and leaves the callee reachable
        # from that site's siblings; the cold second reference still calls it.
        assert_matches "$_asm" '^_tl_checked_depth0_site_hash_words:$' \
            "checked-depth0-site-$_target"
        assert_regex_count_eq "$_asm" \
            '^[[:space:]]+call _tl_checked_depth0_site_hash_words$' 1 \
            "checked-depth0-site-$_target"
    done
}

check_checked_setup_helper() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "checked_setup_helper_$_suffix" \
            tests/integration/checked_setup_helper.tl "$_target")
        _main=$(function_body "$_asm" main)

        # The recorded loser's shape: a seven-parameter setup builder at the
        # ENTRY block of a caller that holds a hot loop, reached through a loop
        # of its own caller. The site-depth clause used to refuse it without
        # pricing it; it is offered to the verdict, and the verdict -- the
        # allocator's own estimator (INL-15) with the site's three literal
        # setup arguments priced as the fold they are (INL-18) -- keeps it, as
        # the smoke self-tests of this shape record; the loop-holding caller
        # is itself kept at `main`'s loop. The difference is visible only
        # here: absorbing the builder is correct, and an exit code cannot tell
        # the two apart. `--trace-passes` reports the numbers.
        assert_not_matches "$_asm" '^_tl_checked_setup_helper_run:$' \
            "checked-setup-helper-$_target"
        assert_matches "$_main" '^\.L[A-Za-z0-9_]+_inl\.' \
            "checked-setup-helper-$_target"
        # The tier COPIES the builder into the site and leaves it reachable
        # from its cold second reference, which still calls it: `rebuild` is
        # absorbed into `main` by the single-reference band, so that one call
        # is the only one the program makes.
        assert_matches "$_asm" '^_tl_checked_setup_helper_build_csr:$' \
            "checked-setup-helper-$_target"
        assert_regex_count_eq "$_asm" \
            '^[[:space:]]+call _tl_checked_setup_helper_build_csr$' 1 \
            "checked-setup-helper-$_target"
    done
}

check_checked_cheap_tier_claim() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "checked_cheap_tier_claim_$_suffix" \
            tests/integration/checked_cheap_tier_claim.tl "$_target")
        _probe=$(function_body "$_asm" _tl_checked_cheap_tier_claim_probe)

        # CB-2b: the measured tier CLAIMS `hash-words` at `probe`'s entry site
        # -- the relaxed depth floor is the only clause that admits it -- so the
        # FNV seed and the word loop are inside the caller.
        assert_not_matches "$_probe" \
            '^[[:space:]]+call _tl_checked_cheap_tier_claim_hash_words$' \
            "checked-cheap-tier-claim-$_target"
        assert_matches "$_probe" '^[[:space:]]+movq \$2166136261, %r' \
            "checked-cheap-tier-claim-$_target"

        # ...and the claim takes NOTHING away. `mix` is the four-site tiny leaf
        # the unmeasured bands inline for free, two of its sites inside this
        # very caller's loop: no call to it survives here...
        assert_not_matches "$_probe" \
            '^[[:space:]]+call _tl_checked_cheap_tier_claim_mix$' \
            "checked-cheap-tier-claim-$_target"
        # ...nor anywhere else in the program, and with all four sites inlined
        # the leaf keeps no out-of-line body at all.
        assert_regex_count_eq "$_asm" \
            '^[[:space:]]+call _tl_checked_cheap_tier_claim_mix$' 0 \
            "checked-cheap-tier-claim-$_target"
        assert_not_matches "$_asm" '^_tl_checked_cheap_tier_claim_mix:$' \
            "checked-cheap-tier-claim-$_target"

        # The claimed callee is COPIED, not absorbed: the cold second reference
        # in `checksum` still calls it, so the claim is a real one.
        assert_matches "$_asm" '^_tl_checked_cheap_tier_claim_hash_words:$' \
            "checked-cheap-tier-claim-$_target"
        assert_regex_count_eq "$_asm" \
            '^[[:space:]]+call _tl_checked_cheap_tier_claim_hash_words$' 1 \
            "checked-cheap-tier-claim-$_target"
    done
}

# INL-5. The inliner's instruction whitelist admits `Store` -- the write to a
# module global cell -- so a helper that advances a global CURSOR is inlinable.
# `gc-next` is `benchmarks/asm_render/bench.tl`'s `asm-tok-next` shape: one
# block that reads `tokens[cursor]` and bumps `cursor`, called from five sites,
# three of them inside `gc-run`'s loop.
check_global_cursor_helper() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "global_cursor_helper_$_suffix" \
            tests/integration/global_cursor_helper.tl "$_target")

        # No site keeps the boundary, and with every site inlined the helper
        # keeps no out-of-line body at all.
        assert_regex_count_eq "$_asm" \
            '^[[:space:]]+call _tl_global_cursor_helper_gc_next$' 0 \
            "global-cursor-helper-$_target"
        assert_not_matches "$_asm" '^_tl_global_cursor_helper_gc_next:$' \
            "global-cursor-helper-$_target"

        # INL-6: read out of `main`, not out of `gc-run`. With the MULTIBLOCK
        # whitelist carrying `Store` as well, the two callers that hold the
        # helper's copies -- `gc-run` and `gc-peek-pair` -- are themselves
        # inlinable and are absorbed into `main`, so all five copies live here.
        # The claims are the same claims, counted over the caller that now
        # holds them.
        _run=$(function_body "$_asm" main)

        # Five copies, one per site, each with its own freshened bounds
        # ok-label: the three in the loop and the two in the straight-line
        # pair.
        assert_regex_count_eq "$_run" \
            '^\.[A-Za-z0-9_.]*inl\.[A-Za-z0-9_.]*bounds_ok[A-Za-z0-9_.]*:$' 5 \
            "global-cursor-helper-$_target"

        # What the splice buys beyond the boundary: the token array's
        # descriptor -- the two global-cell words each site used to reload -- is
        # loop-invariant and is read ONCE per absorbed caller region, in the
        # loop's preheader and once more for the straight-line pair, with the
        # loop body addressing elements out of registers. Two, not five.
        assert_regex_count_eq "$_run" \
            '^[[:space:]]+movq _tl_global_cursor_helper_gc_tokens\(%rip\), %r' 2 \
            "global-cursor-helper-$_target"

        # The cursor write survived the clone at every site -- five stores to
        # the cell, one per copy, each writing a register rather than leaving
        # the cell to a call. A clone that dropped the store would leave fewer
        # here and every site would read position zero; a clone that duplicated
        # it would leave more and the run would skip tokens. The read side is
        # five matching reads plus `main`'s own read of the cursor for the last
        # printed line.
        assert_regex_count_eq "$_run" \
            '^[[:space:]]+movq %r[a-z0-9]+, _tl_global_cursor_helper_gc_cursor\(%rip\)$' 5 \
            "global-cursor-helper-$_target"
        assert_regex_count_eq "$_run" \
            '^[[:space:]]+movq _tl_global_cursor_helper_gc_cursor\(%rip\), %r' 6 \
            "global-cursor-helper-$_target"
    done
}

# INL-6. The inliner's instruction whitelists both carry `Store` now, and what
# had blocked the multiblock one was a cascade in the measured tier's RESCAN
# generation: `asm-bench` keeps `asm-round`, which moves `asm-round`'s
# straight-line call of `asm-fold-text` into `asm-bench`'s loop, and the bands
# then absorbed that 29-instruction BYTE LOOP into the merged caller. The
# accumulator lost its register there: the unrolled fold wrote it back to its
# home slot after every `xor` and every `imul` -- twenty times in the unrolled
# body -- `asm-bench` went from 9 frame-slot references to 74, and the row paid
# +33.5M. opt-inline-checked-rescan-loop-import? refuses that absorption.
#
# The claim pinned here is the REGISTER, not the inline decision, and it is
# spelled as the exact four-instruction signature of an accumulator that has no
# register at all:
#
#     xorq  %rN, %rACC
#     movq  %rACC, K(%rsp)
#     imulq %rM, %rACC
#     movq  %rACC, K(%rsp)
#
# A fold whose accumulator lives in a register produces neither store; a fold
# spilled ACROSS A CALL produces one store and no `xor`/`imul` pair around it,
# which is an ordinary and correct thing for the outer loop of `asm-bench` to
# do and is why the signature is four instructions rather than two. On the base
# compiler and on this one the whole asm_render assembly matches it zero times;
# with the absorption admitted it matches twenty.
#
# The benchmark itself is the fixture: the shape only exists at this size, and
# a mirror of it in tests/integration would pin a copy of the cascade rather
# than the cascade. Both targets are checked -- the register allocator's
# callee-saved set differs between them, so "the accumulator gets a register"
# is a separate fact on each.
assert_no_frame_homed_fold() {
    _asm=$1
    _label=$2
    _got=$(awk '
        /^[[:space:]]+xorq %r[a-z0-9]+, %r[a-z0-9]+$/ { acc=$3; state=1; next }
        state==1 && $0 ~ ("^[[:space:]]+movq " acc ", [0-9]+\\(%rsp\\)$") { state=2; next }
        state==2 && $0 ~ ("^[[:space:]]+imulq %r[a-z0-9]+, " acc "$") { state=3; next }
        state==3 && $0 ~ ("^[[:space:]]+movq " acc ", [0-9]+\\(%rsp\\)$") { n++; state=0; next }
        { state=0 }
        END { print n+0 }
    ' "$_asm")
    if [ "$_got" -ne 0 ]; then
        fail "$_label expected no frame-homed fold accumulator, got $_got"
    fi
}

check_asm_render_fold_accumulator() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "asm_render_fold_$_suffix" \
            benchmarks/asm_render/bench.tl "$_target")
        assert_no_frame_homed_fold "$_asm" "asm-render-fold-$_target"
    done
}

# INL-6. The multiblock companion of check_global_cursor_helper. `gcg-step` is
# `gc-next` with a guard in front of it -- a bounds ARM that returns a sentinel,
# then the read and the global cursor store -- so it is two blocks and its
# `Store` was refused by the MULTIBLOCK whitelist until this packet. Five sites
# across three functions, so the body is COPIED and every copy has to carry its
# own store.
#
# The three IN-LOOP sites take it and the two straight-line ones do not, which
# is the loop-bearing bounds band's own clause made visible: a bounds-carrying
# callee is absorbed where the boundary is repaid per iteration and left behind
# where it is repaid once. So `gcg-step` keeps an out-of-line body for the pair
# and `gcg-run` holds three copies with no call left in it.
check_global_cursor_guarded() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "global_cursor_guarded_$_suffix" \
            tests/integration/global_cursor_guarded.tl "$_target")

        _run=$(function_body "$_asm" _tl_global_cursor_guarded_gcg_run)

        # No boundary left in the loop.
        assert_regex_count_eq "$_run" \
            '^[[:space:]]+call _tl_global_cursor_guarded_gcg_step$' 0 \
            "global-cursor-guarded-$_target"

        # ...and the straight-line pair still calls it, so a body survives.
        assert_matches "$_asm" '^_tl_global_cursor_guarded_gcg_step:$' \
            "global-cursor-guarded-$_target"

        # Three copies landed in the loop, one per site, each with its own
        # freshened bounds ok-label -- the check that lives INSIDE the callee's
        # non-guard arm, which is what makes the abort twin a claim about a
        # spliced check rather than about the caller's own.
        assert_regex_count_eq "$_run" \
            '^\.[A-Za-z0-9_.]*inl\.[A-Za-z0-9_.]*bounds_ok[A-Za-z0-9_.]*:$' 3 \
            "global-cursor-guarded-$_target"

        # The cursor write survived the clone at every site: three stores to the
        # cell, one per copy, and the three matching reads that are the read
        # side of the same read-modify-write. A clone that dropped one would
        # leave every later site reading the same position and the printed fold
        # would change; a clone that duplicated one would skip a token.
        assert_regex_count_eq "$_run" \
            '^[[:space:]]+movq %r[a-z0-9]+, _tl_global_cursor_guarded_gcg_cursor\(%rip\)$' 3 \
            "global-cursor-guarded-$_target"
        assert_regex_count_eq "$_run" \
            '^[[:space:]]+movq _tl_global_cursor_guarded_gcg_cursor\(%rip\), %r' 3 \
            "global-cursor-guarded-$_target"

        # And the descriptor the three calls used to reload is read once, in
        # the preheader, exactly as in the single-block fixture.
        assert_regex_count_eq "$_run" \
            '^[[:space:]]+movq _tl_global_cursor_guarded_gcg_tokens\(%rip\), %r' 1 \
            "global-cursor-guarded-$_target"
    done
}

# INL-7. The hot-loop-leaf band's third site tier admits a cyclic, call-free
# body at a STRAIGHT-LINE site when the caller has no natural loop, on the
# argument that "the imported loop becomes the caller's only one". The inliner
# runs before the per-function pipeline, whose first pass (opt-tailrec-function)
# turns a SELF TAIL-CALL into a back edge -- so a self-tail-recursive caller
# reads as loop-free here and leaves the pipeline with a loop around its whole
# body, with the import inside it. opt-inline-caller-loop-free? refuses that.
#
# `sccp-rewrite-rows` is the measured case: the tail-recursive per-instruction
# rewrite driver of benchmarks/sccp_lattice, into which INL-6's multiblock
# `Store` admission let `sccp-rewrite-phi` (102 instructions, 26 blocks, one
# static reference, its own phi loop) be imported. Callgrind split the trade
# exactly -- `sccp_rewrite_rows` 32,885,952 -> 39,790,784 against
# `sccp_rewrite_phi` retiring 4,558,608 -- so the copy inside the loop ran
# 2,346,224 instructions more than the boundary it removed.
#
# Two claims, and the second is the one the row is about. The DECISION: the
# boundary survives and a body is still emitted for it. The FRAME: the merged
# driver went from ten frame-slot references to seventeen on linux and from 21
# to 28 on win64 -- the loop-carried accumulator, the row cursor and the tape
# base stopped holding registers across the imported loop. The bound is an
# upper one, set above what the driver spends without the import and below what
# it spends with it, so an unrelated allocator change does not land here.
#
# The benchmark itself is the fixture because the shape only exists at this
# size; tests/integration/recursive_loop_import.tl is the miniature, and
# check_recursive_loop_import below is its gate.
check_sccp_rewrite_phi_import() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        # INL-9 moved both bounds by twelve. `sccp-rewrite-rows` absorbs
        # `sccp-rewritten-i64`, and the dispatch reading gives that helper an
        # `sccp-env-tag-in` of its own at one arm of its tag `cond` -- a keep
        # worth -1,427,200 in `sccp_env_tag_in` against +948,048 in
        # `sccp_rewrite_rows`, whose extra frame traffic is exactly these twelve
        # references. The bound is what it was plus that import, with the same
        # two of headroom it always carried; what the gate is about --
        # `sccp-rewrite-phi` staying OUT of line and reached by exactly one call
        # -- is unchanged, and so is the row, which INL-9 moves -17,525,408.
        # SUM-6 moved both bounds by three more: the driver's loop calls
        # `sccp-rewrite-instr`, whose summary writes named cells beside its
        # element stores, and the new header-clean bit lets LICM hoist the
        # tape descriptor's length and data words out of the loop. The hoisted
        # words take three frame slots (25 references on linux, 36 on win64,
        # from 22 and 33); the row is -86,592 for it and the import decision
        # is what it was.
        _bound=27
        if [ "$_target" = windows-x86_64 ]; then
            _bound=38
        fi
        _asm=$(compile_gate "sccp_rewrite_phi_import_$_suffix" \
            benchmarks/sccp_lattice/bench.tl "$_target")

        # The body is still emitted, and the driver still reaches it by call.
        assert_matches "$_asm" '^_tl_bench_sccp_rewrite_phi:$' \
            "sccp-rewrite-phi-import-$_target"
        _rows=$(function_body "$_asm" _tl_bench_sccp_rewrite_rows)
        assert_regex_count_eq "$_rows" \
            '^[[:space:]]+call _tl_bench_sccp_rewrite_phi$' 1 \
            "sccp-rewrite-phi-import-$_target"

        # ...and the driver's own loop-carried values keep their registers.
        assert_regex_count_at_most "$_rows" '[-0-9]+\(%rsp\)' "$_bound" \
            "sccp-rewrite-phi-import-$_target"
    done
}

# INL-7. The miniature of the pair above, with both answers over ONE callee so
# the only thing that differs between them is the caller's own recursion.
# `rli-scan` is cyclic, call-free, 42 instructions in 8 blocks and writes a
# module global; `rli-rows` walks the tape by self tail-call and `rli-peek`
# does not call itself. Both callers carry a bounds check of their own, so the
# cascade clause is out of the comparison and only the recursion is in it.
#
# INL-11 rewrites the self tail call into a back edge BEFORE the inliner runs,
# so the recursion no longer differs: `rli-rows` presents its loop, the site
# reads in-loop, and the hot-loop-leaf band's in-loop tier prices the import
# there exactly as it does for a `while`-written driver -- and takes it, for
# the same 42-instruction leaf `rli-peek` takes. So both callers carry the
# copy, no call is left, and the callee -- referenced by nothing -- is not
# emitted at all. What the pair above still pins is the size half of the same
# question: `sccp-rewrite-phi` (102 instructions, 26 blocks) stays out of
# `sccp-rewrite-rows` under the in-loop tier's own gates, and that gate is
# unchanged.
check_recursive_loop_import() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "recursive_loop_import_$_suffix" \
            tests/integration/recursive_loop_import.tl "$_target")

        # No caller keeps a call, so no body is emitted for the callee.
        assert_not_matches "$_asm" '^_tl_recursive_loop_import_rli_scan:$' \
            "recursive-loop-import-$_target"

        # The driver, a loop once its self tail call is a back edge, takes the
        # copy: no call left, and the scan's fold landed in it. The FNV
        # multiplier is the callee's own constant and appears nowhere else in
        # the program.
        _rows=$(function_body "$_asm" _tl_recursive_loop_import_rli_rows)
        assert_regex_count_eq "$_rows" \
            '^[[:space:]]+call _tl_recursive_loop_import_rli_scan$' 0 \
            "recursive-loop-import-$_target"
        assert_regex_count_at_least "$_rows" '1099511628211' 1 \
            "recursive-loop-import-$_target"

        # The non-recursive caller at the same kind of site takes the copy as
        # it always did.
        _peek=$(function_body "$_asm" _tl_recursive_loop_import_rli_peek)
        assert_regex_count_eq "$_peek" \
            '^[[:space:]]+call _tl_recursive_loop_import_rli_scan$' 0 \
            "recursive-loop-import-$_target"
        assert_regex_count_at_least "$_peek" '1099511628211' 1 \
            "recursive-loop-import-$_target"
    done
}

check_synth_wrapped_probe() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "synth_wrapped_probe_$_suffix" \
            tests/integration/synth_wrapped_probe.tl "$_target")
        _get_or=$(function_body "$_asm" _tl_synth_wrapped_probe_sp_get_or)

        # INL-1: the accessor's site is at the ENTRY block of a wrapper two
        # straight-line call levels below a nested loop. On the census's own
        # one-level reference count that site reads as composite frequency one
        # and the measured tier refuses it; on the counts propagated over the
        # call graph it reads as the loop's own weight and the verdict keeps it.
        assert_not_matches "$_get_or" \
            '^[[:space:]]+call _tl_synth_wrapped_probe_sp_probe$' \
            "synth-wrapped-probe-$_target"
        # ...and the probe's own loop is what landed there: the wrap-around mask
        # and the Knuth multiplier of its first block.
        assert_matches "$_get_or" '2654435761' "synth-wrapped-probe-$_target"

        # The accessor is COPIED, not absorbed: the cold second reference in
        # `sp-contains?` still calls the out-of-line body, so the keep is a real
        # one and no single-site band could have taken it first.
        assert_matches "$_asm" '^_tl_synth_wrapped_probe_sp_probe:$' \
            "synth-wrapped-probe-$_target"
        assert_regex_count_eq "$_asm" \
            '^[[:space:]]+call _tl_synth_wrapped_probe_sp_probe$' 1 \
            "synth-wrapped-probe-$_target"

        # The inline retires no bounds check. Every load the accessor makes is
        # still checked inside the merged body, which is what the abort twin
        # (tests/integration/synth_wrapped_probe_abort.tl) then runs into.
        assert_regex_count_at_least "$_get_or" \
            '^[[:space:]]+call tl_oob_abort' 1 "synth-wrapped-probe-$_target"

        _abort_asm=$(compile_gate "synth_wrapped_probe_abort_$_suffix" \
            tests/integration/synth_wrapped_probe_abort.tl "$_target")
        _abort_get_or=$(function_body "$_abort_asm" \
            _tl_synth_wrapped_probe_abort_sp_get_or)
        assert_not_matches "$_abort_get_or" \
            '^[[:space:]]+call _tl_synth_wrapped_probe_abort_sp_probe$' \
            "synth-wrapped-probe-abort-$_target"
        assert_regex_count_at_least "$_abort_get_or" \
            '^[[:space:]]+call tl_oob_abort' 1 \
            "synth-wrapped-probe-abort-$_target"

        # ABT-1: every check in the merged body -- the caller's own and the two
        # the copied accessor brought with it -- reaches the LOCATED handler
        # with a site descriptor, and none of them the bare one. A clone that
        # lost its callee's span answers `call tl_oob_abort` here, which is what
        # `tl: array index out of bounds` at --opt-level 2 was.
        assert_regex_count_eq "$_abort_get_or" \
            '^[[:space:]]+call tl_oob_abort_at$' 3 \
            "synth-wrapped-probe-abort-$_target"
        assert_regex_count_eq "$_abort_get_or" \
            '^[[:space:]]+call tl_oob_abort$' 0 \
            "synth-wrapped-probe-abort-$_target"
        assert_regex_count_at_least "$_abort_asm" \
            '^\.L_tl_abort_site_[0-9]+_bounds:$' 3 \
            "synth-wrapped-probe-abort-$_target"
        # ...and the descriptor is cold data reached only past the check's own
        # fast branch: the merged body's compare/branch shape is what it was
        # before the site was armed, to the instruction.
        assert_regex_count_eq "$_abort_get_or" \
            '^[[:space:]]+cmpq ' 9 "synth-wrapped-probe-abort-$_target"
        assert_regex_count_eq "$_abort_get_or" \
            '^[[:space:]]+jb ' 3 "synth-wrapped-probe-abort-$_target"
        # ...and the folded checks' tails re-read the LENGTH through the first
        # staging push, never the index through the second one.
        assert_abort_tail_staging_push_not_memory "$_abort_get_or" \
            "synth-wrapped-probe-abort-$_target"
    done
}

check_synth_tail_wrapper() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "synth_tail_wrapper_$_suffix" \
            tests/integration/synth_tail_wrapper.tl "$_target")
        _slot_id=$(function_body "$_asm" _tl_synth_tail_wrapper_sp_slot_id)

        # INL-2: `sp-slot-id`'s whole body is `return sp-get-or(...)`, which
        # lowers to a direct tail call. The checked tier's multiblock path now
        # offers that site a verdict, and the verdict keeps it -- so the
        # wrapper neither calls nor jumps to the accessor it used to forward
        # to.
        assert_not_matches "$_slot_id" \
            '^[[:space:]]+call _tl_synth_tail_wrapper_sp_get_or$' \
            "synth-tail-wrapper-$_target"
        assert_not_matches "$_slot_id" \
            '^[[:space:]]+jmp _tl_synth_tail_wrapper_sp_get_or$' \
            "synth-tail-wrapper-$_target"
        # ...and what landed there is the accessor's own body, through the
        # wrapper the tail site copied: the probe's Knuth multiplier.
        assert_matches "$_slot_id" '2654435761' "synth-tail-wrapper-$_target"
        # The probe is not reached out of line from the merged body either.
        assert_not_matches "$_slot_id" \
            '^[[:space:]]+call _tl_synth_tail_wrapper_sp_probe$' \
            "synth-tail-wrapper-$_target"

        # The copied wrapper is COPIED, not absorbed: the cold second reference
        # in `main` still calls the out-of-line body, so the keep is a real one
        # and no single-site band could have taken it first.
        assert_matches "$_asm" '^_tl_synth_tail_wrapper_sp_get_or:$' \
            "synth-tail-wrapper-$_target"
        assert_regex_count_eq "$_asm" \
            '^[[:space:]]+call _tl_synth_tail_wrapper_sp_get_or$' 1 \
            "synth-tail-wrapper-$_target"

        # The splice retires no bounds check: every load the accessor makes is
        # still checked inside the merged body, which is what the abort twin
        # (tests/integration/synth_tail_wrapper_abort.tl) then runs into.
        assert_regex_count_at_least "$_slot_id" \
            '^[[:space:]]+call tl_oob_abort' 1 "synth-tail-wrapper-$_target"

        _abort_asm=$(compile_gate "synth_tail_wrapper_abort_$_suffix" \
            tests/integration/synth_tail_wrapper_abort.tl "$_target")
        _abort_slot_id=$(function_body "$_abort_asm" \
            _tl_synth_tail_wrapper_abort_sp_slot_id)
        assert_not_matches "$_abort_slot_id" \
            '^[[:space:]]+call _tl_synth_tail_wrapper_abort_sp_get_or$' \
            "synth-tail-wrapper-abort-$_target"
        assert_not_matches "$_abort_slot_id" \
            '^[[:space:]]+jmp _tl_synth_tail_wrapper_abort_sp_get_or$' \
            "synth-tail-wrapper-abort-$_target"
        assert_regex_count_at_least "$_abort_slot_id" \
            '^[[:space:]]+call tl_oob_abort' 1 \
            "synth-tail-wrapper-abort-$_target"

        # ABT-1, through the tail site's copy: same claim, same reason.
        assert_regex_count_eq "$_abort_slot_id" \
            '^[[:space:]]+call tl_oob_abort_at$' 3 \
            "synth-tail-wrapper-abort-$_target"
        assert_regex_count_eq "$_abort_slot_id" \
            '^[[:space:]]+call tl_oob_abort$' 0 \
            "synth-tail-wrapper-abort-$_target"
        assert_regex_count_at_least "$_abort_asm" \
            '^\.L_tl_abort_site_[0-9]+_bounds:$' 3 \
            "synth-tail-wrapper-abort-$_target"
        assert_regex_count_eq "$_abort_slot_id" \
            '^[[:space:]]+cmpq ' 9 "synth-tail-wrapper-abort-$_target"
        assert_regex_count_eq "$_abort_slot_id" \
            '^[[:space:]]+jb ' 3 "synth-tail-wrapper-abort-$_target"
        assert_abort_tail_staging_push_not_memory "$_abort_slot_id" \
            "synth-tail-wrapper-abort-$_target"
    done
}

check_synth_struct_accessor() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "synth_struct_accessor_$_suffix" \
            tests/integration/synth_struct_accessor.tl "$_target")
        _value=$(function_body "$_asm" _tl_synth_struct_accessor_sa_value)

        # INL-3: `sa-lookup-in` BUILDS a four-word value -- an `alloc` run, its
        # closing `addr_of`, the arms' stores and a `copy_bytes` into the
        # caller's sret buffer. The multiblock gate's whitelist refused `Alloc`
        # and `AddrOf`, so no site of it was ever priced. It is priced now, and
        # the verdict keeps it: the wrapper no longer calls the accessor.
        assert_not_matches "$_value" \
            '^[[:space:]]+call _tl_synth_struct_accessor_sa_lookup_in$' \
            "synth-struct-accessor-$_target"
        # ...and what landed there is the accessor's own body: `sa-value` makes
        # no table read of its own, so the only bounds check that can be inside
        # it is the one the spliced body brought with it.
        assert_regex_count_at_least "$_value" \
            '^[[:space:]]+call tl_oob_abort' 1 "synth-struct-accessor-$_target"

        # The accessor is COPIED, not absorbed: the cold second reference in
        # `sa-peek` still calls the out-of-line body, so the keep is a real one
        # and no single-site band could have taken it first.
        assert_matches "$_asm" '^_tl_synth_struct_accessor_sa_lookup_in:$' \
            "synth-struct-accessor-$_target"
        assert_regex_count_eq "$_asm" \
            '^[[:space:]]+call _tl_synth_struct_accessor_sa_lookup_in$' 1 \
            "synth-struct-accessor-$_target"

        _abort_asm=$(compile_gate "synth_struct_accessor_abort_$_suffix" \
            tests/integration/synth_struct_accessor_abort.tl "$_target")
        _abort_value=$(function_body "$_abort_asm" \
            _tl_synth_struct_accessor_abort_sa_value)
        assert_not_matches "$_abort_value" \
            '^[[:space:]]+call _tl_synth_struct_accessor_abort_sa_lookup_in$' \
            "synth-struct-accessor-abort-$_target"
        assert_regex_count_at_least "$_abort_value" \
            '^[[:space:]]+call tl_oob_abort' 1 \
            "synth-struct-accessor-abort-$_target"
    done
}

check_checked_arm_wrapper() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "checked_arm_wrapper_$_suffix" \
            tests/integration/checked_arm_wrapper.tl "$_target")
        _slot_id=$(function_body "$_asm" _tl_checked_arm_wrapper_aw_slot_id)

        # INL-4: `aw-slot-id` is `(if (< id 0) -1 (aw-get-or ...))`, so the
        # accessor call sits in an ARM of the entry branch whose sibling arm
        # returns a literal. The depth floor used to refuse that site for not
        # being the entry block; it now reads as entry-equivalent in this
        # wrapper-shaped caller, and the verdict keeps it -- so the arm neither
        # calls nor jumps to the wrapper it used to forward to.
        assert_not_matches "$_slot_id" \
            '^[[:space:]]+call _tl_checked_arm_wrapper_aw_get_or$' \
            "checked-arm-wrapper-$_target"
        assert_not_matches "$_slot_id" \
            '^[[:space:]]+jmp _tl_checked_arm_wrapper_aw_get_or$' \
            "checked-arm-wrapper-$_target"
        # ...and what landed there is the accessor's own body, through the
        # wrapper the arm site copied: the probe's Knuth multiplier.
        assert_matches "$_slot_id" '2654435761' "checked-arm-wrapper-$_target"
        # The probe is not reached out of line from the merged body either.
        assert_not_matches "$_slot_id" \
            '^[[:space:]]+call _tl_checked_arm_wrapper_aw_probe$' \
            "checked-arm-wrapper-$_target"

        # The copied wrapper is COPIED, not absorbed: the cold second reference
        # in `main` still calls the out-of-line body, so the keep is a real one
        # and no single-site band could have taken it first.
        assert_matches "$_asm" '^_tl_checked_arm_wrapper_aw_get_or:$' \
            "checked-arm-wrapper-$_target"
        assert_regex_count_eq "$_asm" \
            '^[[:space:]]+call _tl_checked_arm_wrapper_aw_get_or$' 1 \
            "checked-arm-wrapper-$_target"

        # The splice retires no bounds check: every load the accessor makes is
        # still checked inside the merged body, which is what the abort twin
        # (tests/integration/checked_arm_wrapper_abort.tl) then runs into.
        assert_regex_count_at_least "$_slot_id" \
            '^[[:space:]]+call tl_oob_abort' 1 "checked-arm-wrapper-$_target"

        _abort_asm=$(compile_gate "checked_arm_wrapper_abort_$_suffix" \
            tests/integration/checked_arm_wrapper_abort.tl "$_target")
        _abort_slot_id=$(function_body "$_abort_asm" \
            _tl_checked_arm_wrapper_abort_aw_slot_id)
        assert_not_matches "$_abort_slot_id" \
            '^[[:space:]]+call _tl_checked_arm_wrapper_abort_aw_get_or$' \
            "checked-arm-wrapper-abort-$_target"
        assert_not_matches "$_abort_slot_id" \
            '^[[:space:]]+jmp _tl_checked_arm_wrapper_abort_aw_get_or$' \
            "checked-arm-wrapper-abort-$_target"
        assert_regex_count_at_least "$_abort_slot_id" \
            '^[[:space:]]+call tl_oob_abort' 1 \
            "checked-arm-wrapper-abort-$_target"
    done
}

check_checked_post_multi_call() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "checked_post_multi_call_$_suffix" \
            tests/integration/checked_post_multi_call.tl "$_target")
        _lookup=$(function_body "$_asm" _tl_checked_post_multi_call_pm_lookup)

        # INL-8: the accessor's site is the merge below `pm-lookup`'s guard,
        # which POST-DOMINATES the entry, in a caller that is straight-line but
        # carries `pm-crowded?` and `pm-penalty` of its own. The caller clause
        # used to refuse that reading on the call COUNT -- the census line ended
        # `site-depth` with `pos` reading `none` and no verdict was priced --
        # and now asks the caller's LOOPS instead, which a straight-line caller
        # has none of. The verdict keeps the site, so the merge holds no call to
        # the accessor at all. This is callgraph_scc's `cg-map-probe` into
        # `cg-map-insert-ref!`, mirrored: the row's largest single gap to C.
        assert_matches "$_asm" '^_tl_checked_post_multi_call_pm_lookup:$' \
            "checked-post-multi-call-$_target"
        assert_not_matches "$_lookup" \
            '^[[:space:]]+call _tl_checked_post_multi_call_pm_probe$' \
            "checked-post-multi-call-$_target"
        assert_not_matches "$_lookup" \
            '^[[:space:]]+jmp _tl_checked_post_multi_call_pm_probe$' \
            "checked-post-multi-call-$_target"
        # ...and what landed there is the accessor's own LOOP: the probe's Knuth
        # multiplier, inside the caller's body.
        assert_matches "$_lookup" '2654435761' "checked-post-multi-call-$_target"

        # The accessor is COPIED, not absorbed: the cold second reference still
        # calls the out-of-line body, so the keep is a real one and no
        # single-site band could have taken it first.
        assert_matches "$_asm" '^_tl_checked_post_multi_call_pm_probe:$' \
            "checked-post-multi-call-$_target"

        # The splice retires no bounds check: every load the accessor makes is
        # still checked inside the merged body, which is what the abort twin
        # (tests/integration/checked_post_multi_call_abort.tl) then runs into.
        assert_regex_count_at_least "$_lookup" \
            '^[[:space:]]+call tl_oob_abort' 1 \
            "checked-post-multi-call-$_target"

        _abort_asm=$(compile_gate "checked_post_multi_call_abort_$_suffix" \
            tests/integration/checked_post_multi_call_abort.tl "$_target")
        _abort_lookup=$(function_body "$_abort_asm" \
            _tl_checked_post_multi_call_abort_pm_lookup)
        assert_not_matches "$_abort_lookup" \
            '^[[:space:]]+call _tl_checked_post_multi_call_abort_pm_probe$' \
            "checked-post-multi-call-abort-$_target"
        assert_regex_count_at_least "$_abort_lookup" \
            '^[[:space:]]+call tl_oob_abort' 1 \
            "checked-post-multi-call-abort-$_target"
    done
}

check_checked_dispatch_arm() {
    for _target in linux-x86_64 windows-x86_64; do
        _suffix=$(printf '%s' "$_target" | tr -c 'A-Za-z0-9_' '_')
        _asm=$(compile_gate "checked_dispatch_arm_$_suffix" \
            tests/integration/checked_dispatch_arm.tl "$_target")
        _dispatch=$(function_body "$_asm" _tl_checked_dispatch_arm_da_dispatch)

        # INL-9: `da-dispatch` is a five-case `cond` whose spine -- the entry
        # block and the else-blocks under it -- only compares and branches, and
        # four of whose arms call `da-fold`. Only the FIRST arm is a successor
        # of the entry branch, so the arm reading covered one of the four and
        # the other three read `pos=none` for want of a reading rather than for
        # a clause; the caller clause the arm reading carries is hopeless here
        # anyway, since a dispatch holds one call per arm. The dispatch reading
        # takes all four, and the verdict keeps all four, so no arm of this
        # function holds a call to the helper at all.
        assert_matches "$_asm" '^_tl_checked_dispatch_arm_da_dispatch:$' \
            "checked-dispatch-arm-$_target"
        assert_not_matches "$_dispatch" \
            '^[[:space:]]+call _tl_checked_dispatch_arm_da_fold$' \
            "checked-dispatch-arm-$_target"
        assert_not_matches "$_dispatch" \
            '^[[:space:]]+jmp _tl_checked_dispatch_arm_da_fold$' \
            "checked-dispatch-arm-$_target"

        # ...and what landed in the arms is the helper's own arithmetic: its
        # two bounds-checked table reads, once per arm, all four arms.
        assert_regex_count_at_least "$_dispatch" \
            '^[[:space:]]+call tl_oob_abort_at' 8 \
            "checked-dispatch-arm-$_target"

        # The helper is COPIED, not absorbed: the cold second reference still
        # calls the out-of-line body, so the keep is a real one and no
        # single-site band could have taken it first.
        assert_matches "$_asm" '^_tl_checked_dispatch_arm_da_fold:$' \
            "checked-dispatch-arm-$_target"

        _abort_asm=$(compile_gate "checked_dispatch_arm_abort_$_suffix" \
            tests/integration/checked_dispatch_arm_abort.tl "$_target")
        _abort_dispatch=$(function_body "$_abort_asm" \
            _tl_checked_dispatch_arm_abort_da_dispatch)
        assert_not_matches "$_abort_dispatch" \
            '^[[:space:]]+call _tl_checked_dispatch_arm_abort_da_fold$' \
            "checked-dispatch-arm-abort-$_target"
        assert_regex_count_at_least "$_abort_dispatch" \
            '^[[:space:]]+call tl_oob_abort_at' 8 \
            "checked-dispatch-arm-abort-$_target"
    done
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
    # #6288: `%rbp` is a VALUE home here. Its add-immediate must use the
    # structurally distinct no-base SIB spelling so the final rsp frame rebase
    # cannot turn `acc + 31` into a frame address.
    assert_matches "$_body" '^[[:space:]]+leaq 31\(,%rbp,1\), %r[a-z0-9]+$' rbp-sixth-csr
    assert_not_contains "$_body" 'leaq 31(%rsp)' rbp-sixth-csr
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
    #
    # INL-6 absorbed `mix-writing` into this scan (its only unwhitelisted
    # instruction was that `set!`, the global-cell `Store` the MULTIBLOCK
    # whitelist refused until then) and the gate read four occurrences: the
    # absorbed body's own read and write beside the loop's two. INL-17c puts
    # the boundary back: `writer-scan` is a self-tail-recursive caller whose
    # loop opt-tailrec builds from that call, and the checked tier refuses a
    # loop-carrying callee at every site of such a caller
    # (opt-inline-checked-clause-converted-caller; the measured case is
    # `sccp-rewrite-phi` into `sccp-rewrite-rows`, check_sccp_rewrite_phi_import).
    # The claim is unchanged: the cell is WRITTEN inside the loop, so nothing
    # about it is invariant, and every read stays a read -- two per iteration
    # around the surviving call, never one preheader load -- while the write
    # stays inside the callee.
    assert_fixed_count_eq "$_writer" "${_sym}_gcell_c(%rip)" 2 licm-memclean-promote
    assert_regex_count_eq "$_writer" \
        "^[[:space:]]+movq %r[a-z0-9]+, ${_sym}_gcell_c\\(%rip\\)$" 0 \
        licm-memclean-promote
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

# The block that starts at the labelled line whose text contains $2 and runs to
# the next label definition.
labeled_block() {
    _file=$1
    _suffix=$2
    _out="$WORKDIR/$(basename "$_file").$(printf '%s' "$_suffix" | tr -c 'A-Za-z0-9' '_')"
    awk -v suffix="$_suffix" '
        started && /^[^[:blank:]]*:$/ { exit }
        started { print }
        !started && /:$/ && index($0, suffix) { started = 1 }
    ' "$_file" > "$_out"
    printf '%s\n' "$_out"
}

# The block's indexed 8-byte memory traffic as one string, in emission order:
# `L` for a load out of an indexed slot, `S` for a store into one. It is the
# ORDER, not the counts, that an overlapping copy depends on.
memory_order_signature() {
    awk '
        /^[[:space:]]+movq -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$/ {
            printf "L"; next
        }
        /^[[:space:]]+movq %r[a-z0-9]+, -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$/ {
            printf "S"; next
        }
        END { printf "\n" }
    ' "$1"
}

# UNR-2: the DESCENDING counted loop the unroller now admits. `ud-shift-words!`
# is an overlapping shift -- it reads slot `c` and writes slot `c + 3` walking
# downward -- and every access in its body is a 64-bit word through a
# 64-bit-element gep, so it takes the word-merge tier's K=4 exactly as the
# ascending merge does. What is pinned:
#
#   * the unrolled group holds FOUR shifted moves per `add`/`cmp`/`jge`, and
#     its counter steps by -4;
#   * the group's memory traffic is LSLSLSLS -- copy j's store never precedes a
#     load of a copy emitted before it, which is what makes an overlapping copy
#     come out right (the group's fourth copy stores into the slot its first
#     copy read);
#   * the guard computes `floor + 4` with a `leaq 4(...)`, the mirror of the
#     ascending guard's `bound - K`, and not a subtraction;
#   * the one-at-a-time remainder loop is still there, stepping by -1.
check_descending_shift_unroll() {
    _asm=$(compile_gate descending_shift_unroll \
        tests/integration/unroll_descending_shift.tl)
    _fn=$(function_body "$_asm" _tl_unroll_descending_shift_ud_shift_words_bang)
    _group=$(unroll_body_block "$_fn")
    assert_regex_count_eq "$_group" \
        '^[[:space:]]+movq %r[a-z0-9]+, -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' 4 \
        descending-shift-unroll-k4-stores
    assert_regex_count_eq "$_group" \
        '^[[:space:]]+movq -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' 4 \
        descending-shift-unroll-k4-loads
    assert_contains "$_group" 'addq $-4,' descending-shift-unroll-k4-step
    assert_regex_count_eq "$_group" '^[[:space:]]+jge ' 1 \
        descending-shift-unroll-one-latch
    _order=$(memory_order_signature "$_group")
    if [ "$_order" != LSLSLSLS ]; then
        fail "descending-shift-unroll group memory order is $_order, want LSLSLSLS"
    fi
    _guard=$(labeled_block "$_fn" '__unroll_guard:')
    assert_matches "$_guard" 'leaq 4\(%r' descending-shift-unroll-guard-adds
    assert_not_matches "$_guard" 'subq \$4,' descending-shift-unroll-guard-not-sub
    # The remainder loop stays exactly as it was: one shifted move per step.
    assert_contains "$_fn" 'subq $1,' descending-shift-unroll-remainder
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
    # SAME loop written over `(__tl_dyn-array u8)`. It is still the load-and-store class,
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

check_copy_call_word() {
    _asm=$(compile_gate copy_call_word tests/integration/copy_call_word.tl)
    # copy_call's EIGHT-BYTE tier: `dst[i] = src[i]` over i64 elements becomes
    # ONE `tl_mem_copy8_fwd` call and no loop at all. The unrolled body it
    # pre-empts is the word-merge K=4 group checked just above, at 11
    # instructions per four elements; the call is 4 plus one `rep movsq`
    # iteration per element. Correctness of the call cannot be seen here -- the
    # manifest case is the runtime twin -- but a missed rewrite is invisible to
    # an exit code, which is why the shape is pinned.
    # The unrolled fast body is GONE, not merely supplemented. Each dynamic
    # kernel keeps exactly ONE element-wise store -- the CHECKED slow path, which
    # this pass deliberately leaves alone so a program that would abort mid-copy
    # still aborts at the same element. Before this tier existed each of them had
    # six: four in the unrolled group, one in its remainder, one checked.
    for _kernel in copy_words shift_up shift_down; do
        _body=$(function_body "$_asm" "_tl_copy_call_word_$_kernel")
        assert_fixed_count_eq "$_body" 'call tl_mem_copy8_fwd' 1 \
            "copy-call-word-$_kernel"
        assert_regex_count_eq "$_body" \
            '^[[:space:]]+movq %r[a-z0-9]+, -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' 1 \
            "copy-call-word-$_kernel-checked-store-only"
    done
    # The fixed-size pair have statically provable lengths, so no checked path
    # survives at all and the whole function is the call.
    for _kernel in copy_fixed8 copy_fixed4; do
        _body=$(function_body "$_asm" "_tl_copy_call_word_$_kernel")
        assert_fixed_count_eq "$_body" 'call tl_mem_copy8_fwd' 1 \
            "copy-call-word-$_kernel"
        assert_regex_count_eq "$_body" \
            '^[[:space:]]+movq %r[a-z0-9]+, -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' 0 \
            "copy-call-word-$_kernel-no-element-store"
    done
    # The count is the ELEMENT count, handed over as-is: a literal trip count of
    # eight becomes `movl $8, %edx`, not $64. A byte count here would copy an
    # eighth of the range.
    _fixed8=$(function_body "$_asm" _tl_copy_call_word_copy_fixed8)
    assert_contains "$_fixed8" 'movl $8, %edx' copy-call-word-slot-count
    # REFUSED, and both refusals must keep their loops. `copy_fixed3` is ONE trip
    # below the pass's slot floor -- its admitted neighbour `copy_fixed4` is
    # right above -- and `copy_halfwords` is u32, a width with no total
    # forward-copy helper at all.
    for _kernel in copy_fixed3 copy_halfwords; do
        _body=$(function_body "$_asm" "_tl_copy_call_word_$_kernel")
        assert_not_contains "$_body" 'call tl_mem_copy8_fwd' \
            "copy-call-word-$_kernel-refused"
        assert_not_contains "$_body" 'call tl_mem_copy_fwd' \
            "copy-call-word-$_kernel-refused-byte"
    done
    # The byte tier still names the BYTE helper: the two widths are separate
    # symbols because their counts and their overlap granularity differ.
    _bytes=$(function_body "$_asm" _tl_copy_call_word_copy_bytes)
    assert_fixed_count_eq "$_bytes" 'call tl_mem_copy_fwd' 1 copy-call-word-byte-tier
    assert_not_contains "$_bytes" 'call tl_mem_copy8_fwd' copy-call-word-byte-tier
    # The runtime helper itself: the propagating overlap gets a SCALAR
    # eight-byte forward loop, not the wide `rep movsq`. No program run can tell
    # the two apart on a machine whose REP MOVS honours element granularity, so
    # this is the only place the arm's existence is pinned.
    assert_contains "$_asm" '.Ltl_mem_copy8_fwd_loop:' copy-call-word-helper-scalar-arm
    assert_contains "$_asm" '    rep movsq' copy-call-word-helper-wide-arm
    # And the row the tier exists for: peephole_lines' inlined 25-element
    # `pl-copy-line`, which paid 14.68M instructions as a K=4 unrolled loop.
    _bench=$(compile_gate copy_call_word_peephole benchmarks/peephole_lines/bench.tl)
    _chunk=$(function_body "$_bench" _tl_bench_pl_run_chunk)
    assert_fixed_count_eq "$_chunk" 'call tl_mem_copy8_fwd' 2 copy-call-word-peephole
    assert_fixed_count_eq "$_chunk" 'movl $25, %edx' 2 copy-call-word-peephole-count
}

# A3: the unsigned range-check merge. `(and (>= i 0) (< i n))` is two compares
# and two conditional branches for a question one unsigned compare answers, and
# `bounds_dom` merges them whenever `n` is provably non-negative. Both halves of
# the verdict are pinned on one fixture: `literal_window`'s bound is a literal,
# so it merges outright; `paired_window` is the straight-line `and`-chain whose
# FIRST guard has nothing bounding `n` (it must keep the two-compare form) and
# whose SECOND is proved by the first through the fact chain (it must merge).
#
# Pre-change both functions carry `testq %rX, %rX` + a signed `jl` in front of a
# signed length compare; the sign test is what goes.
# DCE-2: the call-free flag loop. Its exit join is a phi of bool literals over
# a phi of i64 literals, decided on every edge; the final slot below `cmp_dup`
# is what retires it. If either the sweep or the threading above it stops
# running, `main` grows back the dead `movq $-1` it never reads and the
# `movl $1 ; testq ; je` that branches on a constant.
# On windows-x86_64 the last emitted function carries no `.size` directive and
# the hand-written runtime prelude that follows it opens with an INDENTED
# `.globl`, so `extract_function` runs on past the body. Cut it at the SEH
# epilogue marker, which is where the function proper ends.
truncate_at_seh_endproc() {
    _seh_body=$1
    _seh_out="$_seh_body.seh"
    awk '{ print } /^[[:space:]]*\.seh_endproc$/ { exit }' "$_seh_body" \
        > "$_seh_out"
    printf '%s\n' "$_seh_out"
}

# ALIAS-1: the descending shift loop over a MODULE-GLOBAL vector.
#
# `a[i + 3] = a[i]` walked downward is `rg-union-insert-segment!`'s shift, and
# three separate verdicts have to hold for it to reach its five-instruction
# form. The loop's only write is a scalar element store through the data
# pointer the global's descriptor holds, so LICM lifts the cell load, the
# length and the data pointer into the preheader BEFORE `bce_version` runs
# (opt-licm-header-slot-gep?'s `Global` arm); the versioner then reads an
# invariant length off a descending counter and mints a fast clone with
# neither bounds check; and `gep_offset` folds the loop-invariant base into the
# clone's own preheader so the two accesses share one index register, the write
# reaching its slot as a +24 displacement.
#
# The block extracted here is the self-looping `__bce_fast` body that carries
# that displacement -- the only loop in the fixture that writes one -- and what
# is pinned is what each verdict buys: no rip-relative reload of the cell, no
# check, one load and one displaced store off the same base and index.
extract_fast_self_loop_with() {
    _body=$1
    _needle=$2
    _out="$_body.fastloop"
    awk -v needle="$_needle" '
        /__bce_fast:$/ {
            label = $0
            sub(/:$/, "", label)
            inblk = 1
            buf = ""
            hit = 0
            next
        }
        inblk {
            buf = buf $0 "\n"
            if (index($0, needle) > 0) { hit = 1 }
            if (index($0, label) > 0) {
                if (hit) { printf "%s", buf }
                inblk = 0
            } else if ($0 ~ /^\.L/) {
                inblk = 0
            }
        }
    ' "$_body" > "$_out"
    printf '%s\n' "$_out"
}

# ALIAS-2: the descriptor chain of a global whose program overflows the packed
# per-global rows. `aro-scan` reads two global cells and calls a store-free leaf
# every trip; before the overflow bit both rows were declined for the whole
# program and both cells were re-read inside the loop.
check_alias_row_overflow() {
    _asm=$(compile_gate alias_row_overflow tests/integration/alias_row_overflow.tl)
    _sym=_tl_alias_row_overflow
    _body=$(function_body "$_asm" "${_sym}_aro_scan")
    # One read per cell in the whole function...
    assert_fixed_count_eq "$_body" "${_sym}_aro_edge(%rip)" 1 alias-row-overflow
    assert_fixed_count_eq "$_body" "${_sym}_aro_mark(%rip)" 1 alias-row-overflow
    # ...and it is in the PREHEADER: nothing rip-relative for either cell
    # survives from the loop's first block onward.
    _loop="$WORKDIR/alias_row_overflow.loop"
    awk '
        inblk { print }
        /^\.L[A-Za-z0-9_.]*while_body\.1[A-Za-z0-9_.]*:$/ { inblk = 1 }
    ' "$_body" > "$_loop"
    [ -s "$_loop" ] || fail "alias-row-overflow found no loop body"
    assert_not_contains "$_loop" "${_sym}_aro_edge(%rip)" alias-row-overflow
    assert_not_contains "$_loop" "${_sym}_aro_mark(%rip)" alias-row-overflow
    # The call the chain has to survive is still inside the loop: this is a
    # claim about invariance across a call, not about a call-free loop.
    assert_contains "$_loop" "call ${_sym}_aro_marked_question" alias-row-overflow
}

# ALIAS-3: the `*-scan-ints` tokenizer. Its loop reads three words of the
# object the `(&mut Vec)` parameter designates on every trip -- the `slots`
# handle at `*out + 0`, that descriptor's length word and its data pointer --
# and its only write is an element store through the buffer they name. The
# element store writes an `i64`; the `slots` read is a descriptor-handle word,
# a different alias class, so no store in the loop can reach it and the whole
# chain leaves. Before the rule all three reloaded every trip.
check_alias_typed_word() {
    _asm=$(compile_gate alias_typed_word tests/integration/alias_typed_word.tl)
    _body=$(function_body "$_asm" _tl_alias_typed_word_atw_scan_ints)
    # The three reads are in the loop's PREHEADER...
    _pre="$WORKDIR/alias_typed_word.pre"
    awk '
        /^\.L[A-Za-z0-9_.]*:$/ { inblk = 0 }
        /^\.L[A-Za-z0-9_.]*while_header\.0__rotate_land:$/ { inblk = 1; next }
        inblk { print }
    ' "$_body" > "$_pre"
    [ -s "$_pre" ] || fail "alias-typed-word found no loop preheader"
    assert_regex_count_eq "$_pre" \
        '^[[:space:]]+movq (8)?\(%r[a-z0-9]+\), %r[a-z0-9]+$' 3 alias-typed-word
    # ...and nothing from the loop's first block onward reloads a descriptor
    # word of either parameter.
    _loop="$WORKDIR/alias_typed_word.loop"
    awk '
        inblk { print }
        /^\.L[A-Za-z0-9_.]*while_body\.1:$/ { inblk = 1 }
    ' "$_body" > "$_loop"
    [ -s "$_loop" ] || fail "alias-typed-word found no loop body"
    assert_regex_count_eq "$_loop" \
        '^[[:space:]]+movq (8)?\(%r[a-z0-9]+\), %r[a-z0-9]+$' 0 alias-typed-word
    # The element store itself is still in the loop, with its bounds check: this
    # is a claim about the loads that survive a store, not about a store-free
    # loop.
    assert_regex_count_eq "$_loop" \
        '^[[:space:]]+movq %r[a-z0-9]+, \(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' 1 \
        alias-typed-word
    assert_contains "$_loop" 'call tl_oob_abort_at' alias-typed-word
}

check_alias_global_shift() {
    _asm=$(compile_gate alias_global_shift tests/integration/alias_global_shift.tl)
    _body=$(function_body "$_asm" main)
    _fast=$(extract_fast_self_loop_with "$_body" ', 24(')
    if [ ! -s "$_fast" ]; then
        fail "alias-global-shift found no versioned shift loop with a folded +24 store"
    fi
    # The global's cell is read once, in the preheader: nothing rip-relative
    # survives in the loop body.
    assert_not_contains "$_fast" '_tl_alias_global_shift_al_vec(%rip)' \
        alias-global-shift
    # Both checks left with the clone.
    assert_not_contains "$_fast" 'call tl_oob_abort' alias-global-shift
    assert_regex_count_eq "$_fast" '^[[:space:]]+j(ae|b) ' 0 alias-global-shift
    # One load and one store, sharing one base and one index register, the
    # element offset folded into the store's displacement.
    assert_regex_count_eq "$_fast" \
        '^[[:space:]]+movq \(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' 1 \
        alias-global-shift
    assert_regex_count_eq "$_fast" \
        '^[[:space:]]+movq %r[a-z0-9]+, 24\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' 1 \
        alias-global-shift
    # ...and the descending latch, with no address arithmetic left over.
    assert_regex_count_eq "$_fast" '^[[:space:]]+leaq ' 0 alias-global-shift
    assert_matches "$_fast" '^[[:space:]]+subq \$1, %r[a-z0-9]+$' \
        alias-global-shift
}

# VT-1: the two multi-block recoveries the refusal census turned up, pinned on
# the shapes they exist for.
#
# `extract_fast_region_with` takes the RUN of consecutive `__bce_fast` blocks
# the multi-block versioner mints -- its clone is a region, not a self-loop, so
# ALIAS-1's single-block extractor above does not see it -- and stops at the
# first block that is not part of the clone.
extract_fast_region_with() {
    _body=$1
    _needle=$2
    _out="$_body.fastregion"
    awk -v needle="$_needle" '
        /__bce_fast[^:]*:$/ {
            if (!inblk) { inblk = 1; buf = ""; hit = 0 }
            next
        }
        inblk && /^\.L/ {
            if (index($0, "__bce_fast") > 0) { next }
            if (hit) { printf "%s", buf; inblk = 0; exit }
            inblk = 0
            next
        }
        inblk {
            buf = buf $0 "\n"
            if (index($0, needle) > 0) { hit = 1 }
        }
        END { if (inblk && hit) printf "%s", buf }
    ' "$_body" > "$_out"
    printf '%s\n' "$_out"
}

# The copy loop whose TEST reads `src + i`. Without the offset recovery no
# counter is found at all (`--trace-passes` says `shape:not-a-counter`) and both
# checks run every trip; with it the counter's limit is `stop - src`, computed
# once in the guard, and the clone is a load, an add and a store off one base.
check_vt_offset_copy() {
    _asm=$(compile_gate vt_offset_copy tests/integration/vt_offset_copy.tl)
    _body=$(function_body "$_asm" main)
    _fast=$(extract_fast_region_with "$_body" ',8), %r')
    if [ ! -s "$_fast" ]; then
        fail "vt-offset-copy found no versioned copy loop"
    fi
    # Neither check survives in the clone.
    assert_not_contains "$_fast" 'call tl_oob_abort' vt-offset-copy
    assert_regex_count_eq "$_fast" '^[[:space:]]+j(ae|b) ' 0 vt-offset-copy
    # One indexed load and one indexed store, off the same data pointer.
    assert_regex_count_eq "$_fast" \
        '^[[:space:]]+movq \(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' 1 \
        vt-offset-copy
    assert_regex_count_eq "$_fast" \
        '^[[:space:]]+movq %r[a-z0-9]+, \(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' 1 \
        vt-offset-copy
    # ...and the guard names the subtracted limit.
    assert_matches "$_body" '^[[:space:]]+subq %r[a-z0-9]+, %r[a-z0-9]+$' \
        vt-offset-copy
}

# The strided scan whose index is strength-reduced into a step-3 cursor phi.
# Without the derived-induction arm the variable-base recovery sees a Phi and
# derives nothing (`--trace-passes` says `guard:derived-zero`); with it the two
# accesses are one derived family and reach their slots as +8 and +16
# displacements off one base and one index.
check_vt_derived_stride() {
    _asm=$(compile_gate vt_derived_stride tests/integration/vt_derived_stride.tl)
    _body=$(function_body "$_asm" main)
    _fast=$(extract_fast_region_with "$_body" 'movq 8(%r')
    if [ ! -s "$_fast" ]; then
        fail "vt-derived-stride found no versioned strided scan"
    fi
    assert_not_contains "$_fast" 'call tl_oob_abort' vt-derived-stride
    assert_regex_count_eq "$_fast" '^[[:space:]]+j(ae|b) ' 0 vt-derived-stride
    assert_regex_count_eq "$_fast" \
        '^[[:space:]]+movq 8\(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$' 1 \
        vt-derived-stride
    assert_regex_count_eq "$_fast" \
        '^[[:space:]]+movq %r[a-z0-9]+, 16\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$' 1 \
        vt-derived-stride
    # The cursor keeps its own literal step; the counter keeps its unit one.
    assert_matches "$_fast" '^[[:space:]]+addq \$3, %r[a-z0-9]+$' \
        vt-derived-stride
    assert_matches "$_fast" '^[[:space:]]+addq \$1, %r[a-z0-9]+$' \
        vt-derived-stride
}

check_dce_late_flag_loop() {
    _asm=$(compile_gate dce_late_flag_loop tests/integration/dce_late_flag_loop.tl)
    _body=$(function_body "$_asm" main)
    assert_no_literal_then_test "$_body" dce-late-flag-loop
    assert_no_literal_then_redef "$_body" dce-late-flag-loop
    assert_not_matches "$_body" '^[[:space:]]+movq \$-1, %[a-z0-9]+$' dce-late-flag-loop
    _win_asm=$(compile_gate dce_late_flag_loop_win64 \
        tests/integration/dce_late_flag_loop.tl windows-x86_64)
    _win_body=$(truncate_at_seh_endproc "$(function_body "$_win_asm" main)")
    assert_no_literal_then_test "$_win_body" dce-late-flag-loop-win64
    assert_no_literal_then_redef "$_win_body" dce-late-flag-loop-win64
    assert_not_matches "$_win_body" '^[[:space:]]+movq \$-1, %[a-z0-9]+$' \
        dce-late-flag-loop-win64
}

check_range_merge_unsigned() {
    _asm=$(compile_gate range_merge_unsigned tests/integration/range_merge_unsigned.tl)
    _lit=$(function_body "$_asm" _tl_range_merge_unsigned_literal_window)
    # One unsigned compare, no sign test, no signed length compare.
    assert_matches "$_lit" '^[[:space:]]+cmpq \$16, %r[a-z0-9]+$' range-merge-unsigned
    assert_matches "$_lit" '^[[:space:]]+jae ' range-merge-unsigned
    assert_not_matches "$_lit" '^[[:space:]]+testq %r[a-z0-9]+, %r[a-z0-9]+$' range-merge-unsigned
    assert_not_matches "$_lit" '^[[:space:]]+j(l|ge) ' range-merge-unsigned

    _paired=$(function_body "$_asm" _tl_range_merge_unsigned_paired_window)
    # The first guard stays signed (one sign test, one signed compare); the
    # second is the merged unsigned one.
    assert_regex_count_eq "$_paired" '^[[:space:]]+testq %r[a-z0-9]+, %r[a-z0-9]+$' 1 range-merge-unsigned
    assert_regex_count_eq "$_paired" '^[[:space:]]+jae ' 1 range-merge-unsigned
    # The signed guard's two jumps may spell either polarity (the shrink-wrap
    # arm layout inverts them); what is pinned is that exactly two SIGNED
    # jumps survive alongside the one unsigned jae.
    assert_regex_count_eq "$_paired" '^[[:space:]]+j(l|ge) ' 2 range-merge-unsigned
    assert_regex_count_eq "$_paired" '^[[:space:]]+cmpq %r[a-z0-9]+, %r[a-z0-9]+$' 2 range-merge-unsigned

    # The cached-length global: nothing in this function bounds `rm-len`, so
    # only the whole-program non-negativity table can merge it. One compare
    # straight against the cell, an unsigned jump, and no sign test.
    _global=$(function_body "$_asm" _tl_range_merge_unsigned_global_window)
    assert_matches "$_global" '^[[:space:]]+cmpq _tl_range_merge_unsigned_rm_len\(%rip\), %r[a-z0-9]+$' range-merge-unsigned
    assert_regex_count_eq "$_global" '^[[:space:]]+jae ' 1 range-merge-unsigned
    assert_not_matches "$_global" '^[[:space:]]+testq %r[a-z0-9]+, %r[a-z0-9]+$' range-merge-unsigned
    assert_not_matches "$_global" '^[[:space:]]+j(l|ge) ' range-merge-unsigned
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

# T1-6 (a): System V red-zone leaf frames. A Linux function with no RETURNING
# call and a frame that fits (with the body's own transient stack depth) inside
# the ABI's 128 reserved bytes addresses its slots at NEGATIVE displacements
# from %rsp and emits no stack adjustment at all. The gate pins all four sides
# of the rule on one fixture: the red-zone leaf, the over-128 leaf that must
# keep its adjust, the call-bearing function that must keep its adjust, and the
# abort-site leaf, whose located `tl_oob_abort_at` splitter stages its two
# reported values with `pushq`/`popq` BELOW %rsp. That last one is the whole
# soundness question, and ABT-1 answers it differently than the anchor did: the
# staging pushes are on an edge that ends in a call which never returns to this
# function, so the slots they overwrite are dead and the slot region is no
# longer pushed below them -- `rzl-abort` starts at -8 exactly like the
# push-free `rzl-slots`. What the overlap needs instead is that nothing is READ
# from that window afterwards: the pops read only the tail's own two words, and
# the one operand read after %rsp has moved -- the second push's -- is never
# memory. The runtime halves are the red_zone_leaf / red_zone_abort_ok /
# red_zone_abort_trap manifest cases; the trap case runs the abort edge itself.
# SS-P5 (T2-4): the flags-driven select and the staged gep's direct index.
# tests/integration/select_flags_lea.tl carries both shapes; its runtime half
# is the select_flags_lea manifest case, which checks every answer.
#
# (b)/(c) A scalar Select fed by the comparison immediately in front of it, with
# no other reader of the mask, must read that comparison's own EFLAGS. The join
# is then `mov ; cmp ; cmov<cc>` plus the allocator's spill store -- four
# instructions -- against the seven the materialising form spent: the mask
# built with `mov ; cmp ; setcc ; movzbq` and then RE-tested with
# `mov ; testq ; cmovne`. So: no `setcc`, no `movzbq` OF A BYTE REGISTER (the
# byte LOADS in sfl-scales are the other `movzbq` and are not this), no
# `cmovne` (the mask test's own condition code), and every `cmov` sitting
# directly under its own `cmp` -- which is what rules the `testq` re-test out
# too, since a `cmov` under a `testq` fails that. A blanket `testq` count would
# not do: the loop's own `n > 0` entry guard is one.
# The mnemonic itself pins the condition-code table: signed `min` is `cmovl`,
# signed `max` is `cmovg`, unsigned `min` is `cmovb` -- an inverted or
# wrong-signedness entry assembles perfectly and only shows up as a wrong
# answer, which is what the runtime case is for.
#
# (a) A variable-index gep whose base is spilled goes through the staged
# emitter. `addq idx, base` and `leaq (base,idx,s), base` only READ the index,
# so a register-homed index needs no staging copy -- and the copy was not free:
# with the scratch occupied it dragged an emergency save/restore behind it.
# assert_no_staged_index_copy pins the exact pair over the WHOLE fixture,
# register names and all: 8 of them before the change, none after.
assert_no_staged_index_copy() {
    _file=$1
    _label=$2
    _got=$(awk '
        {
            if (prev ~ /^[[:space:]]+movq %r[a-z0-9]+, %r[a-z0-9]+$/) {
                split(prev, p, ", ")
                reg = p[2]
                if ($0 ~ ("^[[:space:]]+addq " reg ", %r")) n++
                else if ($0 ~ ("^[[:space:]]+leaq \\(%r[a-z0-9]+," reg ",[1248]\\), %r")) n++
            }
            prev = $0
        }
        END { print n + 0 }
    ' "$_file")
    if [ "$_got" -ne 0 ]; then
        fail "$_label expected no staged gep index copy, got $_got"
    fi
}

# Every `cmov` in the body must be the line directly under a `cmp`: that is the
# whole content of "reads the comparison's own flags". A `cmov` under anything
# else is reading flags this gate cannot account for.
assert_cmov_reads_cmp() {
    _file=$1
    _label=$2
    if ! awk '
        /^[[:space:]]+cmov/ {
            n++
            if (prev !~ /^[[:space:]]+cmp[bwlq] /) bad = 1
        }
        { prev = $0 }
        END { exit (bad || n == 0) ? 1 : 0 }
    ' "$_file"; then
        fail "$_label expected every cmov directly under its cmp"
    fi
}

check_select_flags_lea() {
    _asm=$(compile_gate select_flags_lea tests/integration/select_flags_lea.tl)

    for _case in tl_sfl_min_scan:cmovl tl_sfl_max_scan:cmovg tl_sfl_umin_scan:cmovb; do
        _fn=${_case%:*}
        _cc=${_case#*:}
        _body=$(function_body "$_asm" "$_fn")
        assert_regex_count_eq "$_body" '^[[:space:]]+set[a-z]+ ' 0 "select-flags-$_fn"
        assert_regex_count_eq "$_body" '^[[:space:]]+movzbq %r[a-z0-9]+b, ' 0 \
            "select-flags-$_fn"
        assert_regex_count_eq "$_body" '^[[:space:]]+cmovne ' 0 "select-flags-$_fn"
        # The loop is versioned, so the join is emitted once per version.
        assert_regex_count_eq "$_body" "^[[:space:]]+$_cc " 2 "select-flags-$_fn"
        assert_regex_count_eq "$_body" '^[[:space:]]+cmov' 2 "select-flags-$_fn"
        assert_cmov_reads_cmp "$_body" "select-flags-$_fn"
    done

    # The staged gep keeps no copy of a register-homed index, at any scale.
    assert_no_staged_index_copy "$_asm" select-flags-gep
    _scales=$(function_body "$_asm" tl_sfl_scales)
    assert_matches "$_scales" '^[[:space:]]+leaq \(%r[a-z0-9]+,%r[a-z0-9]+,8\), ' \
        select-flags-scales
    assert_matches "$_scales" '^[[:space:]]+leaq \(%r[a-z0-9]+,%r[a-z0-9]+,4\), ' \
        select-flags-scales
    assert_matches "$_scales" '^[[:space:]]+leaq \(%r[a-z0-9]+,%r[a-z0-9]+,2\), ' \
        select-flags-scales
    _copy=$(function_body "$_asm" tl_sfl_copy)
    assert_matches "$_copy" '^[[:space:]]+addq %r[a-z0-9]+, %r[a-z0-9]+$' \
        select-flags-copy
}

check_red_zone_leaf() {
    _asm=$(compile_gate red_zone_leaf tests/integration/red_zone_leaf.tl)

    # (a) call-free leaf, frame inside the red zone: no adjust, slots negative.
    _slots=$(function_body "$_asm" tl_rzl_slots)
    assert_regex_count_eq "$_slots" '^[[:space:]]+call ' 0 red-zone-slots
    assert_regex_count_eq "$_slots" '^[[:space:]]+subq \$[0-9]+, %rsp$' 0 red-zone-slots
    assert_regex_count_eq "$_slots" '^[[:space:]]+addq \$[0-9]+, %rsp$' 0 red-zone-slots
    # Three distinct spill slots, all below %rsp and inside the 128-byte zone.
    _neg=$(grep -oE -- '-[0-9]+\(%rsp\)' "$_slots" | sort -u | wc -l)
    if [ "$_neg" -lt 3 ]; then
        fail "red-zone-slots expected at least 3 distinct negative %rsp slots, got $_neg"
    fi
    assert_matches "$_slots" '[-]8\(%rsp\)' red-zone-slots
    assert_not_matches "$_slots" '[-](1[3-9][0-9]|[2-9][0-9][0-9])\(%rsp\)' red-zone-slots
    assert_not_matches "$_slots" '\(%rbp\)' red-zone-slots

    # (b) the same shape with a frame LARGER than the red zone keeps its adjust.
    _big=$(function_body "$_asm" tl_rzl_big)
    assert_regex_count_eq "$_big" '^[[:space:]]+call ' 0 red-zone-big
    assert_regex_count_eq "$_big" '^[[:space:]]+subq \$[0-9]+, %rsp$' 1 red-zone-big
    assert_not_matches "$_big" '[-][0-9]+\(%rsp\)' red-zone-big

    # (c) a returning call keeps the frame and the adjust.
    _call=$(function_body "$_asm" tl_rzl_call)
    assert_regex_count_at_least "$_call" '^[[:space:]]+call ' 1 red-zone-call
    assert_regex_count_eq "$_call" '^[[:space:]]+subq \$[0-9]+, %rsp$' 1 red-zone-call
    assert_not_matches "$_call" '[-][0-9]+\(%rsp\)' red-zone-call

    # (d) abort-site leaf: red zone used, and the staging pushes cost it nothing.
    _abort=$(function_body "$_asm" tl_rzl_abort)
    assert_contains "$_abort" 'call tl_oob_abort_at' red-zone-abort
    assert_regex_count_eq "$_abort" '^[[:space:]]+call ' 1 red-zone-abort
    assert_regex_count_eq "$_abort" '^[[:space:]]+subq \$[0-9]+, %rsp$' 0 red-zone-abort
    assert_regex_count_eq "$_abort" '^[[:space:]]+addq \$[0-9]+, %rsp$' 0 red-zone-abort
    _abort_neg=$(grep -oE -- '-[0-9]+\(%rsp\)' "$_abort" | sort -u | wc -l)
    if [ "$_abort_neg" -lt 1 ]; then
        fail "red-zone-abort expected live negative %rsp slots, got $_abort_neg"
    fi
    # ABT-1: the two staging pushes are on the never-returning edge, so the
    # slot region is NOT anchored below them any more -- this leaf starts its
    # slots at -8 exactly like the push-free rzl-slots, instead of spending 16
    # bytes of its 128 to arm a diagnostic that cannot return. What makes the
    # overlap sound is that the only operand read after the first push is the
    # second one, and that one is never memory.
    assert_matches "$_abort" '[-]8\(%rsp\)' red-zone-abort-guard
    assert_abort_tail_staging_push_not_memory "$_abort" red-zone-abort-guard
    assert_not_matches "$_abort" '[-](1[3-9][0-9]|[2-9][0-9][0-9])\(%rsp\)' red-zone-abort
}

# Windows has NO red zone: the same source compiled for Win64 must keep every
# stack adjustment and address every slot at a non-negative displacement.
check_red_zone_leaf_win64() {
    _asm=$(compile_gate red_zone_leaf_win64 tests/integration/red_zone_leaf.tl \
        windows-x86_64)
    for _fn in tl_rzl_slots tl_rzl_big tl_rzl_abort; do
        _body=$(function_body "$_asm" "$_fn")
        assert_regex_count_at_least "$_body" '^[[:space:]]+subq \$[0-9]+, %rsp$' 1 \
            "red-zone-win64-$_fn"
        assert_not_matches "$_body" '[-][0-9]+\(%rsp\)' "red-zone-win64-$_fn"
    done
}

# SCR-1. Sixteen hoisted data pointers exceed the pool, the greedy spills the
# rest, and every store through a spilled pointer must reload it into a scratch
# register. With every pool register live across the loop the scavenger used to
# BORROW one per store and bracket it with a save and a restore (the XMM park),
# and the staged store copied the resident index into a second borrowed
# register: seven instructions per store. The scratch-reserve round prices the
# parks off the plan and replans with %r11 reserved, and the staged store reads
# the index home in place. The body must carry no park, and the spilled
# pointers must be reloaded through %r11 straight into a store.
check_scratch_reserve_zero_fill() {
    _asm=$(compile_gate scratch_reserve_zero_fill tests/integration/scratch_reserve_zero_fill.tl)
    _reset=$(function_body "$_asm" _tl_scratch_reserve_zero_fill_reset_arrays_bang)
    assert_regex_count_eq "$_reset" '^[[:space:]]+movq %r[a-z0-9]+, %xmm[0-9]+$' 0 scratch-reserve-zero-fill
    assert_regex_count_at_least "$_reset" '^[[:space:]]+movq [0-9]+\(%rsp\), %r11$' 4 scratch-reserve-zero-fill
    assert_regex_count_at_least "$_reset" '^[[:space:]]+movq \$(0|-1), \(%r11,%r[a-z0-9]+,8\)$' 4 scratch-reserve-zero-fill
}

check_lattice_join_split
check_short_trip_copy
check_select_flags_lea
check_mem_dest_rmw_fold
check_word_merge_unroll
check_descending_shift_unroll
check_copy_call_word
check_divmagic_hoist
check_hoist_priority
check_lftr_counter_retire
check_fallthrough_jmp_chain
check_jump_only_forward
check_block_layout
check_wide_const_hoist
check_group_pair_home
check_group_pair_phi_home
check_csr_push_prologue
check_csr_unused_save
check_csr_census_loop
check_dead_frame_boundary
check_dead_frame_abort_only_trap
check_dead_frame_boundary_win64
check_red_zone_leaf
check_red_zone_leaf_win64
check_save_reload_elide
check_global_handle_cse
check_loadcse_forward
check_switch_dispatch_scavenge
check_cmp_fold_load
check_global_cmp_mem_fold
check_rmw_mem_operand_fold
check_alu_mem_operand_tie
check_alu_mem_operand_sink
check_checked_depth0_site
check_checked_setup_helper
check_checked_cheap_tier_claim
check_global_cursor_helper
check_global_cursor_guarded
check_asm_render_fold_accumulator
check_sccp_rewrite_phi_import
check_recursive_loop_import
check_synth_wrapped_probe
check_synth_tail_wrapper
check_synth_struct_accessor
check_checked_arm_wrapper
check_checked_post_multi_call
check_checked_dispatch_arm
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
check_range_merge_unsigned
check_dce_late_flag_loop
check_alias_global_shift
check_alias_row_overflow
check_alias_typed_word
check_vt_offset_copy
check_vt_derived_stride
check_scratch_reserve_zero_fill

echo "Assembly shape gates passed."
