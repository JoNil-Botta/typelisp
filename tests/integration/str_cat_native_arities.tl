;; str_cat_native_arities.tl - exercise the native tlci str-cat body across
;; its operand-count dispatch arms (0/1/2/5/6/8 operands) with literal and
;; computed string operands. The compile-profile gate compiles this fixture
;; through the embedded (native) and source (interpreted) routes and requires
;; byte-identical assembly; the integration runner checks the exit code.
;; Exit code: 42
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat)

(define (main) : i64
  (let
    [prefix : String
      (if (= (io.arg-count) 1)
        "p"
        "q")]
    [r0 : String (str_cat.str-cat)]
    [r1 : String (str_cat.str-cat "x")]
    [r2 : String (str_cat.str-cat prefix "b")]
    [r5 : String (str_cat.str-cat "a" prefix "c" "d" "e")]
    [r6 : String (str_cat.str-cat "a" "b" prefix "d" "e" "f")]
    [r8 : String (str_cat.str-cat "1" "2" "3" prefix "5" "6" "7" "8")]
    [total : i64
      (+
        (string.string-length r0)
        (+
          (string.string-length r1)
          (+
            (string.string-length r2)
            (+
              (string.string-length r5)
              (+ (string.string-length r6) (string.string-length r8))))))]
    (if (and
      (= (string.string-length r0) 0)
      (string.eq r1 "x")
      (string.eq r2 "pb")
      (string.eq r5 "apcde")
      (string.eq r6 "abpdef")
      (string.eq r8 "123p5678")
      (= total 22))
      42
      1)))