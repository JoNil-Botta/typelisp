#!/usr/bin/env sh
# Sourced by the Linux stack gate. All mappings below are owned by the test.
: "${ROOT:?}" "${WORK:?}"
cat > "$WORK/combination-host.s" <<'EOF'
.data
.align 8
.globl stack_base, body_count
stack_base: .quad 0
body_count: .quad 0
.text
.globl _start
_start:
    movq $9, %rax
    xorq %rdi, %rdi
    movq $176128, %rsi
    xorq %rdx, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    syscall
    testq %rax, %rax
    js failure
    movq %rax, stack_base(%rip)
    movq %rax, %rdi
    movq $4096, %rsi
    movq $3, %rdx
    movq $10, %rax
    syscall
    testq %rax, %rax
    js failure
    movq stack_base(%rip), %rdi
    addq $45056, %rdi
    movq $131072, %rsi
    movq $3, %rdx
    movq $10, %rax
    syscall
    testq %rax, %rax
    js failure
    movq stack_base(%rip), %rdi
    movabsq $0x1234567812345678, %rax
    movq $512, %rcx
    rep stosq
    movq stack_base(%rip), %r12
    addq $45056+HEADROOM, %r12
    movq %r12, %rsp
    movabsq $0x3456781234567812, %r11
    call combo
    cmpq %r12, %rsp
    jne failure
    movabsq $0x3456781234567812, %r10
    cmpq %r10, %r11
    jne failure
    cmpq $1, body_count(%rip)
    jne failure
    movq stack_base(%rip), %rdi
    movabsq $0x1234567812345678, %rax
    movq $512, %rcx
1:  cmpq %rax, (%rdi)
    jne failure
    addq $8, %rdi
    loop 1b
    movq $42, %rdi
    jmp exit
failure:
    movq $125, %rdi
exit:
    movq $231, %rax
    syscall
.section .note.GNU-stack,"",@progbits
EOF
cat > "$WORK/combination.gdb" <<'EOF'
set pagination off
set confirm off
set debuginfod enabled off
set disable-randomization off
handle SIGSEGV stop print pass
run
set $base = *(unsigned long*)&stack_base
set $fault = (unsigned long)$_siginfo._sifields._sigfault.si_addr
printf "COMBINATION_GUARD=%d\n", $fault >= $base+4096 && $fault < $base+45056
printf "COMBINATION_BODY=%ld\n", *(long*)&body_count
set $ok = 1
set $i = 0
while $i < 512
  if *(unsigned long*)($base+$i*8) != 0x1234567812345678
    set $ok = 0
  end
  set $i = $i+1
end
printf "COMBINATION_CANARY=%d\n", $ok
info proc mappings
x/4i $pc
continue
EOF
for pair in '4096 4096' '32768 4096' '32768 4104' '32776 4096' '32768 32768'; do
    set -- $pair
    entry=$1
    staging=$2
    stem="combination-$entry-$staging"
    bounded "$stem-generate" 512 "$WORK/oracle" combo "$entry" "$staging" "$WORK/$stem.s"
    as "$WORK/$stem.s" -o "$WORK/$stem.o"
    for mode in enough exhausted; do
        case "$mode" in
            enough) headroom=$(( (entry + staging + 31) / 16 * 16 )) ;;
            exhausted) headroom=$(( (entry + 23) / 16 * 16 )) ;;
        esac
        [ "$headroom" -le 131072 ] || fail "invalid combination headroom"
        as --defsym "HEADROOM=$headroom" "$WORK/combination-host.s" -o "$WORK/$stem-$mode-host.o"
        ld -e _start "$WORK/$stem-$mode-host.o" "$WORK/$stem.o" -o "$WORK/$stem-$mode"
        status=0
        case "$mode" in
            enough)
                bounded "$stem-$mode" 512 "$WORK/$stem-$mode" || status=$?
                [ "$status" -eq 42 ] || fail "$stem failed exact RSP/R11/canary control: $status"
                ;;
            exhausted)
                bounded "$stem-$mode" 512 gdb -q -nx -batch -x "$WORK/combination.gdb" \
                    --args "$WORK/$stem-$mode" > "$WORK/$stem-$mode.log" 2>&1
                for proof in COMBINATION_GUARD=1 COMBINATION_BODY=0 COMBINATION_CANARY=1 'terminated with signal SIGSEGV'; do
                    grep -F "$proof" "$WORK/$stem-$mode.log" >/dev/null || fail "$stem missed $proof"
                done
                ;;
        esac
    done
done
echo "Linux entry/transient combinations: 40 KiB host guard, exact RSP/R11, no canary/body write and actual SIGSEGV passed"
