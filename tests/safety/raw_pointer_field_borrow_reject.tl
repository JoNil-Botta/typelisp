(defstruct Point
  (x i64)
  (y i64))

(define (bump [r : (&mut i64)]) : unit
  (set! (deref r) (+ (deref r) 1)))

(define (bump-x [p : (MutPtr Point)]) : unit
  (unsafe
    (bump (&mut (deref p).x))))

(define (main) : i64
  0)