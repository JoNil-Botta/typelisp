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