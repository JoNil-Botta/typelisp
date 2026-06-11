    .text
    .globl main
    .globl _tl_start

main:
    push %rbp
    mov %rsp, %rbp
    movq $1, %rax
    pushq %rax
    movq $2, %rax
    pushq %rax
    movq $3, %rax
    movq %rax, %rcx
    popq %rax
    imulq %rcx, %rax
    movq %rax, %rcx
    popq %rax
    addq %rcx, %rax
    pop %rbp
    ret

_tl_start:
    call main
    movq %rax, %rdi
    movq $60, %rax
    syscall
