;; compiler_backend_runtime_common.tl - Target-neutral backend runtime recipes.
(import compiler_owned_view as owned_view)
(import stdlib.string)
(import compiler_str_cat as str_cat)

(defstruct CompilerBackendRuntimeFeatures
  (alloc bool)
  (region-mark bool)
  (region-reset bool)
  (arena-debug bool)
  (profile bool)
  (tlci-macro-entry bool)
  (startup-profile bool)
  (backtrace bool)
  (leaf-mask i64))

(define (compiler-backend-runtime-features-leaf?
  [features : (& features CompilerBackendRuntimeFeatures)]
  [bit : i64]) : bool
  (!= (bit-and features.leaf-mask bit) 0))

(define (compiler-backend-runtime-fast-alloc-label [size : i64]) : String
  (str_cat.str-cat ".L_tl_alloc" (string.int->string size) "" ""))

;; Arena-debug instrumentation exists only in compiler-arena-debug (and test)
;; builds; elsewhere the runtime text is the plain one whatever the program
;; asked for.
(define (compiler-backend-runtime-arena-debug-text? [_arena-debug : bool]) : bool
  (cfg (any compiler-arena-debug test) _arena-debug false))

(define (compiler-backend-runtime-arena-poison-data [arena-debug : bool]) : String
  (str_cat.str-cat
    "    .section .bss
    .balign 8
.L_tl_arena_poison_enabled:
    .zero 8

"
    (if arena-debug
      "    .balign 8
.L_tl_arena_debug_roots:
    .zero 32768

"
      "")))

;; Replace every OLD in TEXT; NEW must not contain OLD.
(define (compiler-backend-runtime-replace-all
  [text : String]
  [old : String]
  [new : String]) : String
  (let
    [out : String text]
    (while (string.contains (& out) (& old))
      (set!
        out
        (string.replace
          out
          (owned_view.compiler-owned-shared-view old)
          (owned_view.compiler-owned-shared-view new))))
    out))

