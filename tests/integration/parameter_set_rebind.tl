;; Refs #4054: named-function parameters are storage bindings that can be
;; rebound with set!, subject to the ordinary type/move/borrow rules.
(defstruct Big
  (a i64)
  (b i64)
  (c i64))

(define (scalar-param-score [n : i64]) : i64
  (begin
    (set! n (+ n 1))
    n))

(define (aggregate-param-score [value : Big] [seed : i64]) : i64
  (begin
    (set! value (Big seed (+ seed 1) (+ seed 2)))
    (struct-get value b)))

(define (main) : i64
  (+ (scalar-param-score 40) (aggregate-param-score (Big 9 9 9) 0)))