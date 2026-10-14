;: A fixed array holding a reference derived from a reference parameter
;: carries the caller's lifetime back.
(define (make-ref-array [n : (& n i64)]) : (Array (& n i64) 1)
  (array n))

(define (use [n : i64]) : i64
  (let
    [items : (Array (& n i64) 1) (make-ref-array (& n))]
    (+ (deref (array-ref items 0)) 1)))

(define (main) : i64
  (use 41))