;; The arena-debug root registry and its checked entry points for one target:
;; ARG is the first argument register, IDX the slot index, and SUFFIX tells the
;; target's local labels apart. The ELF leaf closes each symbol's extent and
;; jumps to the aborts; Win64 calls them from a shadow-space frame.
(define (compiler-backend-runtime-arena-debug-functions
  [arg : String]
  [idx : String]
  [suffix : String]
  [elf : bool]) : String
  (compiler-backend-runtime-replace-all
    (compiler-backend-runtime-replace-all
      (compiler-backend-runtime-replace-all
        (str_cat.str-cat
          ".L_tl_arena_debug_register_root:
    leaq .L_tl_arena_debug_roots(%rip), %r8
    xorq %idx, %idx
.L_tl_arena_debug_register_root_SFX_loop:
    cmpq $4096, %idx
    jae .L_tl_arena_debug_protect_SFX_invalid
    xorq %rax, %rax
    lock cmpxchgq %arg, (%r8,%idx,8)
    je .L_tl_arena_debug_register_root_SFX_done
    cmpq %arg, %rax
    je .L_tl_arena_debug_register_root_SFX_done
    incq %idx
    jmp .L_tl_arena_debug_register_root_SFX_loop
.L_tl_arena_debug_register_root_SFX_done:
    movq %arg, %rax
    ret

.L_tl_arena_debug_unregister_root:
    leaq .L_tl_arena_debug_roots(%rip), %r8
    xorq %idx, %idx
.L_tl_arena_debug_unregister_root_SFX_loop:
    cmpq $4096, %idx
    jae .L_tl_arena_debug_unregister_root_SFX_done
    movq (%r8,%idx,8), %rax
    cmpq %arg, %rax
    jne .L_tl_arena_debug_unregister_root_SFX_next
    xorq %r9, %r9
    lock cmpxchgq %r9, (%r8,%idx,8)
    jne .L_tl_arena_debug_unregister_root_SFX_loop
    ret
.L_tl_arena_debug_unregister_root_SFX_next:
    incq %idx
    jmp .L_tl_arena_debug_unregister_root_SFX_loop
.L_tl_arena_debug_unregister_root_SFX_done:
    ret

    .globl tl_arena_debug_protect_never_reset
"
          (if elf
            "    .type tl_arena_debug_protect_never_reset,@function\n"
            "")
          "tl_arena_debug_protect_never_reset:
    testq %arg, %arg
    jz .L_tl_arena_debug_protect_SFX_invalid
    leaq .L_tl_arena_debug_roots(%rip), %r8
    xorq %idx, %idx
.L_tl_arena_debug_protect_SFX_find:
    cmpq $4096, %idx
    jae .L_tl_arena_debug_protect_SFX_invalid
    cmpq %arg, (%r8,%idx,8)
    je .L_tl_arena_debug_protect_SFX_found
    incq %idx
    jmp .L_tl_arena_debug_protect_SFX_find
.L_tl_arena_debug_protect_SFX_found:
    cmpq %arg, 40(%arg)
    jne .L_tl_arena_debug_protect_SFX_invalid
    testq $1, 48(%arg)
    jnz .L_tl_arena_debug_protect_SFX_invalid
    orq $8, 48(%arg)
    ret
.L_tl_arena_debug_protect_SFX_invalid:
"
          (if elf
            "    jmp tl_arena_debug_protect_abort
    .size tl_arena_debug_protect_never_reset, . - tl_arena_debug_protect_never_reset
"
            "    subq $40, %rsp
    call tl_arena_debug_protect_abort
")
          "
    .globl tl_arena_debug_retire_protected
tl_arena_debug_retire_protected:
    testq %arg, %arg
    jz .L_tl_arena_debug_protect_SFX_invalid
    leaq .L_tl_arena_debug_roots(%rip), %r8
    xorq %idx, %idx
.L_tl_arena_debug_retire_SFX_find:
    cmpq $4096, %idx
    jae .L_tl_arena_debug_protect_SFX_invalid
    cmpq %arg, (%r8,%idx,8)
    je .L_tl_arena_debug_retire_SFX_found
    incq %idx
    jmp .L_tl_arena_debug_retire_SFX_find
.L_tl_arena_debug_retire_SFX_found:
    cmpq %arg, 40(%arg)
    jne .L_tl_arena_debug_protect_SFX_invalid
    testq $8, 48(%arg)
    jz .L_tl_arena_debug_protect_SFX_invalid
    andq $-9, 48(%arg)
    jmp tl_arena_destroy

    .globl tl_arena_debug_assert_pool_install
"
          (if elf
            "    .type tl_arena_debug_assert_pool_install,@function\n"
            "")
          "tl_arena_debug_assert_pool_install:
    testq %arg, %arg
    jz .L_tl_arena_debug_pool_install_SFX_done
    movq 40(%arg), %rax
    testq %rax, %rax
    jz .L_tl_arena_debug_pool_install_SFX_done
    testq $8, 48(%rax)
"
          (if elf
            "    jnz tl_arena_debug_pool_install_abort\n"
            "    jnz .L_tl_arena_debug_pool_install_SFX_abort\n")
          ".L_tl_arena_debug_pool_install_SFX_done:
    ret
"
          (if elf
            "    .size tl_arena_debug_assert_pool_install, . - tl_arena_debug_assert_pool_install
"
            ".L_tl_arena_debug_pool_install_SFX_abort:
    subq $40, %rsp
    call tl_arena_debug_pool_install_abort
")
          "\n")
        "%arg"
        arg)
      "%idx"
      idx)
    "_SFX"
    suffix))

(define (compiler-backend-runtime-profile-data [profile : bool]) : String
  (if profile
    "    .section .bss
    .balign 8
tl_profile_alloc_total_bytes:
    .zero 8
tl_profile_alloc_live_bytes:
    .zero 8
tl_profile_alloc_peak_bytes:
    .zero 8

"
    ""))

(define (compiler-backend-runtime-startup-profile-data [startup-profile : bool]) : String
  (if startup-profile
    "    .section .bss
    .balign 8
.L_tl_startup_profile_process_entry_tick:
    .zero 8
.L_tl_startup_profile_timespec:
    .zero 16

"
    ""))

(define (compiler-backend-runtime-region-reset-data) : String
  "    .section .rodata
.L_tl_region_reset_msg:
    .byte 116,108,58,32,105,110,118,97,108,105,100,32,114,101,103,105,111,110,32,109,97,114,107,10
    .set .L_tl_region_reset_msg_len, . - .L_tl_region_reset_msg

")

(define (compiler-backend-runtime-argv-data) : String
  "    .data
    .balign 8
.L_tl_argc:
    .quad 0
.L_tl_argv:
    .quad 0

")

(define (compiler-backend-runtime-env-data) : String
  "    .data
    .balign 8
.L_tl_envp:
    .quad 0

")

(define (compiler-backend-runtime-common-data
  [features : (& features CompilerBackendRuntimeFeatures)]
  [arena-data : String]) : String
  (str_cat.str-cat
    arena-data
    (compiler-backend-runtime-startup-profile-data features.startup-profile)
    (compiler-backend-runtime-profile-data features.profile)
    (if features.region-reset
      (compiler-backend-runtime-region-reset-data)
      "")
    (compiler-backend-runtime-argv-data)
    (compiler-backend-runtime-env-data)))

(define (compiler-backend-runtime-startup-profile-functions
  [startup-profile : bool]) : String
  (if startup-profile
    "    .text
    .globl tl_startup_profile_process_entry_tick
tl_startup_profile_process_entry_tick:
    movq .L_tl_startup_profile_process_entry_tick(%rip), %rax
    ret

"
    ""))

(define (compiler-backend-runtime-profile-alloc-account
  [size-reg : (& size-reg str)]
  [done-label : String]
  [profile : bool]) : String
  (compiler-backend-runtime-profile-alloc-account-with-scratch
    size-reg
    done-label
    profile
    "%r10"))

(define (compiler-backend-runtime-profile-alloc-account-with-scratch
  [size-reg : (& size-reg str)]
  [done-label : String]
  [profile : bool]
  [scratch-reg : String]) : String
  (if profile
    (str_cat.str-cat
      (str_cat.str-cat
        "    addq "
        size-reg
        ", tl_profile_alloc_total_bytes(%rip)\n    addq "
        size-reg
        ", tl_profile_alloc_live_bytes(%rip)\n")
      (str_cat.str-cat
        "    movq tl_profile_alloc_live_bytes(%rip), "
        scratch-reg
        "\n    cmpq tl_profile_alloc_peak_bytes(%rip), "
        scratch-reg
        "\n    jbe "
        done-label
        "\n    movq "
        scratch-reg
        ", tl_profile_alloc_peak_bytes(%rip)\n"
        done-label
        ":\n"))
    ""))

;; Explicitly aligned allocation separates the logical payload charge from the
;; physical arena claim.  `total` counts the rounded payload once; `live` and
;; `peak` include the padding consumed between the old cursor and aligned end.
;; Reserved/committed mapping capacity is intentionally not profiled.
(define (compiler-backend-runtime-profile-aligned-alloc-account
  [payload-reg : String]
  [claim-reg : String]
  [done-label : String]
  [profile : bool]
  [scratch-reg : String]) : String
  (if profile
    (str_cat.str-cat
      (str_cat.str-cat
        "    addq "
        payload-reg
        ", tl_profile_alloc_total_bytes(%rip)\n    addq ")
      (str_cat.str-cat
        claim-reg
        ", tl_profile_alloc_live_bytes(%rip)\n    movq tl_profile_alloc_live_bytes(%rip), "
        scratch-reg
        "\n")
      (str_cat.str-cat
        "    cmpq tl_profile_alloc_peak_bytes(%rip), "
        scratch-reg
        "\n    jbe "
        done-label)
      (str_cat.str-cat
        "\n    movq "
        scratch-reg
        ", tl_profile_alloc_peak_bytes(%rip)\n"
        (str_cat.str-cat done-label ":\n" "" "")))
    ""))

(define (compiler-backend-runtime-profile-live-sub
  [arena-reg : String]
  [used-reg : String]
  [profile : bool]) : String
  (if profile
    (str_cat.str-cat
      "    movq 16("
      arena-reg
      "), "
      used-reg
      "\n    subq 8("
      arena-reg
      "), "
      used-reg
      "\n    subq "
      used-reg
      ", tl_profile_alloc_live_bytes(%rip)\n")
    ""))

(define (compiler-backend-runtime-profile-live-rewind
  [arena-reg : String]
  [mark-reg : String]
  [used-reg : String]
  [profile : bool]) : String
  (if profile
    (str_cat.str-cat
      "    movq 16("
      arena-reg
      "), "
      used-reg
      "\n    subq "
      mark-reg
      ", "
      used-reg
      "\n    subq "
      used-reg
      ", tl_profile_alloc_live_bytes(%rip)\n")
    ""))

;; The current-arena slot never holds 0 once a thread's TLS is in place: "no
;; arena yet" is `.L_tl_null_arena`, an arena header no allocation ever writes.
;; Its flag word carries the shared bit (1), so an inline fast path, which tests
;; only that bit, takes its slow path, and the null bit (16), by which runtime
;; readers tell it from a real arena. Its current-segment word (56) is 0, which
;; no real arena has. `tl_arena_current` reports it as 0, by a conditional move
;; from its zero first word, and `tl_arena_set` stores it for 0, so arena
;; handles keep 0 for "none". Every thread installs it before its first
;; allocation, so no reader tests for 0; allocators test the null bit only on
;; the shared-arena branch the shared bit already sent them to.
(define (compiler-backend-runtime-null-arena-data) : String
  "    .section .rodata
    .balign 8
.L_tl_null_arena:
    .quad 0, 0, 0, 0, 0, 0, 17, 0

")

(define (compiler-backend-runtime-fast-alloc-function
  [current-arena-load : (& current-arena-load str)]
  [usable-end-offset : (& usable-end-offset str)]
  [size : i64]
  [size-reg : (& size-reg str)]
  [next-reg : (& next-reg str)]
  [profile : bool]) : String
  (let
    [size-text : String (string.int->string size)]
    [size-imm : String (str_cat.str-cat "$" size-text)]
    [label : String (compiler-backend-runtime-fast-alloc-label size)]
    [slow-label : String (str_cat.str-cat label "_slow")]
    [atomic-label : String (str_cat.str-cat label "_atomic")]
    [atomic-cas-label : String (str_cat.str-cat label "_atomic_cas")]
    [atomic-profile-label : String
      (str_cat.str-cat label "_atomic_profile_done")]
    [profile-label : String (str_cat.str-cat label "_profile_done")]
    ;; No null test: with no arena the slot holds the null-arena sentinel, whose
    ;; shared bit takes the atomic branch below and whose zero current segment
    ;; sends it on to `tl_alloc`.
    [prologue : String (str_cat.str-cat label ":\n" current-arena-load)]
    [ordinary-body-a : String
      (str_cat.str-cat
        "    movq 56(%r8), %r9
    testq $1, 48(%r8)
    jnz "
        atomic-label
        "
    movq 16(%r9), %rax")]
    [ordinary-body-b : String
      (str_cat.str-cat "\n    leaq " size-text "(%rax), " next-reg)]
    ;; No wrap guard: `size` is one of the fixed 8..64 stub sizes, and the bump
    ;; cursor is a canonical user-space arena address, so `cursor + size` cannot
    ;; carry past 2^64. The general variable-size `tl_alloc` keeps its guard
    ;; because its size argument is caller-supplied. Only the usable-end bound
    ;; below can fail, and it routes to the same slow path.
    [ordinary-body-c : String
      (str_cat.str-cat "\n    cmpq " usable-end-offset "(%r9), " next-reg)]
    [ordinary-body-d : String
      (str_cat.str-cat "\n    ja " slow-label "\n    movq " next-reg)]
    [ordinary-body : String
      (str_cat.str-cat
        ordinary-body-a
        ordinary-body-b
        ordinary-body-c
        ordinary-body-d
        ", 16(%r9)\n")]
    [ordinary-profile : String
      (compiler-backend-runtime-profile-alloc-account
        size-imm
        profile-label
        profile)]
    ;; Only the null-arena sentinel has a zero current segment; it arrives here
    ;; through its shared bit and leaves for `tl_alloc`.
    [atomic-body-a : String
      (str_cat.str-cat
        "    ret
"
        atomic-label
        ":
    movq 56(%r8), %r9
    testq %r9, %r9
    jz "
        slow-label
        "
    movq 16(%r9), %rax
"
        atomic-cas-label)]
    [atomic-body-b : String
      (str_cat.str-cat ":\n    leaq " size-text "(%rax), " next-reg)]
    ;; Same fixed-size wrap argument as the ordinary body above.
    [atomic-body-c : String ""]
    [atomic-body-d : String
      (str_cat.str-cat
        "\n    cmpq "
        usable-end-offset
        "(%r9), "
        next-reg
        "\n    ja "
        slow-label)]
    [atomic-body-e : String
      (str_cat.str-cat
        "\n    lock cmpxchgq "
        next-reg
        ", 16(%r9)\n    jne "
        atomic-cas-label)]
    [atomic-body : String
      (str_cat.str-cat
        atomic-body-a
        atomic-body-b
        atomic-body-c
        atomic-body-d
        atomic-body-e
        "\n")]
    [atomic-profile : String
      (compiler-backend-runtime-profile-alloc-account
        size-imm
        atomic-profile-label
        profile)]
    [slow-body : String
      (str_cat.str-cat
        "    ret
"
        slow-label
        ":\n    movq $"
        size-text
        ", "
        size-reg
        "\n    jmp tl_alloc\n")]
    (str_cat.str-cat
      prologue
      ordinary-body
      ordinary-profile
      atomic-body
      atomic-profile
      slow-body)))

;; One bump stub per size class 8, 16, ..., 64.
(define (compiler-backend-runtime-fast-alloc-functions
  [current-arena-load : String]
  [usable-end-offset : String]
  [size-reg : String]
  [next-reg : String]
  [profile : bool]) : String
  (let
    [out : String ""]
    [size : i64 8]
    (while (<= size 64)
      (set!
        out
        (str_cat.str-cat
          out
          (compiler-backend-runtime-fast-alloc-function
            current-arena-load
            usable-end-offset
            size
            size-reg
            next-reg
            profile)
          ""
          ""))
      (set! size (+ size 8)))
    out))

(define (compiler-backend-runtime-region-mark-functions
  [current-arena-load : String]) : String
  (str_cat.str-cat
    "    .globl tl_region_mark
tl_region_mark:
"
    current-arena-load
    "    testb $16, 48(%rax)
    jnz .L_tl_region_mark_zero
.L_tl_region_mark_current:
    movq 56(%rax), %rax
.L_tl_region_mark_read:
    movq 16(%rax), %rax
    ret
.L_tl_region_mark_zero:
    xorq %rax, %rax
    ret

"))

(define (compiler-backend-runtime-profile-functions) : String
  "    .globl tl_profile_alloc_total
tl_profile_alloc_total:
    movq tl_profile_alloc_total_bytes(%rip), %rax
    ret

    .globl tl_profile_alloc_live
tl_profile_alloc_live:
    movq tl_profile_alloc_live_bytes(%rip), %rax
    ret

    .globl tl_profile_alloc_peak
tl_profile_alloc_peak:
    movq tl_profile_alloc_peak_bytes(%rip), %rax
    ret

    .globl tl_profile_alloc_reset_peak
tl_profile_alloc_reset_peak:
    movq tl_profile_alloc_live_bytes(%rip), %rax
    movq %rax, tl_profile_alloc_peak_bytes(%rip)
    xorq %rax, %rax
    ret

")