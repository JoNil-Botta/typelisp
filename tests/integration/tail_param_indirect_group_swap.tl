;; The hidden environment and a two-word argument leave the scalar swap intact.
(defstruct Pair
  (x i64)
  (y i64))

(define (finish [a : i64] [b : i64] [p : Pair]) : i64
  (if (> a 0)
    (+ (* 3 a) (+ b (+ p.x p.y)))
    0))

(define (step
  [callback : (-> i64 i64 Pair i64)]
  [a : i64]
  [b : i64]
  [p : Pair]
  [n : i64]
  [limit : i64]) : i64
  (if (>= n limit)
    (callback b a p)
    (step callback a b p (+ n 1) limit)))

(define (main) : i64
  (step finish 7 10 (Pair 2 3) 0 3))