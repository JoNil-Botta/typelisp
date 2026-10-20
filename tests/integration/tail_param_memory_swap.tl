;; Memory-class transport must not hide a cycle between scalar parameter homes.
(defstruct Triple
  (x i64)
  (y i64)
  (z i64))

(define (finish [a : i64] [b : i64] [p : Triple]) : i64
  (if (> a 0)
    (+ (* 3 a) (+ b (+ p.x (+ p.y p.z))))
    0))

(define (step [a : i64] [b : i64] [n : i64] [limit : i64] [p : Triple]) : i64
  (if (>= n limit)
    (finish b a p)
    (step a b (+ n 1) limit p)))

(define (main) : i64
  (- (step 7 10 0 3 (Triple 2 3 5)) 5))