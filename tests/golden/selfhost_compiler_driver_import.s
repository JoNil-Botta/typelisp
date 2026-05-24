.data
.globl _tl_shared
_tl_shared:
    .quad 2
.text
.globl _start
.globl _tl_helper
_tl_helper:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp
.L_tl_helper_entry:
    movq _tl_shared(%rip), %rax
    movq %rax, -16(%rbp)
    movq $38, %rax
    movq -16(%rbp), %rbx
    addq %rbx, %rax
    movq %rax, -24(%rbp)
    movq -24(%rbp), %rax
    movq %rbp, %rsp
    popq %rbp
    ret

.globl main
main:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp
.Lmain_entry:
    call _tl_helper
    movq %rax, -8(%rbp)
    movq _tl_shared(%rip), %rax
    movq %rax, -16(%rbp)
    movq -8(%rbp), %rax
    movq -16(%rbp), %rbx
    addq %rbx, %rax
    movq %rax, -24(%rbp)
    movq -24(%rbp), %rax
    movq %rbp, %rsp
    popq %rbp
    ret

_start:
    call main
    movq %rax, %rdi
    movq $60, %rax
    syscall
