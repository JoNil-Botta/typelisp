;; No implicit numeric conversions (SPEC 3.8): an `f32` cannot stand for an
;; `f64`. Main accepted these and lowered the `f32` bits unconverted, so the
;; returned and joined values read as 0.
(define (ret [x : f32]) : f64
  x)

(define (branch [x : f32] [flag : bool]) : f64
  (if flag
    x
    2.0))

(define (main) : i64
  (cast (+ (ret (cast 40.0 : f32)) (branch (cast 1.0 : f32) false)) : i64))