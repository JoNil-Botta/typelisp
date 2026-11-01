;; Primitive helpers exercise certified scalar/control emission and its ABI.
;; The macro-based short-circuit helper remains an explicit Legacy control
;; until source expansion provenance is represented.
(define (captured-left [value : i64]) : i64
  (+
    value
    (begin
      (set! value 99)
      0)))

(define (ordered-comparison [value : i64]) : bool
  (=
    value
    (begin
      (set! value 99)
      42)))

(define (control [limit : i64] [skip : i64]) : i64
  (let
    [index : i64 0]
    [sum : i64 0]
    (begin
      (while (< index limit)
        (begin
          (set! index (+ index 1))
          ;; lint-allow: unit-if-guard
          (if (= index skip)
            (continue)
            unit)
          ;; lint-allow: unit-if-guard
          (if (> index 6)
            (break)
            unit)
          (let
            [term : i64 (* index 2)]
            (set! sum (+ sum term)))))
      sum)))

(define (short-circuit [left : bool]) : i64
  (let
    [value : i64 0]
    (begin
      (and
        left
        (begin
          (set! value 10)
          true))
      (or
        left
        (begin
          (set! value (+ value 20))
          false))
      value)))

(define (early [value : i64]) : i64
  (begin
    ;; lint-allow: unit-if-guard
    (if (< value 0)
      (return 42)
      unit)
    (+ value 2)))

(define (unsigned [_unused : i64] [value : u64]) : bool
  (> value 9223372036854775807))

(define (main) : i64
  (if (and
    (= (captured-left 42) 42)
    (ordered-comparison 42)
    (= (control 9 3) 36)
    (= (short-circuit true) 10)
    (= (short-circuit false) 20)
    (= (early -1) 42)
    (= (early 40) 42)
    (unsigned 17 18446744073709551615))
    42
    1))