;: A write through a mutable borrow conflicts with a live shared reference.
(define (bump [value : (&mut value i64)]) : unit
  (set! (deref value) (+ (deref value) 1)))

(define (run) : i64
  (let
    [n : i64 1]
    [shared : (& n i64) (& n)]
    (begin
      (bump (&mut n))
      (deref shared))))

(define (main) : i64
  0)