;# Variadic single-allocation String concatenation macro.
;#
;# `str-cat` lives in its own module (rather than core_macros.tl) so that
;# importing it does not also pull in the builtin-named guard/boolean macros,
;# which would shadow the parser's built-in `when`/`and`/`or`/`unless` forms in
;# files that use them.
;#
;# Usage: `(import "stdlib/str_cat.tl")` then `(str-cat a b c)`. The macro owns
;# its fixed-arity concat helper dependency, so callers do not need to import
;# `stdlib/string.tl` unless they use string helpers directly.
;#
;# ```typelisp
;# (import "stdlib/str_cat.tl")
;#
;# (define (greet [name : String]) : String
;#   (str-cat "hello, " name "!"))
;# ```
(import "string.tl")

(module stdlib.str-cat)

;: Concatenate any number of `String` operands into a fresh active-arena String.
;:
;: The macro expands common fixed arities to helper calls, so each helper is
;: compiled once while preserving a single allocation for two to five operands.
;: Longer arities are chunked through `string-concat5`. With no operands it
;: expands to `""`.
(defmacro (str-cat [args : String ...]) : String
  (if (expr-list-empty? args)
    `""
    (let
      [a : Expr (expr-list-head args)]
      [rest1 : ExprList (expr-list-tail args)]
      (if (expr-list-empty? rest1)
        a
        (let
          [b : Expr (expr-list-head rest1)]
          [rest2 : ExprList (expr-list-tail rest1)]
          (if (expr-list-empty? rest2)
            `(string-append ,a ,b)
            (let
              [c : Expr (expr-list-head rest2)]
              [rest3 : ExprList (expr-list-tail rest2)]
              (if (expr-list-empty? rest3)
                `(string-concat3 ,a ,b ,c)
                (let
                  [d : Expr (expr-list-head rest3)]
                  [rest4 : ExprList (expr-list-tail rest3)]
                  (if (expr-list-empty? rest4)
                    `(string-concat4 ,a ,b ,c ,d)
                    (let
                      [e : Expr (expr-list-head rest4)]
                      [rest5 : ExprList (expr-list-tail rest4)]
                      (if (expr-list-empty? rest5)
                        `(string-concat5 ,a ,b ,c ,d ,e)
                        `(string-concat5 ,a ,b ,c ,d (str-cat ,e ,@rest5))))))))))))))

(export (macro str-cat))