#!/usr/bin/env sh
set -eu
# Analyze the actual reclaim interval, then instrument a compiled fixture.
# Marker writes are test-only and use retired stack below the imminent scrub.
# A mutant replaces one phase's call with no wipe or a 64-byte wipe; the
# sentinel check, algorithm, setup and result checks remain identical.
[ "$#" -eq 5 ] || { echo 'usage: check-crypto-stack-scrub.sh ASSEMBLY OUTPUT TARGET OPT MUTANT' >&2; exit 2; }
assembly=$1
output=$2
target=$3
opt=$4
mutant=$5
mkdir -p "$output"
awk -v output="$output" -v target="$target" -v opt="$opt" -v mutant="$mutant" '
function fail(message) { print "crypto-stack-scrub: " message > "/dev/stderr"; failed=1; exit 1 }
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function immediate(s) { sub(/^[^$]*[$]/, "", s); sub(/,.*/, "", s); return s+0 }
function selected(n) { return n ~ /^_tl_stdlib_crypto_/ || n ~ /^(scrub_|aes_audit_|gcm_audit_)/ || n == "main" || has_scrub[n] }
function reclaim(n) { return n ~ /^_tl_stdlib_crypto_stack_scrub_/ }
function extent(n,  best,i,c,d) {
    if (memo_done[n]) return memo[n]
    if (visiting[n]) fail("unexpected recursive crypto frame: " n)
    visiting[n]=1
    best=frame[n]+red[n]
    for (i=1;i<=edge_count[n];i++) {
        c=edge_target[n,i]
        if (!selected(c) || reclaim(c) || !(c in defined)) continue
        d=(edge_tail[n,i] ? 0 : frame[n]+8)+extent(c)
        if (d>best) best=d
    }
    visiting[n]=0; memo_done[n]=1; memo[n]=best
    return best
}
function out(s) { print s > (output "/probe.s") }
function instrument_call(line,n,kind,required,high,  top,d,badphase,after,original) {
    site++
    top=-high+8
    # Actual array-high slots contain ABI return/save/argument metadata, not
    # secret arithmetic values. See the reviewed per-frame disclosure.
    out("    movabsq $0x4d53435255425331, %r10")
    for (d=top;d<=required;d+=8) out("    movq %r10, -" d "(%rsp)")
    out("    movq " phase "(%rip), %r10")
    out("    leaq _tl_scrub_probe_hits(%rip), %r11")
    out("    addq $1, (%r11,%r10,8)")
    if (mutant!=0) {
        badphase=mutant<0 ? -mutant : mutant
        original=".Lscrub_probe_original_" site
        after=".Lscrub_probe_after_" site
        out("    cmpq $" badphase ", %r10")
        out("    jne " original)
        if (mutant<0)
            for (d=top;d<top+64;d+=8) out("    movq $0, -" d "(%rsp)")
        out("    jmp " after); out(original ":"); out(line); out(after ":")
    } else out(line)
    for (d=top;d<=required;d+=8) {
        out("    cmpq $0, -" d "(%rsp)")
        out("    je .Lscrub_probe_clean_" site "_" d)
        out("    addq $1, _tl_scrub_probe_failures(%rip)")
        out(".Lscrub_probe_clean_" site "_" d ":")
    }
}
{
    sub(/\r$/, "")
    source[NR]=$0
    s=trim($0)
    if (s ~ /^\.globl /) {
        split(s,a,/ +/); pending=a[2]; current=""
        if (pending ~ /_probe_phase$/) { phase=pending; phase_count++ }
    }
    if (s==pending ":") { current=pending; defined[current]=1; pending=""; next }
    if (s ~ /^\.(size|section|seh_endproc)( |$)/) { current=""; next }
    owner[NR]=current
    if (current=="") next
    if (s ~ /^\.seh_stackalloc /) { split(s,a,/ +/); if (a[2]+0>reserve[current]) reserve[current]=a[2]+0 }
    if (s ~ /^\./ && s !~ /:$/) next
    if (s=="" || s ~ /^[#;]/) next
    if (s ~ /^\.Lf/) in_body[current]=1
    if (s ~ /^pushq / && !in_body[current]) prologue_push[current]++
    if (s ~ /^(subq|addq) [$][0-9]+, %rsp$/) {
        v=immediate(s)
        if (v>reserve[current]) reserve[current]=v
        if (s ~ /^addq/) { last_add[current]=v; final_pops[current]=0 }
    }
    if (s ~ /^popq / && last_add[current]) final_pops[current]++
    if (s ~ /, -[0-9]+\(%rsp\)$/) {
        t=s; sub(/^.*, -/, "", t); sub(/\(.*/, "", t)
        if (t+0>red[current]) red[current]=t+0
    }
    if (s ~ /^leaq [0-9]+\(%rsp\),/ && !array_offset_set[current]) {
        t=s; sub(/^leaq /,"",t); sub(/\(.*/,"",t)
        array_offset[current]=t+0; array_offset_set[current]=1
    }
    if (s ~ /^movq [$]0,/ && !wipe_seen[current]) init_words[current]++
    if (s ~ /^mov[lq] [$][0-9]+, %(esi|edx)$/) chunk_argument[current]=immediate(s)
    if (s ~ /^callq? _tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_wipe_chunks_bang$/) {
        wipe_seen[current]=1; chunks[current]=chunk_argument[current]
    }
    if (s !~ /:$/) instructions[current]++
    if (s ~ /^(callq?|jmp) /) {
        split(s,a,/ +/); i=++edge_count[current]; edge_target[current,i]=a[2]; edge_tail[current,i]=(a[1]=="jmp")
        if (a[2] ~ /^_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_(block|setup|tree)_bang$/) {
            k=a[2]; sub(/^.*_scrub_/,"",k); sub(/_bang$/,"",k)
            has_scrub[current]=1; call_kind[NR]=k
        }
    }
    cls=""
    if (s ~ /^pushq %r11$/) cls="stack-probe-save"
    else if (s ~ /^pushq /) cls="callee-saved-copy"
    else if (s ~ /, -?[0-9]*\(%rsp\)$/ && s !~ /^(cmp|test)/)
        cls=(s ~ /^mov/ ? "spill-store" : "read-modify-write")
    if (cls=="spill-store") spill_stores[current]++
    if (cls!="") print current "\t" NR "\t" cls "\t" s > (output "/stack-destinations.tsv")
}
END {
    if (failed) exit 1
    if (phase_count!=1) fail("missing or ambiguous public probe phase")
    print "kind\tlow\thigh-exclusive\twords\tchunks\tframe" > (output "/intervals.tsv")
    kinds[1]="block"; kinds[2]="setup"; kinds[3]="tree"
    prefix="_tl_stdlib_crypto_stack_scrub_stdlib_crypto_stack_scrub_"
    for (n in defined) frame[n]=reserve[n]+8*prologue_push[n]
    for (i=1;i<=3;i++) {
        k=kinds[i]; n=prefix k "_bang"
        if (!(n in defined) || !array_offset_set[n] || !chunks[n]) fail("missing reclaim body/array/wipe: " k)
        d=last_add[n]+8*final_pops[n]
        low[k]=-8-d+array_offset[n]; high[k]=low[k]+8*init_words[n]
        if (high[k]>-8 || low[k]>=high[k]) fail("invalid reclaim interval: " k)
        if (init_words[n]!=chunks[n]*init_words[prefix "block_bang"])
            fail("reclaim chunks do not cover initialized array: " k)
        print k "\t" low[k] "\t" high[k] "\t" init_words[n] "\t" chunks[n] "\t" d > (output "/intervals.tsv")
    }
    if (chunks[prefix "block_bang"]!=1) fail("block cost requires exactly one chunk")
    cost=instructions[prefix "block_bang"]+instructions[prefix "wipe_chunks_bang"]+1
    print "block-scrub-path-instructions\t" cost > (output "/cost.tsv")
    if (target ~ /windows/ && opt==2 && cost>450) fail("Windows block scrub exceeds 450 instructions")
    for (n in defined) if (selected(n) && !reclaim(n)) unused=extent(n)
    # Keep the D-C150 opt1 ceilings in the same emitted-code coverage boundary.
    if (opt==1) {
        if (spill_stores["_tl_stdlib_crypto_ghash_core_stdlib_crypto_ghash_core_multiply_bang"]>38)
            fail("D-C150 GHASH store ceiling exceeded")
        if (spill_stores["_tl_stdlib_crypto_aes128_gcm_stdlib_crypto_aes128_gcm_gctr_bang"]>31)
            fail("D-C150 GCTR store ceiling exceeded")
    }
    print "caller\tline\tkind\tderived-depth\trequired-depth" > (output "/coverage.tsv")
    for (line_number=1;line_number<=NR;line_number++) {
        if (!(line_number in call_kind)) continue
        n=owner[line_number]; k=call_kind[line_number]; depth=0
        for (j=1;j<=edge_count[n];j++) {
            c=edge_target[n,j]
            if (!selected(c) || reclaim(c) || !(c in defined)) continue
            if (k=="setup" && c !~ /^_tl_stdlib_crypto_aes_core_/) continue
            d=(edge_tail[n,j] ? -frame[n] : 8)+extent(c)
            if (d>depth) depth=d
        }
        floor=(k=="block" ? (target ~ /windows/ ? 816 : 728) : k=="setup" ? (target ~ /windows/ ? 1456 : 1304) : (target ~ /windows/ ? 5360 : 5144))
        required[line_number]=int((depth>floor ? depth : floor)+7)/8
        required[line_number]=int(required[line_number])*8
        if (low[k]>-required[line_number]) fail("under-coverage: " n " " k " needs " required[line_number] " low=" low[k])
        print n "\t" line_number "\t" k "\t" depth "\t" required[line_number] > (output "/coverage.tsv")
    }
    for (line_number=1;line_number<=NR;line_number++) {
        line=source[line_number]; s=trim(line)
        if (line_number in call_kind) {
            k=call_kind[line_number]
            instrument_call(line,owner[line_number],k,required[line_number],high[k])
            continue
        }
        if (owner[line_number]=="main" && s=="ret") {
            bad=".Lscrub_probe_bad_" line_number; good=bad "_done"
            out("    cmpq $0, _tl_scrub_probe_failures(%rip)"); out("    jne " bad)
            for (i=1;i<=8;i++) { out("    cmpq $1, _tl_scrub_probe_hits+" (8*i) "(%rip)"); out("    jne " bad) }
            out("    jmp " good); out(bad ":"); out("    movq $1, %rax"); out(good ":")
            main_exits++
        }
        out(line)
    }
    if (!site || !main_exits) fail("missing live call sites or main exit")
    out(".data"); out(".p2align 3"); out("_tl_scrub_probe_failures:"); out("    .quad 0")
    out("_tl_scrub_probe_hits:"); out("    .zero 72")
    print "crypto-stack-scrub: target=" target " opt=" opt " sites=" site " mutant=" mutant " block-path=" cost
}
' "$assembly"
