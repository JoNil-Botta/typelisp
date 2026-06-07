.data
.globl _tl_shared_u2etl_colon_colonshared
_tl_shared_u2etl_colon_colonshared:
    .quad 2
    .section .rodata
.L_tl_str_data_l30_684964583_949472601:
    .string "tl: array index out of bounds\n"
    .balign 8
.L_tl_str_l30_684964583_949472601:
    .quad .L_tl_str_data_l30_684964583_949472601
    .quad 30
.L_tl_str_data_l40_150886025_1314050685:
    .string "tl: integer division or remainder error\n"
    .balign 8
.L_tl_str_l40_150886025_1314050685:
    .quad .L_tl_str_data_l40_150886025_1314050685
    .quad 40
.L_tl_str_data_l29_1993323280_919009571:
    .string "tl: shift count out of range\n"
    .balign 8
.L_tl_str_l29_1993323280_919009571:
    .quad .L_tl_str_data_l29_1993323280_919009571
    .quad 29

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
.globl _tl_stdlib_slashruntime_u2etl_colon_colonruntime_ptr_arg
_tl_stdlib_slashruntime_u2etl_colon_colonruntime_ptr_arg:
    pushq %rbp
    movq %rsp, %rbp
    subq $16, %rsp
    movq %rdi, -8(%rbp)
.Lf0_entry:
    movq -8(%rbp), %rax
    movq %rax, -16(%rbp)
    movq -16(%rbp), %rax
    leave
    ret

.globl _tl_stdlib_slashruntime_u2etl_colon_colonruntime_os_write
_tl_stdlib_slashruntime_u2etl_colon_colonruntime_os_write:
    pushq %rbp
    movq %rsp, %rbp
    subq $48, %rsp
    movq %rdi, -8(%rbp)
    movq %rsi, -16(%rbp)
    movq %rdx, -24(%rbp)
.Lf1_entry:
    movq -16(%rbp), %rdi
    call _tl_stdlib_slashruntime_u2etl_colon_colonruntime_ptr_arg
    movq %rax, -40(%rbp)
    movq $1, %rax
    pushq %rax
    movq -8(%rbp), %rax
    pushq %rax
    movq -40(%rbp), %rax
    pushq %rax
    movq -24(%rbp), %rax
    pushq %rax
    popq %rdx
    popq %rsi
    popq %rdi
    popq %rax
    syscall
    movq %rax, -48(%rbp)
    movq -48(%rbp), %rax
    leave
    ret

.globl _tl_stdlib_slashruntime_u2etl_colon_colonruntime_os_exit
_tl_stdlib_slashruntime_u2etl_colon_colonruntime_os_exit:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp
    movq %rdi, -8(%rbp)
.Lf2_entry:
    movq $231, %rax
    pushq %rax
    movq -8(%rbp), %rax
    pushq %rax
    popq %rdi
    popq %rax
    syscall
    movq %rax, -24(%rbp)
    movq -8(%rbp), %rdi
    call _tl_stdlib_slashruntime_u2etl_colon_colonruntime_os_exit
    movq $0, %rax
    leave
    ret

.globl _tl_stdlib_slashruntime_u2etl_colon_colonruntime_abort_write
_tl_stdlib_slashruntime_u2etl_colon_colonruntime_abort_write:
    pushq %rbp
    movq %rsp, %rbp
    subq $80, %rsp
    movq %rdi, -8(%rbp)
.Lf3_entry:
    movq -8(%rbp), %r10
    movq 8(%r10), %rax
    movq %rax, -24(%rbp)
    movq -8(%rbp), %r10
    movq (%r10), %rax
    movq %rax, -48(%rbp)
    movq $2, %rdi
    movq -48(%rbp), %rsi
    movq -24(%rbp), %rdx
    call _tl_stdlib_slashruntime_u2etl_colon_colonruntime_os_write
    movq %rax, -72(%rbp)
    leave
    ret

.globl tl_oob_abort
tl_oob_abort:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp
.Lf4_entry:
    leaq .L_tl_str_l30_684964583_949472601(%rip), %rax
    movq %rax, -8(%rbp)
    movq -8(%rbp), %rdi
    call _tl_stdlib_slashruntime_u2etl_colon_colonruntime_abort_write
    movq %rax, -16(%rbp)
    movq $134, %rdi
    call _tl_stdlib_slashruntime_u2etl_colon_colonruntime_os_exit
    movq %rax, -32(%rbp)

