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
(import stdlib.comptime)
(import stdlib.array)
(import stdlib.string)
(cfg test (import stdlib.test))
(cfg test (import stdlib.hashmap))
(cfg test (import (hashmap i64 i64) as map_i64_i64))
(cfg test (import stdlib.str_cat_runtime as str_cat_runtime))

;: Internal pack step used by `str-cat` expansion for six or more operands.
;:
;: `carrier` wraps all operands in a marker call so each step reads the next
;: operand by index (`expr-list-nth`) instead of copying a shrinking tail;
;: `parts` threads the filled dynamic array and `idx` is the next literal slot.
;: When every slot is filled it returns `parts`.
(defmacro (str-cat-pack
  [carrier : comptime.Expr]
  [parts : (Array String)]
  [idx : comptime.Expr]) : (Array String)
  (match idx
    [(comptime.ExprInt i)
      (match carrier
        [(comptime.ExprCall _ elems)
          (if (>= i (comptime.expr-list-length elems))
            parts
            `(str-cat-pack
              ,carrier
              (stdlib.string.concat-all-pack-part
                ,parts
                ,(comptime.expr-int i)
                ,(comptime.expr-list-nth elems i))
              ,(comptime.expr-int (+ i 1))))]
        [_ parts])]
    [_ parts]))

;: Concatenate any number of `String` operands into a fresh active-arena String.
;:
;: Dispatches on the operand count and indexes operands directly with
;: `expr-list-nth`. With no operands it expands to `""`; with one operand it
;: expands to that operand unchanged. Two to five operands use direct
;: one-allocation helpers. Longer arities are packed into one dynamic parts
;: array and copied by `stdlib.string.concat-all`, so they no longer allocate chunk
;: intermediates.
(defmacro (str-cat [args : String ...]) : String
  (match (comptime.expr-list-length args)
    [0 `""]
    [1 (comptime.expr-list-nth args 0)]
    [2
      `(stdlib.string.concat3
        ,(comptime.expr-list-nth args 0)
        ,(comptime.expr-list-nth args 1)
        "")]
    [3
      `(stdlib.string.concat3
        ,(comptime.expr-list-nth args 0)
        ,(comptime.expr-list-nth args 1)
        ,(comptime.expr-list-nth args 2))]
    [4
      `(stdlib.string.concat4
        ,(comptime.expr-list-nth args 0)
        ,(comptime.expr-list-nth args 1)
        ,(comptime.expr-list-nth args 2)
        ,(comptime.expr-list-nth args 3))]
    [5
      `(stdlib.string.concat5
        ,(comptime.expr-list-nth args 0)
        ,(comptime.expr-list-nth args 1)
        ,(comptime.expr-list-nth args 2)
        ,(comptime.expr-list-nth args 3)
        ,(comptime.expr-list-nth args 4))]
    [n
      `(stdlib.string.concat-all
        (str-cat-pack
          (__str-cat-args ,@args)
          (stdlib.array.make-array
            ,(comptime.expr-var "String")
            ,(comptime.expr-int n))
          0))]))

;; Inline test coverage.
;; Published stage0 compilers have a hardcoded `stdlib.str_cat` test fast path
;; that emits legacy helper names, so the cfg-test fixture exercises the same
;; checked-in macro body through the bootstrap-safe runtime module name.
(cfg
  test
  (define (str-cat-api-eq [got : String] [want : String]) : i64
    (if (string.eq got want)
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
        (set! score (+ score (str-cat-api-eq (str_cat_runtime.str-cat) "")))
        (set!
          score
          (+ score (str-cat-api-eq (str_cat_runtime.str-cat a) "foo")))
        (set!
          score
          (+ score (str-cat-api-eq (str_cat_runtime.str-cat a b) "foobar")))
        (set!
          score
          (+ score (str-cat-api-eq (str_cat_runtime.str-cat b "!" b) "bar!bar")))
        (set!
          score
          (+
            score
            (str-cat-api-eq (str_cat_runtime.str-cat empty a empty) "foo")))
        (set!
          score
          (+
            score
            (str-cat-api-eq
              (str_cat_runtime.str-cat "1" "2" "3" "4" "5" "6" "7")
              "1234567")))
        ;; A str-cat-produced value remains a valid operand to another flat
        ;; str-cat call.
        (let
          [middle : String (str_cat_runtime.str-cat "-" b "-")]
          (set!
            score
            (+
              score
              (str-cat-api-eq
                (str_cat_runtime.str-cat a middle a)
                "foo-bar-foo"))))
        (let
          [__tl_str_cat_parts : String "baz"]
          (set!
            score
            (+
              score
              (str-cat-api-eq
                (str_cat_runtime.str-cat
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
    (let
      [m : map_i64_i64.Map (map_i64_i64.with-capacity 8)]
      (begin
        (map_i64_i64.insert! m 1 7)
        (>= (map_i64_i64.capacity (& m)) 8)))))

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