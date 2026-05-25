.data
.globl _tl_shared_u2etl_colon_colonshared
_tl_shared_u2etl_colon_colonshared:
    .quad 2
.text
.globl _start
.globl _tl_helper_u2etl_colon_colonhelper
_tl_helper_u2etl_colon_colonhelper:
    pushq %rbp
    movq %rsp, %rbp
    subq $64, %rsp
    movq %r12, -32(%rbp)
    movq %r13, -40(%rbp)
.L_tl_helper_u2etl_colon_colonhelper_entry:
    movq _tl_shared_u2etl_colon_colonshared(%rip), %rax
    movq %rax, %r12
    movq $38, %rax
    movq %r12, %rbx
    addq %rbx, %rax
    movq %rax, %r13
    movq %r13, %rax
    movq -40(%rbp), %r13
    movq -32(%rbp), %r12
    movq %rbp, %rsp
    popq %rbp
    ret

.globl main
main:
    pushq %rbp
    movq %rsp, %rbp
    subq $64, %rsp
    movq %r12, -32(%rbp)
    movq %r13, -40(%rbp)
.Lmain_entry:
    call _tl_helper_u2etl_colon_colonhelper
    movq %rax, -8(%rbp)
    movq _tl_shared_u2etl_colon_colonshared(%rip), %rax
    movq %rax, %r12
    movq -8(%rbp), %rax
    movq %r12, %rbx
    addq %rbx, %rax
    movq %rax, %r13
    movq %r13, %rax
    movq -40(%rbp), %r13
    movq -32(%rbp), %r12
    movq %rbp, %rsp
    popq %rbp
    ret

_start:
    call main
    movq %rax, %rdi
    movq $60, %rax
    syscall
