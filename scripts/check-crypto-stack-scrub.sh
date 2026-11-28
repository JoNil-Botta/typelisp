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
LC_ALL=C awk -v output="$output" -v target="$target" -v opt="$opt" -v mutant="$mutant" '
function fail(message) { print "crypto-stack-scrub: " message > "/dev/stderr"; failed=1; exit 1 }
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
# Restrict proof operands to decimal as emitted by the compiler. A leading zero
# can denote octal in assembly, and AWK silently coerces malformed operands.
function decimal(s) {
    if (s !~ /^(0|[1-9][0-9]*)$/ || s+0>2147483647) return -1
    return s+0
}
function immediate(s) {
    sub(/^[^$]*[$]/, "", s)
    sub(/, %[a-z0-9]+$/, "", s)
    return decimal(s)
}
function selected(n) { return n ~ /^_tl_stdlib_crypto_/ || n ~ /^(scrub_|aes_audit_|gcm_audit_)/ || n == "main" || has_scrub[n] }
function reclaim(n) { return n ~ /^_tl_stdlib_crypto_stack_scrub_/ }
function gp(r) { return r ~ /^%r(ax|bx|cx|dx|si|di|bp|[89]|1[0-5])$/ }
function qword_reg(r) {
    if (r ~ /^%e(ax|bx|cx|dx|si|di|bp)$/) return "%r" substr(r,3)
    if (r ~ /^%r([89]|1[0-5])d$/) return substr(r,1,length(r)-1)
    return ""
}
function displacement(operand, offset) {
    offset=operand; sub(/\(%[a-z0-9]+\)$/, "", offset)
    return (offset=="" ? 0 : decimal(offset))
}
function valid_slot(offset, size) { return offset>=0 && offset%8==0 && offset+8<=size }
function known_chkstk(  code,steps,i,num,line) {
    line=label["__chkstk"]
    if (!line) return 0
    code="pushq %rcx;pushq %rax;movq %rax, %rcx;leaq 16(%rsp), %rax;"
    code=code ".L_tl_ck_loop:;cmpq $4096, %rcx;jb .L_tl_ck_done;subq $4096, %rax;"
    code=code "movb $0, (%rax);subq $4096, %rcx;jmp .L_tl_ck_loop;.L_tl_ck_done:;"
    code=code "subq %rcx, %rax;movb $0, (%rax);popq %rax;popq %rcx;ret"
    num=split(code,steps,";")
    for (i=1;i<=num;i++) if (trim(source[line+i])!=steps[i]) return 0
    return 1
}
function wipe_arg(symbol, wipe,  line,move) {
    if (symbol==wipe) return (target ~ /windows/ ? "%rcx" : "%rdi")
    # The Linux group entry can marshal the pointer into RDI then fall through.
    line=label[symbol]
    if (target ~ /windows/ || symbol !~ /^"__tl_arg_entry:[0-9]+"$/ || !line ||
        trim(source[line+2])!=".size " symbol ", . - " symbol ||
        trim(source[line+3])!=wipe ":") return ""
    if (split(trim(source[line+1]),move,/[ ,]+/)!=3 || move[1]!="movq" ||
        !gp(move[2]) || move[3]!="%rdi") return ""
    return move[2]
}
# Prove only straight-line REP fills from the ABI entry, where DF is clear.
# Facts distinguish stack offsets from integers. Unknown instructions, changes
# to RSP outside the prologue, and arbitrary calls cannot establish the proof.
function rep_interval(n, offset, depth, wipe,  i,s,a,op,dst,src,k,size,pushes,probed,
                      regs,spills,saved,words,chunk_reg,arg,finish) {
    for (i=body_start[n];owner[i]==n;i++) {
        s=trim(source[i])
        if (s=="" || s ~ /^#/ || s ~ /^\.Lf[0-9]+_entry:$/ ||
            s ~ /^\.seh_(stackalloc [0-9]+|pushreg %r[a-z0-9]+|endprologue)$/) continue
        if (probed && !size && s!="subq %rax, %rsp") return 0
        if (s=="rep stosq") {
            if (words || regs["%rdi"]!="p:" offset || regs["%rax"]!="c:0" ||
                regs["%rcx"] !~ /^c:[0-9]+$/ || !valid_slot(offset,size)) return 0
            words=substr(regs["%rcx"],3)+0
            if (words<=0 || words>(size-offset)/8) return 0
            # AWK array indices are strings when iterated.
            for (k in spills) if (k+0>=offset && k+0<offset+8*words) delete spills[k]
            delete regs["%rdi"]
            regs["%rcx"]="c:0"
            continue
        }
        split(s,a,/[ ,]+/)
        op=a[1]; src=a[2]; dst=a[3]
        if (op ~ /^callq?$/) {
            if (s ~ /^callq? __chkstk$/ && target ~ /windows/ && !size && !probed &&
                regs["%rax"] ~ /^c:[0-9]+$/ && known_chkstk()) {
                # The checked freestanding probe restores RAX, RCX and RSP.
                probed=1
                continue
            }
            arg=wipe_arg(src,wipe)
            chunk_reg=(target ~ /windows/ ? "%rdx" : "%rsi")
            if (!words || !arg || s!=op " " src || regs[arg]!="p:" offset ||
                regs[chunk_reg] !~ /^c:[1-9][0-9]*$/ || depth!=size+8*pushes) return 0
            finish=i+1
            if (trim(source[finish])=="movl $0, %eax") finish++
            if (trim(source[finish++])!="addq $" size ", %rsp") return 0
            for (k=pushes;k>0;k--) if (trim(source[finish++])!="popq " saved[k]) return 0
            if (trim(source[finish])!="ret") return 0
            chunks[n]=substr(regs[chunk_reg],3)+0
            return words
        }
        if (!size && s ~ /^pushq %r[a-z0-9]+$/ && gp(src) && !probed) {
            saved[++pushes]=src
        } else if (!size && s ~ /^subq [$][0-9]+, %rsp$/ && !probed) {
            size=immediate(s)
            if (size<=0) return 0
        } else if (!size && s=="subq %rax, %rsp" && probed) {
            size=substr(regs["%rax"],3)+0
            if (size<=0 || size>2147483647) return 0
        } else if (s ~ /^movl [$][0-9]+, %[a-z0-9]+$/ && qword_reg(dst)) {
            k=immediate(s)
            if (k<0) return 0
            regs[qword_reg(dst)]="c:" k
        } else if (s ~ /^xorl %[a-z0-9]+, %[a-z0-9]+$/ && src==dst && qword_reg(dst)) {
            regs[qword_reg(dst)]="c:0"
        } else if (s ~ /^leaq [0-9]*\(%rsp\), %r[a-z0-9]+$/ && gp(dst) && valid_slot(displacement(src),size)) {
            regs[dst]="p:" displacement(src)
        } else if (s ~ /^movq %rsp, %r[a-z0-9]+$/ && gp(dst) && valid_slot(0,size)) {
            regs[dst]="p:0"
        } else if (s ~ /^movq %r[a-z0-9]+, %r[a-z0-9]+$/ && gp(src) && gp(dst)) {
            regs[dst]=regs[src]
        } else if (s ~ /^movq %r[a-z0-9]+, [0-9]*\(%rsp\)$/ && gp(src) && valid_slot(displacement(dst),size)) {
            spills[displacement(dst)]=regs[src]
        } else if (s ~ /^movq [0-9]*\(%rsp\), %r[a-z0-9]+$/ && gp(dst) && valid_slot(displacement(src),size)) {
            regs[dst]=spills[displacement(src)]
        } else return 0
    }
    return 0
}
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
    if (s ~ /^(__chkstk|"__tl_arg_entry:[0-9]+"):$/) {
        key=substr(s,1,length(s)-1)
        # Duplicate labels will not assemble, and must not supply proof either.
        if (key in label) fail("duplicate entry: " key)
        label[key]=NR
    }
    if (s ~ /^\.globl /) {
        split(s,a,/ +/); pending=a[2]; current=""
        if (pending ~ /_probe_phase$/) { phase=pending; phase_count++ }
    }
    if (s==pending ":") { current=pending; defined[current]=1; body_start[current]=NR+1; pending=""; delete zero_xmm; delete zero_gp; next }
    # A lowered Win64 unwind replaces `.seh_endproc` with its end label.
    if (s ~ /^\.(size|section|seh_endproc)( |$)/ || s ~ /^\.L_tl_seh_end_[0-9]+:$/) { current=""; delete zero_xmm; delete zero_gp; next }
    owner[NR]=current
    if (current=="") next
    if (s=="rep stosq") has_rep[current]=1
    if (s ~ /^\.seh_stackalloc /) {
        v=decimal(substr(s,length(".seh_stackalloc ")+1))
        if (v<0) bad_geometry[current]=1
        else if (v>reserve[current]) reserve[current]=v
    }
    if (s ~ /^\./ && s !~ /:$/) next
    if (s=="" || s ~ /^[#;]/) next
    if (s ~ /^\.Lf/) in_body[current]=1
    if (s ~ /^pushq / && !in_body[current]) prologue_push[current]++
    if (s ~ /^(subq|addq)[[:space:]]+[$].*,[[:space:]]*%rsp$/) {
        v=immediate(s)
        if (v<0) bad_geometry[current]=1
        else {
            if (v>reserve[current]) reserve[current]=v
            if (s ~ /^addq/) { last_add[current]=v; final_pops[current]=0 }
        }
    }
    # A lowered `__chkstk` frame reserves the size loaded into %eax.
    if (s ~ /^movl [$].*, %eax$/) probe_size[current]=immediate(s)
    if (s ~ /^callq? __chkstk$/) {
        if (probe_size[current]<=0) bad_geometry[current]=1
        else if (probe_size[current]>reserve[current]) reserve[current]=probe_size[current]
    }
    if (s ~ /^popq / && last_add[current]) final_pops[current]++
    if (s ~ /, [^,]*\(%rsp\)$/) {
        t=s; sub(/^.*, /, "", t); sub(/\(%rsp\)$/, "", t)
        if (t!="") {
            v=decimal(t ~ /^-/ ? substr(t,2) : t)
            if (v<0) bad_geometry[current]=1
            else if (t ~ /^-/ && v>red[current]) red[current]=v
        }
    }
    if (s ~ /^leaq [^,]*\(%rsp\),/ && !array_offset_set[current]) {
        t=s; sub(/^leaq /,"",t); sub(/,.*/,"",t)
        array_offset[current]=displacement(t); array_offset_set[current]=1
    } else if (s ~ /^movq %rsp,/ && s !~ /^movq %rsp, %rbp$/ && !array_offset_set[current]) {
        array_offset[current]=0; array_offset_set[current]=1
    }
    if (s ~ /:$/) { delete zero_xmm; delete zero_gp }
    if (s ~ /^xorps %xmm[0-9]+, %xmm[0-9]+$/) {
        split(s, za, /[ ,]+/)
        if (za[2] == za[3]) zero_xmm[za[2]] = 1
        else delete zero_xmm[za[3]]
    } else if (s ~ /^xorl %[a-z0-9]+, %[a-z0-9]+$/) {
        split(s, za, /[ ,]+/)
        if (za[2] == za[3]) {
            zg = za[2]
            if (zg ~ /^%e/) { sub(/^%e/, "%r", zg); zero_gp[zg] = 1 }
            else if (zg ~ /^%r[0-9]+d$/) { sub(/d$/, "", zg); zero_gp[zg] = 1 }
        } else { delete zero_gp }
    } else if (s ~ /^(callq?|j|ret)/) {
        delete zero_xmm; delete zero_gp
    } else {
        if (s ~ /%xmm[0-9]+$/) {
            zr = s; sub(/^.*, /, "", zr); delete zero_xmm[zr]
        }
        if (s !~ /%[xyz]mm[0-9]+$/ && s ~ /%[a-z0-9]+$/) {
            delete zero_gp
        }
    }
    if (!wipe_seen[current] && s ~ /, [^,]*\(%[a-z0-9]+\)$/) {
        words=0
        if (s ~ /^movq [$]0,/) words=1
        else if (s ~ /^movups %xmm[0-9]+, /) {
            split(s, za, /[ ,]+/)
            if (za[2] in zero_xmm) words=2
        } else if (s ~ /^movq %xmm[0-9]+, /) {
            split(s, za, /[ ,]+/)
            if (za[2] in zero_xmm) words=1
        } else if (s ~ /^movq %r[a-z0-9]+, /) {
            split(s, za, /[ ,]+/)
            if (za[2] in zero_gp) words=1
        }
        if (words && reclaim(current)) {
            t=s; sub(/^.*, /,"",t)
            if (displacement(t)<0) bad_store[current]=1
            else init_words[current]+=words
        }
    }
    if (s ~ /^mov[lq] [$].*, %(esi|edx)$/) chunk_argument[current]=immediate(s)
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
        d=last_add[n]+8*final_pops[n]
        if (has_rep[n]) {
            init_words[n]=rep_interval(n,array_offset[n],d,prefix "wipe_chunks_bang")
            if (!init_words[n]) fail("unproved REP STOSQ reclaim interval: " k)
        } else if (bad_store[n]) fail("unproved reclaim store displacement: " k)
        if (!(n in defined) || !array_offset_set[n] || array_offset[n]<0 || chunks[n]<=0)
            fail("missing reclaim body/array/wipe: " k)
        low[k]=-8-d+array_offset[n]; high[k]=low[k]+8*init_words[n]
        if (high[k]>-8 || low[k]>=high[k]) fail("invalid reclaim interval: " k)
        if (init_words[n]!=chunks[n]*init_words[prefix "block_bang"])
            fail("reclaim chunks do not cover initialized array: " k)
        print k "\t" low[k] "\t" high[k] "\t" init_words[n] "\t" chunks[n] "\t" d > (output "/intervals.tsv")
    }
    if (chunks[prefix "block_bang"]!=1) fail("block cost requires exactly one chunk")
    cost=instructions[prefix "block_bang"]+instructions[prefix "wipe_chunks_bang"]+1
    if (has_rep[prefix "block_bang"]) cost+=init_words[prefix "block_bang"]-1
    print "block-scrub-path-instructions\t" cost > (output "/cost.tsv")
    if (target ~ /windows/ && opt==2 && cost>450) fail("Windows block scrub exceeds 450 instructions")
    for (n in defined) {
        if (!selected(n)) continue
        if (bad_geometry[n]) fail("unproved stack geometry: " n)
        if (!reclaim(n)) unused=extent(n)
    }
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
