;; Optimization removes this helper's body uses, leaving private AVX2 entry
;; stores that still require disjoint, full-width parameter homes.
(define (touch-heavy [x : i64]) : unit
  (let
    [_sum : i64 (+ (+ (+ (+ (+ (+ (+ x 1) 2) 3) 4) 5) 6) 7)]
    unit))

(define (fill [n : i64]) : unit
  (foreach ([i : i64 0 n]) (touch-heavy i)))

(define (main) : i64
  (begin
    (fill 0)
    (fill 1)
    (fill 3)
    (fill 4)
    (fill 5)
    (fill 8)
    (fill 13)
    (fill 20)
    42))