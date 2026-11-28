(import compiler_backend_peephole as outline)
(import stdlib.string)
(import stdlib.test)
(import compiler_str_cat as str_cat)

(define (first-function [unwind : String]) : String
  (str_cat.str-cat
    "first:
    testq %rcx, %rcx
    je .L_first
    ret
.L_first:
    movl $42, %eax
    ret
"
    unwind))

(define (second-function [before : String] [after : String]) : String
  (str_cat.str-cat
    "second:
    testq %rcx, %rcx
    je .L_second
"
    before
    ".L_second:
    movl $42, %eax
    ret
"
    after))

(test
  complete-tail-redirect-requires-independent-entry
  (let
    [first : String (first-function "    .size first, . - first\n")]
    [plain : String (second-function "    ret\n" "")]
    [fallthrough : String (second-function "    nop\n" "")]
    [taken : String
      (second-function
        "    ret\n"
        "    .section .rodata\n    .quad .L_second\n")]
    [immediate : String
      (second-function "    movl $.L_second, %ecx\n    ret\n" "")]
    [merged : String
      (outline.compiler-backend-machine-outline
        (str_cat.str-cat first plain)
        false
        false)]
    (test.assert-true
      (string.contains (& merged) "    je .L_tl_tail_1\n    ret\n.L_second:\n")
      "redirect the branch without adding a jump")
    (test.assert-true
      (not (string.contains (& merged) ".L_second:\n    movl"))
      "remove the duplicate body")
    (let
      [fallthrough-output : String
        (outline.compiler-backend-machine-outline
          (str_cat.str-cat first fallthrough)
          false
          false)]
      [taken-output : String
        (outline.compiler-backend-machine-outline
          (str_cat.str-cat first taken)
          false
          false)]
      [immediate-output : String
        (outline.compiler-backend-machine-outline
          (str_cat.str-cat first immediate)
          false
          false)]
      (test.assert-true
        (string.contains (& fallthrough-output) ".L_second:\n    movl")
        "keep fallthrough entries")
      (test.assert-true
        (string.contains (& taken-output) ".L_second:\n    movl")
        "keep address-taken entries")
      (test.assert-true
        (string.contains (& immediate-output) ".L_second:\n    movl")
        "keep entries used as immediate addresses"))))

(define (win64-row [symbol : (& str)] [record : (& str)]) : String
  (str_cat.str-cat
    ".L_tl_seh_end_"
    symbol
    ":\n"
    "    .pushsection .pdata,\"dr\"\n    .rva "
    symbol
    ", .L_tl_seh_end_"
    symbol
    ", "
    record
    "\n    .popsection\n"))

(test
  complete-tail-redirect-requires-matching-unwind
  (let
    [first : String (first-function (win64-row "first" ".L_tl_xdata_0"))]
    [same : String
      (second-function "    ret\n" (win64-row "second" ".L_tl_xdata_0"))]
    [different : String
      (second-function "    ret\n" (win64-row "second" ".L_tl_xdata_1"))]
    [jump : String
      (string.replace
        (second-function "    ret\n" (win64-row "second" ".L_tl_xdata_0"))
        "    je .L_second"
        "    jmp .L_second")]
    [merged : String
      (outline.compiler-backend-machine-outline
        (str_cat.str-cat first same)
        true
        false)]
    [kept : String
      (outline.compiler-backend-machine-outline
        (str_cat.str-cat first different)
        true
        false)]
    [kept-jump : String
      (outline.compiler-backend-machine-outline
        (str_cat.str-cat first jump)
        true
        false)]
    (test.assert-true
      (not (string.contains (& merged) ".L_second:\n    movl"))
      "share tails with the same unwind record")
    (test.assert-true
      (string.contains (& kept) ".L_second:\n    movl")
      "keep tails with different unwind records")
    (test.assert-true
      (string.contains (& kept-jump) "    jmp .L_second\n")
      "keep unconditional jumps within their original unwind range")))

(define replicate-prologue : String
  "    movq %rdi, 8(%rsp)
    movq %rsi, 120(%rsp)
    leaq 32(%rsp), %rdx
    movabsq $1311768467463790320, %rcx
")

(test
  outline-helper-uses-stdlib-prefix-only-for-stdlib-callers
  (let
    [standard : String
      (str_cat.str-cat
        "_tl_stdlib_foo:\n"
        replicate-prologue
        "    call foo\n    ret\n")]
    [stdlib-only : String
      (outline.compiler-backend-machine-outline
        (str_cat.str-cat
          standard
          "_tl_stdlib_bar:\n"
          replicate-prologue
          "    call bar\n    ret\n")
        false
        true)]
    [mixed : String
      (outline.compiler-backend-machine-outline
        (str_cat.str-cat
          standard
          "_tl_user_bar:\n"
          replicate-prologue
          "    call bar\n    ret\n")
        false
        true)]
    (test.assert-true
      (string.contains (& stdlib-only) "call _tl_stdlib_outline_1")
      "attribute stdlib-only helpers to the stdlib")
    (test.assert-true
      (string.contains (& mixed) "call _tl_outline_1")
      "attribute a helper with any user caller to user text")))