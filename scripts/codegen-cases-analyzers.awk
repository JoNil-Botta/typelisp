# codegen-cases-analyzers.awk - named assembly analyzers for
# scripts/verify-codegen-cases.sh.
#
#   CC_ARG=ARG awk -v analyzer=NAME -f scripts/codegen-cases-analyzers.awk FILE
#
# A metric (`metric NAME[:ARG] OP VALUE`) prints one value. A window
# (`narrow NAME[:ARG]`, analyzer=window-NAME) prints the selected lines. ARG is
# read from the environment so regular expressions keep their backslashes.

{ L[NR] = $0 }

function label_of(s) { return substr(s, 1, length(s) - 1) }

function is_label(s) { return s ~ /^[^[:blank:]:]+:$/ }

# ------------------------------------------------------------------ metrics

# Direct branches to a label defined earlier in the body: a loop back edge
# however the optimizer spelled it (jmp or a rotated conditional branch).
function backward_branches(   i, n, f) {
    for (i = 1; i <= NR; i++) {
        if (is_label(L[i])) { seen[label_of(L[i])] = 1; continue }
        if (L[i] ~ /^[[:blank:]]+j[a-z]+[[:blank:]]+[^[:blank:]*%(,]+$/) {
            split(L[i], f)
            if (f[2] in seen) n++
        }
    }
    return n + 0
}

# `jmp L` whose target is reached by falling through label definitions only --
# the shape the assembled-body peephole deletes.
function fallthrough_jmps(   i, n, pending, target) {
    for (i = 1; i <= NR; i++) {
        if (pending) {
            if (L[i] ~ /^[^[:blank:]:]+:$/) {
                if (label_of(L[i]) == target) { n++; pending = 0 }
                continue
            }
            pending = 0
        }
        if (L[i] ~ /^    jmp [^[:blank:]*%(,]+$/) {
            pending = 1
            target = substr(L[i], 9)
        }
    }
    return n + 0
}

# Branches into a block that emits nothing but one `jmp` (jump forwarding
# retires these); a lone jmp back to its own label is a self-loop, not counted.
function jumps_into_jump_only_blocks(   i, j, k, l, n, t, target) {
    for (i = 1; i <= NR; i++)
        if (is_label(L[i])) at[label_of(L[i])] = i
    for (l in at) {
        i = at[l] + 1
        while (i <= NR && is_label(L[i])) i++
        if (i > NR || L[i] !~ /^    jmp [^[:blank:]*%(,]+$/) continue
        target = substr(L[i], 9)
        if (target == l) continue
        j = i + 1
        if (j > NR || is_label(L[j]) || L[j] ~ /^[[:space:]]*\./) solo[l] = 1
    }
    for (k = 1; k <= NR; k++)
        if (L[k] ~ /^    j[a-z]+ [^[:blank:]*%(,]+$/) {
            t = L[k]
            sub(/^    j[a-z]+ /, "", t)
            if (t in solo) n++
        }
    return n + 0
}

# `jmp L` whose only preceding lines back to `L:` are label definitions.
function self_loop_jmps(   i, n, depth, target, d) {
    for (i = 1; i <= NR; i++) {
        if (is_label(L[i])) { run[++depth] = label_of(L[i]); continue }
        if (L[i] ~ /^    jmp [^[:blank:]*%(,]+$/) {
            target = substr(L[i], 9)
            for (d = 1; d <= depth; d++)
                if (run[d] == target) { n++; break }
        }
        depth = 0
    }
    return n + 0
}

# Compares that read back a frame slot an earlier line of the same block wrote
# from a register.
function store_then_cmp_same_slot(   i, n, f, slot) {
    for (i = 1; i <= NR; i++) {
        if (is_label(L[i])) { for (slot in stored) delete stored[slot]; continue }
        if (L[i] ~ /^    movq %[a-z0-9]+, -?[0-9]+\(%rsp\)$/) { split(L[i], f); stored[f[3]] = 1; continue }
        if (L[i] ~ /^    cmpq -?[0-9]+\(%rsp\), %[a-z0-9]+$/) {
            split(L[i], f)
            slot = f[2]
            sub(/,$/, "", slot)
            if (slot in stored) n++
        }
    }
    return n + 0
}

# Adjacent GP copy chains `movq SRC, TMP; movq TMP, %rax`.
function copy_chains_to_rax(   i, n, f, source, previous, previous_dst) {
    for (i = 1; i <= NR; i++) {
        if (L[i] ~ /^    movq %[a-z0-9]+, %[a-z0-9]+$/) {
            split(L[i], f)
            source = f[2]
            sub(/,$/, "", source)
            if (previous && source == previous_dst && f[3] == "%rax") n++
            previous = 1
            previous_dst = f[3]
        } else {
            previous = 0
            previous_dst = ""
        }
    }
    return n + 0
}

# Located abort tails whose staging push right before the descriptor `leaq`
# reads memory.
function abort_staging_push_from_memory(   i, n) {
    for (i = 2; i <= NR; i++)
        if (L[i] ~ /^[[:space:]]+leaq \.L_tl_abort_site_/ && L[i - 1] ~ /^[[:space:]]+pushq [-0-9]*\(%/) n++
    return n + 0
}

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

function test_reg(line,   parts) {
    if (line ~ /^test[bwlq][ \t]+%[a-z0-9]+,[ \t]*%[a-z0-9]+$/) {
        split(line, parts, /[ \t,]+/)
        if (norm(parts[2]) == norm(parts[3])) return norm(parts[2])
    }
    return ""
}

# A register loaded with a literal and then TESTED (want = "test") or
# REDEFINED (want = "redef") on the next line.
function literal_then(want,   i, n, line, pending, got) {
    pending = ""
    for (i = 1; i <= NR; i++) {
        line = L[i]
        sub(/^[ \t]+/, "", line)
        sub(/[ \t]+$/, "", line)
        got = (want == "test") ? test_reg(line) : literal_dst(line)
        if (pending != "" && got == pending) n++
        pending = literal_dst(line)
    }
    return n + 0
}

# Callee-saved registers the prologue pushes: the pushq run before the first
# inner label (abort sites marshal their own pushq/popq pairs).
function prologue_csrs(out,   i, n, r) {
    for (i = 2; i <= NR; i++) {
        if (L[i] ~ /:[[:space:]]*$/) break
        if (L[i] ~ /^[[:space:]]+pushq %(r1[2-5]|rbx|rbp)$/) {
            r = L[i]
            sub(/^[[:space:]]+pushq %/, "", r)
            out[++n] = r
        }
    }
    return n + 0
}

function count_fixed(text,   i, n) {
    for (i = 1; i <= NR; i++) if (index(L[i], text)) n++
    return n + 0
}

# Pushed callee-save homes over the whole body; "unbalanced-REG" when a
# register's pushes and pops differ or it is pushed twice.
function csr_pushes(   regs, k, r, pushes, pops, saved) {
    split("r12 r13 r14 r15 rbx rbp", regs, " ")
    for (k = 1; k <= 6; k++) {
        r = regs[k]
        pushes = count_fixed("pushq %" r)
        pops = count_fixed("popq %" r)
        if (pushes != pops || pushes > 1) return "unbalanced-" r
        saved += pushes
    }
    return saved + 0
}

# "even" or "odd" pushed callee-save homes ("unbalanced-REG" as above).
function csr_pushes_parity(   saved) {
    saved = csr_pushes()
    if (saved !~ /^[0-9]+$/) return saved
    return (saved % 2 == 0) ? "even" : "odd"
}

# Prologue-pushed callee-saved registers the body never names at any width
# (frame operands `K(%rbp)` are not a use; the restore does not count).
function unnamed_pushed_csrs(   n, k, r, pat, i, line, mentions, bad) {
    n = prologue_csrs(pushed)
    for (k = 1; k <= n; k++) {
        r = pushed[k]
        if (r == "rbx") pat = "%rbx|%ebx|%bx|%bl"
        else if (r == "rbp") pat = "%rbp|%ebp|%bp|%bpl"
        else pat = "%" r
        mentions = 0
        for (i = 1; i <= NR; i++) {
            line = L[i]
            gsub(/[-0-9]*\(%r[bs]p[^)]*\)/, "FRAME", line)
            if (line ~ pat && line !~ ("^[[:space:]]+popq %" r "$")) mentions++
        }
        if (mentions <= 1) bad++
    }
    return bad + 0
}

function first_stack_sub(   i, v) {
    for (i = 1; i <= NR; i++)
        if (L[i] ~ /^[[:space:]]*subq \$[0-9]+, %rsp$/) {
            v = L[i]
            sub(/^[[:space:]]*subq \$/, "", v)
            sub(/, %rsp$/, "", v)
            return v
        }
    return ""
}

function count_regex(re,   i, n) {
    for (i = 1; i <= NR; i++) if (L[i] ~ re) n++
    return n + 0
}

# D = 8 * pushes + prologue sub must be 8 mod 16 so the body's calls stay
# 16-byte aligned. ARG is a push count, "prologue" (prologue pushes) or
# "pushes" (balanced pushes over the body).
function call_alignment(spec,   pushes, sub_) {
    if (spec == "prologue") pushes = prologue_csrs(unused)
    else if (spec == "pushes") pushes = csr_pushes()
    else pushes = spec + 0
    if (pushes !~ /^[0-9]+$/) return pushes
    sub_ = first_stack_sub()
    if (sub_ == "") return "no-stack-adjustment"
    if ((8 * pushes + sub_) % 16 != 8) return "misaligned-" pushes "-pushes-subq-" sub_
    return "ok"
}

# A push-mode frame reserves no slot region: an odd push run adjusts nothing,
# an even one only its 8-byte alignment pad.
function dead_slot_region(   saved, subs, adds, pad) {
    saved = csr_pushes()
    if (saved !~ /^[0-9]+$/) return saved
    subs = count_regex("^[[:space:]]+subq \\$[0-9]+, %rsp$")
    adds = count_regex("^[[:space:]]+addq \\$[0-9]+, %rsp$")
    pad = count_regex("^[[:space:]]+subq \\$8, %rsp$")
    if (saved % 2 == 1) {
        if (subs != 0 || adds != 0) return "odd-pushes-with-" subs "-subq-" adds "-addq"
    } else {
        if (pad != 1 || subs != 1) return "even-pushes-with-" subs "-subq-" pad "-pads"
    }
    return "ok"
}

# The subq count and first frame size of the body, e.g. "1:24" or "0:".
function stack_frame(   subs) {
    subs = count_regex("^[[:space:]]+subq \\$[0-9]+, %rsp$")
    return subs ":" first_stack_sub()
}

# The first prologue frame size, 0 when the body adjusts nothing.
function frame_size(   v) {
    v = first_stack_sub()
    return (v == "") ? 0 : v
}

# A read-modify-write of CELL that kept the load before it or the store after it.
function rmw_fold_staging(cell,   i, n, pending, prev) {
    for (i = 1; i <= NR; i++) {
        if (L[i] ~ ("^[[:space:]]+(addq|subq|orq|andq|xorq) ([$][0-9-]+|%r[a-z0-9]+), " cell "\\(%rip\\)$")) {
            if (prev ~ ("^[[:space:]]+movq " cell "\\(%rip\\), %r")) n++
            pending = 1
            prev = L[i]
            continue
        }
        if (pending == 1) {
            if (L[i] ~ ("^[[:space:]]+movq %r[a-z0-9]+, " cell "\\(%rip\\)$")) n++
            pending = 0
        }
        prev = L[i]
    }
    return n + 0
}

# A fold accumulator homed in a frame slot across its xor/imul/store cycle.
function frame_homed_fold_accumulators(   i, n, state, f, acc) {
    for (i = 1; i <= NR; i++) {
        if (L[i] ~ /^[[:space:]]+xorq %r[a-z0-9]+, %r[a-z0-9]+$/) { split(L[i], f); acc = f[3]; state = 1; continue }
        if (state == 1 && L[i] ~ ("^[[:space:]]+movq " acc ", [0-9]+\\(%rsp\\)$")) { state = 2; continue }
        if (state == 2 && L[i] ~ ("^[[:space:]]+imulq %r[a-z0-9]+, " acc "$")) { state = 3; continue }
        if (state == 3 && L[i] ~ ("^[[:space:]]+movq " acc ", [0-9]+\\(%rsp\\)$")) { n++; state = 0; continue }
        state = 0
    }
    return n + 0
}

# The order of indexed word loads (L) and stores (S).
function memory_order(   i, s) {
    for (i = 1; i <= NR; i++) {
        if (L[i] ~ /^[[:space:]]+movq -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\), %r[a-z0-9]+$/) s = s "L"
        else if (L[i] ~ /^[[:space:]]+movq %r[a-z0-9]+, -?[0-9]*\(%r[a-z0-9]+,%r[a-z0-9]+,8\)$/) s = s "S"
    }
    return s
}

# A register copy consumed at once as a gep index.
function staged_index_copies(   i, n, p, reg) {
    for (i = 2; i <= NR; i++)
        if (L[i - 1] ~ /^[[:space:]]+movq %r[a-z0-9]+, %r[a-z0-9]+$/) {
            split(L[i - 1], p, ", ")
            reg = p[2]
            if (L[i] ~ ("^[[:space:]]+addq " reg ", %r")) n++
            else if (L[i] ~ ("^[[:space:]]+leaq \\(%r[a-z0-9]+," reg ",[1248]\\), %r")) n++
        }
    return n + 0
}

# "ok" when there is a cmov and every cmov sits directly under its cmp.
function cmov_under_cmp(   i, n, bad) {
    for (i = 1; i <= NR; i++)
        if (L[i] ~ /^[[:space:]]+cmov/) {
            n++
            if (i == 1 || L[i - 1] !~ /^[[:space:]]+cmp[bwlq] /) bad = 1
        }
    return (bad || n == 0) ? "bad" : "ok"
}

# Distinct strings matched by ERE (grep -o | sort -u | wc -l).
function distinct(re,   i, s, n, k) {
    for (i = 1; i <= NR; i++) {
        s = L[i]
        while (s != "" && match(s, re)) {
            if (RLENGTH <= 0) { s = substr(s, RSTART + 1); continue }
            k = substr(s, RSTART, RLENGTH)
            if (!(k in got)) { got[k] = 1; n++ }
            s = substr(s, RSTART + RLENGTH)
        }
    }
    return n + 0
}

function bare_reg(text) { gsub(/[,()]/, "", text); return text }

function offset_base(text) { text = bare_reg(text); sub(/^16/, "", text); return text }

# Correlated 24-byte shallow copies: movups load/store of one vector between
# two bases, then the offset-16 word between the same bases.
function copy24_sequences(   i, f, n, state, source, vector, destination, word) {
    for (i = 1; i <= NR; i++) {
        split(L[i], f)
        if (f[1] == "movups" && f[2] ~ /^\(%r[a-z0-9]+\),$/ && f[3] ~ /^%xmm[0-9]+$/) {
            source = bare_reg(f[2]); vector = f[3]; state = 1; continue
        }
        if (state == 1 && f[1] == "movups" && f[2] ~ /^%xmm[0-9]+,$/ && f[3] ~ /^\(%r[a-z0-9]+\)$/) {
            if (bare_reg(f[2]) == vector) { destination = bare_reg(f[3]); state = 2; continue }
            state = 0
        }
        if (state == 2 && f[1] == "movq" && f[2] ~ /^16\(%r[a-z0-9]+\),$/ && f[3] ~ /^%r[a-z0-9]+$/) {
            if (offset_base(f[2]) == source) { word = f[3]; state = 3; continue }
            state = 0
        }
        if (state == 3 && f[1] == "movq" && f[2] ~ /^%r[a-z0-9]+,$/ && f[3] ~ /^16\(%r[a-z0-9]+\)$/) {
            if (bare_reg(f[2]) == word && offset_base(f[3]) == destination) n++
            state = 0
        }
    }
    return n + 0
}

# ------------------------------------------------------------------ windows

# The unrolled group: the lines after the `__unroll_body:` label up to the next label.
function window_unroll_body(   i, started) {
    for (i = 1; i <= NR; i++) {
        if (started && L[i] ~ /^[^[:blank:]]*:$/) return
        if (started) print L[i]
        if (!started && L[i] ~ /__unroll_body:$/) started = 1
    }
}

# The block after the first label containing ARG, up to the next label.
function window_labeled_block(suffix,   i, started) {
    for (i = 1; i <= NR; i++) {
        if (started && L[i] ~ /^[^[:blank:]]*:$/) return
        if (started) print L[i]
        if (!started && L[i] ~ /:$/ && index(L[i], suffix)) started = 1
    }
}

# The body up to its `.seh_endproc` (Windows emits unwind data after it).
function window_seh_endproc(   i) {
    for (i = 1; i <= NR; i++) {
        print L[i]
        if (L[i] ~ /^[[:space:]]*\.seh_endproc$/) return
    }
}

# Every `__bce_fast:` self-loop (back to its own label before any other .L
# line) that contains ARG.
function window_fast_self_loop(needle,   i, inblk, buf, hit, label) {
    for (i = 1; i <= NR; i++) {
        if (L[i] ~ /__bce_fast:$/) {
            label = L[i]
            sub(/:$/, "", label)
            inblk = 1; buf = ""; hit = 0
            continue
        }
        if (inblk) {
            buf = buf L[i] "\n"
            if (index(L[i], needle) > 0) hit = 1
            if (index(L[i], label) > 0) {
                if (hit) printf "%s", buf
                inblk = 0
            } else if (L[i] ~ /^\.L/) inblk = 0
        }
    }
}

# The first run of `__bce_fast` blocks containing ARG.
function window_fast_region(needle,   i, inblk, buf, hit) {
    for (i = 1; i <= NR; i++) {
        if (L[i] ~ /__bce_fast[^:]*:$/) {
            if (!inblk) { inblk = 1; buf = ""; hit = 0 }
            continue
        }
        if (inblk && L[i] ~ /^\.L/) {
            if (index(L[i], "__bce_fast") > 0) continue
            if (hit) { printf "%s", buf; return }
            inblk = 0
            continue
        }
        if (inblk) {
            buf = buf L[i] "\n"
            if (index(L[i], needle) > 0) hit = 1
        }
    }
    if (inblk && hit) printf "%s", buf
}

# Everything after the first line matching the ERE ARG.
function window_after(re,   i, inblk) {
    for (i = 1; i <= NR; i++) {
        if (inblk) print L[i]
        if (L[i] ~ re) inblk = 1
    }
}

# The first line matching the ERE ARG and everything after it.
function window_from(re,   i, inblk) {
    for (i = 1; i <= NR; i++) {
        if (L[i] ~ re) inblk = 1
        if (inblk) print L[i]
    }
}

# Every sed-style range /START/,/END/ (ARG is START~END, both EREs): a line
# matching START through the next later line matching END, then the next range.
function window_ranges(spec,   i, cut, start_re, end_re, inblk) {
    cut = index(spec, "~")
    start_re = substr(spec, 1, cut - 1)
    end_re = substr(spec, cut + 1)
    for (i = 1; i <= NR; i++) {
        if (inblk) {
            print L[i]
            if (L[i] ~ end_re) inblk = 0
        } else if (L[i] ~ start_re) {
            print L[i]
            inblk = 1
        }
    }
}

# The lines after a label matching the ERE ARG, up to the next .L label.
function window_block_after(re,   i, inblk) {
    for (i = 1; i <= NR; i++) {
        if (L[i] ~ /^\.L[A-Za-z0-9_.]*:$/) inblk = 0
        if (L[i] ~ re) { inblk = 1; continue }
        if (inblk) print L[i]
    }
}

# The scalar argument setup of `call ARG`: from the last `movq ..., %rdi`
# before the call through the call.
function window_call_args(symbol,   i, j, start, needle) {
    needle = "call " symbol
    for (i = 1; i <= NR; i++) {
        if (L[i] ~ /^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rdi$/) start = i
        if (index(L[i], needle)) {
            if (!start) return
            for (j = start; j <= i; j++) print L[j]
            return
        }
    }
}

# TypeLisp source lines that are not `;` comments.
function window_tl_code(   i) {
    for (i = 1; i <= NR; i++) if (L[i] !~ /^[[:space:]]*;/) print L[i]
}

END {
    arg = ENVIRON["CC_ARG"]
    if (analyzer == "backward-branches") print backward_branches()
    else if (analyzer == "fallthrough-jmps") print fallthrough_jmps()
    else if (analyzer == "jumps-into-jump-only-blocks") print jumps_into_jump_only_blocks()
    else if (analyzer == "self-loop-jmps") print self_loop_jmps()
    else if (analyzer == "store-then-cmp-same-slot") print store_then_cmp_same_slot()
    else if (analyzer == "copy-chains-to-rax") print copy_chains_to_rax()
    else if (analyzer == "abort-staging-push-from-memory") print abort_staging_push_from_memory()
    else if (analyzer == "literal-then-test") print literal_then("test")
    else if (analyzer == "literal-then-redef") print literal_then("redef")
    else if (analyzer == "prologue-csrs") print prologue_csrs(unused)
    else if (analyzer == "csr-pushes") print csr_pushes()
    else if (analyzer == "csr-pushes-parity") print csr_pushes_parity()
    else if (analyzer == "unnamed-pushed-csrs") print unnamed_pushed_csrs()
    else if (analyzer == "call-alignment") print call_alignment(arg)
    else if (analyzer == "dead-slot-region") print dead_slot_region()
    else if (analyzer == "stack-frame") print stack_frame()
    else if (analyzer == "frame-size") print frame_size()
    else if (analyzer == "rmw-fold-staging") print rmw_fold_staging(arg)
    else if (analyzer == "frame-homed-fold-accumulators") print frame_homed_fold_accumulators()
    else if (analyzer == "memory-order") print memory_order()
    else if (analyzer == "staged-index-copies") print staged_index_copies()
    else if (analyzer == "cmov-under-cmp") print cmov_under_cmp()
    else if (analyzer == "distinct") print distinct(arg)
    else if (analyzer == "copy24-sequences") print copy24_sequences()
    else if (analyzer == "window-unroll-body") window_unroll_body()
    else if (analyzer == "window-labeled-block") window_labeled_block(arg)
    else if (analyzer == "window-seh-endproc") window_seh_endproc()
    else if (analyzer == "window-fast-self-loop") window_fast_self_loop(arg)
    else if (analyzer == "window-fast-region") window_fast_region(arg)
    else if (analyzer == "window-after") window_after(arg)
    else if (analyzer == "window-from") window_from(arg)
    else if (analyzer == "window-block-after") window_block_after(arg)
    else if (analyzer == "window-ranges") window_ranges(arg)
    else if (analyzer == "window-call-args") window_call_args(arg)
    else if (analyzer == "window-tl-code") window_tl_code()
    else {
        print "unknown analyzer: " analyzer > "/dev/stderr"
        exit 2
    }
}
