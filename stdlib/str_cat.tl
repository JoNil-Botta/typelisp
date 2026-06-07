;# Variadic single-allocation String concatenation macro.
;#
;# `str-cat` lives in its own module (rather than core_macros.tl) so that
;# importing it does not also pull in the builtin-named guard/boolean macros,
;# which would shadow the parser's built-in `when`/`and`/`or`/`unless` forms in
;# files that use them.
;#
;# Usage: `(import "stdlib/str_cat.tl")` then `(str-cat a b c)`. The expansion
;# references `str-copy-bytes-into` and the string primitives from
;# `stdlib/string.tl`, so import that module at the call site too. Lifting that
;# requirement (naming a fully-qualified path from this package's dependencies)
;# is tracked by #2223.
;#
;# ```typelisp
;# (import "stdlib/str_cat.tl")
;# (import "stdlib/string.tl")
;#
;# (define (greet [name : String]) : String
;#   (str-cat "hello, " name "!"))
;# ```
(module stdlib.str-cat)

;: Concatenate any number of `String` operands into one fresh active-arena
;: String.
;:
;: Regardless of arity the expansion allocates the result buffer exactly once
;: (sized from the total operand length) and copies each operand in with one
;: linear `str-copy-bytes-into` pass, avoiding the quadratic copy amplification
;: of a right-nested `string-append` chain. With no operands it expands to `""`.
(defmacro
  (str-cat [args : String ...])
  :
  String
  (if (expr-list-empty? args)
    `""
    `(let
      [str-cat-parts (array ,@args)]
      [str-cat-n : i64 ,(expr-int (expr-list-length args))]
      [str-cat-total : i64 0]
      [str-cat-i : i64 0]
      (begin
        (while (< str-cat-i str-cat-n)
          (begin
            (set!
              str-cat-total
              (+
                str-cat-total
                (string-length (& (array-ref str-cat-parts str-cat-i)))))
            (set! str-cat-i (+ str-cat-i 1))))
        (let
          [str-cat-out : (Array u8) (make-array u8 str-cat-total)]
          [str-cat-dst : (MutPtr u8)
            (unsafe
              (array-data str-cat-out))]
          [str-cat-off : i64 0]
          (begin
            (set! str-cat-i 0)
            (while (< str-cat-i str-cat-n)
              (begin
                (str-copy-bytes-into
                  (unsafe
                    (string-data (& (array-ref str-cat-parts str-cat-i))))
                  str-cat-dst
                  str-cat-off
                  (string-length (& (array-ref str-cat-parts str-cat-i))))
                (set!
                  str-cat-off
                  (+
                    str-cat-off
                    (string-length (& (array-ref str-cat-parts str-cat-i)))))
                (set! str-cat-i (+ str-cat-i 1))))
            (unsafe
              (string-from-bytes
                (ptr-cast str-cat-dst : (Ptr u8))
                str-cat-total))))))))

(export (macro str-cat))