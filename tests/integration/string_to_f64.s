    .section .rodata
.L_tl_str_0:
    .string "0.0"
.L_tl_str_1:
    .string "1.5"
.L_tl_str_2:
    .string "100"
.L_tl_str_3:
    .string "-2.25"
.L_tl_str_4:
    .string "3.0e2"
.L_tl_str_5:
    .string "25e-1"

    .text
    .globl main


    .globl tl_string_to_f64
tl_string_to_f64:
    push %rdi
    push %rsi
    movq %rcx, %rdi
    movq %rdx, %rsi
    xorq %rax, %rax
    xorq %r8, %r8
    xorq %r9, %r9
    xorq %r10, %r10
    xorq %r11, %r11
    xorq %rdx, %rdx
    pxor %xmm0, %xmm0
    testq %rsi, %rsi
    jz .L_tl_string_to_f64_done
    movzbl (%rdi), %ecx
    cmpb $45, %cl
    jne .L_tl_string_to_f64_check_plus
    movq $1, %r8
    incq %rdi
    decq %rsi
    jmp .L_tl_string_to_f64_mant_loop
.L_tl_string_to_f64_check_plus:
    cmpb $43, %cl
    jne .L_tl_string_to_f64_mant_loop
    incq %rdi
    decq %rsi
.L_tl_string_to_f64_mant_loop:
    testq %rsi, %rsi
    jz .L_tl_string_to_f64_build
    movzbl (%rdi), %ecx
    cmpb $46, %cl
    jne .L_tl_string_to_f64_not_dot
    testq %r10, %r10
    jnz .L_tl_string_to_f64_build
    movq $1, %r10
    incq %rdi
    decq %rsi
    jmp .L_tl_string_to_f64_mant_loop
.L_tl_string_to_f64_not_dot:
    cmpb $101, %cl
    je .L_tl_string_to_f64_exponent
    cmpb $69, %cl
    je .L_tl_string_to_f64_exponent
    cmpb $48, %cl
    jb .L_tl_string_to_f64_build
    cmpb $57, %cl
    ja .L_tl_string_to_f64_build
    imulq $10, %rax, %rax
    subq $48, %rcx
    addq %rcx, %rax
    testq %r10, %r10
    jz .L_tl_string_to_f64_mant_next
    incq %r9
.L_tl_string_to_f64_mant_next:
    incq %rdi
    decq %rsi
    jmp .L_tl_string_to_f64_mant_loop
.L_tl_string_to_f64_exponent:
    incq %rdi
    decq %rsi
    testq %rsi, %rsi
    jz .L_tl_string_to_f64_build
    movzbl (%rdi), %ecx
    cmpb $45, %cl
    jne .L_tl_string_to_f64_exp_check_plus
    movq $1, %rdx
    incq %rdi
    decq %rsi
    jmp .L_tl_string_to_f64_exp_loop
.L_tl_string_to_f64_exp_check_plus:
    cmpb $43, %cl
    jne .L_tl_string_to_f64_exp_loop
    incq %rdi
    decq %rsi
.L_tl_string_to_f64_exp_loop:
    testq %rsi, %rsi
    jz .L_tl_string_to_f64_exp_apply
    movzbl (%rdi), %ecx
    cmpb $48, %cl
    jb .L_tl_string_to_f64_exp_apply
    cmpb $57, %cl
    ja .L_tl_string_to_f64_exp_apply
    imulq $10, %r11, %r11
    subq $48, %rcx
    addq %rcx, %r11
    incq %rdi
    decq %rsi
    jmp .L_tl_string_to_f64_exp_loop
.L_tl_string_to_f64_exp_apply:
    testq %rdx, %rdx
    jz .L_tl_string_to_f64_build
    negq %r11
.L_tl_string_to_f64_build:
    subq %r9, %r11
    cvtsi2sdq %rax, %xmm0
    movabsq $0x4024000000000000, %rax
    movq %rax, %xmm1
    testq %r11, %r11
    jz .L_tl_string_to_f64_apply_sign
    jg .L_tl_string_to_f64_pow_pos
    negq %r11
.L_tl_string_to_f64_pow_neg_loop:
    divsd %xmm1, %xmm0
    decq %r11
    jnz .L_tl_string_to_f64_pow_neg_loop
    jmp .L_tl_string_to_f64_apply_sign
.L_tl_string_to_f64_pow_pos:
.L_tl_string_to_f64_pow_pos_loop:
    mulsd %xmm1, %xmm0
    decq %r11
    jnz .L_tl_string_to_f64_pow_pos_loop
