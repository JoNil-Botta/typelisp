;; compiler_backend_runtime_windows.tl - Windows backend runtime leaf emitter.
(import compiler_backend_runtime_common as runtime_common)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(define (compiler-backend-runtime-arena-data) : String
  "    .section .bss
    .balign 8
.L_tl_arena_poison_enabled:
    .zero 8

")

(define (compiler-backend-current-arena-load [dst : String]) : String
  (str_cat.str-cat "    movq %gs:0x28, " dst "\n"))

(define (compiler-backend-current-arena-store [src : String]) : String
  (str_cat.str-cat "    movq " src ", %gs:0x28\n"))

(define (compiler-backend-runtime-fast-alloc-functions
  [size-reg : String]
  [next-reg : String]
  [profile : bool]) : String
  (runtime_common.compiler-backend-runtime-fast-alloc-functions
    (compiler-backend-current-arena-load "%r8")
    "64"
    size-reg
    next-reg
    profile))

(define (compiler-backend-runtime-region-mark-functions) : String
  (runtime_common.compiler-backend-runtime-region-mark-functions
    (compiler-backend-current-arena-load "%rax")))

(define (compiler-backend-runtime-data
  [features : (& features runtime_common.CompilerBackendRuntimeFeatures)]) : String
  (runtime_common.compiler-backend-runtime-common-data
    features
    (compiler-backend-runtime-arena-data)))

(define (compiler-backend-runtime-windows-libc-shim-functions) : String
  "    .globl __chkstk
__chkstk:
    pushq %rcx
    pushq %rax
    movq %rax, %rcx
    leaq 16(%rsp), %rax
.L_tl_ck_loop:
    cmpq $4096, %rcx
    jb .L_tl_ck_done
    subq $4096, %rax
    movb $0, (%rax)
    subq $4096, %rcx
    jmp .L_tl_ck_loop
.L_tl_ck_done:
    subq %rcx, %rax
    movb $0, (%rax)
    popq %rax
    popq %rcx
    ret

    .globl tl_setup_argv
tl_setup_argv:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $40, %rsp
    call GetCommandLineA
    movq %rax, %rbx
    xorq %r12, %r12
.L_tl_argv_cmdlen:
    cmpb $0, (%rbx,%r12)
    je .L_tl_argv_cmdlen_done
    incq %r12
    jmp .L_tl_argv_cmdlen
.L_tl_argv_cmdlen_done:
    leaq 1(%r12), %rcx
    subq $32, %rsp
    call .L_tl_boot_alloc
    addq $32, %rsp
    movq %rax, %r13
    xorq %rcx, %rcx
.L_tl_argv_cp:
    cmpq %r12, %rcx
    jge .L_tl_argv_cpd
    movb (%rbx,%rcx), %al
    movb %al, (%r13,%rcx)
    incq %rcx
    jmp .L_tl_argv_cp
.L_tl_argv_cpd:
    movb $0, (%r13,%r12)
    movq $2056, %rcx
    subq $32, %rsp
    call .L_tl_boot_alloc
    addq $32, %rsp
    movq %rax, %r14
    xorq %r15, %r15
    movq %r13, %rbx
.L_tl_argv_scan:
    movb (%rbx), %al
    cmpb $0, %al
    je .L_tl_argv_done
    cmpb $0x20, %al
    jne .L_tl_argv_tokstart
    incq %rbx
    jmp .L_tl_argv_scan
.L_tl_argv_tokstart:
    cmpq $255, %r15
    jge .L_tl_argv_done
    movq %rbx, (%r14,%r15,8)
    incq %r15
    xorl %r9d, %r9d
.L_tl_argv_tok:
    movb (%rbx), %al
    cmpb $0, %al
    je .L_tl_argv_done
    cmpb $0x22, %al
    jne .L_tl_argv_notq
    xorl $1, %r9d
    movq %rbx, %rcx
.L_tl_argv_shift:
    movb 1(%rcx), %al
    movb %al, (%rcx)
    incq %rcx
    cmpb $0, %al
    jne .L_tl_argv_shift
    jmp .L_tl_argv_tok
.L_tl_argv_notq:
    cmpb $0x20, %al
    jne .L_tl_argv_adv
    testl %r9d, %r9d
    jnz .L_tl_argv_adv
    movb $0, (%rbx)
    incq %rbx
    jmp .L_tl_argv_scan
.L_tl_argv_adv:
    incq %rbx
    jmp .L_tl_argv_tok
.L_tl_argv_done:
    movq $0, (%r14,%r15,8)
    movq %r15, .L_tl_argc(%rip)
    movq %r14, .L_tl_argv(%rip)
    addq $40, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

.L_tl_boot_alloc:
    movq tl_boot_off(%rip), %rax
    leaq tl_boot_pool(%rip), %rdx
    addq %rdx, %rax
    addq %rcx, tl_boot_off(%rip)
    ret

    .globl _tl_start
_tl_start:
    subq $40, %rsp
    call tl_setup_argv
    movq $0, %gs:0x28
    movq .L_tl_argc(%rip), %rcx
    movq .L_tl_argv(%rip), %rdx
    call main
    movq %rax, %rcx
    call ExitProcess

    .bss
    .balign 8
tl_boot_off:
    .quad 0
tl_boot_pool:
    .space 524288
    .text

    .section .rsrc,\"dr\"
.L_tl_rsrc_base:
    .long 0
    .long 0
    .short 0
    .short 0
    .short 0
    .short 1
    .long 24
    .long 0x80000000 + (.L_tl_rsrc_type - .L_tl_rsrc_base)
.L_tl_rsrc_type:
    .long 0
    .long 0
    .short 0
    .short 0
    .short 0
    .short 1
    .long 1
    .long 0x80000000 + (.L_tl_rsrc_lang - .L_tl_rsrc_base)
.L_tl_rsrc_lang:
    .long 0
    .long 0
    .short 0
    .short 0
    .short 0
    .short 1
    .long 1033
    .long .L_tl_rsrc_data - .L_tl_rsrc_base
.L_tl_rsrc_data:
    .rva .L_tl_manifest
    .long .L_tl_manifest_end - .L_tl_manifest
    .long 0
    .long 0
    .balign 4
.L_tl_manifest:
    .byte 60,63,120,109,108,32,118,101,114,115,105,111,110,61,34,49
    .byte 46,48,34,32,101,110,99,111,100,105,110,103,61,34,85,84
    .byte 70,45,56,34,32,115,116,97,110,100,97,108,111,110,101,61
    .byte 34,121,101,115,34,63,62,13,10,60,97,115,115,101,109,98
    .byte 108,121,32,120,109,108,110,115,61,34,117,114,110,58,115,99
    .byte 104,101,109,97,115,45,109,105,99,114,111,115,111,102,116,45
    .byte 99,111,109,58,97,115,109,46,118,49,34,32,109,97,110,105
    .byte 102,101,115,116,86,101,114,115,105,111,110,61,34,49,46,48
    .byte 34,62,13,10,32,32,60,97,112,112,108,105,99,97,116,105
    .byte 111,110,32,120,109,108,110,115,61,34,117,114,110,58,115,99
    .byte 104,101,109,97,115,45,109,105,99,114,111,115,111,102,116,45
    .byte 99,111,109,58,97,115,109,46,118,51,34,62,13,10,32,32
    .byte 32,32,60,119,105,110,100,111,119,115,83,101,116,116,105,110
    .byte 103,115,62,13,10,32,32,32,32,32,32,60,97,99,116,105
    .byte 118,101,67,111,100,101,80,97,103,101,32,120,109,108,110,115
    .byte 61,34,104,116,116,112,58,47,47,115,99,104,101,109,97,115
    .byte 46,109,105,99,114,111,115,111,102,116,46,99,111,109,47,83
    .byte 77,73,47,50,48,49,57,47,87,105,110,100,111,119,115,83
    .byte 101,116,116,105,110,103,115,34,62,85,84,70,45,56,60,47
    .byte 97,99,116,105,118,101,67,111,100,101,80,97,103,101,62,13
    .byte 10,32,32,32,32,60,47,119,105,110,100,111,119,115,83,101
    .byte 116,116,105,110,103,115,62,13,10,32,32,60,47,97,112,112
    .byte 108,105,99,97,116,105,111,110,62,13,10,60,47,97,115,115
    .byte 101,109,98,108,121,62,13,10
.L_tl_manifest_end:
    .text

")

(define (compiler-backend-runtime-windows-arena-functions [profile : bool]) : String
  (string.append
    "    .globl tl_arena_current
tl_arena_current:
"
    (string.append
      (compiler-backend-current-arena-load "%rax")
      (string.append
        "    ret

    .globl tl_arena_set
tl_arena_set:
"
        (string.append
          (compiler-backend-current-arena-store "%rcx")
          (string.append
            "    ret

    .globl tl_arena_poison_enable
tl_arena_poison_enable:
    movq $1, .L_tl_arena_poison_enabled(%rip)
    ret

    .globl tl_arena_make
tl_arena_make:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    sub $48, %rsp
    movq $0x4000000, %rsi
    jmp .L_tl_arena_make_win_sized

    .globl tl_arena_make_small
tl_arena_make_small:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    sub $48, %rsp
    movq $0x1000000, %rsi
.L_tl_arena_make_win_sized:
    movq %rsi, 40(%rsp)
    xorq %rcx, %rcx
    movq %rsi, %rdx
    movq $0x2000, %r8
    movq $0x4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_arena_make_win_reserve_os_fail
    movq %rax, %rbx
    movq %rbx, %rcx
    movq $0x400000, %rdx
    movq $0x1000, %r8
    movq $0x4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_arena_make_win_initial_commit_os_fail
    movq $0, 0(%rbx)
    movq $0, 32(%rbx)
    movq %rbx, 40(%rbx)
    movq $0, 48(%rbx)
    movq %rbx, 56(%rbx)
    leaq 72(%rbx), %rcx
    movq %rcx, 8(%rbx)
    movq %rcx, 16(%rbx)
    movq %rbx, %rsi
    addq $0x400000, %rsi
    movq %rsi, 64(%rbx)
    movq %rbx, %rcx
    addq 40(%rsp), %rcx
    movq %rcx, 24(%rbx)
    movq %rbx, %rax
    add $48, %rsp
    popq %rsi
    popq %rbx
    popq %rbp
    ret
.L_tl_arena_make_win_reserve_os_fail:
    call GetLastError
    movl %eax, %eax
    movq %rax, 40(%rsp)
    movq $0, 32(%rsp)
    xorq %rcx, %rcx
    xorq %rdx, %rdx
    movq %rsi, %r8
    xorq %r9, %r9
    call tl_windows_allocation_abort
    call tl_oom_abort
.L_tl_arena_make_win_initial_commit_os_fail:
    call GetLastError
    movl %eax, %eax
    movq %rax, 40(%rsp)
    movq %rbx, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    call VirtualFree
    movq $0, 32(%rsp)
    xorq %rcx, %rcx
    movq $1, %rdx
    movq $0x400000, %r8
    movq %rsi, %r9
    call tl_windows_allocation_abort
    call tl_oom_abort

    .globl tl_arena_make_atomic
tl_arena_make_atomic:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    sub $48, %rsp
    xorq %rcx, %rcx
    movq $0x4000000, %rdx
    movq $0x2000, %r8
    movq $0x4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_arena_make_atomic_win_reserve_os_fail
    movq %rax, %rbx
    movq %rbx, %rcx
    movq $0x400000, %rdx
    movq $0x1000, %r8
    movq $0x4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_arena_make_atomic_win_initial_commit_os_fail
    movq $0, 0(%rbx)
    movq $0, 32(%rbx)
    movq %rbx, 40(%rbx)
    movq $1, 48(%rbx)
    movq %rbx, 56(%rbx)
    leaq 72(%rbx), %rcx
    movq %rcx, 8(%rbx)
    movq %rcx, 16(%rbx)
    movq %rbx, %rsi
    addq $0x400000, %rsi
    movq %rsi, 64(%rbx)
    movq %rbx, %rcx
    addq $0x4000000, %rcx
    movq %rcx, 24(%rbx)
    movq %rbx, %rax
    add $48, %rsp
    popq %rsi
    popq %rbx
    popq %rbp
    ret
.L_tl_arena_make_atomic_win_reserve_os_fail:
    call GetLastError
    movl %eax, %eax
    movq %rax, 40(%rsp)
    movq $0, 32(%rsp)
    movq $1, %rcx
    xorq %rdx, %rdx
    movq $0x4000000, %r8
    xorq %r9, %r9
    call tl_windows_allocation_abort
    call tl_oom_abort
.L_tl_arena_make_atomic_win_initial_commit_os_fail:
    call GetLastError
    movl %eax, %esi
    movq %rbx, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    call VirtualFree
    movq %rsi, 40(%rsp)
    movq $0, 32(%rsp)
    movq $1, %rcx
    movq $1, %rdx
    movq $0x400000, %r8
    movq $0x4000000, %r9
    call tl_windows_allocation_abort
    call tl_oom_abort

    .globl tl_arena_destroy
tl_arena_destroy:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    push %r12
    sub $40, %rsp
    movq %rcx, %rsi
    xorq %r12, %r12
    testq %rsi, %rsi
    jz .L_tl_arena_destroy_win_active_done
    movq 40(%rsi), %r12
    testq %r12, %r12
    jz .L_tl_arena_destroy_win_loop
    movq 56(%r12), %rsi
    testq %rsi, %rsi
    jnz .L_tl_arena_destroy_win_head_ready
    movq %r12, %rsi
.L_tl_arena_destroy_win_head_ready:
.L_tl_arena_destroy_win_retired_ready:
    movq 32(%r12), %r12
.L_tl_arena_destroy_win_loop:
    testq %rsi, %rsi
    jz .L_tl_arena_destroy_win_active_done
    movq 0(%rsi), %rbx
"
            (string.append
              (runtime_common.compiler-backend-runtime-profile-live-sub
                "%rsi"
                "%r10"
                profile)
              "    movq %rsi, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    call VirtualFree
    movq %rbx, %rsi
    jmp .L_tl_arena_destroy_win_loop
.L_tl_arena_destroy_win_active_done:
    movq %r12, %rsi
.L_tl_arena_destroy_win_retired_loop:
    testq %rsi, %rsi
    jz .L_tl_arena_destroy_win_done
    movq 32(%rsi), %rbx
    movq %rsi, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    call VirtualFree
    movq %rbx, %rsi
    jmp .L_tl_arena_destroy_win_retired_loop
.L_tl_arena_destroy_win_done:
    add $40, %rsp
    popq %r12
    popq %rsi
    popq %rbx
    popq %rbp
    ret

")))))))

(define (compiler-backend-runtime-windows-alloc-functions [profile : bool]) : String
  (let
    [fast-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_fast_done"
        profile)]
    [atomic-fast-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_atomic_fast_done"
        profile)]
    [atomic-locked-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_atomic_locked_done"
        profile)]
    [atomic-new-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_atomic_new_done"
        profile)]
    [new-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%r11"
        ".L_tl_alloc_profile_win_new_done"
        profile)]
    (str_cat.str-cat
      (compiler-backend-runtime-fast-alloc-functions "%rcx" "%r10" profile)
      "# Commit through REQUIRED-END inside ARENA in 4 MiB increments.
# rcx=arena, rdx=required-end, rax=1 success / 0 failure.
.L_tl_alloc_win_commit_to:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    sub $48, %rsp
    movq %rcx, %rbx
    movq %rdx, %rsi
    subq %rbx, %rsi
    addq $0x3fffff, %rsi
    jc .L_tl_alloc_win_commit_fail
    andq $-0x400000, %rsi
    addq %rbx, %rsi
    jc .L_tl_alloc_win_commit_fail
    cmpq 24(%rbx), %rsi
    jbe .L_tl_alloc_win_commit_end_ready
    movq 24(%rbx), %rsi
.L_tl_alloc_win_commit_end_ready:
    movq 64(%rbx), %rcx
    cmpq %rcx, %rsi
    jbe .L_tl_alloc_win_commit_done
    movq %rsi, %rdx
    subq %rcx, %rdx
    movq $0x1000, %r8
    movq $0x4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_alloc_win_commit_os_fail
    movq %rsi, 64(%rbx)
.L_tl_alloc_win_commit_done:
    movq $1, %rax
    jmp .L_tl_alloc_win_commit_return
.L_tl_alloc_win_commit_os_fail:
    call GetLastError
    movl %eax, %eax
    movq %rax, 40(%rsp)
    movq 64(%rbx), %rax
    subq %rbx, %rax
    movq %rax, 32(%rsp)
    movq %rsi, %r8
    subq 64(%rbx), %r8
    movq 24(%rbx), %r9
    subq %rbx, %r9
    movq 48(%rbx), %rcx
    andq $1, %rcx
    movq $2, %rdx
    call tl_windows_allocation_abort
.L_tl_alloc_win_commit_fail:
    xorq %rax, %rax
.L_tl_alloc_win_commit_return:
    add $48, %rsp
    popq %rsi
    popq %rbx
    popq %rbp
    ret

    .globl tl_alloc
tl_alloc:
    testq %rcx, %rcx
    jnz .L_tl_alloc_win_size_ready
    movq $1, %rcx
.L_tl_alloc_win_size_ready:
    addq $7, %rcx
    jc .L_tl_alloc_enter_abort
    andq $-8, %rcx
    movq %rcx, %r11
    movq %gs:0x28, %r8
    testq %r8, %r8
    jz .L_tl_alloc_new_arena_entry
    movq 40(%r8), %r9
    testq $1, 48(%r9)
    jnz .L_tl_alloc_win_atomic
.L_tl_alloc_win_ordinary_retry:
    movq 16(%r8), %r10
    movq %r10, %rax
    addq %r11, %r10
    jc .L_tl_alloc_enter_abort
    cmpq 24(%r8), %r10
    ja .L_tl_alloc_new_arena_entry
    cmpq 64(%r8), %r10
    ja .L_tl_alloc_commit_arena_entry
    movq %r10, 16(%r8)
"
      fast-profile
      "    ret
.L_tl_alloc_win_atomic:
    movq 56(%r9), %r8
    movq 16(%r8), %rax
.L_tl_alloc_win_atomic_cas:
    movq %rax, %r10
    addq %r11, %r10
    jc .L_tl_alloc_enter_abort
    cmpq 24(%r8), %r10
    ja .L_tl_alloc_atomic_new_arena_entry
    cmpq 64(%r8), %r10
    ja .L_tl_alloc_atomic_new_arena_entry
    lock cmpxchgq %r10, 16(%r8)
    jne .L_tl_alloc_win_atomic_cas
"
      atomic-fast-profile
      "    ret
.L_tl_alloc_commit_arena_entry:
    push %rbp
    mov %rsp, %rbp
    sub $80, %rsp
    movq %r11, -8(%rbp)
    movq %r8, -16(%rbp)
    movq %r8, %rcx
    movq %r10, %rdx
    call .L_tl_alloc_win_commit_to
    testq %rax, %rax
    jz .L_tl_alloc_abort
    movq -8(%rbp), %r11
    movq -16(%rbp), %r8
    mov %rbp, %rsp
    pop %rbp
    jmp .L_tl_alloc_win_ordinary_retry
.L_tl_alloc_atomic_new_arena_entry:
    push %rbp
    mov %rsp, %rbp
    sub $80, %rsp
    jmp .L_tl_alloc_atomic_new_arena
.L_tl_alloc_new_arena_entry:
    push %rbp
    mov %rsp, %rbp
    sub $80, %rsp
    jmp .L_tl_alloc_new_arena
.L_tl_alloc_enter_abort:
    push %rbp
    mov %rsp, %rbp
    sub $80, %rsp
    jmp .L_tl_alloc_abort
.L_tl_alloc_atomic_new_arena:
    movq %r9, -24(%rbp)
.L_tl_alloc_atomic_lock:
    movq -24(%rbp), %r9
    movq $1, %rax
    movq $3, %r10
    lock cmpxchgq %r10, 48(%r9)
    je .L_tl_alloc_atomic_locked
    pause
    jmp .L_tl_alloc_atomic_lock
.L_tl_alloc_atomic_locked:
    movq 56(%r9), %r8
    movq 16(%r8), %rax
.L_tl_alloc_atomic_locked_cas:
    movq %rax, %r10
    addq %r11, %r10
    jc .L_tl_alloc_atomic_abort_locked
    cmpq 24(%r8), %r10
    ja .L_tl_alloc_atomic_map
    cmpq 64(%r8), %r10
    ja .L_tl_alloc_atomic_commit
    lock cmpxchgq %r10, 16(%r8)
    jne .L_tl_alloc_atomic_locked_cas
    movq $1, 48(%r9)
"
      atomic-locked-profile
      "    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_alloc_atomic_commit:
    movq %r11, -8(%rbp)
    movq %r8, -16(%rbp)
    movq %r8, %rcx
    movq %r10, %rdx
    call .L_tl_alloc_win_commit_to
    testq %rax, %rax
    jz .L_tl_alloc_atomic_commit_failed
    movq -24(%rbp), %r9
    movq -16(%rbp), %r8
    movq -8(%rbp), %r11
    movq 16(%r8), %rax
    jmp .L_tl_alloc_atomic_locked_cas
.L_tl_alloc_atomic_commit_failed:
    movq -24(%rbp), %r9
.L_tl_alloc_atomic_abort_locked:
    movq $1, 48(%r9)
    jmp .L_tl_alloc_abort
.L_tl_alloc_atomic_map:
    movq %r11, -8(%rbp)
    movq $0x4000000, %rdx
    movq %r11, %rax
    addq $72, %rax
    jc .L_tl_alloc_atomic_abort_locked
    cmpq %rdx, %rax
    jbe .L_tl_alloc_atomic_len_ready
    movq %rax, %rdx
.L_tl_alloc_atomic_len_ready:
    movq %rdx, -16(%rbp)
    xorq %rcx, %rcx
    movq $0x2000, %r8
    movq $4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_alloc_atomic_reserve_os_fail
    movq %rax, -32(%rbp)
    movq -8(%rbp), %r11
    movq %r11, %rdx
    addq $72, %rdx
    jc .L_tl_alloc_atomic_commit_failed
    cmpq $0x400000, %rdx
    jae .L_tl_alloc_atomic_commit_len_ready
    movq $0x400000, %rdx
.L_tl_alloc_atomic_commit_len_ready:
    cmpq -16(%rbp), %rdx
    jbe .L_tl_alloc_atomic_commit_len_capped
    movq -16(%rbp), %rdx
.L_tl_alloc_atomic_commit_len_capped:
    movq %rdx, -40(%rbp)
    movq -32(%rbp), %rcx
    movq $0x1000, %r8
    movq $4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_alloc_atomic_initial_commit_os_fail
    movq -24(%rbp), %r9
    movq -32(%rbp), %rax
    movq -16(%rbp), %rdx
    movq -8(%rbp), %r11
    movq %rax, %rcx
    addq %rdx, %rcx
    jc .L_tl_alloc_atomic_commit_failed
    movq 56(%r9), %r8
    movq %r8, 0(%rax)
    leaq 72(%rax), %r8
    movq %r8, 8(%rax)
    movq %r8, 16(%rax)
    movq %rcx, 24(%rax)
    movq $0, 32(%rax)
    movq %r9, 40(%rax)
    movq $1, 48(%rax)
    movq $0, 56(%rax)
    movq -40(%rbp), %rdx
    addq %rax, %rdx
    movq %rdx, 64(%rax)
    movq %r8, %r10
    addq %r11, %r10
    jc .L_tl_alloc_atomic_commit_failed
    movq %r10, 16(%rax)
    movq %rax, 56(%r9)
    movq %rax, %gs:0x28
    movq $1, 48(%r9)
    movq %r8, %rax
"
      atomic-new-profile
      "    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_alloc_atomic_reserve_os_fail:
    call GetLastError
    movl %eax, %eax
    movq %rax, 40(%rsp)
    movq $0, 32(%rsp)
    movq -24(%rbp), %rax
    movq $1, 48(%rax)
    movq $1, %rcx
    xorq %rdx, %rdx
    movq -16(%rbp), %r8
    xorq %r9, %r9
    call tl_windows_allocation_abort
    jmp .L_tl_alloc_abort
.L_tl_alloc_atomic_initial_commit_os_fail:
    call GetLastError
    movl %eax, %eax
    movq %rax, -48(%rbp)
    movq -32(%rbp), %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    call VirtualFree
    movq -48(%rbp), %rax
    movq -40(%rbp), %r8
    movq %rax, 40(%rsp)
    movq $0, 32(%rsp)
    movq -24(%rbp), %rax
    movq $1, 48(%rax)
    movq $1, %rcx
    movq $1, %rdx
    movq -16(%rbp), %r9
    call tl_windows_allocation_abort
    jmp .L_tl_alloc_abort
.L_tl_alloc_new_arena:
    movq %r11, -8(%rbp)
    movq $0x4000000, %rdx
    movq %r11, %rax
    addq $72, %rax
    jc .L_tl_alloc_abort
    cmpq %rdx, %rax
    jbe .L_tl_alloc_len_ready
    movq %rax, %rdx
.L_tl_alloc_len_ready:
    movq %rdx, -16(%rbp)
    xorq %rcx, %rcx
    movq $0x2000, %r8
    movq $4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_alloc_reserve_os_fail
    movq %rax, -32(%rbp)
    movq -8(%rbp), %r11
    movq %r11, %rdx
    addq $72, %rdx
    jc .L_tl_alloc_abort
    cmpq $0x400000, %rdx
    jae .L_tl_alloc_commit_len_ready
    movq $0x400000, %rdx
.L_tl_alloc_commit_len_ready:
    cmpq -16(%rbp), %rdx
    jbe .L_tl_alloc_commit_len_capped
    movq -16(%rbp), %rdx
.L_tl_alloc_commit_len_capped:
    movq %rdx, -40(%rbp)
    movq -32(%rbp), %rcx
    movq $0x1000, %r8
    movq $4, %r9
    call VirtualAlloc
    testq %rax, %rax
    jz .L_tl_alloc_initial_commit_os_fail
    movq -32(%rbp), %rax
    movq -16(%rbp), %rdx
    movq -8(%rbp), %r11
    movq %rax, %rcx
    addq %rdx, %rcx
    jc .L_tl_alloc_abort
    movq %gs:0x28, %r8
    movq %r8, -48(%rbp)
    movq %r8, 0(%rax)
    leaq 72(%rax), %r8
    movq %r8, 8(%rax)
    movq %r8, 16(%rax)
    movq %rcx, 24(%rax)
    movq $0, 32(%rax)
    movq -48(%rbp), %r8
    testq %r8, %r8
    jz .L_tl_alloc_win_root_self
    movq 40(%r8), %r10
    jmp .L_tl_alloc_win_root_ready
.L_tl_alloc_win_root_self:
    movq %rax, %r10
.L_tl_alloc_win_root_ready:
    movq %r10, 40(%rax)
    movq $0, 48(%rax)
    movq %rax, 56(%r10)
    movq %rax, 56(%rax)
    movq -40(%rbp), %rdx
    addq %rax, %rdx
    movq %rdx, 64(%rax)
    movq 8(%rax), %r8
    movq %r8, %r10
    addq %r11, %r10
    jc .L_tl_alloc_abort
    movq %r10, 16(%rax)
    movq %rax, %gs:0x28
    movq %r8, %rax
"
      new-profile
      "
    mov %rbp, %rsp
    pop %rbp
    ret
.L_tl_alloc_reserve_os_fail:
    call GetLastError
    movl %eax, %eax
    movq %rax, 40(%rsp)
    movq $0, 32(%rsp)
    xorq %rcx, %rcx
    xorq %rdx, %rdx
    movq -16(%rbp), %r8
    xorq %r9, %r9
    call tl_windows_allocation_abort
    jmp .L_tl_alloc_abort
.L_tl_alloc_initial_commit_os_fail:
    call GetLastError
    movl %eax, %eax
    movq %rax, -48(%rbp)
    movq -32(%rbp), %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    call VirtualFree
    movq -48(%rbp), %rax
    movq -40(%rbp), %r8
    movq %rax, 40(%rsp)
    movq $0, 32(%rsp)
    xorq %rcx, %rcx
    movq $1, %rdx
    movq -16(%rbp), %r9
    call tl_windows_allocation_abort
    jmp .L_tl_alloc_abort
.L_tl_alloc_abort:
    sub $32, %rsp
    call tl_oom_abort

")))

;; Rewinding a non-atomic arena marks it as reused with flags bit 2 (bit 0 is
;; the atomic flag, which runs a 1/3 lock protocol and is left untouched);
;; tl_array_zero consults that bit to skip its fill only for virgin arenas.
(define (compiler-backend-runtime-windows-region-reset-functions
  [profile : bool]) : String
  (string.append
    "    .globl tl_region_reset
tl_region_reset:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    movq %rcx, %r12
    testq %r12, %r12
    jz .L_tl_region_reset_win_all
    movq %gs:0x28, %r13
    testq %r13, %r13
    jz .L_tl_region_reset_win_invalid
    movq 40(%r13), %r11
    testq $1, 48(%r11)
    jz .L_tl_region_reset_win_find
    movq 56(%r11), %r13
.L_tl_region_reset_win_find:
    movq 8(%r13), %rax
    cmpq %rax, %r12
    jb .L_tl_region_reset_win_next
    movq 24(%r13), %rax
    cmpq %rax, %r12
    jbe .L_tl_region_reset_win_found
.L_tl_region_reset_win_next:
    movq 0(%r13), %r13
    testq %r13, %r13
    jnz .L_tl_region_reset_win_find
    jmp .L_tl_region_reset_win_invalid
.L_tl_region_reset_win_invalid:
    sub $32, %rsp
    call tl_region_abort
.L_tl_region_reset_win_found:
    movq 40(%r13), %r11
    movq %gs:0x28, %r14
.L_tl_region_reset_win_drop:
    cmpq %r13, %r14
    je .L_tl_region_reset_win_restore
    movq 0(%r14), %rbx
"
    (string.append
      (runtime_common.compiler-backend-runtime-profile-live-sub
        "%r14"
        "%rax"
        profile)
      (string.append
        "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    jne .L_tl_region_reset_win_retire
    movq %r14, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    sub $32, %rsp
    call VirtualFree
    add $32, %rsp
    testq %rax, %rax
    jnz .L_tl_region_reset_win_drop_next
.L_tl_region_reset_win_retire:
    movq 40(%r13), %r11
    movq 32(%r11), %rax
    movq %rax, 32(%r14)
    movq $0, 0(%r14)
    movq %r14, 32(%r11)
.L_tl_region_reset_win_drop_next:
    movq %rbx, %r14
    jmp .L_tl_region_reset_win_drop
.L_tl_region_reset_win_restore:
    movq 40(%r13), %r11
"
        (string.append
          (runtime_common.compiler-backend-runtime-profile-live-rewind
            "%r13"
            "%r12"
            "%rax"
            profile)
          (string.append
            "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    jne .L_tl_region_reset_win_decommit_done
    movq %r12, %rbx
    subq %r13, %rbx
    addq $0x3fffff, %rbx
    andq $-0x400000, %rbx
    cmpq $0x400000, %rbx
    jae .L_tl_region_reset_win_retain_ready
    movq $0x400000, %rbx
.L_tl_region_reset_win_retain_ready:
    addq %r13, %rbx
    cmpq 64(%r13), %rbx
    jae .L_tl_region_reset_win_decommit_done
    movq %rbx, %rcx
    movq 64(%r13), %rdx
    subq %rcx, %rdx
    movq $0x4000, %r8
    sub $32, %rsp
    call VirtualFree
    add $32, %rsp
    testq %rax, %rax
    jz .L_tl_region_reset_win_decommit_done
    movq %rbx, 64(%r13)
.L_tl_region_reset_win_decommit_done:
    movq 40(%r13), %r11
    testq $1, 48(%r13)
    jnz .L_tl_region_reset_win_reused_ready
    orq $4, 48(%r13)
.L_tl_region_reset_win_reused_ready:
    movq %r12, 16(%r13)
    movq %r13, 56(%r11)
    movq %r13, %gs:0x28
    jmp .L_tl_region_reset_win_done
.L_tl_region_reset_win_all:
    movq %gs:0x28, %r14
    movq $0, %gs:0x28
    xorq %r12, %r12
    testq %r14, %r14
    jz .L_tl_region_reset_win_done
    movq 40(%r14), %r12
    testq %r12, %r12
    jz .L_tl_region_reset_win_all_drop
    movq 56(%r12), %r14
    testq %r14, %r14
    jnz .L_tl_region_reset_win_all_head_ready
    movq %r12, %r14
.L_tl_region_reset_win_all_head_ready:
.L_tl_region_reset_win_all_retired_ready:
    movq 32(%r12), %r12
.L_tl_region_reset_win_all_drop:
    testq %r14, %r14
    jz .L_tl_region_reset_win_all_retired
    movq 0(%r14), %rbx
"
            (string.append
              (runtime_common.compiler-backend-runtime-profile-live-sub
                "%r14"
                "%rax"
                profile)
              "    movq %r14, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    sub $32, %rsp
    call VirtualFree
    add $32, %rsp
    movq %rbx, %r14
    jmp .L_tl_region_reset_win_all_drop
.L_tl_region_reset_win_all_retired:
    movq %r12, %r14
.L_tl_region_reset_win_all_retired_drop:
    testq %r14, %r14
    jz .L_tl_region_reset_win_done
    movq 32(%r14), %rbx
    movq %r14, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    sub $32, %rsp
    call VirtualFree
    add $32, %rsp
    movq %rbx, %r14
    jmp .L_tl_region_reset_win_all_retired_drop
.L_tl_region_reset_win_done:
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

")))))))

(define (compiler-backend-runtime-windows-thread-functions) : String
  "    .data
    .globl tl_thread_entry_ptr
    .balign 8
tl_thread_entry_ptr:
    .quad .L_tl_thread_entry

    .text
.L_tl_thread_entry:
    pushq %r12
    pushq %r13
    subq $40, %rsp
    movq $0, %gs:0x28
    movq (%rcx), %r11
    movq 8(%rcx), %rdx
    movq 16(%rcx), %r12
    movq 24(%rcx), %r13
    movl $1, (%r13)
    movq 8(%r11), %rcx
    call *(%r11)
    movq %rax, (%r12)
    addq $40, %rsp
    popq %r13
    popq %r12
    ret

")

(define (compiler-backend-runtime-memcpy-functions) : String
  "    .globl tl_memcpy
tl_memcpy:
    cmpq $1, %r8
    jne .Ltl_memcpy_setup
    movzbl (%rdx), %eax
    movb %al, (%rcx)
    ret
.Ltl_memcpy_setup:
    movq %rdi, %rax
    movq %rsi, %r10
    movq %rcx, %rdi
    movq %rdx, %rsi
    movq %r8, %rcx
    cmpq %rsi, %rdi
    jbe .Ltl_memcpy_fwd
    movq %rsi, %r9
    addq %rcx, %r9
    cmpq %r9, %rdi
    jae .Ltl_memcpy_fwd
.Ltl_memcpy_bwd_64:
    cmpq $64, %rcx
    jb .Ltl_memcpy_bwd_32
    subq $64, %rcx
    movups (%rsi,%rcx), %xmm0
    movups 16(%rsi,%rcx), %xmm1
    movups 32(%rsi,%rcx), %xmm2
    movups 48(%rsi,%rcx), %xmm3
    movups %xmm0, (%rdi,%rcx)
    movups %xmm1, 16(%rdi,%rcx)
    movups %xmm2, 32(%rdi,%rcx)
    movups %xmm3, 48(%rdi,%rcx)
    jmp .Ltl_memcpy_bwd_64
.Ltl_memcpy_bwd_32:
    cmpq $32, %rcx
    jb .Ltl_memcpy_bwd_16
    subq $32, %rcx
    movups (%rsi,%rcx), %xmm0
    movups 16(%rsi,%rcx), %xmm1
    movups %xmm0, (%rdi,%rcx)
    movups %xmm1, 16(%rdi,%rcx)
.Ltl_memcpy_bwd_16:
    cmpq $16, %rcx
    jb .Ltl_memcpy_bwd_tail
    subq $16, %rcx
    movups (%rsi,%rcx), %xmm0
    movups %xmm0, (%rdi,%rcx)
.Ltl_memcpy_bwd_tail:
    testq %rcx, %rcx
    je .Ltl_memcpy_done
    leaq -1(%rdi,%rcx), %rdi
    leaq -1(%rsi,%rcx), %rsi
    std
    rep movsb
    cld
.Ltl_memcpy_done:
    movq %rax, %rdi
    movq %r10, %rsi
    ret
.Ltl_memcpy_fwd:
.Ltl_memcpy_fwd_64:
    cmpq $64, %rcx
    jb .Ltl_memcpy_fwd_32
    movups (%rsi), %xmm0
    movups 16(%rsi), %xmm1
    movups 32(%rsi), %xmm2
    movups 48(%rsi), %xmm3
    movups %xmm0, (%rdi)
    movups %xmm1, 16(%rdi)
    movups %xmm2, 32(%rdi)
    movups %xmm3, 48(%rdi)
    addq $64, %rsi
    addq $64, %rdi
    subq $64, %rcx
    jmp .Ltl_memcpy_fwd_64
.Ltl_memcpy_fwd_32:
    cmpq $32, %rcx
    jb .Ltl_memcpy_fwd_16
    movups (%rsi), %xmm0
    movups 16(%rsi), %xmm1
    movups %xmm0, (%rdi)
    movups %xmm1, 16(%rdi)
    addq $32, %rsi
    addq $32, %rdi
    subq $32, %rcx
.Ltl_memcpy_fwd_16:
    cmpq $16, %rcx
    jb .Ltl_memcpy_fwd_tail
    movups (%rsi), %xmm0
    movups %xmm0, (%rdi)
    addq $16, %rsi
    addq $16, %rdi
    subq $16, %rcx
.Ltl_memcpy_fwd_tail:
    rep movsb
    movq %rax, %rdi
    movq %r10, %rsi
    ret
")

(define (compiler-backend-runtime-memchr-functions) : String
  "    .globl tl_memchr
tl_memchr:
    testq %rdx, %rdx
    jle .Ltl_memchr_not_found
    movzbl %r8b, %r8d
    xorq %rax, %rax
.Ltl_memchr_loop:
    cmpb %r8b, (%rcx,%rax)
    je .Ltl_memchr_found
    incq %rax
    cmpq %rdx, %rax
    jl .Ltl_memchr_loop
.Ltl_memchr_not_found:
    movq $-1, %rax
.Ltl_memchr_found:
    ret
")

;; Arena pages arrive zeroed from the OS and the bump allocator only moves
;; forward until tl_region_reset marks the arena as reused (flags bit 2).
;; While the current arena has never been rewound (and is not atomic, whose
;; flags word runs the 1/3 lock protocol), every allocation is already
;; all-zero and the fill is a no-op. The reused/atomic cases keep the fill.
;; Small fills are cheaper to run than to vet, so the virgin check only
;; gates fills of 64 bytes or more.
(define (compiler-backend-runtime-array-zero-functions) : String
  "    .globl tl_array_zero
tl_array_zero:
    cmpq $64, %rdx
    jb .Ltl_array_zero_fill
    movq %gs:0x28, %r8
    testq %r8, %r8
    jz .Ltl_array_zero_fill
    testq $5, 48(%r8)
    jnz .Ltl_array_zero_fill
    ret
.Ltl_array_zero_fill:
    pushq %rdi
    movq %rcx, %rdi
    movq %rdx, %rcx
    shrq $3, %rcx
    xorl %eax, %eax
    rep stosq
    movq %rdx, %rcx
    andq $7, %rcx
    rep stosb
    popq %rdi
    ret
")

(define (compiler-backend-runtime-tlci-entry-functions) : String
  "    .globl tl_tlci_call_image_entry
tl_tlci_call_image_entry:
    movq %rcx, %rax
    movq %rdx, %rcx
    movq %r8, %rdx
    subq $40, %rsp
    call *%rax
    addq $40, %rsp
    ret

")

(define (compiler-backend-runtime-tlci-macro-entry-functions) : String
  "    .globl tl_tlci_call_macro_entry
tl_tlci_call_macro_entry:
    movq %rcx, %rax
    movq %rdx, %rcx
    movq %r8, %rdx
    movq %r9, %r8
    movq 40(%rsp), %r9
    movq 48(%rsp), %r10
    movq 56(%rsp), %r11
    subq $56, %rsp
    movq %r10, 32(%rsp)
    movq %r11, 40(%rsp)
    call *%rax
    addq $56, %rsp
    ret

    .data
    .globl tl_comptime_host_invoke_fn
    .balign 8
tl_comptime_host_invoke_fn:
    .quad 0
    .globl tl_comptime_host_invoke_entry_ptr
tl_comptime_host_invoke_entry_ptr:
    .quad .L_tl_comptime_host_invoke_entry

    .text
    .globl tl_comptime_host_invoke_set
tl_comptime_host_invoke_set:
    movq %rcx, tl_comptime_host_invoke_fn(%rip)
    leaq .L_tl_comptime_host_invoke_entry(%rip), %rax
    ret

.L_tl_comptime_host_invoke_entry:
    movq tl_comptime_host_invoke_fn(%rip), %r11
    movq 8(%r11), %rcx
    jmp *(%r11)

")

(define (compiler-backend-runtime-functions
  [features : (& features runtime_common.CompilerBackendRuntimeFeatures)]) : String
  (let
    [profile : bool
      (runtime_common.compiler-backend-runtime-features-profile? features)]
    [alloc-asm : String
      (if (runtime_common.compiler-backend-runtime-features-alloc? features)
        (compiler-backend-runtime-windows-alloc-functions profile)
        "")]
    [region-mark-asm : String
      (if (runtime_common.compiler-backend-runtime-features-region-mark?
        features)
        (compiler-backend-runtime-region-mark-functions)
        "")]
    [region-reset-asm : String
      (if (runtime_common.compiler-backend-runtime-features-region-reset?
        features)
        (compiler-backend-runtime-windows-region-reset-functions profile)
        "")]
    [arena-asm : String
      (compiler-backend-runtime-windows-arena-functions profile)]
    [profile-asm : String
      (if profile
        (runtime_common.compiler-backend-runtime-profile-functions)
        "")]
    [memcpy-asm : String (compiler-backend-runtime-memcpy-functions)]
    [memchr-asm : String (compiler-backend-runtime-memchr-functions)]
    [array-zero-asm : String (compiler-backend-runtime-array-zero-functions)]
    [tlci-entry-asm : String (compiler-backend-runtime-tlci-entry-functions)]
    [tlci-macro-entry-asm : String
      (if (runtime_common.compiler-backend-runtime-features-tlci-macro-entry?
        features)
        (compiler-backend-runtime-tlci-macro-entry-functions)
        "")]
    [runtime-front-asm : String
      (string.append
        memcpy-asm
        (string.append
          memchr-asm
          (string.append
            array-zero-asm
            (string.append
              tlci-entry-asm
              (string.append
                tlci-macro-entry-asm
                (string.append
                  arena-asm
                  (string.append
                    profile-asm
                    (str_cat.str-cat
                      alloc-asm
                      region-mark-asm
                      region-reset-asm
                      ""))))))))]
    [libc-shims-asm : String
      (compiler-backend-runtime-windows-libc-shim-functions)]
    [thread-asm : String (compiler-backend-runtime-windows-thread-functions)]
    (str_cat.str-cat runtime-front-asm thread-asm libc-shims-asm "")))

(define (compiler-backend-runtime-externs
  [features : (& features runtime_common.CompilerBackendRuntimeFeatures)]) : String
  (str_cat.str-cat
    "    .extern VirtualAlloc
    .extern VirtualFree
    .extern GetLastError
    .extern ExitProcess
"
    (if (runtime_common.compiler-backend-runtime-features-write-exit? features)
      "    .extern WriteFile
"
      "")
    (if (runtime_common.compiler-backend-runtime-features-write-exit? features)
      "    .extern GetStdHandle
"
      "")
    (if (runtime_common.compiler-backend-runtime-features-print-f64? features)
      "    .extern _snprintf
"
      "")))