;; An `f32` joined under an `f64` result is widened by an explicit cast (SPEC
;; 3.8 has no implicit conversions); the widened value is exact.
(define (branch [x : f32] [flag : bool]) : f64
  (if flag
    (cast x : f64)
    2.0))

(define (main) : i64
  (cast
    (+ (branch (cast 40.0 : f32) true) (branch (cast 1.0 : f32) false))
    : i64))