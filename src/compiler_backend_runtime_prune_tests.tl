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
        "    .tl_abort_row f, .L_pc, .L_path, \"p.tl\", 4097, tl_oob_abort_at
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
    .set .L_tl_str_data_b, .L_tl_str_data_a + 3
    .ascii \"panic\"
"
        (prune.literal-unit-end)
        ".L_tl_str_data_c:
    .ascii \"dead\"
"
        (prune.literal-unit-end)
        ".L_tl_str_data_d:
    .set .L_tl_str_data_e, .L_tl_str_data_d + 2
    .ascii \"overlap\"
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
        ".L_tl_str_data_a:\n    .set .L_tl_str_data_b, .L_tl_str_data_a + 3\n    .ascii \"panic\"\n")
      "a live string keeps its whole suffix-shared run")
    (test.assert-true
      (string.contains
        (& output)
        ".L_tl_str_data_d:\n    .set .L_tl_str_data_e, .L_tl_str_data_d + 2\n    .ascii \"overlap\"\n")
      "a string named through an interior label keeps its whole unit")
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

(test
  compiler-backend-runtime-prune-mid-stream-ranges
  (let
    [dead-prefix : String (prune.optional-fragment "dead_pre:\n    ret\n")]
    [cold-a : String "cold_a:\n    movl $1, %eax\n    ret\n"]
    [dead-mid : String
      (prune.optional-fragment "dead_mid:\n    movl $99, %eax\n    ret\n")]
    [cold-b : String "cold_b:\n    movl $2, %eax\n    ret\n"]
    [warm-c : String "warm_c:\n    movl $3, %eax\n    ret\n"]
    [asm : String (str_cat.str-cat dead-prefix cold-a dead-mid cold-b warm-c)]
    [p-len : i64 (string.string-length (& dead-prefix))]
    [a-len : i64 (string.string-length (& cold-a))]
    [m-len : i64 (string.string-length (& dead-mid))]
    [b-len : i64 (string.string-length (& cold-b))]
    [a-start : i64 p-len]
    [a-end : i64 (+ a-start a-len)]
    [m-start : i64 a-end]
    [m-end : i64 (+ m-start m-len)]
    [b-start : i64 m-end]
    [b-end : i64 (+ b-start b-len)]
    [starts : (__tl_dyn-array i64) (__tl_make-array a-start m-start b-start)]
    [ends : (__tl_dyn-array i64) (__tl_make-array a-end m-end b-end)]
    [pruned : String (prune.prune-with-ranges! asm 3 (&mut starts) (&mut ends))]
    (test.assert-true
      (not (string.contains (& pruned) "dead_pre:"))
      "unreachable prefix fragment is pruned")
    (test.assert-true
      (not (string.contains (& pruned) "dead_mid:"))
      "unreachable mid-stream fragment is pruned")
    (test.assert-i64-eq
      (array-ref starts 0)
      0
      "cold_a start shifts by pruned prefix")
    (test.assert-i64-eq
      (array-ref ends 0)
      a-len
      "cold_a end shifts by pruned prefix")
    (test.assert-i64-eq
      (array-ref starts 1)
      0
      "cold range contained inside pruned mid-stream fragment collapses to 0")
    (test.assert-i64-eq
      (array-ref ends 1)
      0
      "cold range contained inside pruned mid-stream fragment collapses to empty")
    (test.assert-i64-eq
      (array-ref starts 2)
      a-len
      "cold_b start shifts by both prefix and mid-stream pruned fragments")
    (test.assert-i64-eq
      (array-ref ends 2)
      (+ a-len b-len)
      "cold_b end aligns exactly before warm_c")
    (test.assert-true
      (string.contains (& pruned) (& warm-c))
      "warm_c remains intact after mid-stream pruning")))