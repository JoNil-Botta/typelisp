;# Variadic single-allocation String concatenation macro.
;#
;# `str-cat` lives in its own module (rather than core_macros.tl) so that
;# importing it does not also pull in the builtin-named guard/boolean macros,
;# which would shadow the parser's built-in `when`/`and`/`or`/`unless` forms in
;# files that use them.
;#
;# Dotted usage: import this module as `stdlib.str_cat`, then call
;# `(str_cat.str-cat a b c)`. Legacy path imports can call `(str-cat a b c)`.
;# Expansions reference fully qualified `stdlib.string` helpers, so callers do
;# not need string helper imports.
;#
;# ```lisp
;# (import stdlib.str_cat)
;#
;# (define (greet [name : String]) : String
;#   (str_cat.str-cat "hello, " name "!"))
;# ```
(module stdlib.str_cat)

(import stdlib.comptime)
(import stdlib.string)
(cfg test (import stdlib.test))
(cfg test (import stdlib.hashmap))

;: Internal recursive pack step used by `str-cat` expansion.
;:
;: `parts` is a dynamic array expression and `index` is the next runtime index
;: expression. Each step returns an expression that threads the filled array to
;: the next step.
(defmacro (str-cat-pack
  [parts : comptime.Expr]
  [index : comptime.Expr]
  [args : String ...]) : comptime.Expr
  (if (comptime.expr-list-empty? args)
    parts
    `(str-cat-pack
      (stdlib.string.string-concat-all-pack-part
        ,parts
        ,index
        ,(comptime.expr-list-head args))
      (+ ,index 1)
      ,@(comptime.expr-list-tail args))))

;: Concatenate any number of `String` operands into a fresh active-arena String.
;:
;: With no operands it expands to `""`; with one operand it expands to that
;: operand unchanged. Two to five operands use direct one-allocation helpers.
;: Longer arities are packed into one dynamic parts array and copied by
;: `string-concat-all`, so they no longer allocate chunk intermediates.
(defmacro (str-cat [args : String ...]) : String
  (if (comptime.expr-list-empty? args)
    `""
    (let
      [a : comptime.Expr (comptime.expr-list-head args)]
      [rest1 : comptime.ExprList (comptime.expr-list-tail args)]
      (if (comptime.expr-list-empty? rest1)
        a
        (let
          [b : comptime.Expr (comptime.expr-list-head rest1)]
          [rest2 : comptime.ExprList (comptime.expr-list-tail rest1)]
          (if (comptime.expr-list-empty? rest2)
            `(stdlib.string.string-concat3 ,a ,b "")
            (let
              [c : comptime.Expr (comptime.expr-list-head rest2)]
              [rest3 : comptime.ExprList (comptime.expr-list-tail rest2)]
              (if (comptime.expr-list-empty? rest3)
                `(stdlib.string.string-concat3 ,a ,b ,c)
                (let
                  [d : comptime.Expr (comptime.expr-list-head rest3)]
                  [rest4 : comptime.ExprList (comptime.expr-list-tail rest3)]
                  (if (comptime.expr-list-empty? rest4)
                    `(stdlib.string.string-concat4 ,a ,b ,c ,d)
                    (let
                      [e : comptime.Expr (comptime.expr-list-head rest4)]
                      [rest5 : comptime.ExprList
                        (comptime.expr-list-tail rest4)]
                      (if (comptime.expr-list-empty? rest5)
                        `(stdlib.string.string-concat5 ,a ,b ,c ,d ,e)
                        `(stdlib.string.string-concat-all
                          (str-cat-pack
                            (stdlib.array.make-array
                              String
                              ,(comptime.expr-int
                                (comptime.expr-list-length args)))
                            0
                            ,@args))))))))))))))

;: Exported only so imported `str-cat` expansions can finish their internal
;: recursive pack step.
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