;; compiler_backend_runtime_common.tl - Target-neutral backend runtime recipes.
(import compiler_owned_view as owned_view)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(defstruct CompilerBackendRuntimeFeatures
  (alloc bool)
  (region-mark bool)
  (region-reset bool)
  (arena-debug bool)
  (profile bool)
  (tlci-macro-entry bool)
  (write-exit bool)
  (startup-profile bool)
  (backtrace bool))

(define (compiler-backend-runtime-features-alloc?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  features.alloc)

(define (compiler-backend-runtime-features-region-mark?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  features.region-mark)

(define (compiler-backend-runtime-features-region-reset?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  features.region-reset)

(define (compiler-backend-runtime-features-arena-debug?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  features.arena-debug)

(define (compiler-backend-runtime-features-profile?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  features.profile)

(define (compiler-backend-runtime-features-tlci-macro-entry?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  features.tlci-macro-entry)

(define (compiler-backend-runtime-features-write-exit?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  features.write-exit)

(define (compiler-backend-runtime-features-startup-profile?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  features.startup-profile)

(define (compiler-backend-runtime-features-backtrace?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  features.backtrace)

(define (compiler-backend-runtime-fast-alloc-label [size : i64]) : String
  (str_cat.str-cat ".L_tl_alloc" (string.int->string size) "" ""))

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
    (compiler-backend-runtime-startup-profile-data
      (compiler-backend-runtime-features-startup-profile? features))
    (compiler-backend-runtime-profile-data
      (compiler-backend-runtime-features-profile? features))
    (if (compiler-backend-runtime-features-region-reset? features)
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
  [size-reg : String]
  [done-label : String]
  [profile : bool]) : String
  (compiler-backend-runtime-profile-alloc-account-with-scratch
    size-reg
    done-label
    profile
    "%r10"))

(define (compiler-backend-runtime-profile-alloc-account-with-scratch
  [size-reg : String]
  [done-label : String]
  [profile : bool]
  [scratch-reg : String]) : String
  (if profile
    (str_cat.str-cat
      (str_cat.str-cat
        "    addq "
        (owned_view.compiler-owned-shared-view size-reg)
        ", tl_profile_alloc_total_bytes(%rip)\n    addq "
        size-reg
        ", tl_profile_alloc_live_bytes(%rip)\n")
      (str_cat.str-cat
        "    movq tl_profile_alloc_live_bytes(%rip), "
        (owned_view.compiler-owned-shared-view scratch-reg)
        "\n    cmpq tl_profile_alloc_peak_bytes(%rip), "
        (owned_view.compiler-owned-shared-view scratch-reg)
        "\n    jbe "
        (owned_view.compiler-owned-shared-view done-label)
        "\n    movq "
        scratch-reg
        ", tl_profile_alloc_peak_bytes(%rip)\n"
        done-label
        ":\n"))
    ""))

(define (compiler-backend-runtime-profile-live-sub
  [arena-reg : String]
  [used-reg : String]
  [profile : bool]) : String
  (if profile
    (str_cat.str-cat
      "    movq 16("
      (owned_view.compiler-owned-shared-view arena-reg)
      "), "
      (owned_view.compiler-owned-shared-view used-reg)
      "\n    subq 8("
      arena-reg
      "), "
      (owned_view.compiler-owned-shared-view used-reg)
      "\n    subq "
      (owned_view.compiler-owned-shared-view used-reg)
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
      (owned_view.compiler-owned-shared-view used-reg)
      "\n    subq "
      mark-reg
      ", "
      (owned_view.compiler-owned-shared-view used-reg)
      "\n    subq "
      used-reg
      ", tl_profile_alloc_live_bytes(%rip)\n")
    ""))

(define (compiler-backend-runtime-fast-alloc-function
  [current-arena-load : String]
  [usable-end-offset : String]
  [size : i64]
  [size-reg : String]
  [next-reg : String]
  [profile : bool]) : String
  (let
    [size-text : String (string.int->string size)]
    [size-imm : String
      (str_cat.str-cat "$" (owned_view.compiler-owned-shared-view size-text))]
    [label : String (compiler-backend-runtime-fast-alloc-label size)]
    [slow-label : String
      (str_cat.str-cat (owned_view.compiler-owned-shared-view label) "_slow")]
    [atomic-label : String
      (str_cat.str-cat (owned_view.compiler-owned-shared-view label) "_atomic")]
    [atomic-cas-label : String
      (str_cat.str-cat
        (owned_view.compiler-owned-shared-view label)
        "_atomic_cas")]
    [atomic-profile-label : String
      (str_cat.str-cat
        (owned_view.compiler-owned-shared-view label)
        "_atomic_profile_done")]
    [profile-label : String
      (str_cat.str-cat
        (owned_view.compiler-owned-shared-view label)
        "_profile_done")]
    [prologue : String
      (str_cat.str-cat
        label
        ":\n"
        current-arena-load
        "    testq %r8, %r8\n    jz "
        (owned_view.compiler-owned-shared-view slow-label)
        "\n")]
    [ordinary-body-a : String
      (str_cat.str-cat
        "    movq 56(%r8), %r9
    testq $1, 48(%r8)
    jnz "
        (owned_view.compiler-owned-shared-view atomic-label)
        "
    movq 16(%r9), %rax")]
    [ordinary-body-b : String
      (str_cat.str-cat
        "\n    leaq "
        (owned_view.compiler-owned-shared-view size-text)
        "(%rax), "
        (owned_view.compiler-owned-shared-view next-reg))]
    ;; No wrap guard: `size` is one of the fixed 8..64 stub sizes, and the bump
    ;; cursor is a canonical user-space arena address, so `cursor + size` cannot
    ;; carry past 2^64. The general variable-size `tl_alloc` keeps its guard
    ;; because its size argument is caller-supplied. Only the usable-end bound
    ;; below can fail, and it routes to the same slow path.
    [ordinary-body-c : String
      (str_cat.str-cat
        "\n    cmpq "
        (owned_view.compiler-owned-shared-view usable-end-offset)
        "(%r9), "
        (owned_view.compiler-owned-shared-view next-reg))]
    [ordinary-body-d : String
      (str_cat.str-cat
        "\n    ja "
        (owned_view.compiler-owned-shared-view slow-label)
        "\n    movq "
        (owned_view.compiler-owned-shared-view next-reg))]
    [ordinary-body : String
      (str_cat.str-cat
        ordinary-body-a
        ordinary-body-b
        ordinary-body-c
        ordinary-body-d
        ", 16(%r9)\n")]
    [ordinary-profile : String
      (compiler-backend-runtime-profile-alloc-account
        (owned_view.compiler-owned-shared-view size-imm)
        profile-label
        profile)]
    [atomic-body-a : String
      (str_cat.str-cat
        "    ret
"
        atomic-label
        ":
    movq 56(%r8), %r9
    movq 16(%r9), %rax
"
        (owned_view.compiler-owned-shared-view atomic-cas-label))]
    [atomic-body-b : String
      (str_cat.str-cat
        ":\n    leaq "
        (owned_view.compiler-owned-shared-view size-text)
        "(%rax), "
        (owned_view.compiler-owned-shared-view next-reg))]
    ;; Same fixed-size wrap argument as the ordinary body above.
    [atomic-body-c : String ""]
    [atomic-body-d : String
      (str_cat.str-cat
        "\n    cmpq "
        (owned_view.compiler-owned-shared-view usable-end-offset)
        "(%r9), "
        (owned_view.compiler-owned-shared-view next-reg)
        "\n    ja "
        (owned_view.compiler-owned-shared-view slow-label))]
    [atomic-body-e : String
      (str_cat.str-cat
        "\n    lock cmpxchgq "
        (owned_view.compiler-owned-shared-view next-reg)
        ", 16(%r9)\n    jne "
        (owned_view.compiler-owned-shared-view atomic-cas-label))]
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
        (owned_view.compiler-owned-shared-view size-imm)
        (owned_view.compiler-owned-shared-view atomic-profile-label)
        profile)]
    [slow-body : String
      (str_cat.str-cat
        "    ret
"
        (owned_view.compiler-owned-shared-view slow-label)
        ":\n    movq $"
        (owned_view.compiler-owned-shared-view size-text)
        ", "
        (owned_view.compiler-owned-shared-view size-reg)
        "\n    jmp tl_alloc\n")]
    (str_cat.str-cat
      prologue
      ordinary-body
      ordinary-profile
      atomic-body
      atomic-profile
      slow-body)))

(define (compiler-backend-runtime-fast-alloc-functions
  [current-arena-load : String]
  [usable-end-offset : String]
  [size-reg : String]
  [next-reg : String]
  [profile : bool]) : String
  (str_cat.str-cat
    (compiler-backend-runtime-fast-alloc-function
      (owned_view.compiler-owned-shared-view current-arena-load)
      (owned_view.compiler-owned-shared-view usable-end-offset)
      8
      (owned_view.compiler-owned-shared-view size-reg)
      (owned_view.compiler-owned-shared-view next-reg)
      profile)
    (compiler-backend-runtime-fast-alloc-function
      (owned_view.compiler-owned-shared-view current-arena-load)
      (owned_view.compiler-owned-shared-view usable-end-offset)
      16
      (owned_view.compiler-owned-shared-view size-reg)
      (owned_view.compiler-owned-shared-view next-reg)
      profile)
    (compiler-backend-runtime-fast-alloc-function
      (owned_view.compiler-owned-shared-view current-arena-load)
      (owned_view.compiler-owned-shared-view usable-end-offset)
      24
      (owned_view.compiler-owned-shared-view size-reg)
      (owned_view.compiler-owned-shared-view next-reg)
      profile)
    (compiler-backend-runtime-fast-alloc-function
      (owned_view.compiler-owned-shared-view current-arena-load)
      (owned_view.compiler-owned-shared-view usable-end-offset)
      32
      (owned_view.compiler-owned-shared-view size-reg)
      (owned_view.compiler-owned-shared-view next-reg)
      profile)
    (compiler-backend-runtime-fast-alloc-function
      (owned_view.compiler-owned-shared-view current-arena-load)
      (owned_view.compiler-owned-shared-view usable-end-offset)
      40
      (owned_view.compiler-owned-shared-view size-reg)
      (owned_view.compiler-owned-shared-view next-reg)
      profile)
    (compiler-backend-runtime-fast-alloc-function
      (owned_view.compiler-owned-shared-view current-arena-load)
      (owned_view.compiler-owned-shared-view usable-end-offset)
      48
      (owned_view.compiler-owned-shared-view size-reg)
      (owned_view.compiler-owned-shared-view next-reg)
      profile)
    (compiler-backend-runtime-fast-alloc-function
      (owned_view.compiler-owned-shared-view current-arena-load)
      (owned_view.compiler-owned-shared-view usable-end-offset)
      56
      (owned_view.compiler-owned-shared-view size-reg)
      (owned_view.compiler-owned-shared-view next-reg)
      profile)
    (compiler-backend-runtime-fast-alloc-function
      (owned_view.compiler-owned-shared-view current-arena-load)
      (owned_view.compiler-owned-shared-view usable-end-offset)
      64
      (owned_view.compiler-owned-shared-view size-reg)
      (owned_view.compiler-owned-shared-view next-reg)
      profile)))

(define (compiler-backend-runtime-region-mark-functions
  [current-arena-load : String]) : String
  (str_cat.str-cat
    "    .globl tl_region_mark
tl_region_mark:
"
    current-arena-load
    "    testq %rax, %rax
    jz .L_tl_region_mark_zero
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