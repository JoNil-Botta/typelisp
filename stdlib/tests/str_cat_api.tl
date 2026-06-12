;# Runnable coverage for the `str-cat` variadic concatenation macro
;# (stdlib/str_cat.tl). Exercises the empty, single, two, many, and
;# variable-operand expansions and confirms each produces the expected bytes.
;# Also imports stdlib/hashmap.tl and uses a generated `I64I64Map` function in
;# the same program as a macro, covering the "generate declaration families
;# before macro expansion" pipeline ordering. Exits 42 on success.
(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(import "stdlib/str_cat.tl")

(import "stdlib/hashmap.tl")

;: 1 when the strings are byte-equal, else 0.
(define (str-cat-api-eq [got : String] [want : String]) : i64
  (if (string-eq got want)
    1
    0))

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
      ;; A str-cat operand that is itself a str-cat call: the inner macro must be
      ;; expanded before the outer operand is typechecked.
      (set!
        score
        (+
          score
          (str-cat-api-eq (str-cat a (str-cat "-" b "-") a) "foo-bar-foo")))
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
      score)))

;: Uses generated I64I64Map functions in a program that also defines macros.
(define (str-cat-api-generated-ok) : bool
  (>=
    (i64-i64-map-capacity (i64-i64-map-put (i64-i64-map-with-capacity 8) 1 7))
    8))

(define (main) : i64
  (if (core/and (= (str-cat-api-checks) 8) (str-cat-api-generated-ok))
    42
    1))