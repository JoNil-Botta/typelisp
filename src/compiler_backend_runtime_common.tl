;; compiler_backend_runtime_common.tl - Target-neutral backend runtime recipes.
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
  (print-f64 bool)
  (startup-profile bool))

(define (compiler-backend-runtime-features-alloc?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  (struct-get features alloc))

(define (compiler-backend-runtime-features-region-mark?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  (struct-get features region-mark))

(define (compiler-backend-runtime-features-region-reset?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  (struct-get features region-reset))

(define (compiler-backend-runtime-features-arena-debug?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  (struct-get features arena-debug))

(define (compiler-backend-runtime-features-profile?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  (struct-get features profile))

(define (compiler-backend-runtime-features-tlci-macro-entry?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  (struct-get features tlci-macro-entry))

(define (compiler-backend-runtime-features-write-exit?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  (struct-get features write-exit))

(define (compiler-backend-runtime-features-print-f64?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  (struct-get features print-f64))

(define (compiler-backend-runtime-features-startup-profile?
  [features : (& features CompilerBackendRuntimeFeatures)]) : bool
  (struct-get features startup-profile))

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
    (string.append
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

(define (compiler-backend-runtime-fast-alloc-function
  [current-arena-load : String]
  [usable-end-offset : String]
  [size : i64]
  [size-reg : String]
  [next-reg : String]
  [profile : bool]) : String
  (let
    [size-text : String (string.int->string size)]
    [size-imm : String (string.append "$" size-text)]
    [label : String (compiler-backend-runtime-fast-alloc-label size)]
    [slow-label : String (string.append label "_slow")]
    [atomic-label : String (string.append label "_atomic")]
    [atomic-cas-label : String (string.append label "_atomic_cas")]
    [atomic-profile-label : String (string.append label "_atomic_profile_done")]
    [profile-label : String (string.append label "_profile_done")]
    [prologue : String
      (str_cat.str-cat
        label
        ":\n"
        current-arena-load
        "    testq %r8, %r8\n    jz "
        slow-label
        "\n")]
    [ordinary-body-a : String
      (str_cat.str-cat
        "    movq 40(%r8), %r9
    testq $1, 48(%r9)
    jnz "
        atomic-label
        "
    movq 16(%r8), %rax")]
    [ordinary-body-b : String
      (str_cat.str-cat "\n    leaq " size-text "(%rax), " next-reg)]
    ;; No wrap guard: `size` is one of the fixed 8..64 stub sizes, and the bump
    ;; cursor is a canonical user-space arena address, so `cursor + size` cannot
    ;; carry past 2^64. The general variable-size `tl_alloc` keeps its guard
    ;; because its size argument is caller-supplied. Only the usable-end bound
    ;; below can fail, and it routes to the same slow path.
    [ordinary-body-c : String
      (str_cat.str-cat "\n    cmpq " usable-end-offset "(%r8), " next-reg)]
    [ordinary-body-d : String
      (str_cat.str-cat "\n    ja " slow-label "\n    movq " next-reg)]
    [ordinary-body : String
      (str_cat.str-cat
        ordinary-body-a
        ordinary-body-b
        ordinary-body-c
        ordinary-body-d
        ", 16(%r8)\n")]
    [ordinary-profile : String
      (compiler-backend-runtime-profile-alloc-account
        size-imm
        profile-label
        profile)]
    [atomic-body-a : String
      (str_cat.str-cat
        "    ret
"
        atomic-label
        ":
    movq 56(%r9), %r8
    movq 16(%r8), %rax
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
        "(%r8), "
        next-reg
        "\n    ja "
        slow-label)]
    [atomic-body-e : String
      (str_cat.str-cat
        "\n    lock cmpxchgq "
        next-reg
        ", 16(%r8)\n    jne "
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
    (string.append
      prologue
      (string.append
        ordinary-body
        (string.append
          ordinary-profile
          (string.append atomic-body (string.append atomic-profile slow-body)))))))

(define (compiler-backend-runtime-fast-alloc-functions
  [current-arena-load : String]
  [usable-end-offset : String]
  [size-reg : String]
  [next-reg : String]
  [profile : bool]) : String
  (string.append
    (string.append
      (compiler-backend-runtime-fast-alloc-function
        current-arena-load
        usable-end-offset
        8
        size-reg
        next-reg
        profile)
      (compiler-backend-runtime-fast-alloc-function
        current-arena-load
        usable-end-offset
        16
        size-reg
        next-reg
        profile))
    (string.append
      (string.append
        (compiler-backend-runtime-fast-alloc-function
          current-arena-load
          usable-end-offset
          24
          size-reg
          next-reg
          profile)
        (compiler-backend-runtime-fast-alloc-function
          current-arena-load
          usable-end-offset
          32
          size-reg
          next-reg
          profile))
      (string.append
        (string.append
          (compiler-backend-runtime-fast-alloc-function
            current-arena-load
            usable-end-offset
            40
            size-reg
            next-reg
            profile)
          (compiler-backend-runtime-fast-alloc-function
            current-arena-load
            usable-end-offset
            48
            size-reg
            next-reg
            profile))
        (string.append
          (compiler-backend-runtime-fast-alloc-function
            current-arena-load
            usable-end-offset
            56
            size-reg
            next-reg
            profile)
          (compiler-backend-runtime-fast-alloc-function
            current-arena-load
            usable-end-offset
            64
            size-reg
            next-reg
            profile))))))

(define (compiler-backend-runtime-region-mark-functions
  [current-arena-load : String]) : String
  (string.append
    "    .globl tl_region_mark
tl_region_mark:
"
    (string.append
      current-arena-load
      "    testq %rax, %rax
    jz .L_tl_region_mark_zero
.L_tl_region_mark_current:
    movq 40(%rax), %r8
    testq $1, 48(%r8)
    jz .L_tl_region_mark_read
    movq 56(%r8), %rax
.L_tl_region_mark_read:
    movq 16(%rax), %rax
    ret
.L_tl_region_mark_zero:
    xorq %rax, %rax
    ret

")))

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