.globl tl_div_abort
tl_div_abort:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp
.Lf5_entry:
    leaq .L_tl_str_l40_150886025_1314050685(%rip), %rax
    movq %rax, -8(%rbp)
    movq -8(%rbp), %rdi
    call _tl_stdlib_slashruntime_u2etl_colon_colonruntime_abort_write
    movq %rax, -16(%rbp)
    movq $135, %rdi
    call _tl_stdlib_slashruntime_u2etl_colon_colonruntime_os_exit
    movq %rax, -32(%rbp)

.globl tl_shift_abort
tl_shift_abort:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp
.Lf6_entry:
    leaq .L_tl_str_l29_1993323280_919009571(%rip), %rax
    movq %rax, -8(%rbp)
    movq -8(%rbp), %rdi
    call _tl_stdlib_slashruntime_u2etl_colon_colonruntime_abort_write
    movq %rax, -16(%rbp)
    movq $129, %rdi
    call _tl_stdlib_slashruntime_u2etl_colon_colonruntime_os_exit
    movq %rax, -32(%rbp)

.globl _tl_helper_u2etl_colon_colonhelper
_tl_helper_u2etl_colon_colonhelper:
    pushq %rbp
    movq %rsp, %rbp
    subq $16, %rsp
.Lf7_entry:
    movq $38, %rax
    movq _tl_shared_u2etl_colon_colonshared(%rip), %r8
    addq %r8, %rax
    movq %rax, -16(%rbp)
    movq -16(%rbp), %rax
    leave
    ret

.globl main
main:
    pushq %rbp
    movq %rsp, %rbp
    subq $16, %rsp
.Lf8_entry:
    call _tl_helper_u2etl_colon_colonhelper
    movq %rax, -8(%rbp)
    movq -8(%rbp), %rax
    movq _tl_shared_u2etl_colon_colonshared(%rip), %r8
    addq %r8, %rax
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

    .globl __errno_location
__errno_location:
    leaq tl_errno(%rip), %rax
    ret

    .globl read
read:
    movq $0, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl write
write:
    movq $1, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl open
open:
    movq $2, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl close
close:
    movq $3, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl lseek
lseek:
    movq $8, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl access
access:
    movq $21, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl mkdir
mkdir:
    movq $83, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl rmdir
rmdir:
    movq $84, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl unlink
unlink:
    movq $87, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl rename
rename:
    movq $82, %rax
    syscall
    jmp .L_tl_shim_ret
    .globl getcwd
getcwd:
    pushq %rdi
    movq $79, %rax
    syscall
    cmpq $-4095, %rax
    jae .L_tl_shim_getcwd_err
    popq %rax
    ret
.L_tl_shim_getcwd_err:
    addq $8, %rsp
    negq %rax
    movl %eax, tl_errno(%rip)
    xorq %rax, %rax
    ret
    .globl getrandom
getrandom:
    movq $318, %rax
    syscall
    jmp .L_tl_shim_ret
.L_tl_shim_ret:
    cmpq $-4095, %rax
    jae .L_tl_shim_err
    ret
.L_tl_shim_err:
    negq %rax
    movl %eax, tl_errno(%rip)
    movq $-1, %rax
    ret

    .globl getpid
getpid:
    movq $39, %rax
    syscall
    ret

    .globl exit
exit:
    movq $231, %rax
    syscall
    ret

    .globl fflush
fflush:
    xorq %rax, %rax
    ret

    .globl strlen
strlen:
    movq %rdi, %rax
.L_tl_strlen_loop:
    cmpb $0, (%rax)
    je .L_tl_strlen_done
    incq %rax
    jmp .L_tl_strlen_loop
.L_tl_strlen_done:
    subq %rdi, %rax
    ret

    .globl getenv
getenv:
    movq .L_tl_envp(%rip), %r8
.L_tl_getenv_loop:
    movq (%r8), %rsi
    testq %rsi, %rsi
    jz .L_tl_getenv_nf
    movq %rdi, %rax
.L_tl_getenv_cmp:
    movb (%rax), %cl
    testb %cl, %cl
    jz .L_tl_getenv_namedone
    movb (%rsi), %dl
    cmpb %cl, %dl
    jne .L_tl_getenv_next
    incq %rax
    incq %rsi
    jmp .L_tl_getenv_cmp
.L_tl_getenv_namedone:
    cmpb $61, (%rsi)
    jne .L_tl_getenv_next
    leaq 1(%rsi), %rax
    ret
.L_tl_getenv_next:
    addq $8, %r8
    jmp .L_tl_getenv_loop
.L_tl_getenv_nf:
    xorq %rax, %rax
    ret

    .data
    .balign 4
tl_errno:
    .long 0
    .text

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
