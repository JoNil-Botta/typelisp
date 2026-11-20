;# Variadic single-allocation String concatenation macro.
;#
;# `str-cat` lives in its own module (rather than core_macros.tl) so that
;# importing it does not also pull in the builtin-named guard/boolean macros,
;# which would shadow the parser's built-in `when`/`and`/`or`/`unless` forms in
;# files that use them.
;#
;# Dotted usage: import this module as `stdlib.str_cat`, then call
;# `(str_cat.str-cat a b c)`.
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

;: Concatenate any number of string expressions into a fresh active-arena String.
;:
;: The implementation lives in `stdlib.str_cat_runtime` so bootstrap compiler
;: sources and public callers execute one checked-in macro body. Capturing raw
;: syntax lets the implementation select borrowed helpers for owned or borrowed
;: string variables while retaining owned-helper handling for rvalues.
(defmacro (str-cat [args : Expr ...]) : String
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
    (set! str-cat-evaluation-count (+ str-cat-evaluation-count 1))
    text))

(cfg
  test
  (define (str-cat-order-operand) : String
    (set! str-cat-evaluation-count (+ str-cat-evaluation-count 1))
    (string.int->string str-cat-evaluation-count)))

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
  (define (str-cat-borrowed-input [text : (& text str)]) : String
    (str-cat text "!")))

(cfg
  test
  (define (str-cat-api-checks) : i64
    (let
      [a : String "foo"]
      [b : String "bar"]
      [empty : String ""]
      [score : i64 0]
      (set! score (+ score (str-cat-api-eq (str_cat_runtime.str-cat) "")))
      (set!
        score
        (+
          score
          (str-cat-api-eq (str_cat_runtime.str-cat (string.copy (& a))) "foo")))
      (set!
        score
        (+
          score
          (str-cat-api-eq
            (str_cat_runtime.str-cat (string.copy (& a)) (string.copy (& b)))
            "foobar")))
      (set!
        score
        (+
          score
          (str-cat-api-eq
            (str_cat_runtime.str-cat
              (string.copy (& b))
              "!"
              (string.copy (& b)))
            "bar!bar")))
      (set!
        score
        (+
          score
          (str-cat-api-eq
            (str_cat_runtime.str-cat
              (string.copy (& empty))
              (string.copy (& a))
              empty)
            "foo")))
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
              (str_cat_runtime.str-cat
                (string.copy (& a))
                middle
                (string.copy (& a)))
              "foo-bar-foo"))))
      (let
        [__tl_str_cat_parts : String "baz"]
        (set!
          score
          (+
            score
            (str-cat-api-eq
              (str_cat_runtime.str-cat
                (string.copy (& __tl_str_cat_parts))
                "!"
                (string.copy (& __tl_str_cat_parts))
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
      (let
        [borrowed : String "borrowed"]
        (if (string.eq (str-cat-borrowed-input (& borrowed)) "borrowed!")
          (set! score (+ score 1))
          unit))
      ;; Six or more operands build one borrowed fixed array of the parts; each
      ;; operand is evaluated once, left to right, and moves as it did before.
      (let
        [long-a : String "foo"]
        [long-b : String "bar"]
        [long-empty : String ""]
        (set!
          score
          (+
            score
            (str-cat-api-eq
              (str_cat_runtime.str-cat
                (string.copy (& long-a))
                ":"
                (string.copy (& long-b))
                ":"
                (string.int->string 6)
                ":!")
              "foo:bar:6:!")))
        (set!
          score
          (+
            score
            (str-cat-api-eq
              (str_cat_runtime.str-cat
                (string.copy (& long-a))
                "-"
                (string.copy (& long-empty))
                "-"
                (string.copy (& long-b))
                "-"
                (string.int->string 7))
              "foo--bar-7")))
        (set!
          score
          (+
            score
            (str-cat-api-eq
              (str_cat_runtime.str-cat
                "0"
                (string.copy (& long-a))
                "2"
                "3"
                "4"
                "5"
                "6"
                "7"
                "8"
                "9"
                "10"
                "11"
                "12"
                "13"
                (string.copy (& long-empty))
                "15"
                (string.int->string 16)
                "17"
                "18"
                "19")
              "0foo23456789101112131516171819"))))
      (set! str-cat-evaluation-count 0)
      (let
        [ordered : String
          (str_cat_runtime.str-cat-scoped
            (str-cat-order-operand)
            (str-cat-order-operand)
            (str-cat-order-operand)
            (str-cat-order-operand)
            (str-cat-order-operand)
            (str-cat-order-operand))]
        (if (and (string.eq ordered "123456") (= str-cat-evaluation-count 6))
          (set! score (+ score 1))
          unit))
      (let
        [moved : String "moved"]
        [long : String (str_cat_runtime.str-cat moved "-" "a" "b" "c" "d" "e")]
        (set! moved (string.copy (& long)))
        (if (string.eq moved "moved-abcde")
          (set! score (+ score 1))
          unit))
      score)))

(cfg
  test
  (define (str-cat-test-main) : i64
    (if (= (str-cat-api-checks) 17)
      42
      1)))

(cfg
  test
  (test
    str-cat-api
    (if (= (str-cat-test-main) 42)
      unit
      (begin
        (/ 1 0)
        unit))))