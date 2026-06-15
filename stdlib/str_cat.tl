;# Variadic single-allocation String concatenation macro.
;#
;# `str-cat` lives in its own module (rather than core_macros.tl) so that
;# importing it does not also pull in the builtin-named guard/boolean macros,
;# which would shadow the parser's built-in `when`/`and`/`or`/`unless` forms in
;# files that use them.
;#
;# Usage: `(import stdlib.str_cat)` then `(str-cat a b c)`. The macro owns
;# its concat helper dependency, so callers do not need to import
;# `stdlib/string.tl` unless they use string helpers directly.
;#
;# ```typelisp
;# (import stdlib.str_cat)
;#
;# (define (greet [name : String]) : String
;#   (str_cat.str-cat "hello, " name "!"))
;# ```
(module stdlib.str_cat)

(import stdlib.string as string_mod)

;: Wrapper helpers used by exported `str-cat` macro expansions.
;:
;: Keeping these in this module lets callers import only `stdlib.str_cat`; the
;: macro expansion does not leak the private `stdlib.string` import alias.
(define (str-cat-string-append [a : String] [b : String]) : String
  (string_mod.string-append a b))

(define (str-cat-string-concat3 [a : String] [b : String] [c : String]) : String
  (string_mod.string-concat3 a b c))

(define (str-cat-string-concat4
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (string_mod.string-concat4 a b c d))

(define (str-cat-string-concat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string_mod.string-concat5 a b c d e))

(define (str-cat-string-concat-all [parts : (Array String)]) : String
  (string_mod.string-concat-all parts))

(define (str-cat-string-concat-all-pack-part
  [parts : (Array String)]
  [index : i64]
  [part : String]) : (Array String)
  (string_mod.string-concat-all-pack-part parts index part))

;: Internal recursive pack step used by `str-cat` expansion.
;:
;: `parts` is a dynamic array expression and `index` is the next runtime index
;: expression. Each step returns an expression that threads the filled array to
;: the next step.
(defmacro (str-cat-pack [parts : Expr] [index : Expr] [args : String ...]) : Expr
  (if (expr-list-empty? args)
    parts
    `(str-cat-pack
      (str-cat-string-concat-all-pack-part ,parts ,index ,(expr-list-head args))
      (+ ,index 1)
      ,@(expr-list-tail args))))

;: Concatenate any number of `String` operands into a fresh active-arena String.
;:
;: With no operands it expands to `""`; with one operand it expands to that
;: operand unchanged. Two to five operands use direct one-allocation helpers.
;: Longer arities are packed into one dynamic parts array and copied by
;: `string-concat-all`, so they no longer allocate chunk intermediates.
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
            `(str-cat-string-append ,a ,b)
            (let
              [c : Expr (expr-list-head rest2)]
              [rest3 : ExprList (expr-list-tail rest2)]
              (if (expr-list-empty? rest3)
                `(str-cat-string-concat3 ,a ,b ,c)
                (let
                  [d : Expr (expr-list-head rest3)]
                  [rest4 : ExprList (expr-list-tail rest3)]
                  (if (expr-list-empty? rest4)
                    `(str-cat-string-concat4 ,a ,b ,c ,d)
                    (let
                      [e : Expr (expr-list-head rest4)]
                      [rest5 : ExprList (expr-list-tail rest4)]
                      (if (expr-list-empty? rest5)
                        `(str-cat-string-concat5 ,a ,b ,c ,d ,e)
                        `(str-cat-string-concat-all
                          (str-cat-pack
                            (make-array
                              String
                              ,(expr-int (expr-list-length args)))
                            0
                            ,@args))))))))))))))

;: Exported only so imported `str-cat` expansions can finish their internal
;: recursive pack step.
(export
  (value str-cat-string-append)
  (value str-cat-string-concat3)
  (value str-cat-string-concat4)
  (value str-cat-string-concat5)
  (value str-cat-string-concat-all)
  (value str-cat-string-concat-all-pack-part)
  (macro str-cat-pack)
  (macro str-cat))