;; Exercise the labels and relocations that can cross emitted helper fragments.
(import compiler_backend_runtime_prune as prune)
(import compiler_str_cat as str_cat)
(import stdlib.string)
(import stdlib.test)

(test
  compiler-backend-runtime-prune-dependencies
  (let
    [program : String
      (str_cat.str-cat
        ".globl user_export
user_export:
    jmp \"__tl_arg_entry:9\"
    .quad .L_tl_thunk
    .extern unused
"
        (prune.optional-fragment
          ".globl tl_oob_abort_at
\"__tl_arg_entry:9\":
tl_oob_abort_at:
    call .L_tl_alloc16
    ret
")
        (prune.optional-fragment "unused:
    jmp other_unused
")
        (prune.optional-fragment "other_unused:
    jmp unused
")
        (prune.optional-fragment
          ".L_tl_thunk:
    call tl_oob_abort_at
    ret
")
        (prune.optional-bundle
          ".L_tl_alloc8:
    jmp .L_tl_alloc8_slow
.L_tl_alloc8_slow:
    ret
.L_tl_alloc16:
    jmp .L_tl_alloc16_slow
.L_tl_alloc16_slow:
    ret
"))]
    [output : String (prune.prune program)]
    (test.assert-true
      (string.contains (& output) ".globl user_export\n")
      "user C ABI export remains a root")
    (test.assert-true
      (string.contains (& output) ".L_tl_thunk:\n")
      "a data relocation keeps the located abort thunk")
    (test.assert-true
      (string.contains (& output) "tl_oob_abort_at:\n")
      "a quoted arg-entry reference keeps its containing abort handler")
    (test.assert-true
      (string.contains (& output) ".L_tl_alloc16_slow:\n")
      "the selected allocator fragment includes internal slow-path labels")
    (test.assert-true
      (not (string.contains (& output) ".L_tl_alloc8:"))
      "unreferenced fast allocator size class is omitted")
    (test.assert-true
      (not (string.contains (& output) "other_unused:"))
      "an extern declaration does not root a dead helper cycle")))

(test
  compiler-backend-runtime-prune-abort-handlers
  (let
    [program : String
      (str_cat.str-cat
        "    .tl_abort_row .L_pc, .L_path, 1, 1, tl_oob_abort_at
"
        (prune.optional-fragment "tl_oob_abort_at:
    ret
")
        (prune.optional-fragment "tl_div_abort_at:
    ret
")
        (prune.optional-fragment "tl_shift_abort_at:
    ret
")
        (prune.optional-fragment "tl_panic_at:
    ret
")
        "    .irp kind, tl_oob_abort_at, tl_div_abort_at, tl_shift_abort_at, tl_panic_at
    .ifdef .L_tl_abort_used_\\kind
    jmp \\kind
    .endif
    .endr
")]
    [output : String (prune.prune program)]
    (test.assert-true
      (string.contains (& output) "tl_oob_abort_at:\n")
      "the abort row keeps its handler")
    (test.assert-true
      (not (string.contains (& output) "tl_div_abort_at:\n"))
      "the iteration list does not keep the division abort handler")
    (test.assert-true
      (not (string.contains (& output) "tl_shift_abort_at:\n"))
      "the iteration list does not keep the shift abort handler")
    (test.assert-true
      (not (string.contains (& output) "tl_panic_at:\n"))
      "the iteration list does not keep the panic handler")))

(test
  compiler-backend-runtime-prune-literals
  (let
    [program : String
      (str_cat.str-cat
        "main:
    leaq .L_tl_str_la(%rip), %rdi
    leaq .L_tl_str_le(%rip), %rsi
    ret
    .section .rodata
"
        (prune.literal-begin)
        ".L_tl_str_data_a:
    .ascii \"pan\"
.L_tl_str_data_b:
    .ascii \"ic\"
"
        (prune.literal-unit-end)
        ".L_tl_str_data_c:
    .ascii \"dead\"
"
        (prune.literal-unit-end)
        ".L_tl_str_data_d:
    .ascii \"ov\"
.L_tl_str_data_e:
    .ascii \"erlap\"
"
        (prune.literal-unit-end)
        "    .balign 8
"
        (prune.literal-begin)
        ".L_tl_str_la:
    .quad .L_tl_str_data_a
    .quad 5
.L_tl_str_lc:
    .quad .L_tl_str_data_c
    .quad 4
.L_tl_str_le:
    .quad .L_tl_str_data_e
    .quad 5
"
        (prune.literal-end)
        "    .text
"
        (prune.optional-fragment
          "tl_dead_helper:
    leaq .L_tl_str_lc(%rip), %rdi
    ret
"))]
    [output : String (prune.prune program)]
    (test.assert-true
      (string.contains (& output) ".L_tl_str_la:\n")
      "a header named by live code remains")
    (test.assert-true
      (string.contains
        (& output)
        ".L_tl_str_data_a:\n    .ascii \"pan\"\n.L_tl_str_data_b:\n    .ascii \"ic\"\n")
      "a live string keeps its whole suffix-shared run")
    (test.assert-true
      (string.contains
        (& output)
        ".L_tl_str_data_d:\n    .ascii \"ov\"\n.L_tl_str_data_e:\n    .ascii \"erlap\"\n")
      "a live string keeps every owner overlapped into its unit")
    (test.assert-true
      (not (string.contains (& output) ".L_tl_str_lc:"))
      "a header named only by a dead helper is omitted")
    (test.assert-true
      (not (string.contains (& output) "\"dead\""))
      "string data named only by a dead header is omitted")
    (test.assert-true
      (string.contains (& output) "    .balign 8\n")
      "the alignment between the literal bundles remains")))

(test
  compiler-backend-runtime-prune-intern-epilogues
  (let
    [output : String
      (prune.intern-epilogues
        "f:
    addq $8, %rsp
    popq %r13
    popq %r12
    ret
g:
    movl $1, %eax
    addq $8, %rsp
    popq %r13
    popq %r12
    ret
_tl_stdlib_crypto_aes_scrub_block:
    addq $8, %rsp
    popq %r13
    popq %r12
    ret
h:
    xorl %eax, %eax
.Lh_mid:
    addq $8, %rsp
    popq %r13
    popq %r12
    ret
k:
    popq %r12
    ret
m:
    popq %r12
    ret
")]
    (test.assert-true
      (string.contains
        (& output)
        "f:\n.L_tl_epi_1:\n    addq $8, %rsp\n    popq %r13\n    popq %r12\n    ret\n")
      "the first copy of a return tail becomes the shared anchor")
    (test.assert-true
      (string.contains
        (& output)
        "g:\n    movl $1, %eax\n    jmp .L_tl_epi_1\n")
      "a later identical tail jumps to the anchor")
    (test.assert-true
      (string.contains
        (& output)
        "_tl_stdlib_crypto_aes_scrub_block:\n    addq $8, %rsp\n    popq %r13\n    popq %r12\n    ret\n")
      "a crypto scrub function keeps its own epilogue")
    (test.assert-true
      (string.contains (& output) ".Lh_mid:\n    jmp .L_tl_epi_1\n")
      "a tail starts after the last label")
    (test.assert-true
      (string.contains (& output) "m:\n    popq %r12\n    ret\n")
      "a tail no longer than a jmp stays in place")))