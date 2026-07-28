.data
.globl _tl_shared_shared
_tl_shared_shared:
    .quad 2
    .section .rodata
.L_tl_str_data_l10_304307728_937500463:
    .string "0123456789"
    .balign 8
.L_tl_str_l10_304307728_937500463:
    .quad .L_tl_str_data_l10_304307728_937500463
    .quad 10
.L_tl_str_data_l1_46_46:
    .string "-"
    .balign 8
.L_tl_str_l1_46_46:
    .quad .L_tl_str_data_l1_46_46
    .quad 1
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
.L_tl_str_data_l1_59_59:
    .string ":"
    .balign 8
.L_tl_str_l1_59_59:
    .quad .L_tl_str_data_l1_59_59
    .quad 1
.L_tl_str_data_l2_7762_4382:
    .string ": "
    .balign 8
.L_tl_str_l2_7762_4382:
    .quad .L_tl_str_data_l2_7762_4382
    .quad 2
.L_tl_str_data_l4_264904958_75213898:
    .string "tl: "
    .balign 8
.L_tl_str_l4_264904958_75213898:
    .quad .L_tl_str_data_l4_264904958_75213898
    .quad 4
.L_tl_str_data_l33_1631118949_1000764118:
    .string "array index out of bounds: index="
    .balign 8
.L_tl_str_l33_1631118949_1000764118:
    .quad .L_tl_str_data_l33_1631118949_1000764118
    .quad 33
.L_tl_str_data_l8_905955447_756090375:
    .string " length="
    .balign 8
.L_tl_str_l8_905955447_756090375:
    .quad .L_tl_str_data_l8_905955447_756090375
    .quad 8
.L_tl_str_data_l1_11_11:
    .string "\n"
    .balign 8
.L_tl_str_l1_11_11:
    .quad .L_tl_str_data_l1_11_11
    .quad 1
.L_tl_str_data_l46_1086198315_356156002:
    .string "integer division or remainder error: dividend="
    .balign 8
.L_tl_str_l46_1086198315_356156002:
    .quad .L_tl_str_data_l46_1086198315_356156002
    .quad 46
.L_tl_str_data_l9_947384945_655811481:
    .string " divisor="
    .balign 8
.L_tl_str_l9_947384945_655811481:
    .quad .L_tl_str_data_l9_947384945_655811481
    .quad 9
.L_tl_str_data_l32_1951757166_1356077733:
    .string "shift count out of range: count="
    .balign 8
.L_tl_str_l32_1951757166_1356077733:
    .quad .L_tl_str_data_l32_1951757166_1356077733
    .quad 32
.L_tl_str_data_l7_56598913_2146427533:
    .string " width="
    .balign 8
.L_tl_str_l7_56598913_2146427533:
    .quad .L_tl_str_data_l7_56598913_2146427533
    .quad 7
.L_tl_str_data_l7_910180273_741428058:
    .string "panic: "
    .balign 8
.L_tl_str_l7_910180273_741428058:
    .quad .L_tl_str_data_l7_910180273_741428058
    .quad 7
.L_tl_str_data_l24_1300740986_1050262163:
    .string "tl: invalid region mark\n"
    .balign 8
.L_tl_str_l24_1300740986_1050262163:
    .quad .L_tl_str_data_l24_1300740986_1050262163
    .quad 24
.L_tl_str_data_l22_1063972566_1775948496:
    .string "tl: allocation failed\n"
    .balign 8
.L_tl_str_l22_1063972566_1775948496:
    .quad .L_tl_str_data_l22_1063972566_1775948496
    .quad 22
.L_tl_str_data_l17_601028665_2058124766:
    .string "stdlib/runtime.tl"
    .balign 8
.L_tl_str_l17_601028665_2058124766:
    .quad .L_tl_str_data_l17_601028665_2058124766
    .quad 17

    .section .tbss,"awT",@nobits
    .balign 8
    .globl tl_current_arena
