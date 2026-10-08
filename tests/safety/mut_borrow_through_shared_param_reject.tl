;: A `&mut` borrow cannot reach a referent through a shared reference: `r` is
;: mutable storage, but the `(& i64)` it holds is not (#8694).
(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (f [r : (& i64)]) : i64
  (bump (&mut r))
  (deref r))

(define (main) : i64
  (let
    [n : i64 40]
    (f (& n))))