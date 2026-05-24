    .text
    .globl main


_tl_bits_i64:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp
    movsd %xmm0, -8(%rbp)
_tl_bits_i64.entry:
    movsd -8(%rbp), %xmm0
    movq %xmm0, %rax
    movq %rax, -16(%rbp)
    movq -16(%rbp), %rax
    movq %rax, -24(%rbp)
    movq -24(%rbp), %rax
    mov %rbp, %rsp
    pop %rbp
    ret
main:
    push %rbp
    mov %rsp, %rbp
    sub $80, %rsp
main.entry:
    movabsq $0x3ff0000000000000, %rax
    movq %rax, %xmm0
    sub $32, %rsp
    call _tl_bits_i64
    add $32, %rsp
    movq %rax, -8(%rbp)
    movq -8(%rbp), %rax
    movq $4607182418800017408, %rcx
    cmpq %rcx, %rax
    sete %al
    movzbq %al, %rax
    movb %al, -9(%rbp)
    movzbq -9(%rbp), %rax
    testb %al, %al
    jnz main.then.0
    jmp main.else.1
main.then.0:
    movabsq $0x4000000000000000, %rax
    movq %rax, %xmm0
    sub $32, %rsp
    call _tl_bits_i64
    add $32, %rsp
    movq %rax, -24(%rbp)
    movq -24(%rbp), %rax
    movq $4611686018427387904, %rcx
    cmpq %rcx, %rax
    sete %al
    movzbq %al, %rax
    movb %al, -25(%rbp)
    movzbq -25(%rbp), %rax
    testb %al, %al
    jnz main.then.3
    jmp main.else.4
main.then.3:
    movabsq $0x3fe0000000000000, %rax
    movq %rax, %xmm0
    sub $32, %rsp
    call _tl_bits_i64
    add $32, %rsp
    movq %rax, -40(%rbp)
    movq -40(%rbp), %rax
    movq $4602678819172646912, %rcx
    cmpq %rcx, %rax
    sete %al
    movzbq %al, %rax
    movb %al, -41(%rbp)
    movzbq -41(%rbp), %rax
    testb %al, %al
    jnz main.then.6
    jmp main.else.7
main.then.6:
    movq $42, -56(%rbp)
    jmp main.merge.8
main.else.7:
    movq $3, -56(%rbp)
    jmp main.merge.8
main.merge.8:
    movq -56(%rbp), %rax
    movq %rax, -64(%rbp)
    jmp main.merge.5
main.else.4:
    movq $2, -64(%rbp)
    jmp main.merge.5
main.merge.5:
    movq -64(%rbp), %rax
    movq %rax, -72(%rbp)
    jmp main.merge.2
main.else.1:
    movq $1, -72(%rbp)
    jmp main.merge.2
main.merge.2:
    movq -72(%rbp), %rax
    mov %rbp, %rsp
    pop %rbp
    ret
