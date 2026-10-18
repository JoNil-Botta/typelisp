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

(define (sum [left : i64] [right : i64]) : i64
  (+ left right))

(define (captured-call [value : i64]) : i64
  (sum
    value
    (begin
      (set! value 99)
      0)))

(define (nested-calls) : i64
  (sum (sum 10 10) (sum 11 11)))

(define (recursive-call [remaining : i64]) : i64
  (if (= remaining 0)
    0
    (+ 7 (recursive-call (- remaining 1)))))

(define (ordered-calls) : bool
  (let
    [value : i64 0]
    (=
      (sum
        (begin
          (set! value 20)
          value)
        (begin
          (set! value (+ value 2))
          value))
      42)))

(define (multiply [left : i64] [right : i64]) : i64
  (* left right))

(define (invoke-snapshot
  [func : (-> i64 i64 i64)]
  [other : (-> i64 i64 i64)]
  [value : i64]) : i64
  (func
    value
    (begin
      (set! func other)
      0)))

(define (invoke-choice
  [func : (-> i64 i64 i64)]
  [other : (-> i64 i64 i64)]
  [first : bool]) : i64
  ((if first
      func
      other)
    20
    22))

(define (invoke-loop [func : (-> i64 i64 i64)]) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (while (< index 6)
      (set! total (func total 7))
      (set! index (+ index 1)))
    total))

(define (forward-callable [func : (-> i64 i64 i64)]) : (-> i64 i64 i64)
  func)

(define (exited-binary [value : i64]) : i64
  (+ value (return 42)))

(define (exited-call [value : i64]) : i64
  (sum value (return 42)))

(define (main) : i64
  (if (and
    (= (captured-left 42) 42)
    (= (exited-binary 1) 42)
    (= (exited-call 1) 42)
    (= (captured-call 42) 42)
    (= (nested-calls) 42)
    (= (recursive-call 6) 42)
    (ordered-calls)
    (= (invoke-snapshot sum multiply 42) 42)
    (= (invoke-choice sum multiply true) 42)
    (= (invoke-choice sum multiply false) 440)
    (= (invoke-loop sum) 42)
    (= ((forward-callable sum) 20 22) 42)
    (ordered-comparison 42)
    (= (control 9 3) 36)
    (= (short-circuit true) 10)
    (= (short-circuit false) 20)
    (= (early -1) 42)
    (= (early 40) 42)
    (unsigned 17 18446744073709551615))
    42
    1))