;; Optional poison/quarantine templates for bounded compiler test workloads.
;; Retired mappings remain reserved for the process lifetime. Reclamation first
;; discards committed pages, so quarantine does not retain their resident bytes.
;; The normal runtime templates are returned byte-for-byte when not selected.
;; Rewind seals the segment at the exact mark, so later allocations grow into
;; fresh segments. Full tail pages become inaccessible. The shared partial page
;; stays readable and is poisoned; this cannot detect every stale scalar read.
;; Header limits describe the remaining allocatable prefix. Quarantined virtual
;; reservations are intentionally absent from the ordinary live-arena counters.
(import compiler_owned_view as owned_view)
(import stdlib.string)
(import stdlib.io)
(import stdlib.str_cat_runtime as str_cat)

(define (runtime-sanitize-replace
  [text : String]
  [old : String]
  [replacement : String]
  [expected : i64]) : String
  (let
    [out : String text]
    [count : i64 0]
    (while (string.contains (& out) (& old))
      (when
        (>= count expected)
        (io.panic "compiler: unexpected arena sanitizer template site count\n"))
      (set!
        out
        (string.replace
          out
          (owned_view.compiler-owned-shared-view old)
          (owned_view.compiler-owned-shared-view replacement)))
      (set! count (+ count 1)))
    (unless
      (= count expected)
      (io.panic "compiler: missing arena sanitizer template site\n"))
    out))

(define (runtime-sanitize-linux-arena [text : String]) : String
  (str_cat.str-cat
    "    .globl tl_arena_sanitize_enable
    .type tl_arena_sanitize_enable,@function
tl_arena_sanitize_enable:
    jmp tl_arena_poison_enable
    .size tl_arena_sanitize_enable, . - tl_arena_sanitize_enable

"
    (runtime-sanitize-replace
      (runtime-sanitize-replace
        (runtime-sanitize-replace
          text
          "    movq $11, %rax
    syscall
"
          "    movq $28, %rax
    movq $4, %rdx
    syscall
    testq %rax, %rax
    js tl_oom_abort
    movq $10, %rax
    xorq %rdx, %rdx
    syscall
    testq %rax, %rax
    js tl_oom_abort
"
          2)
        "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_arena_destroy_unmap
    movq 8(%rbx), %rdi
    movq 24(%rbx), %rcx
    subq %rdi, %rcx
    jbe .L_tl_arena_destroy_unmap
    movb $0xA5, %al
    rep stosb
"
        ""
        1)
      "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_arena_destroy_retired_unmap
    movq 8(%rbx), %rdi
    movq 24(%rbx), %rcx
    subq %rdi, %rcx
    jbe .L_tl_arena_destroy_retired_unmap
    movb $0xA5, %al
    rep stosb
"
      ""
      1)))

(define (runtime-sanitize-linux-reset [text : String]) : String
  (runtime-sanitize-replace
    (runtime-sanitize-replace
      (runtime-sanitize-replace
        (runtime-sanitize-replace
          (runtime-sanitize-replace
            text
            "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    jne .L_tl_region_reset_drop_newer_poison
"
            ""
            1)
          "    movq $11, %rax
    syscall
"
          "    movq $28, %rax
    movq $4, %rdx
    syscall
    testq %rax, %rax
    js tl_oom_abort
    movq $10, %rax
    xorq %rdx, %rdx
    syscall
    testq %rax, %rax
    js tl_oom_abort
"
          3)
        "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_all_unmap
    movq 8(%r8), %rdi
    movq 24(%r8), %rcx
    subq %rdi, %rcx
    jbe .L_tl_region_reset_all_unmap
    movb $0xA5, %al
    rep stosb
"
        ""
        1)
      "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_all_retired_unmap
    movq 8(%r8), %rdi
    movq 24(%r8), %rcx
    subq %rdi, %rcx
    jbe .L_tl_region_reset_all_retired_unmap
    movb $0xA5, %al
    rep stosb
"
      ""
      1)
    "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    je .L_tl_region_reset_restore_set
    movq 16(%r8), %rcx
    subq %rbx, %rcx
    jbe .L_tl_region_reset_restore_set
    movq %rbx, %rdi
    movb $0xA5, %al
    rep stosb
.L_tl_region_reset_restore_set:
"
    "    leaq 4095(%rbx), %rsi
    andq $-4096, %rsi
    movq 16(%r8), %rcx
    cmpq %rsi, %rcx
    cmovaq %rsi, %rcx
    subq %rbx, %rcx
    jbe .L_tl_region_sanitize_tail_pages
    movq %rbx, %rdi
    movb $0xA5, %al
    rep stosb
.L_tl_region_sanitize_tail_pages:
    leaq 4095(%rbx), %rdi
    andq $-4096, %rdi
    movq 24(%r8), %rsi
    subq %rdi, %rsi
    jbe .L_tl_region_reset_restore_set
    movq $28, %rax
    movq $4, %rdx
    syscall
    testq %rax, %rax
    js tl_oom_abort
    movq $10, %rax
    xorq %rdx, %rdx
    syscall
    testq %rax, %rax
    js tl_oom_abort
.L_tl_region_reset_restore_set:
    movq %rbx, 24(%r8)
"
    1))