tl_current_arena:
    .zero 8

    .section .bss
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
.globl _tl_start
.globl _tl_stdlib_runtime_stdlib_runtime_os_write
_tl_stdlib_runtime_stdlib_runtime_os_write:
    pushq %rbp
    movq %rsp, %rbp
    subq $64, %rsp
    movq %rdi, -8(%rbp)
    movq %rsi, -16(%rbp)
    movq %rdx, -24(%rbp)
.Lf0_entry:
    movq -16(%rbp), %r8
    movq %r8, -64(%rbp)
    movq -8(%rbp), %rdi
    movq -64(%rbp), %rsi
    movq -24(%rbp), %rdx
    movl $1, %eax
    syscall
    movq %rax, -56(%rbp)
    leave
    ret

.globl _tl_stdlib_runtime_stdlib_runtime_os_exit
_tl_stdlib_runtime_stdlib_runtime_os_exit:
    pushq %rbp
    movq %rsp, %rbp
    subq $32, %rsp
    movq %rdi, -8(%rbp)
.Lf1_entry:
    movq -8(%rbp), %rdi
    movl $231, %eax
    syscall
    movq -8(%rbp), %rdi
    leave
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl _tl_stdlib_runtime_stdlib_runtime_abort_write
_tl_stdlib_runtime_stdlib_runtime_abort_write:
    subq $104, %rsp
    movq %rdi, 88(%rsp)
.Lf2_entry:
    movq 88(%rsp), %r10
    movq 8(%r10), %r8
    movq %r8, 8(%rsp)
    movq (%r10), %r8
    movl $2, %edi
    movq %r8, %rsi
    movq 8(%rsp), %rdx
    call _tl_stdlib_runtime_stdlib_runtime_os_write
    addq $104, %rsp
    ret

.globl _tl_stdlib_runtime_stdlib_runtime_abort_write_decimal
_tl_stdlib_runtime_stdlib_runtime_abort_write_decimal:
    subq $184, %rsp
    movq %rdi, 168(%rsp)
.Lf3_entry:
    cmpq $10, 168(%rsp)
    jb .Lf3_if_else.1
.Lf3_if_then.0:
    movq 168(%rsp), %rax
    movabsq $-3689348814741910323, %r8
    mulq %r8
    movq %rdx, %rax
    shrq $3, %rax
    movq %rax, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_decimal
    jmp .Lf3_if_merge.2
.Lf3_if_else.1:
.Lf3_if_merge.2:
    movq 168(%rsp), %rax
    movq %rax, %r10
    movabsq $-3689348814741910323, %r8
    mulq %r8
    shrq $3, %rdx
    imulq $10, %rdx, %r8
    movq %r10, %rax
    subq %r8, %rax
    leaq .L_tl_str_l10_304307728_937500463(%rip), %r8
    movq (%r8), %r8
    movq %r8, 64(%rsp)
    movq %rax, %r8
    movq %r8, 40(%rsp)
    movq 64(%rsp), %r10
    movq 40(%rsp), %r8
    addq %r8, %r10
    movl $2, %edi
    movq %r10, %rsi
    movl $1, %edx
    call _tl_stdlib_runtime_stdlib_runtime_os_write
    addq $184, %rsp
    ret

.globl _tl_stdlib_runtime_stdlib_runtime_abort_write_negative_decimal
_tl_stdlib_runtime_stdlib_runtime_abort_write_negative_decimal:
    subq $184, %rsp
    movq %rdi, 168(%rsp)
.Lf4_entry:
    cmpq $-10, 168(%rsp)
    jg .Lf4_if_else.1
.Lf4_if_then.0:
    movq 168(%rsp), %r10
    movq %r10, %rax
    movabsq $7378697629483820647, %r8
    imulq %r8
    movq %rdx, %rax
    shrq $63, %rax
    sarq $2, %rdx
    addq %rax, %rdx
    movq %rdx, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_negative_decimal
    jmp .Lf4_if_merge.2
