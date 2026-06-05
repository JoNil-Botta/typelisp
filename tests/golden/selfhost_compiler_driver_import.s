.data
.globl _tl_shared_u2etl_colon_colonshared
_tl_shared_u2etl_colon_colonshared:
    .quad 2
    .globl tl_current_arena
    .section .bss
    .balign 8
tl_current_arena:
    .zero 8
    .balign 8
.L_tl_arena_poison_enabled:
    .zero 8

    .data
    .balign 8
.L_tl_argc:
    .quad 0
.L_tl_argv:
    .quad 0

    .data
    .balign 8
.L_tl_envp:
    .quad 0

.text
.globl _start
.globl _tl_helper_u2etl_colon_colonhelper
_tl_helper_u2etl_colon_colonhelper:
    pushq %rbp
    movq %rsp, %rbp
    subq $16, %rsp
.Lf0_entry:
    movq $38, %rax
    movq _tl_shared_u2etl_colon_colonshared(%rip), %rbx
    addq %rbx, %rax
    movq %rax, -16(%rbp)
    movq -16(%rbp), %rax
    leave
    ret

.globl main
main:
    pushq %rbp
    movq %rsp, %rbp
    subq $16, %rsp
.Lf1_entry:
    call _tl_helper_u2etl_colon_colonhelper
    movq %rax, -8(%rbp)
    movq -8(%rbp), %rax
    movq _tl_shared_u2etl_colon_colonshared(%rip), %rbx
    addq %rbx, %rax
    movq %rax, -16(%rbp)
    movq -16(%rbp), %rax
    leave
    ret

    .globl tl_arena_current
tl_arena_current:
    movq tl_current_arena(%rip), %rax
    ret

    .globl tl_arena_set
tl_arena_set:
    movq %rdi, tl_current_arena(%rip)
    ret

    .globl tl_arena_poison_enable
tl_arena_poison_enable:
    movq $1, .L_tl_arena_poison_enabled(%rip)
    ret

    .globl tl_arena_make
tl_arena_make:
    movq $0x4000000, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_arena_make_abort
    movq $0, 0(%rax)
    leaq 32(%rax), %rcx
    movq %rcx, 8(%rax)
    movq %rcx, 16(%rax)
    movq %rax, %rcx
    addq $0x4000000, %rcx
    movq %rcx, 24(%rax)
    ret
.L_tl_arena_make_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_arena_destroy
tl_arena_destroy:
    push %rbx
    movq %rdi, %rbx
.L_tl_arena_destroy_loop:
    testq %rbx, %rbx
    jz .L_tl_arena_destroy_done
    movq 0(%rbx), %r8
    push %r8
    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_arena_destroy_unmap
    movq 8(%rbx), %rdi
    movq 24(%rbx), %rcx
    subq %rdi, %rcx
    jbe .L_tl_arena_destroy_unmap
    movb $0xA5, %al
    rep stosb
.L_tl_arena_destroy_unmap:
    movq 24(%rbx), %rsi
    subq %rbx, %rsi
    movq %rbx, %rdi
    movq $11, %rax
    syscall
    pop %r8
    movq %r8, %rbx
    jmp .L_tl_arena_destroy_loop
.L_tl_arena_destroy_done:
    pop %rbx
    ret

_start:
    movq (%rsp), %rax
    movq %rax, .L_tl_argc(%rip)
    leaq 8(%rsp), %rax
    movq %rax, .L_tl_argv(%rip)
    movq (%rsp), %rax
    leaq 16(%rsp,%rax,8), %rax
    movq %rax, .L_tl_envp(%rip)
    movq $0x40000000, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_main_keep_stack
    addq $0x40000000, %rax
    andq $-16, %rax
    movq %rax, %rsp
.L_tl_main_keep_stack:
    call main
    movq %rax, %rdi
    movq $60, %rax
    syscall