(define (runtime-sanitize-windows-arena [text : String]) : String
  (str_cat.str-cat
    "    .globl tl_arena_sanitize_enable
tl_arena_sanitize_enable:
    jmp tl_arena_poison_enable

"
    (runtime-sanitize-replace
      text
      "    movq %rsi, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    call VirtualFree
"
      "    movq %rsi, %rcx
    movq 24(%rsi), %rdx
    subq %rsi, %rdx
    movq $0x4000, %r8
    call VirtualFree
    testq %rax, %rax
    jnz 1f
    call tl_oom_abort
1:
"
      2)))

(define (runtime-sanitize-windows-reset [text : String]) : String
  (runtime-sanitize-replace
    (runtime-sanitize-replace
      (runtime-sanitize-replace
        text
        "    cmpq $0, .L_tl_arena_poison_enabled(%rip)
    jne .L_tl_region_reset_win_retire
"
        ""
        1)
      "    movq %r14, %rcx
    xorq %rdx, %rdx
    movq $0x8000, %r8
    sub $32, %rsp
    call VirtualFree
    add $32, %rsp
"
      "    movq %r14, %rcx
    movq 24(%r14), %rdx
    subq %r14, %rdx
    movq $0x4000, %r8
    sub $32, %rsp
    call VirtualFree
    testq %rax, %rax
    jnz 1f
    call tl_oom_abort
1:
    add $32, %rsp
"
      3)
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
"
    "    leaq 4095(%r12), %rbx
    andq $-4096, %rbx
    movq 16(%r13), %rcx
    cmpq %rbx, %rcx
    cmovaq %rbx, %rcx
    subq %r12, %rcx
    jbe .L_tl_region_sanitize_win_tail_pages
    pushq %rdi
    movq %r12, %rdi
    movb $0xA5, %al
    rep stosb
    popq %rdi
.L_tl_region_sanitize_win_tail_pages:
    cmpq 64(%r13), %rbx
    jae .L_tl_region_reset_win_decommit_done
    movq %rbx, %rcx
    movq 64(%r13), %rdx
    subq %rcx, %rdx
    movq $0x4000, %r8
    sub $32, %rsp
    call VirtualFree
    testq %rax, %rax
    jnz 1f
    call tl_oom_abort
1:
    add $32, %rsp
    movq %rbx, 64(%r13)
.L_tl_region_reset_win_decommit_done:
    movq %r12, 24(%r13)
    movq %r12, 64(%r13)
"
    1))

(define (runtime-sanitize-data [text : String]) : String
  (runtime-sanitize-replace
    text
    "    .section .bss
    .balign 8
.L_tl_arena_poison_enabled:
    .zero 8
"
    "    .section .data
    .balign 8
.L_tl_arena_poison_enabled:
    .quad 1
    .section .bss
"
    1))