.Lf4_if_else.1:
.Lf4_if_merge.2:
    movq 168(%rsp), %r10
    movq %r10, %rax
    movabsq $7378697629483820647, %r8
    imulq %r8
    movq %rdx, %rax
    shrq $63, %rax
    sarq $2, %rdx
    addq %rax, %rdx
    imulq $10, %rdx, %rax
    subq %rax, %r10
    movq %r10, 88(%rsp)
    xorl %r8d, %r8d
    subq 88(%rsp), %r8
    movq %r8, 80(%rsp)
    leaq .L_tl_str_l10_304307728_937500463(%rip), %r8
    movq (%r8), %r8
    movq %r8, %r10
    movq 80(%rsp), %r8
    addq %r8, %r10
    movl $2, %edi
    movq %r10, %rsi
    movl $1, %edx
    call _tl_stdlib_runtime_stdlib_runtime_os_write
    addq $184, %rsp
    ret

.globl _tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal
_tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal:
    subq $56, %rsp
    movq %rdi, 40(%rsp)
.Lf5_entry:
    cmpq $0, 40(%rsp)
    jge .Lf5_if_else.1
.Lf5_if_then.0:
    leaq .L_tl_str_l1_46_46(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 40(%rsp), %rdi
    addq $56, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_abort_write_negative_decimal
.Lf5_if_else.1:
    movq 40(%rsp), %r8
    movq %r8, %rdi
    addq $56, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_abort_write_decimal

.globl tl_oob_abort
tl_oob_abort:
    subq $40, %rsp
.Lf6_entry:
    leaq .L_tl_str_l30_684964583_949472601(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movl $134, %edi
    addq $40, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl tl_div_abort
tl_div_abort:
    subq $40, %rsp
.Lf7_entry:
    leaq .L_tl_str_l40_150886025_1314050685(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movl $135, %edi
    addq $40, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl tl_shift_abort
tl_shift_abort:
    subq $40, %rsp
.Lf8_entry:
    leaq .L_tl_str_l29_1993323280_919009571(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movl $129, %edi
    addq $40, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl _tl_stdlib_runtime_stdlib_runtime_abort_write_site
_tl_stdlib_runtime_stdlib_runtime_abort_write_site:
    subq $264, %rsp
    movq %rdi, 248(%rsp)
.Lf9_entry:
    movq 248(%rsp), %r10
    movq (%r10), %r8
    movq %r8, 56(%rsp)
    movq 8(%r10), %r8
    movq %r8, 40(%rsp)
    movq 16(%r10), %r8
    movq %r8, 24(%rsp)
    movq 24(%r10), %r8
    movq %r8, 8(%rsp)
    movq 56(%rsp), %r8
    movq %r8, 136(%rsp)
    movl $2, %edi
    movq 136(%rsp), %rsi
    movq 40(%rsp), %rdx
    call _tl_stdlib_runtime_stdlib_runtime_os_write
    leaq .L_tl_str_l1_59_59(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 24(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal
    leaq .L_tl_str_l1_59_59(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 8(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal
    leaq .L_tl_str_l2_7762_4382(%rip), %r8
    movq %r8, %rdi
    addq $264, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_abort_write

.globl tl_oob_abort_at
tl_oob_abort_at:
    subq $136, %rsp
    movq %rdi, 120(%rsp)
    movq %rsi, 112(%rsp)
    movq %rdx, 104(%rsp)
.Lf10_entry:
    leaq .L_tl_str_l4_264904958_75213898(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 120(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_site
    leaq .L_tl_str_l33_1631118949_1000764118(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 112(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal
    leaq .L_tl_str_l8_905955447_756090375(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 104(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal
    leaq .L_tl_str_l1_11_11(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movl $134, %edi
    addq $136, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl tl_div_abort_at
tl_div_abort_at:
    subq $136, %rsp
    movq %rdi, 120(%rsp)
    movq %rsi, 112(%rsp)
    movq %rdx, 104(%rsp)
.Lf11_entry:
    leaq .L_tl_str_l4_264904958_75213898(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 120(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_site
    leaq .L_tl_str_l46_1086198315_356156002(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 112(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal
    leaq .L_tl_str_l9_947384945_655811481(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 104(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal
    leaq .L_tl_str_l1_11_11(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movl $135, %edi
    addq $136, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl tl_shift_abort_at
tl_shift_abort_at:
    subq $136, %rsp
    movq %rdi, 120(%rsp)
    movq %rsi, 112(%rsp)
    movq %rdx, 104(%rsp)
.Lf12_entry:
    leaq .L_tl_str_l4_264904958_75213898(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 120(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_site
    leaq .L_tl_str_l32_1951757166_1356077733(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 112(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal
    leaq .L_tl_str_l7_56598913_2146427533(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 104(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_signed_decimal
    leaq .L_tl_str_l1_11_11(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movl $129, %edi
    addq $136, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl tl_panic_at
tl_panic_at:
    subq $264, %rsp
    movq %rdi, 248(%rsp)
    movq %rsi, 240(%rsp)
.Lf13_entry:
    movq 240(%rsp), %r10
    movq 8(%r10), %r8
    movq %r8, 8(%rsp)
    movq %r8, 224(%rsp)
    cmpq $0, 8(%rsp)
    jle .Lf13_if_else.1
.Lf13_if_then.0:
    movq (%r10), %r8
    movq %r8, 192(%rsp)
    movq 224(%rsp), %r8
    subq $1, %r8
    movq 192(%rsp), %r10
    movzbq (%r10,%r8,1), %r9
    movq %r9, 160(%rsp)
    movzbq 160(%rsp), %r8
    cmpq $10, %r8
    sete %r8b
    movzbq %r8b, %r8
    movq %r8, 136(%rsp)
    pushq %r8
    movzbq 144(%rsp), %r8
    movq %r8, 128(%rsp)
    popq %r8
    jmp .Lf13_if_merge.2
.Lf13_if_else.1:
    movq $0, 120(%rsp)
.Lf13_if_merge.2:
    leaq .L_tl_str_l4_264904958_75213898(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 248(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write_site
    leaq .L_tl_str_l7_910180273_741428058(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movq 240(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    cmpq $0, 120(%rsp)
    je .Lf13_if_else.4
.Lf13_if_then.3:
    jmp .Lf13_if_merge.5
.Lf13_if_else.4:
    leaq .L_tl_str_l1_11_11(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
.Lf13_if_merge.5:
    movl $134, %edi
    addq $264, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl tl_abort_string
tl_abort_string:
    subq $40, %rsp
    movq %rdi, 24(%rsp)
.Lf14_entry:
    movq 24(%rsp), %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movl $134, %edi
    addq $40, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl tl_array_fill8
tl_array_fill8:
    subq $104, %rsp
    movq %rdi, 88(%rsp)
    movq %rsi, 80(%rsp)
    movq %rdx, 72(%rsp)
.Lf15_entry:
    movq 88(%rsp), %r8
    movq %r8, 64(%rsp)
    movq $0, 48(%rsp)
.Lf15_while_header.0:
    movq 80(%rsp), %r8
    cmpq %r8, 48(%rsp)
    jge .Lf15_while_exit.2
.Lf15_while_body.1:
    movq 64(%rsp), %r10
    movq 48(%rsp), %r8
    movq 72(%rsp), %r9
    movq %r9, (%r10,%r8,8)
    movq 48(%rsp), %rax
    addq $1, %rax
    movq %rax, 48(%rsp)
    jmp .Lf15_while_header.0
.Lf15_while_exit.2:
    addq $104, %rsp
    ret

.globl tl_region_abort
tl_region_abort:
    subq $40, %rsp
.Lf16_entry:
    leaq .L_tl_str_l24_1300740986_1050262163(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movl $134, %edi
    addq $40, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl tl_oom_abort
tl_oom_abort:
    subq $40, %rsp
.Lf17_entry:
    leaq .L_tl_str_l22_1063972566_1775948496(%rip), %r8
    movq %r8, %rdi
    call _tl_stdlib_runtime_stdlib_runtime_abort_write
    movl $134, %edi
    addq $40, %rsp
    jmp _tl_stdlib_runtime_stdlib_runtime_os_exit

.globl _tl_helper_helper_opaque
_tl_helper_helper_opaque:
    subq $72, %rsp
    movq %rdi, 56(%rsp)
    movq %rsi, 48(%rsp)
.Lf18_entry:
    cmpq $1, 48(%rsp)
    jle .Lf18_if_else.1
.Lf18_if_then.0:
    movq 48(%rsp), %r8
    subq $1, %r8
    movq 56(%rsp), %rdi
    movq %r8, %rsi
    call _tl_helper_helper_opaque
    movq %rax, 8(%rsp)
    movq 56(%rsp), %rax
    movq 8(%rsp), %r8
    addq %r8, %rax
    addq $72, %rsp
    ret
.Lf18_if_else.1:
    movq 56(%rsp), %rax
    addq $72, %rsp
    ret

.globl _tl_helper_helper
_tl_helper_helper:
    subq $40, %rsp
.Lf19_entry:
    movl $38, %r9d
    movq _tl_shared_shared(%rip), %r8
    addq %r8, %r9
    movq %r9, %rdi
    movl $1, %esi
    addq $40, %rsp
    jmp _tl_helper_helper_opaque

.globl main
main:
    subq $24, %rsp
.Lf20_entry:
    call _tl_helper_helper
    movq _tl_shared_shared(%rip), %r8
    addq %r8, %rax
    addq $24, %rsp
    ret

    .globl tl_memcpy
tl_memcpy:
    movq %rdx, %rcx
    cmpq %rsi, %rdi
    jbe .Ltl_memcpy_fwd
    movq %rsi, %rax
    addq %rcx, %rax
    cmpq %rax, %rdi
    jae .Ltl_memcpy_fwd
    leaq -1(%rdi,%rcx), %rdi
    leaq -1(%rsi,%rcx), %rsi
    std
    rep movsb
    cld
    ret
.Ltl_memcpy_fwd:
    movq %rcx, %r11
    shrq $3, %rcx
    rep movsq
    movq %r11, %rcx
    andq $7, %rcx
    rep movsb
    ret
    .globl tl_memchr
tl_memchr:
    testq %rsi, %rsi
    jle .Ltl_memchr_not_found
    movzbl %dl, %edx
    xorq %rax, %rax
.Ltl_memchr_loop:
    cmpb %dl, (%rdi,%rax)
    je .Ltl_memchr_found
    incq %rax
    cmpq %rsi, %rax
    jl .Ltl_memchr_loop
.Ltl_memchr_not_found:
    movq $-1, %rax
.Ltl_memchr_found:
    ret
    .globl tl_array_zero
tl_array_zero:
    cmpq $64, %rsi
    jb .Ltl_array_zero_fill
    movq %fs:tl_current_arena@tpoff, %r8
    testq %r8, %r8
    jz .Ltl_array_zero_fill
    testq $5, 48(%r8)
    jnz .Ltl_array_zero_fill
    ret
.Ltl_array_zero_fill:
    movq %rsi, %rcx
    shrq $3, %rcx
    xorl %eax, %eax
    rep stosq
    movq %rsi, %rcx
    andq $7, %rcx
    rep stosb
    ret
    .globl tl_tlci_call_image_entry
tl_tlci_call_image_entry:
    movq %rdi, %rax
    movq %rsi, %rdi
    movq %rdx, %rsi
    subq $8, %rsp
    call *%rax
    addq $8, %rsp
    ret

    .globl tl_thread_init
tl_thread_init:
    movq $4096, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_thread_init_abort
    movq $tl_current_arena@tpoff, %rdi
    subq %rdi, %rax
    movq %rax, %rsi
    movq $0x1002, %rdi
    movq $158, %rax
    syscall
    testq %rax, %rax
    js .L_tl_thread_init_abort
    ret
.L_tl_thread_init_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_arena_current
tl_arena_current:
    movq %fs:tl_current_arena@tpoff, %rax
    ret

    .globl tl_arena_set
tl_arena_set:
    movq %rdi, %fs:tl_current_arena@tpoff
    ret

    .globl tl_arena_poison_enable
tl_arena_poison_enable:
    movq $1, .L_tl_arena_poison_enabled(%rip)
    ret

    .globl tl_arena_make
tl_arena_make:
    movq $0x4000000, %rsi
    jmp .L_tl_arena_make_sized

    .globl tl_arena_make_small
tl_arena_make_small:
    movq $0x1000000, %rsi
.L_tl_arena_make_sized:
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
    movq $0, 32(%rax)
    movq %rax, 40(%rax)
    movq $0, 48(%rax)
    movq %rax, 56(%rax)
    leaq 64(%rax), %rcx
    movq %rcx, 8(%rax)
    movq %rcx, 16(%rax)
    movq %rax, %rcx
    addq %rsi, %rcx
    movq %rcx, 24(%rax)
    ret
.L_tl_arena_make_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_arena_make_atomic
tl_arena_make_atomic:
    movq $0x4000000, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    testq %rax, %rax
    js .L_tl_arena_make_atomic_abort
    movq $0, 0(%rax)
    movq $0, 32(%rax)
    movq %rax, 40(%rax)
    movq $1, 48(%rax)
    movq %rax, 56(%rax)
    leaq 64(%rax), %rcx
    movq %rcx, 8(%rax)
    movq %rcx, 16(%rax)
    movq %rax, %rcx
    addq $0x4000000, %rcx
    movq %rcx, 24(%rax)
    ret
.L_tl_arena_make_atomic_abort:
    movq $60, %rax
    movq $134, %rdi
    syscall

    .globl tl_arena_destroy
tl_arena_destroy:
    push %rbx
    push %r12
    movq %rdi, %rbx
    xorq %r12, %r12
    testq %rbx, %rbx
    jz .L_tl_arena_destroy_active_done
    movq 40(%rbx), %r12
    testq %r12, %r12
    jz .L_tl_arena_destroy_loop
    movq 56(%r12), %rbx
    testq %rbx, %rbx
    jnz .L_tl_arena_destroy_head_ready
    movq %r12, %rbx
.L_tl_arena_destroy_head_ready:
.L_tl_arena_destroy_retired_ready:
    movq 32(%r12), %r12
.L_tl_arena_destroy_loop:
    testq %rbx, %rbx
    jz .L_tl_arena_destroy_active_done
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
.L_tl_arena_destroy_active_done:
    movq %r12, %rbx
.L_tl_arena_destroy_retired_loop:
    testq %rbx, %rbx
    jz .L_tl_arena_destroy_done
    movq 32(%rbx), %r8
    push %r8
    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_arena_destroy_retired_unmap
    movq 8(%rbx), %rdi
    movq 24(%rbx), %rcx
    subq %rdi, %rcx
    jbe .L_tl_arena_destroy_retired_unmap
    movb $0xA5, %al
    rep stosb
.L_tl_arena_destroy_retired_unmap:
    movq 24(%rbx), %rsi
    subq %rbx, %rsi
    movq %rbx, %rdi
    movq $11, %rax
    syscall
    pop %r8
    movq %r8, %rbx
    jmp .L_tl_arena_destroy_retired_loop
.L_tl_arena_destroy_done:
    pop %r12
    pop %rbx
    ret

_tl_start:
    movq (%rsp), %rax
    movq %rax, .L_tl_argc(%rip)
    leaq 8(%rsp), %rax
    movq %rax, .L_tl_argv(%rip)
    movq (%rsp), %rax
    leaq 16(%rsp,%rax,8), %rax
    movq %rax, .L_tl_envp(%rip)
    call tl_thread_init
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
