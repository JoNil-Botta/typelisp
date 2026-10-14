;; A direct tail call with a float argument, a permuted GP register prefix and
;; GP overflow read from the caller's parameter registers. The float used to
;; send the call down the sequential path, which wrote %rdi before moving the
;; caller's `b` out of it (System V) and stored %rcx after overwriting it
;; (Win64). Every GP value is distinct and every argument has its own weight.
(define (fin
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]
  [x : f64]) : i64
  (if (> a 0)
    (+
      (* 2 a)
      (+
        (* 3 b)
        (+
          (* 5 c)
          (+
            (* 7 d)
            (+ (* 11 e) (+ (* 13 f) (+ (* 17 g) (+ (* 19 h) (cast x : i64)))))))))
    (+ b c)))

(define (step
  [a : i64]
  [n : i64]
  [m : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]
  [x : f64]) : i64
  (if (>= n m)
    (fin b c d e a f g h x)
    (step a (+ n 1) m b c d e f g h x)))

;; fin(1, 2, 3, 4, 5, 6, 7, 8, 9.0)
;;   = 2 + 6 + 15 + 28 + 55 + 78 + 119 + 152 + 9 = 464
(define (main) : i64
  (- (step 5 0 3 1 2 3 4 6 7 8 9.0) 422))