;# Variadic single-allocation String concatenation macro.
;#
;# `str-cat` lives in its own module (rather than core_macros.tl) so that
;# importing it does not also pull in the builtin-named guard/boolean macros,
;# which would shadow the parser's built-in `when`/`and`/`or`/`unless` forms in
;# files that use them.
;#
;# Usage in current flat-import callers: import this module, then call
;# `(str-cat a b c)`. A dotted external `str_cat.str-cat` call still needs
;# imported-macro dependency alias support before its helper calls can stay
;# independent of the caller's imports.
;#
;# ```lisp
;# (import "../stdlib/str_cat.tl")
;#
;# (define (greet [name : String]) : String
;#   (str-cat "hello, " name "!"))
;# ```
(module stdlib.str_cat)

(import stdlib.string)
(cfg test (import stdlib.test))
(cfg test (import stdlib.hashmap))

;: Local aliases for the flat helper names emitted by `str-cat` today. External
;: callers still provide these through legacy flat imports; these definitions
;: keep this module's own inline tests independent of a legacy stdlib import.
(define (string-append [left : String] [right : String]) : String
  (string.string-append left right))

;: Local alias for three-part string concatenation.
(define (string-concat3 [a : String] [b : String] [c : String]) : String
  (string.string-concat3 a b c))

;: Local alias for four-part string concatenation.
(define (string-concat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string.string-concat4 a b c d))

;: Local alias for five-part string concatenation.
(define (string-concat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string.string-concat5 a b c d e))

;: Local alias for concatenating a packed dynamic string array.
(define (string-concat-all [parts : (Array String)]) : String
  (string.string-concat-all parts))

;: Local alias for appending one part into a packed concatenation array.
(define (string-concat-all-pack-part
  [parts : (Array String)]
  [index : i64]
  [value : String]) : (Array String)
  (string.string-concat-all-pack-part parts index value))

;: Internal recursive pack step used by `str-cat` expansion.
;:
;: `parts` is a dynamic array expression and `index` is the next runtime index
;: expression. Each step returns an expression that threads the filled array to
;: the next step.
(defmacro (str-cat-pack [parts : Expr] [index : Expr] [args : String ...]) : Expr
  (if (expr-list-empty? args)
    parts
    `(str-cat-pack
      (string-concat-all-pack-part ,parts ,index ,(expr-list-head args))
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
                        `(string-concat-all
                          (str-cat-pack
                            (make-array
                              String
                              ,(expr-int (expr-list-length args)))
                            0
                            ,@args))))))))))))))

;: Exported only so imported `str-cat` expansions can finish their internal
;: recursive pack step.
(export (macro str-cat-pack))

(export (macro str-cat))

;; Inline coverage migrated from stdlib/tests/str_cat_api.tl (#3082).
(cfg
  test
  (define (str-cat-api-eq [got : String] [want : String]) : i64
    (if (string.string-eq got want)
      1
      0)))

(cfg
  test
  (define (str-cat-api-checks) : i64
    (let
      [a : String "foo"]
      [b : String "bar"]
      [empty : String ""]
      [score : i64 0]
      (begin
        (set! score (+ score (str-cat-api-eq (str-cat) "")))
        (set! score (+ score (str-cat-api-eq (str-cat a) "foo")))
        (set! score (+ score (str-cat-api-eq (str-cat a b) "foobar")))
        (set! score (+ score (str-cat-api-eq (str-cat b "!" b) "bar!bar")))
        (set! score (+ score (str-cat-api-eq (str-cat empty a empty) "foo")))
        (set!
          score
          (+
            score
            (str-cat-api-eq (str-cat "1" "2" "3" "4" "5" "6" "7") "1234567")))
        ;; A str-cat-produced value remains a valid operand to another flat
        ;; str-cat call.
        (let
          [middle : String (str-cat "-" b "-")]
          (set!
            score
            (+ score (str-cat-api-eq (str-cat a middle a) "foo-bar-foo"))))
        (let
          [__tl_str_cat_parts : String "baz"]
          (set!
            score
            (+
              score
              (str-cat-api-eq
                (str-cat
                  __tl_str_cat_parts
                  "!"
                  __tl_str_cat_parts
                  "!"
                  "q"
                  "!"
                  "r")
                "baz!baz!q!r"))))
        score))))

(cfg
  test
  (define (str-cat-api-generated-ok) : bool
    (>=
      (hashmap.i64-i64-map-capacity
        (hashmap.i64-i64-map-put (hashmap.i64-i64-map-with-capacity 8) 1 7))
      8)))

(cfg
  test
  (define (str-cat-test-main) : i64
    (if (= (str-cat-api-checks) 8)
      (if (str-cat-api-generated-ok)
        42
        1)
      1)))

(cfg
  test
  (test
    str-cat-api
    (test.assert-i64-eq (str-cat-test-main) 42 "str-cat-api fixture result")))