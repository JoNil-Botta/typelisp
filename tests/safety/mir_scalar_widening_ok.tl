;; An f32 body under an f64 result is widened by an explicit cast (SPEC 3.8
;; has no implicit conversions); nothing moves.
(define (half [x : f64]) : f64
  (cast (cast (/ x 2.0) : f32) : f64))

(define (main) : i64
  (cast (half 84.0) : i64))