;# Variadic single-allocation String concatenation macro.
;#
;# `str-cat` lives in its own module (rather than core_macros.tl) so that
;# importing it does not also pull in the builtin-named guard/boolean macros,
;# which would shadow the parser's built-in `when`/`and`/`or`/`unless` forms in
;# files that use them.
;#
;# Dotted usage: import this module as `stdlib.str_cat`, then call
;# `(str_cat.str-cat a b c)`. Legacy path imports can call `(str-cat a b c)`.
;# Expansions delegate to the bootstrap-safe implementation module, whose
;# fully-qualified helpers require no imports at the call site.
;#
;# ```lisp
;# (import stdlib.str_cat)
;#
;# (define (greet [name : String]) : String
;#   (str_cat.str-cat "hello, " name "!"))
;# ```
(import stdlib.str_cat_runtime)
(cfg test (import stdlib.string))
(cfg test (import stdlib.test))

;: Concatenate any number of `String` operands into a fresh active-arena String.
;:
;: The implementation lives in `stdlib.str_cat_runtime` so bootstrap compiler
;: sources and public callers execute one checked-in macro body.
(defmacro (str-cat [args : String ...]) : String
  `(stdlib.str_cat_runtime.str-cat-scoped ,@args))

(cfg
  test
  (define (str-cat-api-eq [got : String] [want : String]) : i64
    (if (string.eq got want)
      1
      0)))

(cfg
  test
  (define str-cat-evaluation-count : i64
    0))

(cfg
  test
  (define (str-cat-counted-operand [text : String]) : String
    (begin
      (set! str-cat-evaluation-count (+ str-cat-evaluation-count 1))
      text)))

(cfg
  test
  (define (str-cat-scoped-region-ok?) : bool
    (with-arena
      frame
      (let
        [one : String (string.int->string 1)]
        [two : String (string.int->string 2)]
        [three : String (string.int->string 3)]
        [four : String (string.int->string 4)]
        [five : String (string.int->string 5)]
        [got2 : String (str_cat_runtime.str-cat-scoped "visible:" one)]
        [got3 : String (str_cat_runtime.str-cat-scoped one ":" two)]
        [got4 : String (str_cat_runtime.str-cat-scoped one ":" two three)]
        [got5 : String (str_cat_runtime.str-cat-scoped one ":" two three four)]
        (and
          (string.eq got2 "visible:1")
          (string.eq got3 "1:2")
          (string.eq got4 "1:23")
          (string.eq got5 "1:234"))))))

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
        (set! str-cat-evaluation-count 0)
        (let
          [once : String
            (str_cat_runtime.str-cat-scoped
              (str-cat-counted-operand "a")
              (str-cat-counted-operand "b")
              (str-cat-counted-operand "c")
              (str-cat-counted-operand "d")
              (str-cat-counted-operand "e"))]
          (if (and (string.eq once "abcde") (= str-cat-evaluation-count 5))
            (set! score (+ score 1))
            unit))
        (if (string.eq
          (str_cat_runtime.str-cat-scoped
            (if true
              "left"
              "wrong")
            (if false
              "wrong"
              "right"))
          "leftright")
          (set! score (+ score 1))
          unit)
        (if (str-cat-scoped-region-ok?)
          (set! score (+ score 1))
          unit)
        score))))

(cfg
  test
  (define (str-cat-test-main) : i64
    (if (= (str-cat-api-checks) 11)
      42
      1)))

(cfg
  test
  (test
    str-cat-api
    (test.assert-i64-eq (str-cat-test-main) 42 "str-cat-api fixture result")))