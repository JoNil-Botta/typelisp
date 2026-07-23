;; compiler_backend_runtime_linux.tl - Linux backend runtime leaf emitter.
(import compiler_backend_runtime_common as runtime_common)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(define (compiler-backend-runtime-arena-data) : String
  "    .section .tbss,\"awT\",@nobits
    .balign 8
    .globl tl_current_arena
tl_current_arena:
    .zero 8

    .section .bss
    .balign 8
.L_tl_arena_poison_enabled:
    .zero 8

")

(define (compiler-backend-current-arena-load [dst : String]) : String
  (str_cat.str-cat "    movq %fs:tl_current_arena@tpoff, " dst "\n"))

(define (compiler-backend-current-arena-store [src : String]) : String
  (str_cat.str-cat "    movq " src ", %fs:tl_current_arena@tpoff\n"))

(define (compiler-backend-runtime-fast-alloc-functions
  [size-reg : String]
  [next-reg : String]
  [profile : bool]) : String
  (runtime_common.compiler-backend-runtime-fast-alloc-functions
    (compiler-backend-current-arena-load "%r8")
    "24"
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

(define (compiler-backend-runtime-linux-alloc-functions [profile : bool]) : String
  (let
    [fast-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_fast_done"
        profile)]
    [atomic-fast-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_atomic_fast_done"
        profile)]
    [atomic-locked-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_atomic_locked_done"
        profile)]
    [atomic-new-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_atomic_new_done"
        profile)]
    [new-profile : String
      (runtime_common.compiler-backend-runtime-profile-alloc-account
        "%rsi"
        ".L_tl_alloc_profile_new_done"
        profile)]
    [prefix : String
      (str_cat.str-cat
        (compiler-backend-runtime-fast-alloc-functions "%rdi" "%rcx" profile)
        "    .globl tl_alloc
tl_alloc:
    addq $7, %rdi
    jc .L_tl_alloc_abort
    andq $-8, %rdi
    movq %rdi, %rsi
    movq %fs:tl_current_arena@tpoff, %r8
    testq %r8, %r8
    jz .L_tl_alloc_new_arena
    movq 40(%r8), %r9
    testq $1, 48(%r9)
    jnz .L_tl_alloc_atomic
    movq 16(%r8), %rcx
    movq %rcx, %rax
    addq %rsi, %rcx
    jc .L_tl_alloc_abort
    cmpq 24(%r8), %rcx
    ja .L_tl_alloc_new_arena
    movq %rcx, 16(%r8)
"
        "")]
    [atomic-fast-asm : String
      "    ret
.L_tl_alloc_atomic:
    movq 56(%r9), %r8
    movq 16(%r8), %rax
.L_tl_alloc_atomic_cas:
    movq %rax, %rcx
    addq %rsi, %rcx
    jc .L_tl_alloc_abort
    cmpq 24(%r8), %rcx
    ja .L_tl_alloc_atomic_new_arena
    lock cmpxchgq %rcx, 16(%r8)
    jne .L_tl_alloc_atomic_cas
"]
    [atomic-lock-asm : String
      "    ret
.L_tl_alloc_atomic_new_arena:
    movq $1, %rax
    movq $3, %rcx
    lock cmpxchgq %rcx, 48(%r9)
    je .L_tl_alloc_atomic_locked
    pause
    jmp .L_tl_alloc_atomic_new_arena
.L_tl_alloc_atomic_locked:
    movq 56(%r9), %r8
    movq 16(%r8), %rax
.L_tl_alloc_atomic_locked_cas:
    movq %rax, %rcx
    addq %rsi, %rcx
    jc .L_tl_alloc_atomic_abort_locked
    cmpq 24(%r8), %rcx
    ja .L_tl_alloc_atomic_map
    lock cmpxchgq %rcx, 16(%r8)
    jne .L_tl_alloc_atomic_locked_cas
    movq $1, 48(%r9)
"]
    [atomic-map-asm : String
      "    ret
.L_tl_alloc_atomic_abort_locked:
    movq $1, 48(%r9)
    jmp .L_tl_alloc_abort
.L_tl_alloc_atomic_map:
    movq $0x4000000, %rdx
    movq %rsi, %rcx
    addq $64, %rcx
    jc .L_tl_alloc_abort
    cmpq %rdx, %rcx
    jbe .L_tl_alloc_atomic_len_ready
    movq %rcx, %rdx
.L_tl_alloc_atomic_len_ready:
    push %r9
    push %rdx
    push %rsi
    movq %rdx, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    pop %rsi
    pop %rdx
    pop %r9
    testq %rax, %rax
    js .L_tl_alloc_abort
    movq %rax, %rcx
    addq %rdx, %rcx
    jc .L_tl_alloc_abort
    movq 56(%r9), %r8
    movq %r8, 0(%rax)
    movq $0, 32(%rax)
    movq %r9, 40(%rax)
    movq $1, 48(%rax)
    movq $0, 56(%rax)
    leaq 64(%rax), %r8
    movq %r8, 8(%rax)
    movq %rcx, 24(%rax)
    movq %r8, %rcx
    addq %rsi, %rcx
    movq %rcx, 16(%rax)
    movq %rax, 56(%r9)
    movq %rax, %fs:tl_current_arena@tpoff
    movq $1, 48(%r9)
    movq %r8, %rax
"]
    [ordinary-new-asm : String
      "    ret
.L_tl_alloc_new_arena:
    movq $0x4000000, %rdx
    movq %rsi, %rcx
    addq $64, %rcx
    jc .L_tl_alloc_abort
    cmpq %rdx, %rcx
    jbe .L_tl_alloc_len_ready
    movq %rcx, %rdx
.L_tl_alloc_len_ready:
    push %rdx
    push %rsi
    movq %rdx, %rsi
    xorq %rdi, %rdi
    movq $3, %rdx
    movq $0x22, %r10
    movq $-1, %r8
    xorq %r9, %r9
    movq $9, %rax
    syscall
    pop %rsi
    pop %rdx
    testq %rax, %rax
    js .L_tl_alloc_abort
    movq %rax, %rcx
    addq %rdx, %rcx
    jc .L_tl_alloc_abort
    movq %fs:tl_current_arena@tpoff, %r8
    movq %r8, 0(%rax)
    movq $0, 32(%rax)
    testq %r8, %r8
    jz .L_tl_alloc_root_self
    movq 40(%r8), %r10
    jmp .L_tl_alloc_root_ready
.L_tl_alloc_root_self:
    movq %rax, %r10
.L_tl_alloc_root_ready:
    movq %r10, 40(%rax)
    movq $0, 48(%rax)
    movq %rax, 56(%r10)
    movq %rax, 56(%rax)
    leaq 64(%rax), %r8
    movq %r8, 8(%rax)
    movq %rcx, 24(%rax)
    movq %r8, %rcx
    addq %rsi, %rcx
    movq %rcx, 16(%rax)
    movq %rax, %fs:tl_current_arena@tpoff
    movq %r8, %rax
"]
    [tail-asm : String "    ret
.L_tl_alloc_abort:
    jmp tl_oom_abort

"]
    (str_cat.str-cat
      prefix
      fast-profile
      atomic-fast-asm
      atomic-fast-profile
      atomic-lock-asm
      atomic-locked-profile
      atomic-map-asm
      atomic-new-profile
      ordinary-new-asm
      new-profile
      tail-asm)))

(define (compiler-backend-runtime-linux-libc-shim-functions) : String
  "")

(define (compiler-backend-runtime-linux-arena-functions [profile : bool]) : String
  (string.append
    "    .globl tl_thread_init
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
"
    (string.append
      (compiler-backend-current-arena-load "%rax")
      (string.append
        "    ret

    .globl tl_arena_set
tl_arena_set:
"
        (string.append
          (compiler-backend-current-arena-store "%rdi")
          (string.append
            "    ret

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
"
            (string.append
              (runtime_common.compiler-backend-runtime-profile-live-sub
                "%rbx"
                "%r10"
                profile)
              "    push %r8
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

")))))))

(define (compiler-backend-runtime-region-reset-functions [profile : bool]) : String
  (string.append
    "    .globl tl_region_reset
tl_region_reset:
    push %rbx
    push %r12
    movq %rdi, %rbx
    testq %rbx, %rbx
    jz .L_tl_region_reset_all
    movq %fs:tl_current_arena@tpoff, %r8
    testq %r8, %r8
    jz .L_tl_region_reset_invalid
    movq 40(%r8), %r12
    testq $1, 48(%r12)
    jz .L_tl_region_reset_find
    movq 56(%r12), %r8
.L_tl_region_reset_find:
    movq 8(%r8), %r9
    cmpq %r9, %rbx
    jb .L_tl_region_reset_next
    movq 24(%r8), %r9
    cmpq %r9, %rbx
    jbe .L_tl_region_reset_found
.L_tl_region_reset_next:
    movq 0(%r8), %r8
    testq %r8, %r8
    jnz .L_tl_region_reset_find
    jmp .L_tl_region_reset_invalid
.L_tl_region_reset_found:
    movq 40(%r8), %r12
    movq %fs:tl_current_arena@tpoff, %r9
.L_tl_region_reset_drop_newer:
    cmpq %r8, %r9
    je .L_tl_region_reset_restore
    movq 0(%r9), %r10
"
    (string.append
      (runtime_common.compiler-backend-runtime-profile-live-sub
        "%r9"
        "%r11"
        profile)
      (string.append
        "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    jne .L_tl_region_reset_drop_newer_poison
    movq 24(%r9), %rsi
    subq %r9, %rsi
    movq %r9, %rdi
    movq $11, %rax
    syscall
    jmp .L_tl_region_reset_drop_newer_next
.L_tl_region_reset_drop_newer_poison:
    movq 8(%r9), %rdi
    movq 24(%r9), %rcx
    subq %rdi, %rcx
    jbe .L_tl_region_reset_drop_newer_retire
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_drop_newer_retire:
    movq 32(%r12), %r11
    movq %r11, 32(%r9)
    movq $0, 0(%r9)
    movq %r9, 32(%r12)
.L_tl_region_reset_drop_newer_next:
    movq %r10, %r9
    jmp .L_tl_region_reset_drop_newer
.L_tl_region_reset_restore:
"
        (string.append
          (runtime_common.compiler-backend-runtime-profile-live-rewind
            "%r8"
            "%rbx"
            "%r10"
            profile)
          (string.append
            "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_restore_set
    movq 16(%r8), %rcx
    subq %rbx, %rcx
    jbe .L_tl_region_reset_restore_set
    movq %rbx, %rdi
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_restore_set:
    movq %rbx, 16(%r8)
    movq %r8, 56(%r12)
    movq %r8, %fs:tl_current_arena@tpoff
    pop %r12
    pop %rbx
    ret
.L_tl_region_reset_all:
    movq %fs:tl_current_arena@tpoff, %r8
    movq $0, %fs:tl_current_arena@tpoff
    xorq %rbx, %rbx
    testq %r8, %r8
    jz .L_tl_region_reset_done
    movq 40(%r8), %r10
    testq %r10, %r10
    jz .L_tl_region_reset_all_loop
    movq 56(%r10), %r8
    testq %r8, %r8
    jnz .L_tl_region_reset_all_head_ready
    movq %r10, %r8
.L_tl_region_reset_all_head_ready:
.L_tl_region_reset_all_retired_ready:
    movq 32(%r10), %rbx
.L_tl_region_reset_all_loop:
    testq %r8, %r8
    jz .L_tl_region_reset_all_retired
    movq 0(%r8), %r9
"
            (string.append
              (runtime_common.compiler-backend-runtime-profile-live-sub
                "%r8"
                "%r10"
                profile)
              "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_all_unmap
    movq 8(%r8), %rdi
    movq 24(%r8), %rcx
    subq %rdi, %rcx
    jbe .L_tl_region_reset_all_unmap
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_all_unmap:
    movq 24(%r8), %rsi
    subq %r8, %rsi
    movq %r8, %rdi
    push %r9
    movq $11, %rax
    syscall
    pop %r8
    jmp .L_tl_region_reset_all_loop
.L_tl_region_reset_all_retired:
    movq %rbx, %r8
.L_tl_region_reset_all_retired_loop:
    testq %r8, %r8
    jz .L_tl_region_reset_done
    movq 32(%r8), %r9
    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_all_retired_unmap
    movq 8(%r8), %rdi
    movq 24(%r8), %rcx
    subq %rdi, %rcx
    jbe .L_tl_region_reset_all_retired_unmap
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_all_retired_unmap:
    movq 24(%r8), %rsi
    subq %r8, %rsi
    movq %r8, %rdi
    push %r9
    movq $11, %rax
    syscall
    pop %r8
    jmp .L_tl_region_reset_all_retired_loop
.L_tl_region_reset_done:
    pop %r12
    pop %rbx
    ret
.L_tl_region_reset_invalid:
    jmp tl_region_abort

")))))))

(define (compiler-backend-runtime-memcpy-functions) : String
  "    .globl tl_memcpy
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
")

(define (compiler-backend-runtime-memchr-functions) : String
  "    .globl tl_memchr
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
")

(define (compiler-backend-runtime-array-zero-functions) : String
  "    .globl tl_array_zero
tl_array_zero:
    movq %rsi, %rcx
    shrq $3, %rcx
    xorl %eax, %eax
    rep stosq
    movq %rsi, %rcx
    andq $7, %rcx
    rep stosb
    ret
")

(define (compiler-backend-runtime-tlci-entry-functions) : String
  "    .globl tl_tlci_call_image_entry
tl_tlci_call_image_entry:
    movq %rdi, %rax
    movq %rsi, %rdi
    movq %rdx, %rsi
    subq $8, %rsp
    call *%rax
    addq $8, %rsp
    ret

")

(define (compiler-backend-runtime-tlci-macro-entry-functions) : String
  "    .globl tl_tlci_call_macro_entry
tl_tlci_call_macro_entry:
    movq %rdi, %rax
    movq %rsi, %rdi
    movq %rdx, %rsi
    movq %rcx, %rdx
    movq %r8, %rcx
    movq %r9, %r8
    movq 8(%rsp), %r9
    subq $8, %rsp
    call *%rax
    addq $8, %rsp
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
    movq %rdi, tl_comptime_host_invoke_fn(%rip)
    leaq .L_tl_comptime_host_invoke_entry(%rip), %rax
    ret

.L_tl_comptime_host_invoke_entry:
    movq tl_comptime_host_invoke_fn(%rip), %r11
    movq 8(%r11), %rdi
    jmp *(%r11)

")

(define (compiler-backend-runtime-functions
  [features : (& features runtime_common.CompilerBackendRuntimeFeatures)]) : String
  (let
    [profile : bool
      (runtime_common.compiler-backend-runtime-features-profile? features)]
    [alloc-asm : String
      (if (runtime_common.compiler-backend-runtime-features-alloc? features)
        (compiler-backend-runtime-linux-alloc-functions profile)
        "")]
    [region-mark-asm : String
      (if (runtime_common.compiler-backend-runtime-features-region-mark?
        features)
        (compiler-backend-runtime-region-mark-functions)
        "")]
    [region-reset-asm : String
      (if (runtime_common.compiler-backend-runtime-features-region-reset?
        features)
        (compiler-backend-runtime-region-reset-functions profile)
        "")]
    [arena-asm : String
      (compiler-backend-runtime-linux-arena-functions profile)]
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
      (compiler-backend-runtime-linux-libc-shim-functions)]
    [thread-asm : String ""]
    (str_cat.str-cat runtime-front-asm thread-asm libc-shims-asm "")))

(define (compiler-backend-runtime-externs
  [features : (& features runtime_common.CompilerBackendRuntimeFeatures)]) : String
  "")