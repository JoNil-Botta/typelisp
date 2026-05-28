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
    subq $32, %rsp
.L_tl_helper_u2etl_colon_colonhelper_entry:
    movq _tl_shared_u2etl_colon_colonshared(%rip), %rax
    movq %rax, %r8
    movq $38, %rax
    movq %r8, %rbx
    addq %rbx, %rax
    movq %rax, %r8
    movq %r8, %rax
    leave
    ret

.globl main
main:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp
.Lmain_entry:
    call _tl_helper_u2etl_colon_colonhelper
    movq %rax, -8(%rbp)
    movq _tl_shared_u2etl_colon_colonshared(%rip), %rax
    movq %rax, %r8
    movq -8(%rbp), %rax
    movq %r8, %rbx
    addq %rbx, %rax
    movq %rax, %r8
    movq %r8, %rax
    leave
    ret

_start:
    call main
    movq %rax, %rdi
    movq $60, %rax
    syscall