.L_tl_string_to_f64_apply_sign:
    testq %r8, %r8
    jz .L_tl_string_to_f64_done
    movq %xmm0, %rax
    movabsq $0x8000000000000000, %rcx
    xorq %rcx, %rax
    movq %rax, %xmm0
.L_tl_string_to_f64_done:
    pop %rsi
    pop %rdi
    ret

_tl_check:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp
    movsd %xmm0, -8(%rbp)
    movsd %xmm1, -16(%rbp)
_tl_check.entry:
    movsd -8(%rbp), %xmm0
    movsd -16(%rbp), %xmm1
    ucomisd %xmm1, %xmm0
    sete %al
    movzbq %al, %rax
    movb %al, -17(%rbp)
    movzbq -17(%rbp), %rax
    testb %al, %al
    jnz _tl_check.then.0
    jmp _tl_check.else.1
_tl_check.then.0:
    movq $0, -32(%rbp)
    jmp _tl_check.merge.2
_tl_check.else.1:
    movq $1, -32(%rbp)
    jmp _tl_check.merge.2
_tl_check.merge.2:
    movq -32(%rbp), %rax
    mov %rbp, %rsp
    pop %rbp
    ret
main:
    push %rbp
    mov %rsp, %rbp
    sub $592, %rsp
main.entry:
    leaq -16(%rbp), %rax
    movq %rax, -24(%rbp)
    movq -24(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -32(%rbp)
    movq -32(%rbp), %r10
    leaq .L_tl_str_0(%rip), %rax
    movq %rax, (%r10)
    movq -24(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -40(%rbp)
    movq -40(%rbp), %r10
    movq $3, %rax
    movq %rax, (%r10)
    movq -24(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -48(%rbp)
    movq -48(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -56(%rbp)
    movq -24(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -64(%rbp)
    movq -64(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -72(%rbp)
    movq -56(%rbp), %rcx
    movq -72(%rbp), %rdx
    sub $32, %rsp
    call tl_string_to_f64
    add $32, %rsp
    movsd %xmm0, -80(%rbp)
    movsd -80(%rbp), %xmm0
    movabsq $0x0, %rax
    movq %rax, %xmm1
    sub $32, %rsp
    call _tl_check
    add $32, %rsp
    movq %rax, -88(%rbp)
    leaq -104(%rbp), %rax
    movq %rax, -112(%rbp)
    movq -112(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -120(%rbp)
    movq -120(%rbp), %r10
    leaq .L_tl_str_1(%rip), %rax
    movq %rax, (%r10)
    movq -112(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -128(%rbp)
    movq -128(%rbp), %r10
    movq $3, %rax
    movq %rax, (%r10)
    movq -112(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -136(%rbp)
    movq -136(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -144(%rbp)
    movq -112(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -152(%rbp)
    movq -152(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -160(%rbp)
    movq -144(%rbp), %rcx
    movq -160(%rbp), %rdx
    sub $32, %rsp
    call tl_string_to_f64
    add $32, %rsp
    movsd %xmm0, -168(%rbp)
    movsd -168(%rbp), %xmm0
    movabsq $0x3ff8000000000000, %rax
    movq %rax, %xmm1
    sub $32, %rsp
    call _tl_check
    add $32, %rsp
    movq %rax, -176(%rbp)
    leaq -192(%rbp), %rax
    movq %rax, -200(%rbp)
    movq -200(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -208(%rbp)
    movq -208(%rbp), %r10
    leaq .L_tl_str_2(%rip), %rax
    movq %rax, (%r10)
    movq -200(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -216(%rbp)
    movq -216(%rbp), %r10
    movq $3, %rax
    movq %rax, (%r10)
    movq -200(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -224(%rbp)
    movq -224(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -232(%rbp)
    movq -200(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -240(%rbp)
    movq -240(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -248(%rbp)
    movq -232(%rbp), %rcx
    movq -248(%rbp), %rdx
    sub $32, %rsp
    call tl_string_to_f64
    add $32, %rsp
    movsd %xmm0, -256(%rbp)
    movsd -256(%rbp), %xmm0
    movabsq $0x4059000000000000, %rax
    movq %rax, %xmm1
    sub $32, %rsp
    call _tl_check
    add $32, %rsp
    movq %rax, -264(%rbp)
    leaq -280(%rbp), %rax
    movq %rax, -288(%rbp)
    movq -288(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -296(%rbp)
    movq -296(%rbp), %r10
    leaq .L_tl_str_3(%rip), %rax
    movq %rax, (%r10)
    movq -288(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -304(%rbp)
    movq -304(%rbp), %r10
    movq $5, %rax
    movq %rax, (%r10)
    movq -288(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -312(%rbp)
    movq -312(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -320(%rbp)
    movq -288(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -328(%rbp)
    movq -328(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -336(%rbp)
    movq -320(%rbp), %rcx
    movq -336(%rbp), %rdx
    sub $32, %rsp
    call tl_string_to_f64
    add $32, %rsp
    movsd %xmm0, -344(%rbp)
    movsd -344(%rbp), %xmm0
    movabsq $0xc002000000000000, %rax
    movq %rax, %xmm1
    sub $32, %rsp
    call _tl_check
    add $32, %rsp
    movq %rax, -352(%rbp)
    leaq -368(%rbp), %rax
    movq %rax, -376(%rbp)
    movq -376(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -384(%rbp)
    movq -384(%rbp), %r10
    leaq .L_tl_str_4(%rip), %rax
    movq %rax, (%r10)
    movq -376(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -392(%rbp)
    movq -392(%rbp), %r10
    movq $5, %rax
    movq %rax, (%r10)
    movq -376(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -400(%rbp)
    movq -400(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -408(%rbp)
    movq -376(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -416(%rbp)
    movq -416(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -424(%rbp)
    movq -408(%rbp), %rcx
    movq -424(%rbp), %rdx
    sub $32, %rsp
    call tl_string_to_f64
    add $32, %rsp
    movsd %xmm0, -432(%rbp)
    movsd -432(%rbp), %xmm0
    movabsq $0x4072c00000000000, %rax
    movq %rax, %xmm1
    sub $32, %rsp
    call _tl_check
    add $32, %rsp
    movq %rax, -440(%rbp)
    leaq -456(%rbp), %rax
    movq %rax, -464(%rbp)
    movq -464(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -472(%rbp)
    movq -472(%rbp), %r10
    leaq .L_tl_str_5(%rip), %rax
    movq %rax, (%r10)
    movq -464(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -480(%rbp)
    movq -480(%rbp), %r10
    movq $5, %rax
    movq %rax, (%r10)
    movq -464(%rbp), %rax
    movq $0, %rcx
    addq %rcx, %rax
    movq %rax, -488(%rbp)
    movq -488(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -496(%rbp)
    movq -464(%rbp), %rax
    movq $8, %rcx
    addq %rcx, %rax
    movq %rax, -504(%rbp)
    movq -504(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -512(%rbp)
    movq -496(%rbp), %rcx
    movq -512(%rbp), %rdx
    sub $32, %rsp
    call tl_string_to_f64
    add $32, %rsp
    movsd %xmm0, -520(%rbp)
    movsd -520(%rbp), %xmm0
    movabsq $0x4004000000000000, %rax
    movq %rax, %xmm1
    sub $32, %rsp
    call _tl_check
    add $32, %rsp
    movq %rax, -528(%rbp)
    movq -440(%rbp), %rax
    movq -528(%rbp), %rcx
    addq %rcx, %rax
    movq %rax, -536(%rbp)
    movq -352(%rbp), %rax
    movq -536(%rbp), %rcx
    addq %rcx, %rax
    movq %rax, -544(%rbp)
    movq -264(%rbp), %rax
    movq -544(%rbp), %rcx
    addq %rcx, %rax
    movq %rax, -552(%rbp)
    movq -176(%rbp), %rax
    movq -552(%rbp), %rcx
    addq %rcx, %rax
    movq %rax, -560(%rbp)
    movq -88(%rbp), %rax
    movq -560(%rbp), %rcx
    addq %rcx, %rax
    movq %rax, -568(%rbp)
    movq -568(%rbp), %rax
    movq %rax, -576(%rbp)
    movq -576(%rbp), %rax
    movq $0, %rcx
    cmpq %rcx, %rax
    sete %al
    movzbq %al, %rax
    movb %al, -577(%rbp)
    movzbq -577(%rbp), %rax
    testb %al, %al
    jnz main.then.0
    jmp main.else.1
main.then.0:
    movq $42, -592(%rbp)
    jmp main.merge.2
main.else.1:
    movq -576(%rbp), %rax
    movq %rax, -592(%rbp)
    jmp main.merge.2
main.merge.2:
    movq -592(%rbp), %rax
    mov %rbp, %rsp
    pop %rbp
    ret
