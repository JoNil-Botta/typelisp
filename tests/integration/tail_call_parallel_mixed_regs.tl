;; A register-only direct tail call that swaps two GP parameters next to a
;; float argument (#8892). With the float present the call used to take the
;; sequential path, which wrote %rdi before reading `a` out of it.
(define (g [a : i64] [b : i64] [x : f64]) : i64
  (if (> a 0)
    (+ (* 3 a) (+ b (cast x : i64)))
    (+ a b)))

(define (s [a : i64] [b : i64] [n : i64] [m : i64] [x : f64]) : i64
  (if (>= n m)
    (g b a x)
    (s a b (+ n 1) m x)))

;; g(10, 7, 5.0) = 30 + 7 + 5 = 42
(define (main) : i64
  (s 7 10 0 3 5.0))