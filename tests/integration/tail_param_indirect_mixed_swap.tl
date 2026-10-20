;; Probe: indirect tail call that swaps two GP parameters next to a float.
(define (g [a : i64] [b : i64] [x : f64]) : i64
  (if (> a 0)
    (+ (* 3 a) (+ b (cast x : i64)))
    (+ a b)))

(define (s
  [f : (-> i64 i64 f64 i64)]
  [a : i64]
  [b : i64]
  [n : i64]
  [m : i64]
  [x : f64]) : i64
  (if (>= n m)
    (f b a x)
    (s f a b (+ n 1) m x)))

;; g(10, 7, 5.0) = 42
(define (main) : i64
  (s g 7 10 0 3 5.0))